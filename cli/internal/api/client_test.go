package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aurlaw/harbinger/cli/internal/export"
)

// testKey is built at runtime so no key-shaped literal lives in the repo.
var testKey = strings.Repeat("k", 32)

type recorded struct {
	method, path, query string
	header              http.Header
	body                []byte
}

// server serves handler and records every request.
type server struct {
	*httptest.Server
	mu   sync.Mutex
	reqs []recorded
}

func newServer(t *testing.T, handler http.HandlerFunc) (*server, *Client) {
	t.Helper()
	s := &server{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.reqs = append(s.reqs, recorded{r.Method, r.URL.Path, r.URL.RawQuery, r.Header.Clone(), body})
		s.mu.Unlock()
		handler(w, r)
	}))
	t.Cleanup(s.Close)
	c, err := NewClient(s.URL, testKey)
	if err != nil {
		t.Fatal(err)
	}
	c.sleep = func(context.Context, time.Duration) error { return nil }
	return s, c
}

func (s *server) requests() []recorded {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]recorded(nil), s.reqs...)
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	io.WriteString(w, body)
}

func errorBody(code, message string) string {
	b, _ := json.Marshal(map[string]any{"error": map[string]string{"code": code, "message": message}})
	return string(b)
}

func TestEveryRequestSendsHeaders(t *testing.T) {
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/library/films":
			if r.Method == http.MethodGet {
				writeJSON(w, 200, `{"films":[]}`)
			} else {
				writeJSON(w, 200, `{"inserted":0,"updated":0}`)
			}
		case "/library/films/matches":
			writeJSON(w, 200, `{"updated":0}`)
		case "/library/import":
			writeJSON(w, 200, `{"import_id":1,"ratings":0,"watched":0,"watchlist":0,"likes":0,"new_films":0}`)
		case "/library/films/override":
			writeJSON(w, 200, `{"letterboxd_uri":"https://boxd.it/a","name":"A","year":2000,"tmdb_id":null,"match_status":"pending","is_horror":null,"genre_override":null}`)
		case "/library/imports/latest":
			writeJSON(w, 404, errorBody("no_imports", "No imports yet"))
		case "/tmdb/search":
			writeJSON(w, 200, `{"page":1,"total_pages":0,"total_results":0,"results":[]}`)
		case "/tmdb/movie/1":
			writeJSON(w, 200, `{"tmdb_id":1,"is_horror":false}`)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			writeJSON(w, 404, errorBody("not_found", "Not found"))
		}
	})
	ctx := t.Context()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	_, err := c.ListFilms(ctx)
	must(err)
	_, err = c.UpsertFilms(ctx, []export.Film{{LetterboxdURI: "https://boxd.it/a", Name: "A", Year: 2000}})
	must(err)
	_, err = c.RecordMatches(ctx, []Match{Unresolved("https://boxd.it/a", StatusUnmatched)})
	must(err)
	_, err = c.Import(ctx, ImportRequest{SourceFilename: "x.zip"})
	must(err)
	_, err = c.SetOverride(ctx, "https://boxd.it/a", nil)
	must(err)
	row, err := c.LatestImport(ctx)
	must(err)
	if row != nil {
		t.Errorf("LatestImport on no_imports = %+v, want nil", row)
	}
	_, err = c.SearchTMDB(ctx, SearchQuery{Query: "x"})
	must(err)
	_, err = c.MovieTMDB(ctx, 1)
	must(err)

	reqs := s.requests()
	if len(reqs) != 8 {
		t.Fatalf("got %d requests, want 8", len(reqs))
	}
	for _, r := range reqs {
		if got := r.header.Get("Authorization"); got != "Bearer "+testKey {
			t.Errorf("%s %s: Authorization = %q", r.method, r.path, got)
		}
		if got := r.header.Get("Accept"); got != "application/json" {
			t.Errorf("%s %s: Accept = %q", r.method, r.path, got)
		}
		if got := r.header.Get("User-Agent"); got != "harbinger-cli" {
			t.Errorf("%s %s: User-Agent = %q", r.method, r.path, got)
		}
		wantCT := ""
		if len(r.body) > 0 {
			wantCT = "application/json"
		}
		if got := r.header.Get("Content-Type"); got != wantCT {
			t.Errorf("%s %s: Content-Type = %q, want %q", r.method, r.path, got, wantCT)
		}
	}
}

func TestErrorEnvelopeDecoded(t *testing.T) {
	_, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 422, errorBody("unknown_films", "Unknown Letterboxd URIs: https://boxd.it/x"))
	})
	_, err := c.RecordMatches(t.Context(), nil)
	apiErr, ok := err.(*APIError)
	if !ok {
		t.Fatalf("err = %T %v, want *APIError", err, err)
	}
	if apiErr.Status != 422 || apiErr.Code != "unknown_films" || apiErr.Message != "Unknown Letterboxd URIs: https://boxd.it/x" {
		t.Errorf("APIError = %+v", apiErr)
	}
}

