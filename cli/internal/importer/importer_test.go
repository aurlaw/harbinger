package importer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"testing"

	"github.com/aurlaw/harbinger/cli/internal/api"
	"github.com/aurlaw/harbinger/cli/internal/export"
	"github.com/aurlaw/harbinger/cli/internal/match"
	"github.com/aurlaw/harbinger/cli/internal/normalize"
	"github.com/aurlaw/harbinger/cli/internal/prompt"
)

// fakeWorker is an in-memory Worker with a tiny TMDB catalog.
type fakeWorker struct {
	films      map[string]*api.LibraryFilm
	catalog    []api.SearchResult
	failSearch map[string]bool // normalized titles whose searches fail
	importErr  error

	calls        []string // endpoint log, in order
	searchCalls  int
	movieCalls   int
	matchBatches [][]api.Match
	imports      []api.ImportRequest
	nextImportID int
}

func newFake() *fakeWorker {
	return &fakeWorker{films: map[string]*api.LibraryFilm{}, failSearch: map[string]bool{}}
}

func (f *fakeWorker) addMovie(id int, title, date string, horror bool) {
	r := api.SearchResult{TMDBID: id, Title: title, OriginalTitle: title, ReleaseDate: &date}
	if horror {
		r.GenreIDs = []int{api.HorrorGenreID}
	}
	f.catalog = append(f.catalog, r)
}

func (f *fakeWorker) ListFilms(context.Context) ([]api.LibraryFilm, error) {
	f.calls = append(f.calls, "list")
	var out []api.LibraryFilm
	for _, uri := range slices.Sorted(maps.Keys(f.films)) {
		out = append(out, *f.films[uri])
	}
	return out, nil
}

func (f *fakeWorker) UpsertFilms(_ context.Context, films []export.Film) (api.UpsertResult, error) {
	f.calls = append(f.calls, "upsert")
	var res api.UpsertResult
	for _, film := range films {
		if existing, ok := f.films[film.LetterboxdURI]; ok {
			existing.Name, existing.Year = film.Name, film.Year
			continue
		}
		f.films[film.LetterboxdURI] = &api.LibraryFilm{
			LetterboxdURI: film.LetterboxdURI, Name: film.Name, Year: film.Year, MatchStatus: api.StatusPending,
		}
		res.Inserted++
	}
	return res, nil
}

func (f *fakeWorker) RecordMatches(_ context.Context, matches []api.Match) (int, error) {
	f.calls = append(f.calls, "matches")
	f.matchBatches = append(f.matchBatches, slices.Clone(matches))
	for _, m := range matches {
		film := f.films[m.LetterboxdURI]
		film.MatchStatus, film.TMDBID, film.IsHorror = m.MatchStatus, m.TMDBID, m.IsHorror
	}
	return len(matches), nil
}

func (f *fakeWorker) Import(_ context.Context, req api.ImportRequest) (api.ImportResult, error) {
	f.calls = append(f.calls, "import")
	f.imports = append(f.imports, req)
	if f.importErr != nil {
		return api.ImportResult{}, f.importErr
	}
	f.nextImportID++
	return api.ImportResult{ImportID: f.nextImportID, Ratings: len(req.Ratings), Watched: len(req.Watched),
		Watchlist: len(req.Watchlist), Likes: len(req.Likes)}, nil
}

func (f *fakeWorker) SetOverride(context.Context, string, *string) (api.LibraryFilm, error) {
	panic("not used")
}

func (f *fakeWorker) LatestImport(context.Context) (*api.ImportRow, error) { panic("not used") }

