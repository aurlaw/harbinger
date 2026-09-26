package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/aurlaw/harbinger/cli/internal/api"
)

// testKey is built at runtime so no key-shaped literal lives in the repo.
var testKey = strings.Repeat("k", 32)

// runEnv runs the CLI with only env visible, a non-terminal empty stdin.
func runEnv(env map[string]string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	code = runWith(args, deps{
		stdin:      strings.NewReader(""),
		stdout:     &out,
		stderr:     &errOut,
		getenv:     func(k string) string { return env[k] },
		isTerminal: func() bool { return false },
	})
	return code, out.String(), errOut.String()
}

// fakeServer is an HTTP stand-in for the Worker, used through the real client.
type fakeServer struct {
	*httptest.Server
	mu        sync.Mutex
	films     []api.LibraryFilm
	overrides []string // raw PUT bodies
	paths     []string
	badAuth   int
}

func newFakeServer(t *testing.T, films ...api.LibraryFilm) (*fakeServer, map[string]string) {
	t.Helper()
	f := &fakeServer{films: films}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.Close)
	return f, map[string]string{envAPIKey: testKey, envAPIURL: f.URL}
}

func reply(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

func envelope(code, msg string) map[string]any {
	return map[string]any{"error": map[string]string{"code": code, "message": msg}}
}

func (f *fakeServer) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.paths = append(f.paths, r.Method+" "+r.URL.Path)
	if r.Header.Get("Authorization") != "Bearer "+testKey {
		f.badAuth++
		reply(w, 401, envelope("unauthorized", "Missing or invalid API key"))
		return
	}
	body, _ := io.ReadAll(r.Body)

	switch r.Method + " " + r.URL.Path {
	case "GET /library/films":
		reply(w, 200, map[string]any{"films": f.films})
	case "POST /library/films":
		var req struct{ Films []api.LibraryFilm }
		json.Unmarshal(body, &req)
		for _, in := range req.Films {
			if f.find(in.LetterboxdURI) == nil {
				in.MatchStatus = api.StatusPending
				f.films = append(f.films, in)
			}
		}
		reply(w, 200, map[string]int{"inserted": len(req.Films), "updated": 0})
	case "POST /library/import":
		var req api.ImportRequest
		json.Unmarshal(body, &req)
		reply(w, 200, api.ImportResult{ImportID: 7, Ratings: len(req.Ratings), Watched: len(req.Watched),
			Watchlist: len(req.Watchlist), Likes: len(req.Likes), NewFilms: 2})
	case "POST /library/films/matches":
		var req struct{ Matches []api.Match }
		json.Unmarshal(body, &req)
		for _, m := range req.Matches {
			film := f.find(m.LetterboxdURI)
			film.MatchStatus, film.TMDBID, film.IsHorror = m.MatchStatus, m.TMDBID, m.IsHorror
		}
		reply(w, 200, map[string]int{"updated": len(req.Matches)})
	case "GET /tmdb/search":
		var results []map[string]any
		if q := r.URL.Query().Get("query"); q == "The Witch" {
			results = append(results, map[string]any{"tmdb_id": 310131, "title": "The Witch", "original_title": "The Witch",
				"release_date": "2015-01-27", "genre_ids": []int{27}, "overview": "", "popularity": 1.0, "poster_path": nil})
		}
		reply(w, 200, map[string]any{"page": 1, "total_pages": 1, "total_results": len(results), "results": results})
	case "GET /tmdb/movie/310131":
		reply(w, 200, map[string]any{"tmdb_id": 310131, "title": "The Witch", "is_horror": true})
	case "PUT /library/films/override":
		f.overrides = append(f.overrides, string(bytes.TrimSpace(body)))
		var req struct {
			LetterboxdURI string  `json:"letterboxd_uri"`
			GenreOverride *string `json:"genre_override"`
		}
		json.Unmarshal(body, &req)
		film := f.find(req.LetterboxdURI)
		if film == nil {
			reply(w, 404, envelope("not_found", "Unknown Letterboxd URI: "+req.LetterboxdURI))
			return
		}
		film.GenreOverride = req.GenreOverride
		reply(w, 200, film)
	default:
		reply(w, 404, envelope("not_found", "Not found"))
	}
}

func (f *fakeServer) find(uri string) *api.LibraryFilm {
	for i := range f.films {
		if f.films[i].LetterboxdURI == uri {
			return &f.films[i]
		}
	}
	return nil
}

func libFilm(uri, name string, year int, status string, horror *int, override *string) api.LibraryFilm {
	return api.LibraryFilm{LetterboxdURI: uri, Name: name, Year: year, MatchStatus: status, IsHorror: horror, GenreOverride: override}
}

func intPtr(n int) *int { return &n }