func TestNonJSONErrorBody(t *testing.T) {
	_, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		io.WriteString(w, "<html>nope</html>")
	})
	_, err := c.ListFilms(t.Context())
	if !IsAPIError(err, 400, "") {
		t.Fatalf("err = %v", err)
	}
}

func TestRateLimitRetriedThenSucceeds(t *testing.T) {
	calls := 0
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 3 {
			w.Header().Set("Retry-After", "1")
			writeJSON(w, 503, errorBody("tmdb_rate_limited", "TMDB rate limit reached"))
			return
		}
		writeJSON(w, 200, `{"page":1,"total_pages":1,"total_results":0,"results":[]}`)
	})
	var waits []time.Duration
	c.sleep = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }
	if _, err := c.SearchTMDB(t.Context(), SearchQuery{Query: "x"}); err != nil {
		t.Fatal(err)
	}
	if n := len(s.requests()); n != 3 {
		t.Errorf("requests = %d, want 3", n)
	}
	if len(waits) != 2 || waits[0] != time.Second || waits[1] != time.Second {
		t.Errorf("waits = %v, want [1s 1s]", waits)
	}
}

func TestRateLimitGivesUpAfterThreeAttempts(t *testing.T) {
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 503, errorBody("tmdb_rate_limited", "TMDB rate limit reached"))
	})
	var waits []time.Duration
	c.sleep = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }
	_, err := c.MovieTMDB(t.Context(), 1)
	if !IsAPIError(err, 503, "tmdb_rate_limited") {
		t.Fatalf("err = %v", err)
	}
	if n := len(s.requests()); n != 3 {
		t.Errorf("requests = %d, want 3", n)
	}
	// No Retry-After → default 2 s.
	if len(waits) != 2 || waits[0] != 2*time.Second {
		t.Errorf("waits = %v, want [2s 2s]", waits)
	}
}

func TestTransientErrorsRetriedTwice(t *testing.T) {
	for _, status := range []int{502, 500, 503} {
		s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, status, errorBody("tmdb_unavailable", "TMDB is unavailable"))
		})
		var waits []time.Duration
		c.sleep = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }
		_, err := c.SearchTMDB(t.Context(), SearchQuery{Query: "x"})
		if !IsAPIError(err, status, "") {
			t.Fatalf("status %d: err = %v", status, err)
		}
		if n := len(s.requests()); n != 3 {
			t.Errorf("status %d: requests = %d, want 3 (1 + 2 retries)", status, n)
		}
		if len(waits) != 2 || waits[0] != time.Second || waits[1] != 2*time.Second {
			t.Errorf("status %d: waits = %v, want [1s 2s]", status, waits)
		}
	}
}

func TestTransientThenSuccess(t *testing.T) {
	calls := 0
	_, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			writeJSON(w, 502, errorBody("tmdb_unavailable", "x"))
			return
		}
		writeJSON(w, 200, `{"inserted":1,"updated":0}`)
	})
	res, err := c.UpsertFilms(t.Context(), nil)
	if err != nil || res.Inserted != 1 {
		t.Fatalf("res = %+v, err = %v", res, err)
	}
}

func TestNetworkErrorRetried(t *testing.T) {
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {})
	s.Close() // every attempt now fails to connect
	attempts := 0
	c.sleep = func(context.Context, time.Duration) error { attempts++; return nil }
	if _, err := c.ListFilms(t.Context()); err == nil {
		t.Fatal("ListFilms against a closed server succeeded")
	}
	if attempts != 2 {
		t.Errorf("retries = %d, want 2", attempts)
	}
}

func TestClientErrorsNeverRetried(t *testing.T) {
	for _, tc := range []struct {
		status int
		code   string
	}{{400, "invalid_request"}, {404, "not_found"}, {409, "empty_snapshot"}, {422, "unknown_films"}, {401, "unauthorized"}} {
		s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, tc.status, errorBody(tc.code, "nope"))
		})
		_, err := c.Import(t.Context(), ImportRequest{})
		if !IsAPIError(err, tc.status, tc.code) {
			t.Errorf("%d: err = %v", tc.status, err)
		}
		if n := len(s.requests()); n != 1 {
			t.Errorf("%d: requests = %d, want 1", tc.status, n)
		}
	}
}

func TestUnresolvedMatchOmitsTMDBFields(t *testing.T) {
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, `{"updated":2}`) })
	matches := []Match{Unresolved("https://boxd.it/a", StatusAmbiguous), Unresolved("https://boxd.it/b", StatusUnmatched)}
	if _, err := c.RecordMatches(t.Context(), matches); err != nil {
		t.Fatal(err)
	}
	var sent struct {
		Matches []map[string]json.RawMessage `json:"matches"`
	}
	if err := json.Unmarshal(s.requests()[0].body, &sent); err != nil {
		t.Fatal(err)
	}
	for _, m := range sent.Matches {
		for _, k := range []string{"tmdb_id", "is_horror", "tmdb_json"} {
			if _, ok := m[k]; ok {
				t.Errorf("unresolved match has %q: %s", k, s.requests()[0].body)
			}
		}
		if len(m) != 2 {
			t.Errorf("match keys = %v, want letterboxd_uri + match_status", m)
		}
	}
}