// SearchTMDB matches the query exactly (normalized) and filters by year like TMDB.
func (f *fakeWorker) SearchTMDB(_ context.Context, q api.SearchQuery) (api.SearchPage, error) {
	f.calls = append(f.calls, "search")
	f.searchCalls++
	key := normalize.Title(q.Query)
	if f.failSearch[key] {
		return api.SearchPage{}, &api.APIError{Status: 502, Code: "tmdb_unavailable", Message: "TMDB is unavailable"}
	}
	var results []api.SearchResult
	for _, r := range f.catalog {
		y, _ := match.ReleaseYear(r)
		if normalize.Title(r.Title) != key {
			continue
		}
		if (q.PrimaryReleaseYear != 0 && y != q.PrimaryReleaseYear) || (q.Year != 0 && y != q.Year) {
			continue
		}
		results = append(results, r)
	}
	return api.SearchPage{Page: 1, TotalPages: 1, TotalResults: len(results), Results: results}, nil
}

func (f *fakeWorker) MovieTMDB(_ context.Context, id int) (json.RawMessage, error) {
	f.calls = append(f.calls, "movie")
	f.movieCalls++
	for _, r := range f.catalog {
		if r.TMDBID == id {
			return movieBody(r), nil
		}
	}
	return nil, &api.APIError{Status: 404, Code: "not_found", Message: "Not found"}
}

func movieBody(r api.SearchResult) json.RawMessage {
	b, _ := json.Marshal(map[string]any{"tmdb_id": r.TMDBID, "title": r.Title, "is_horror": r.IsHorror()})
	return b
}

// scripted answers prompts from a fixed list and records what it was asked.
type scripted struct {
	answers []prompt.Decision
	asked   []string
}

func (s *scripted) Ask(_ context.Context, name string, year int, cands []api.SearchResult) (prompt.Decision, error) {
	s.asked = append(s.asked, fmt.Sprintf("%s (%d) %d candidates", name, year, len(cands)))
	if len(s.answers) == 0 {
		return prompt.Decision{}, errors.New("unexpected prompt")
	}
	d := s.answers[0]
	s.answers = s.answers[1:]
	return d, nil
}

func uri(n int) string { return fmt.Sprintf("https://boxd.it/f%03d", n) }

// exportOf builds an export whose films are all rated.
func exportOf(films ...export.Film) *export.Export {
	ex := &export.Export{Films: films, Watched: []export.Watched{}, Watchlist: []export.WatchlistEntry{}, Likes: []export.Like{}}
	for _, f := range films {
		ex.Ratings = append(ex.Ratings, export.Rating{LetterboxdURI: f.LetterboxdURI, HalfStars: 8, RatedOn: "2021-01-01"})
	}
	return ex
}

func film(n int, name string, year int) export.Film {
	return export.Film{LetterboxdURI: uri(n), Name: name, Year: year}
}

