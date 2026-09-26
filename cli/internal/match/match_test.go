package match

import (
	"context"
	"errors"
	"testing"

	"github.com/aurlaw/harbinger/cli/internal/api"
)

func movie(id int, title, date string) api.SearchResult {
	r := api.SearchResult{TMDBID: id, Title: title, OriginalTitle: title}
	if date != "" {
		r.ReleaseDate = &date
	}
	return r
}

// stageFake returns one fixed page per stage and records the queries.
type stageFake struct {
	stages  [3][]api.SearchResult
	queries []api.SearchQuery
}

func (f *stageFake) search(_ context.Context, q api.SearchQuery) (api.SearchPage, error) {
	f.queries = append(f.queries, q)
	var stage int
	switch {
	case q.PrimaryReleaseYear != 0:
		stage = 0
	case q.Year != 0:
		stage = 1
	default:
		stage = 2
	}
	return api.SearchPage{Page: 1, Results: f.stages[stage]}, nil
}

func find(t *testing.T, f *stageFake, name string, year int) Result {
	t.Helper()
	res, err := Find(t.Context(), f.search, name, year)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func wantAuto(t *testing.T, res Result, id int) {
	t.Helper()
	if res.Auto == nil || res.Auto.TMDBID != id {
		t.Fatalf("Auto = %+v (candidates %+v), want TMDB %d", res.Auto, res.Candidates, id)
	}
}

func TestStageOneHitStops(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{{movie(1, "The Witch", "2015-01-27")}}}
	wantAuto(t, find(t, f, "The Witch", 2015), 1)
	if len(f.queries) != 1 {
		t.Fatalf("queries = %+v, want only stage 1", f.queries)
	}
	if q := f.queries[0]; q != (api.SearchQuery{Query: "The Witch", PrimaryReleaseYear: 2015}) {
		t.Errorf("stage 1 query = %+v", q)
	}
}

func TestStageTwoHit(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{nil, {movie(2, "Alien", "1979-05-25")}}}
	wantAuto(t, find(t, f, "Alien", 1979), 2)
	if len(f.queries) != 2 || f.queries[1] != (api.SearchQuery{Query: "Alien", Year: 1979}) {
		t.Errorf("queries = %+v", f.queries)
	}
}

func TestStageThreeHit(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{nil, nil, {movie(3, "Tenebrae", "1982-10-28")}}}
	wantAuto(t, find(t, f, "Tenebrae", 1983), 3)
	if len(f.queries) != 3 || f.queries[2] != (api.SearchQuery{Query: "Tenebrae"}) {
		t.Errorf("queries = %+v", f.queries)
	}
}

func TestUnfilteredStageContinues(t *testing.T) {
	// Stage 1 returns only a non-matching title; stage 2 has the real one.
	f := &stageFake{stages: [3][]api.SearchResult{
		{movie(9, "Something Else", "2015-01-01")},
		{movie(1, "The Witch", "2015-01-27")},
	}}
	wantAuto(t, find(t, f, "The Witch", 2015), 1)
}

func TestYearTolerance(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{nil, nil, {movie(1, "Hereditary", "2017-01-21")}}}
	wantAuto(t, find(t, f, "Hereditary", 2018), 1)

	f = &stageFake{stages: [3][]api.SearchResult{nil, nil, {movie(1, "Hereditary", "2016-01-21")}}}
	res := find(t, f, "Hereditary", 2018)
	if res.Auto != nil {
		t.Fatalf("off-by-two auto-matched: %+v", res.Auto)
	}
	// Nothing filtered → the unfiltered results are offered.
	if len(res.Candidates) != 1 || res.Candidates[0].TMDBID != 1 {
		t.Errorf("Candidates = %+v", res.Candidates)
	}
}