func TestTMDBJSONSentByteForByte(t *testing.T) {
	// Compact, as the Worker's JSON.stringify produces; includes characters
	// encoding/json would HTML-escape by default.
	movie := `{"tmdb_id":42,"title":"Rock & Rule <1983>","original_title":"Låt den rätte komma in – ’79","release_date":null,"genres":[{"id":27,"name":"Horror"}],"is_horror":true,"runtime":null,"overview":"a > b && c","poster_path":null}`
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/tmdb/movie/42" {
			writeJSON(w, 200, movie)
			return
		}
		writeJSON(w, 200, `{"updated":1}`)
	})
	raw, err := c.MovieTMDB(t.Context(), 42)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != movie {
		t.Fatalf("MovieTMDB = %s", raw)
	}
	horror, err := MovieIsHorror(raw)
	if err != nil || !horror {
		t.Fatalf("MovieIsHorror = %v, %v", horror, err)
	}
	if _, err := c.RecordMatches(t.Context(), []Match{Matched("https://boxd.it/a", 42, horror, raw)}); err != nil {
		t.Fatal(err)
	}
	body := string(s.requests()[1].body)
	if !strings.Contains(body, `"tmdb_json":`+movie) {
		t.Errorf("tmdb_json not sent verbatim:\n%s", body)
	}
	if !strings.Contains(body, `"tmdb_id":42,"is_horror":1`) {
		t.Errorf("matched fields missing: %s", body)
	}
}

func TestSearchParamsOnlyWhenSet(t *testing.T) {
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"page":1,"total_pages":0,"total_results":0,"results":[]}`)
	})
	ctx := t.Context()
	c.SearchTMDB(ctx, SearchQuery{Query: "Rock & Rule? – x", PrimaryReleaseYear: 1983})
	c.SearchTMDB(ctx, SearchQuery{Query: "A", Year: 2001, Page: 2})
	reqs := s.requests()
	if got := reqs[0].query; got != "primary_release_year=1983&query=Rock+%26+Rule%3F+%E2%80%93+x" {
		t.Errorf("query 1 = %s", got)
	}
	if got := reqs[1].query; got != "page=2&query=A&year=2001" {
		t.Errorf("query 2 = %s", got)
	}
}

func TestKeyNeverInErrors(t *testing.T) {
	// API errors, and network errors against a closed server, must not mention the key.
	s, c := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 400, errorBody("invalid_request", "bad"))
	})
	var errs []error
	_, err := c.ListFilms(t.Context())
	errs = append(errs, err)
	_, err = c.MovieTMDB(t.Context(), 7)
	errs = append(errs, err)
	s.Close()
	c.sleep = func(context.Context, time.Duration) error { return nil }
	_, err = c.SearchTMDB(t.Context(), SearchQuery{Query: "x"})
	errs = append(errs, err)
	for _, err := range errs {
		if err == nil {
			t.Fatal("expected an error")
		}
		if strings.Contains(err.Error(), testKey) {
			t.Errorf("error contains the API key: %v", err)
		}
	}
}

func TestBaseURLWithPath(t *testing.T) {
	s, _ := newServer(t, func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, `{"films":[]}`) })
	c, err := NewClient(s.URL+"/prefix/", testKey)
	if err != nil {
		t.Fatal(err)
	}
	c.ListFilms(t.Context())
	if got := s.requests()[0].path; got != "/prefix/library/films" {
		t.Errorf("path = %s", got)
	}
	for _, bad := range []string{"", "harbinger-api.aurlaw.dev", "ftp://x", "https://"} {
		if _, err := NewClient(bad, testKey); err == nil {
			t.Errorf("NewClient(%q) succeeded", bad)
		}
	}
}

func TestEffectiveHorror(t *testing.T) {
	one, zero := 1, 0
	inc, exc := OverrideInclude, OverrideExclude
	cases := []struct {
		f    LibraryFilm
		want bool
	}{
		{LibraryFilm{IsHorror: &one}, true},
		{LibraryFilm{IsHorror: &zero}, false},
		{LibraryFilm{}, false},
		{LibraryFilm{IsHorror: &zero, GenreOverride: &inc}, true},
		{LibraryFilm{IsHorror: &one, GenreOverride: &exc}, false},
		{LibraryFilm{GenreOverride: &inc}, true},
	}
	for i, tc := range cases {
		if got := tc.f.EffectiveHorror(); got != tc.want {
			t.Errorf("case %d: EffectiveHorror = %v, want %v", i, got, tc.want)
		}
	}
}
