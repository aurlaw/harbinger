// Package match decides which TMDB movie a Letterboxd film is. It is pure
// logic over a search function; the Worker supplies the real one.
package match

import (
	"context"
	"strconv"

	"github.com/aurlaw/harbinger/cli/internal/api"
	"github.com/aurlaw/harbinger/cli/internal/normalize"
)

// SearchFunc runs one TMDB search (api.Worker.SearchTMDB satisfies it).
type SearchFunc func(ctx context.Context, q api.SearchQuery) (api.SearchPage, error)

// MaxFallbackCandidates caps the unfiltered results offered when no search
// stage produced a filtered candidate.
const MaxFallbackCandidates = 5

// YearTolerance is how far a TMDB release year may be from the Letterboxd year.
const YearTolerance = 1

// Result is the outcome of Find.
type Result struct {
	// Auto is the confidently matched movie, or nil if a decision is needed.
	Auto *api.SearchResult
	// Candidates are what to offer when Auto is nil: the filtered candidates
	// if any stage had some, otherwise the top results of the last stage run.
	// Empty means TMDB returned nothing at all.
	Candidates []api.SearchResult
}

// Find runs up to three searches (primary_release_year, year, no year),
// stopping at the first stage with any filtered candidates, and decides.
func Find(ctx context.Context, search SearchFunc, name string, year int) (Result, error) {
	stages := []api.SearchQuery{
		{Query: name, PrimaryReleaseYear: year},
		{Query: name, Year: year},
		{Query: name},
	}
	var last []api.SearchResult
	for _, q := range stages {
		page, err := search(ctx, q)
		if err != nil {
			return Result{}, err
		}
		last = page.Results
		if filtered := Filter(page.Results, name, year); len(filtered) > 0 {
			return decide(filtered, year), nil
		}
	}
	return Result{Candidates: last[:min(len(last), MaxFallbackCandidates)]}, nil
}

// Filter keeps results whose title or original title normalizes to name's key
// and whose release year is within YearTolerance of year. Results without a
// release date are excluded.
func Filter(results []api.SearchResult, name string, year int) []api.SearchResult {
	key := normalize.Title(name)
	var out []api.SearchResult
	for _, r := range results {
		if key != normalize.Title(r.Title) && key != normalize.Title(r.OriginalTitle) {
			continue
		}
		ry, ok := ReleaseYear(r)
		if !ok || ry < year-YearTolerance || ry > year+YearTolerance {
			continue
		}
		out = append(out, r)
	}
	return out
}

func decide(filtered []api.SearchResult, year int) Result {
	if len(filtered) == 1 {
		return Result{Auto: &filtered[0]}
	}
	var exact []int
	for i, r := range filtered {
		if ry, _ := ReleaseYear(r); ry == year {
			exact = append(exact, i)
		}
	}
	if len(exact) == 1 {
		return Result{Auto: &filtered[exact[0]]}
	}
	return Result{Candidates: filtered}
}

// ReleaseYear parses the year from a YYYY-MM-DD release date.
func ReleaseYear(r api.SearchResult) (int, bool) {
	if r.ReleaseDate == nil || len(*r.ReleaseDate) < 4 {
		return 0, false
	}
	y, err := strconv.Atoi((*r.ReleaseDate)[:4])
	return y, err == nil
}