func TestTitleNormalization(t *testing.T) {
	cases := map[string]string{
		"Mission: Impossible – Fallout":  "Mission: Impossible - Fallout",
		"Rosemary’s Baby":                "Rosemary's Baby",
		"the texas chain saw massacre":   "The Texas Chain Saw Massacre",
		"  The   Witch ":                 "The Witch",
		"Let the Right One In":           "LET THE RIGHT ONE IN",
		"Don’t Look Now":                 "Don't Look Now",
		"A Nightmare on Elm Street — II": "a nightmare on elm street - ii",
	}
	for letterboxd, tmdb := range cases {
		f := &stageFake{stages: [3][]api.SearchResult{{movie(1, tmdb, "2000-01-01")}}}
		wantAuto(t, find(t, f, letterboxd, 2000), 1)
	}
}

func TestOriginalTitleMatch(t *testing.T) {
	r := movie(1, "Let the Right One In", "2008-01-26")
	r.OriginalTitle = "Låt den rätte komma in"
	f := &stageFake{stages: [3][]api.SearchResult{{r}}}
	wantAuto(t, find(t, f, "Låt den rätte komma in", 2008), 1)
}

func TestExactYearBreaksTie(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{{
		movie(1, "The Thing", "1981-12-01"),
		movie(2, "The Thing", "1982-06-25"),
		movie(3, "The Thing", "1983-01-01"),
	}}}
	wantAuto(t, find(t, f, "The Thing", 1982), 2)
}

func TestSameYearNeedsDecision(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{{
		movie(1, "The Thing", "1982-06-25"),
		movie(2, "The Thing", "1982-11-01"),
		movie(3, "Unrelated", "1982-01-01"),
	}}}
	res := find(t, f, "The Thing", 1982)
	if res.Auto != nil {
		t.Fatalf("auto-matched %+v", res.Auto)
	}
	if len(res.Candidates) != 2 || res.Candidates[0].TMDBID != 1 || res.Candidates[1].TMDBID != 2 {
		t.Errorf("Candidates = %+v, want the two filtered", res.Candidates)
	}
	if len(f.queries) != 1 {
		t.Errorf("searched %d stages, want to stop at the first with candidates", len(f.queries))
	}
}

func TestNoExactYearAmongSeveralNeedsDecision(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{{
		movie(1, "It", "2016-01-01"),
		movie(2, "It", "2018-01-01"),
	}}}
	if res := find(t, f, "It", 2017); res.Auto != nil || len(res.Candidates) != 2 {
		t.Errorf("res = %+v", res)
	}
}

func TestNullReleaseDateExcluded(t *testing.T) {
	f := &stageFake{stages: [3][]api.SearchResult{
		{movie(1, "Suspiria", ""), movie(2, "Suspiria", "1977-02-01")},
	}}
	wantAuto(t, find(t, f, "Suspiria", 1977), 2)

	f = &stageFake{stages: [3][]api.SearchResult{{movie(1, "Suspiria", "")}, {movie(1, "Suspiria", "")}, {movie(1, "Suspiria", "")}}}
	if res := find(t, f, "Suspiria", 1977); res.Auto != nil {
		t.Errorf("null release date auto-matched")
	}
}

func TestNothingFound(t *testing.T) {
	f := &stageFake{}
	res := find(t, f, "Nonexistent", 2000)
	if res.Auto != nil || len(res.Candidates) != 0 || len(f.queries) != 3 {
		t.Errorf("res = %+v, queries = %d", res, len(f.queries))
	}
}

func TestFallbackCappedAtFive(t *testing.T) {
	var many []api.SearchResult
	for i := range 8 {
		many = append(many, movie(i+1, "Other", "1990-01-01"))
	}
	f := &stageFake{stages: [3][]api.SearchResult{nil, nil, many}}
	res := find(t, f, "Wanted", 2000)
	if len(res.Candidates) != MaxFallbackCandidates || res.Candidates[0].TMDBID != 1 {
		t.Errorf("Candidates = %+v", res.Candidates)
	}
}

func TestSearchErrorReturned(t *testing.T) {
	boom := errors.New("boom")
	_, err := Find(t.Context(), func(context.Context, api.SearchQuery) (api.SearchPage, error) {
		return api.SearchPage{}, boom
	}, "X", 2000)
	if !errors.Is(err, boom) {
		t.Errorf("err = %v", err)
	}
}