var library = []api.LibraryFilm{
	libFilm("https://boxd.it/w", "The Witch", 2015, api.StatusMatched, intPtr(1), nil),
	libFilm("https://boxd.it/j", "Jack Reacher", 2012, api.StatusMatched, intPtr(0), nil),
	libFilm("https://boxd.it/a", "Alien", 1979, api.StatusMatched, intPtr(0), ptr(api.OverrideInclude)),
	libFilm("https://boxd.it/h", "Hereditary", 2018, api.StatusMatched, intPtr(1), ptr(api.OverrideExclude)),
	libFilm("https://boxd.it/t", "The Thing", 1982, api.StatusAmbiguous, nil, nil),
	libFilm("https://boxd.it/n", "Nowhere", 2001, api.StatusUnmatched, nil, nil),
	libFilm("https://boxd.it/p", "Pending Film", 2020, api.StatusPending, nil, nil),
}

func TestFilmsListsSortedByName(t *testing.T) {
	_, env := newFakeServer(t, library...)
	code, out, errOut := runEnv(env, "films")
	if code != exitOK || errOut != "" {
		t.Fatalf("exit %d, stderr %q", code, errOut)
	}
	want := strings.Join([]string{
		"H  Alien (1979)  matched  override:include  https://boxd.it/a",
		"-  Hereditary (2018)  matched  override:exclude  https://boxd.it/h",
		"-  Jack Reacher (2012)  matched  https://boxd.it/j",
		"-  Nowhere (2001)  unmatched  https://boxd.it/n",
		"-  Pending Film (2020)  pending  https://boxd.it/p",
		"-  The Thing (1982)  ambiguous  https://boxd.it/t",
		"H  The Witch (2015)  matched  https://boxd.it/w",
	}, "\n") + "\n"
	if out != want {
		t.Errorf("films:\n%s\nwant:\n%s", out, want)
	}
}

func filmURIs(out string) []string {
	var uris []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line != "" {
			uris = append(uris, line[strings.LastIndex(line, " ")+1:])
		}
	}
	return uris
}

func TestFilmsFilters(t *testing.T) {
	_, env := newFakeServer(t, library...)
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"--status", "matched"}, "a h j w"},
		{[]string{"--status", "ambiguous"}, "t"},
		{[]string{"--horror"}, "a w"},
		{[]string{"--not-horror"}, "h j n p t"},
		{[]string{"--search", "THE"}, "t w"},
		{[]string{"--search", "  the   witch "}, "w"},
		{[]string{"--status", "matched", "--horror", "--search", "a"}, "a"},
		{[]string{"--status", "pending", "--horror"}, ""},
	}
	for _, tc := range cases {
		code, out, errOut := runEnv(env, append([]string{"films"}, tc.args...)...)
		if code != exitOK {
			t.Fatalf("%v: exit %d, stderr %q", tc.args, code, errOut)
		}
		var got []string
		for _, u := range filmURIs(out) {
			got = append(got, strings.TrimPrefix(u, "https://boxd.it/"))
		}
		if strings.Join(got, " ") != tc.want {
			t.Errorf("%v: got %v, want %s", tc.args, got, tc.want)
		}
	}
}

func TestFilmsUsageErrors(t *testing.T) {
	srv, env := newFakeServer(t, library...)
	for _, args := range [][]string{
		{"films", "--horror", "--not-horror"},
		{"films", "--status", "bogus"},
		{"films", "extra"},
		{"films", "--nope"},
	} {
		code, out, errOut := runEnv(env, args...)
		if code != exitUsage || out != "" || !strings.Contains(errOut, "usage:") {
			t.Errorf("%v: exit %d, stdout %q, stderr %q", args, code, out, errOut)
		}
	}
	if len(srv.paths) != 0 {
		t.Errorf("usage errors reached the Worker: %v", srv.paths)
	}
}

func TestOverride(t *testing.T) {
	srv, env := newFakeServer(t, library...)
	cases := []struct {
		action, uri, body, line string
	}{
		{"include", "https://boxd.it/j", `{"genre_override":"include","letterboxd_uri":"https://boxd.it/j"}`,
			"H  Jack Reacher (2012)  matched  override:include  https://boxd.it/j"},
		{"exclude", "https://boxd.it/w", `{"genre_override":"exclude","letterboxd_uri":"https://boxd.it/w"}`,
			"-  The Witch (2015)  matched  override:exclude  https://boxd.it/w"},
		{"clear", "https://boxd.it/w", `{"genre_override":null,"letterboxd_uri":"https://boxd.it/w"}`,
			"H  The Witch (2015)  matched  https://boxd.it/w"},
	}
	for i, tc := range cases {
		code, out, errOut := runEnv(env, "override", tc.action, tc.uri)
		if code != exitOK || errOut != "" {
			t.Fatalf("%s: exit %d, stderr %q", tc.action, code, errOut)
		}
		if srv.overrides[i] != tc.body {
			t.Errorf("%s: body = %s, want %s", tc.action, srv.overrides[i], tc.body)
		}
		if out != tc.line+"\n" {
			t.Errorf("%s: output = %q, want %q", tc.action, out, tc.line)
		}
	}
}