func run(t *testing.T, w api.Worker, ex *export.Export, opts Options) (*Summary, string) {
	t.Helper()
	var out bytes.Buffer
	opts.Out = &out
	if opts.SourceFilename == "" {
		opts.SourceFilename = "letterboxd-test.zip"
	}
	sum, err := Run(t.Context(), w, ex, opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	sum.Print(&out)
	return sum, out.String()
}

func allMatches(f *fakeWorker) []api.Match { return flatten(f.matchBatches) }

func flatten(batches [][]api.Match) []api.Match {
	var all []api.Match
	for _, b := range batches {
		all = append(all, b...)
	}
	return all
}

// standard library: an auto match, a tie needing a decision, and one with no results.
func standard() (*fakeWorker, *export.Export) {
	w := newFake()
	w.addMovie(310131, "The Witch", "2015-01-27", true)
	w.addMovie(1091, "The Thing", "1982-06-25", true)
	w.addMovie(1092, "The Thing", "1982-11-01", false)
	ex := exportOf(film(1, "The Witch", 2015), film(2, "The Thing", 1982), film(3, "Nowhere Film", 2001))
	return w, ex
}

func TestFirstImport(t *testing.T) {
	w, ex := standard()
	d := &scripted{answers: []prompt.Decision{
		{Action: prompt.Choose, Candidate: w.catalog[1]},
		{Action: prompt.Skip},
	}}
	sum, out := run(t, w, ex, Options{Decider: d})

	// Order: upsert → import → list → matching → record → final list.
	if got := strings.Join(w.calls[:3], ","); got != "upsert,import,list" {
		t.Errorf("first calls = %s", got)
	}
	if w.calls[len(w.calls)-1] != "list" || w.calls[len(w.calls)-2] != "matches" {
		t.Errorf("last calls = %v", w.calls)
	}

	byURI := map[string]api.Match{}
	for _, m := range allMatches(w) {
		byURI[m.LetterboxdURI] = m
	}
	if m := byURI[uri(1)]; m.MatchStatus != api.StatusMatched || *m.TMDBID != 310131 || *m.IsHorror != 1 {
		t.Errorf("witch = %+v", m)
	}
	if m := byURI[uri(2)]; m.MatchStatus != api.StatusMatched || *m.TMDBID != 1091 || !bytes.Equal(m.TMDBJSON, movieBody(w.catalog[1])) {
		t.Errorf("thing = %+v", m)
	}
	if m := byURI[uri(3)]; m.MatchStatus != api.StatusUnmatched || m.TMDBID != nil || m.TMDBJSON != nil {
		t.Errorf("nowhere = %+v", m)
	}
	if len(d.asked) != 2 || d.asked[0] != "The Thing (1982) 2 candidates" || d.asked[1] != "Nowhere Film (2001) 0 candidates" {
		t.Errorf("asked = %v", d.asked)
	}

	if sum.Attempted != 3 || sum.Auto != 1 || sum.Chosen != 1 || sum.Unmatched != 1 || sum.Ambiguous != 0 || sum.Pending != 0 {
		t.Errorf("summary = %+v", sum)
	}
	for _, want := range []string{
		"[1/3] The Witch (2015) … matched",
		"[2/3] The Thing (1982) … needs a decision",
		"Import #1 from letterboxd-test.zip",
		"  snapshot   ratings 3 · watched 0 · watchlist 0 · likes 0 · new films 0",
		"  matching   3 attempted · 1 auto · 1 chosen · 0 ambiguous · 1 unmatched · 0 left pending",
		"  library    3 films · 2 horror · 0 ambiguous · 1 unmatched",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestSecondImportMakesNoTMDBCalls(t *testing.T) {
	w, ex := standard()
	run(t, w, ex, Options{}) // non-interactive first run resolves everything
	searches, movies, batches := w.searchCalls, w.movieCalls, len(w.matchBatches)

	sum, out := run(t, w, ex, Options{Decider: &scripted{}})
	if w.searchCalls != searches || w.movieCalls != movies || len(w.matchBatches) != batches {
		t.Errorf("second import made TMDB/match calls: search %d→%d, movie %d→%d, batches %d→%d",
			searches, w.searchCalls, movies, w.movieCalls, batches, len(w.matchBatches))
	}
	if sum.Attempted != 0 || !strings.Contains(out, "  matching   nothing to match") {
		t.Errorf("summary = %+v\n%s", sum, out)
	}
	if !strings.Contains(out, "Import #2") {
		t.Errorf("output:\n%s", out)
	}
}

func TestSecondImportWithNewFilms(t *testing.T) {
	w, ex := standard()
	run(t, w, ex, Options{})
	w.addMovie(493922, "Hereditary", "2018-06-07", true)
	w.addMovie(348, "Alien", "1979-05-25", true)
	batches := len(w.matchBatches)

	ex2 := exportOf(append(slices.Clone(ex.Films), film(4, "Hereditary", 2018), film(5, "Alien", 1979))...)
	sum, _ := run(t, w, ex2, Options{})
	newMatches := flatten(w.matchBatches[batches:])
	var uris []string
	for _, m := range newMatches {
		uris = append(uris, m.LetterboxdURI)
	}
	slices.Sort(uris)
	if !slices.Equal(uris, []string{uri(4), uri(5)}) || sum.Attempted != 2 || sum.Auto != 2 {
		t.Errorf("matched %v, summary %+v", uris, sum)
	}
}

func TestQuitAfterThreeFilms(t *testing.T) {
	w := newFake()
	var films []export.Film
	for i := range 6 {
		// Two same-year candidates each → every film needs a decision.
		title := fmt.Sprintf("Twin %d", i)
		w.addMovie(1000+2*i, title, "2000-01-01", true)
		w.addMovie(1001+2*i, title, "2000-06-01", false)
		films = append(films, film(i, title, 2000))
	}
	d := &scripted{answers: []prompt.Decision{
		{Action: prompt.Choose, Candidate: w.catalog[0]},
		{Action: prompt.Manual, TMDBID: 1003, Movie: movieBody(w.catalog[3])},
		{Action: prompt.Skip},
		{Action: prompt.Quit},
	}}
	sum, out := run(t, w, exportOf(films...), Options{Decider: d})

	if len(w.imports) != 1 {
		t.Fatal("snapshot not applied")
	}
	got := allMatches(w)
	if len(got) != 3 || got[0].MatchStatus != api.StatusMatched || *got[1].TMDBID != 1003 || got[2].MatchStatus != api.StatusAmbiguous {
		t.Fatalf("recorded = %+v", got)
	}
	pending := 0
	for _, f := range w.films {
		if f.MatchStatus == api.StatusPending {
			pending++
		}
	}
	if pending != 3 || !sum.Quit || sum.Pending != 3 || sum.Chosen != 2 || sum.Ambiguous != 1 {
		t.Errorf("pending = %d, summary = %+v", pending, sum)
	}
	if !strings.Contains(out, "6 attempted · 0 auto · 2 chosen · 1 ambiguous · 0 unmatched · 3 left pending") {
		t.Errorf("output:\n%s", out)
	}
}

func TestMatchesPostedInBatches(t *testing.T) {
	w := newFake()
	var films []export.Film
	for i := range 60 {
		title := fmt.Sprintf("Film %d", i)
		w.addMovie(i+1, title, "1990-01-01", i%2 == 0)
		films = append(films, film(i, title, 1990))
	}
	sum, _ := run(t, w, exportOf(films...), Options{})
	var sizes []int
	for _, b := range w.matchBatches {
		sizes = append(sizes, len(b))
	}
	if !slices.Equal(sizes, []int{25, 25, 10}) || sum.Auto != 60 {
		t.Errorf("batch sizes = %v, auto = %d", sizes, sum.Auto)
	}
	if sum.Library.Horror != 30 {
		t.Errorf("horror = %d", sum.Library.Horror)
	}
}

func TestEmptySnapshot(t *testing.T) {
	w, ex := standard()
	w.importErr = &api.APIError{Status: 409, Code: "empty_snapshot", Message: "Import would empty tables that currently have rows: likes."}
	_, err := Run(t.Context(), w, ex, Options{SourceFilename: "x.zip"})
	var es *EmptySnapshotError
	if !errors.As(err, &es) {
		t.Fatalf("err = %v", err)
	}
	if !strings.Contains(err.Error(), "likes") || !strings.Contains(err.Error(), "re-run with --force if this is intentional") {
		t.Errorf("message = %q", err)
	}
	if w.searchCalls != 0 || w.movieCalls != 0 || len(w.matchBatches) != 0 {
		t.Errorf("matching ran after 409")
	}
}

func TestOtherImportErrorIsFatal(t *testing.T) {
	w, ex := standard()
	w.importErr = &api.APIError{Status: 422, Code: "unknown_films", Message: "Unknown"}
	_, err := Run(t.Context(), w, ex, Options{})
	var es *EmptySnapshotError
	if err == nil || errors.As(err, &es) || w.searchCalls != 0 {
		t.Errorf("err = %v", err)
	}
}

func TestForceSent(t *testing.T) {
	w, ex := standard()
	run(t, w, ex, Options{Force: true, SourceFilename: "letterboxd-aurlaw.zip"})
	if !w.imports[0].Force || w.imports[0].SourceFilename != "letterboxd-aurlaw.zip" {
		t.Errorf("import request = %+v", w.imports[0])
	}
	run(t, w, ex, Options{})
	if w.imports[1].Force {
		t.Error("force sent without --force")
	}
}

func TestNonInteractive(t *testing.T) {
	w, ex := standard()
	sum, _ := run(t, w, ex, Options{})
	byURI := map[string]string{}
	for _, m := range allMatches(w) {
		byURI[m.LetterboxdURI] = m.MatchStatus
	}
	if byURI[uri(1)] != api.StatusMatched || byURI[uri(2)] != api.StatusAmbiguous || byURI[uri(3)] != api.StatusUnmatched {
		t.Errorf("statuses = %v", byURI)
	}
	if sum.Auto != 1 || sum.Ambiguous != 1 || sum.Unmatched != 1 {
		t.Errorf("summary = %+v", sum)
	}
}

func TestRetryUnmatched(t *testing.T) {
	w, ex := standard()
	run(t, w, ex, Options{}) // witch matched, thing ambiguous, nowhere unmatched
	searches := w.searchCalls

	sum, _ := run(t, w, ex, Options{})
	if sum.Attempted != 0 || w.searchCalls != searches {
		t.Fatalf("without flag: attempted %d", sum.Attempted)
	}

	w.addMovie(777, "Nowhere Film", "2001-03-03", false)
	d := &scripted{answers: []prompt.Decision{{Action: prompt.Choose, Candidate: w.catalog[2]}}}
	sum, _ = run(t, w, ex, Options{RetryUnmatched: true, Decider: d})
	if sum.Attempted != 2 || sum.Auto != 1 || sum.Chosen != 1 {
		t.Errorf("summary = %+v", sum)
	}
	if len(d.asked) != 1 || !strings.HasPrefix(d.asked[0], "The Thing") {
		t.Errorf("asked = %v (the matched Witch must not be retried)", d.asked)
	}
	if w.films[uri(3)].MatchStatus != api.StatusMatched || *w.films[uri(3)].TMDBID != 777 {
		t.Errorf("nowhere = %+v", w.films[uri(3)])
	}
}

func TestTMDBFailureLeavesFilmPending(t *testing.T) {
	w, ex := standard()
	w.failSearch[normalize.Title("The Thing")] = true
	sum, out := run(t, w, ex, Options{})
	if w.films[uri(2)].MatchStatus != api.StatusPending {
		t.Errorf("failed film status = %s", w.films[uri(2)].MatchStatus)
	}
	if w.films[uri(1)].MatchStatus != api.StatusMatched || w.films[uri(3)].MatchStatus != api.StatusUnmatched {
		t.Errorf("other films not processed")
	}
	if sum.Pending != 1 || sum.Auto != 1 || sum.Unmatched != 1 {
		t.Errorf("summary = %+v", sum)
	}
	if !strings.Contains(out, "[2/3] The Thing (1982) … left pending (") || !strings.Contains(out, "1 left pending") {
		t.Errorf("output:\n%s", out)
	}

	// Next import retries it automatically.
	delete(w.failSearch, normalize.Title("The Thing"))
	sum, _ = run(t, w, ex, Options{})
	if sum.Attempted != 1 || w.films[uri(2)].MatchStatus != api.StatusAmbiguous {
		t.Errorf("retry: summary %+v, status %s", sum, w.films[uri(2)].MatchStatus)
	}
}

func TestMovieFetchFailureLeavesPending(t *testing.T) {
	w, ex := standard()
	d := &scripted{answers: []prompt.Decision{
		{Action: prompt.Choose, Candidate: api.SearchResult{TMDBID: 424242}}, // not in catalog → 404
		{Action: prompt.Skip},
	}}
	sum, _ := run(t, w, ex, Options{Decider: d})
	if w.films[uri(2)].MatchStatus != api.StatusPending || sum.Pending != 1 || sum.Chosen != 0 {
		t.Errorf("status %s, summary %+v", w.films[uri(2)].MatchStatus, sum)
	}
}
