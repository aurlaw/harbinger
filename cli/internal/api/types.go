// Package api is the client for the harbinger Worker's W2 library and W3 TMDB
// proxy endpoints. Callers depend on the Worker interface; Client is the HTTP
// implementation.
package api

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/aurlaw/harbinger/cli/internal/export"
)

// Worker covers every W2/W3 endpoint the CLI uses.
type Worker interface {
	ListFilms(ctx context.Context) ([]LibraryFilm, error)
	UpsertFilms(ctx context.Context, films []export.Film) (UpsertResult, error)
	RecordMatches(ctx context.Context, matches []Match) (int, error)
	Import(ctx context.Context, req ImportRequest) (ImportResult, error)
	SetOverride(ctx context.Context, uri string, override *string) (LibraryFilm, error)
	LatestImport(ctx context.Context) (*ImportRow, error) // nil, nil on 404 no_imports
	SearchTMDB(ctx context.Context, q SearchQuery) (SearchPage, error)
	MovieTMDB(ctx context.Context, id int) (json.RawMessage, error)
}

// Match statuses.
const (
	StatusPending   = "pending"
	StatusMatched   = "matched"
	StatusAmbiguous = "ambiguous"
	StatusUnmatched = "unmatched"
)

// Genre overrides.
const (
	OverrideInclude = "include"
	OverrideExclude = "exclude"
)

// HorrorGenreID is TMDB's Horror genre.
const HorrorGenreID = 27

// LibraryFilm is a row from GET /library/films or PUT /library/films/override.
type LibraryFilm struct {
	LetterboxdURI string  `json:"letterboxd_uri"`
	Name          string  `json:"name"`
	Year          int     `json:"year"`
	TMDBID        *int    `json:"tmdb_id"`
	MatchStatus   string  `json:"match_status"`
	IsHorror      *int    `json:"is_horror"`
	GenreOverride *string `json:"genre_override"`
}

// EffectiveHorror applies the horror rule: the override wins, otherwise the
// TMDB genre; unmatched films are never horror.
func (f LibraryFilm) EffectiveHorror() bool {
	if f.GenreOverride != nil {
		return *f.GenreOverride == OverrideInclude
	}
	return f.IsHorror != nil && *f.IsHorror == 1
}

type UpsertResult struct {
	Inserted int `json:"inserted"`
	Updated  int `json:"updated"`
}

// Match is one POST /library/films/matches item. Only matched items carry
// tmdb_id, is_horror, and tmdb_json; W2 rejects them on the other statuses,
// so they are omitted entirely there.
type Match struct {
	LetterboxdURI string          `json:"letterboxd_uri"`
	MatchStatus   string          `json:"match_status"`
	TMDBID        *int            `json:"tmdb_id,omitempty"`
	IsHorror      *int            `json:"is_horror,omitempty"`
	TMDBJSON      json.RawMessage `json:"tmdb_json,omitempty"`
}

// Matched builds a matched item. movie is the /tmdb/movie/{id} body, sent as-is.
func Matched(uri string, tmdbID int, isHorror bool, movie json.RawMessage) Match {
	h := 0
	if isHorror {
		h = 1
	}
	return Match{LetterboxdURI: uri, MatchStatus: StatusMatched, TMDBID: &tmdbID, IsHorror: &h, TMDBJSON: movie}
}

// Unresolved builds an ambiguous or unmatched item.
func Unresolved(uri, status string) Match {
	return Match{LetterboxdURI: uri, MatchStatus: status}
}

type ImportRequest struct {
	SourceFilename string                  `json:"source_filename"`
	Force          bool                    `json:"force"`
	Ratings        []export.Rating         `json:"ratings"`
	Watched        []export.Watched        `json:"watched"`
	Watchlist      []export.WatchlistEntry `json:"watchlist"`
	Likes          []export.Like           `json:"likes"`
}

type ImportResult struct {
	ImportID  int `json:"import_id"`
	Ratings   int `json:"ratings"`
	Watched   int `json:"watched"`
	Watchlist int `json:"watchlist"`
	Likes     int `json:"likes"`
	NewFilms  int `json:"new_films"`
}

// ImportRow is an imports table row from GET /library/imports/latest.
type ImportRow struct {
	ID             int    `json:"id"`
	ImportedAt     string `json:"imported_at"`
	SourceFilename string `json:"source_filename"`
	RatingsCount   int    `json:"ratings_count"`
	WatchedCount   int    `json:"watched_count"`
	WatchlistCount int    `json:"watchlist_count"`
	LikesCount     int    `json:"likes_count"`
	NewFilmsCount  int    `json:"new_films_count"`
}

// SearchQuery maps 1:1 to GET /tmdb/search. Zero-valued optional fields are not sent.
type SearchQuery struct {
	Query              string
	PrimaryReleaseYear int
	Year               int
	Page               int
}

type SearchPage struct {
	Page         int            `json:"page"`
	TotalPages   int            `json:"total_pages"`
	TotalResults int            `json:"total_results"`
	Results      []SearchResult `json:"results"`
}

type SearchResult struct {
	TMDBID        int     `json:"tmdb_id"`
	Title         string  `json:"title"`
	OriginalTitle string  `json:"original_title"`
	ReleaseDate   *string `json:"release_date"`
	GenreIDs      []int   `json:"genre_ids"`
	Overview      string  `json:"overview"`
	Popularity    float64 `json:"popularity"`
	PosterPath    *string `json:"poster_path"`
}

// IsHorror reports whether genre 27 is among the result's genres.
func (r SearchResult) IsHorror() bool {
	for _, g := range r.GenreIDs {
		if g == HorrorGenreID {
			return true
		}
	}
	return false
}

// MovieIsHorror decodes only is_horror from a /tmdb/movie/{id} body.
func MovieIsHorror(movie json.RawMessage) (bool, error) {
	var m struct {
		IsHorror *bool `json:"is_horror"`
	}
	if err := json.Unmarshal(movie, &m); err != nil {
		return false, fmt.Errorf("decode TMDB movie: %w", err)
	}
	if m.IsHorror == nil {
		return false, fmt.Errorf("TMDB movie has no is_horror")
	}
	return *m.IsHorror, nil
}