func TestOverrideUnknownURI(t *testing.T) {
	_, env := newFakeServer(t, library...)
	code, out, errOut := runEnv(env, "override", "include", "https://boxd.it/zzz")
	if code != exitError || out != "" || errOut != "no film with URI https://boxd.it/zzz\n" {
		t.Errorf("exit %d, stdout %q, stderr %q", code, out, errOut)
	}
}

func TestOverrideUsageErrors(t *testing.T) {
	srv, env := newFakeServer(t, library...)
	for _, args := range [][]string{
		{"override"},
		{"override", "include"},
		{"override", "remove", "https://boxd.it/w"},
		{"override", "include", "https://boxd.it/w", "extra"},
	} {
		if code, _, errOut := runEnv(env, args...); code != exitUsage || !strings.Contains(errOut, "usage:") {
			t.Errorf("%v: exit %d, stderr %q", args, code, errOut)
		}
	}
	if len(srv.paths) != 0 {
		t.Errorf("usage errors reached the Worker: %v", srv.paths)
	}
}

func TestMissingAPIKey(t *testing.T) {
	zip := writeZip(t, validFiles)
	for _, args := range [][]string{
		{"import", zip},
		{"import", "--no-interactive", zip},
		{"films"},
		{"override", "clear", "https://boxd.it/w"},
	} {
		for _, env := range []map[string]string{nil, {envAPIKey: ""}} {
			code, out, errOut := runEnv(env, args...)
			if code != exitError || out != "" || errOut != "HARBINGER_API_KEY is not set\n" {
				t.Errorf("%v: exit %d, stdout %q, stderr %q", args, code, out, errOut)
			}
		}
	}
	if code, out, _ := runEnv(nil, "import", "--dry-run", zip); code != exitOK || !strings.Contains(out, "unique films") {
		t.Errorf("dry-run without key: exit %d", code)
	}
	if code, out, _ := runEnv(nil, "import", "--dry-run", "--json", zip); code != exitOK || !json.Valid([]byte(out)) {
		t.Errorf("dry-run --json without key: exit %d", code)
	}
}

func TestJSONRequiresDryRun(t *testing.T) {
	_, env := newFakeServer(t)
	code, _, errOut := runEnv(env, "import", "--json", writeZip(t, validFiles))
	if code != exitUsage || !strings.Contains(errOut, "--json requires --dry-run") {
		t.Errorf("exit %d, stderr %q", code, errOut)
	}
}

func TestInvalidAPIURL(t *testing.T) {
	code, _, errOut := runEnv(map[string]string{envAPIKey: testKey, envAPIURL: "not a url"}, "films")
	if code != exitError || !strings.Contains(errOut, "HARBINGER_API_URL") || strings.Contains(errOut, testKey) {
		t.Errorf("exit %d, stderr %q", code, errOut)
	}
}

func TestLiveImportEndToEnd(t *testing.T) {
	srv, env := newFakeServer(t)
	files := map[string]string{
		"ratings.csv":     ratingsHdr + "\r\n2021-03-11,The Witch,2015,https://boxd.it/w,4\r\n2021-03-12,Nowhere,2001,https://boxd.it/n,2\r\n",
		"watched.csv":     baseHdr + "\r\n",
		"watchlist.csv":   baseHdr + "\r\n",
		"likes/films.csv": baseHdr + "\r\n",
	}
	code, out, errOut := runEnv(env, "import", writeZip(t, files))
	if code != exitOK || errOut != "" {
		t.Fatalf("exit %d, stderr %q\n%s", code, errOut, out)
	}
	for _, want := range []string{
		"[1/2] Nowhere (2001) … unmatched", // stdin isn't a terminal → no prompt
		"[2/2] The Witch (2015) … matched",
		"Import #7 from letterboxd-test.zip",
		"  snapshot   ratings 2 · watched 0 · watchlist 0 · likes 0 · new films 2",
		"  matching   2 attempted · 1 auto · 0 chosen · 0 ambiguous · 1 unmatched · 0 left pending",
		"  library    2 films · 1 horror · 0 ambiguous · 1 unmatched",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
	if srv.badAuth != 0 {
		t.Errorf("%d requests without the bearer key", srv.badAuth)
	}
	if strings.Contains(out+errOut, testKey) {
		t.Error("API key printed")
	}
	if srv.paths[0] != "POST /library/films" || srv.paths[1] != "POST /library/import" {
		t.Errorf("request order = %v", srv.paths)
	}
}

func TestLiveImportWorkerRejectsKey(t *testing.T) {
	_, env := newFakeServer(t)
	env[envAPIKey] = strings.Repeat("x", 32)
	code, out, errOut := runEnv(env, "import", writeZip(t, validFiles))
	if code != exitError || !strings.Contains(errOut, "401 unauthorized") {
		t.Errorf("exit %d, stdout %q, stderr %q", code, out, errOut)
	}
	if strings.Contains(out+errOut, env[envAPIKey]) {
		t.Error("API key printed")
	}
}
