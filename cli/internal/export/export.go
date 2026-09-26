// Package export parses a Letterboxd export ZIP into the Worker's W2 request
// payload shapes. It reads only the four files Harbinger uses and validates
// every row; any problem is an error naming the file and line.
package export

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

// JSON tags match the W2 payloads exactly, so C2 can send these as-is.

type Film struct {
	LetterboxdURI string `json:"letterboxd_uri"`
	Name          string `json:"name"`
	Year          int    `json:"year"`
}

type Rating struct {
	LetterboxdURI string `json:"letterboxd_uri"`
	HalfStars     int    `json:"half_stars"`
	RatedOn       string `json:"rated_on"`
}

type Watched struct {
	LetterboxdURI string `json:"letterboxd_uri"`
	LoggedOn      string `json:"logged_on"`
}

type WatchlistEntry struct {
	LetterboxdURI string `json:"letterboxd_uri"`
	AddedOn       string `json:"added_on"`
}

type Like struct {
	LetterboxdURI string `json:"letterboxd_uri"`
}

type Export struct {
	Films     []Film           `json:"films"` // union across all four files, sorted by URI
	Ratings   []Rating         `json:"ratings"`
	Watched   []Watched        `json:"watched"`
	Watchlist []WatchlistEntry `json:"watchlist"`
	Likes     []Like           `json:"likes"`
}

// Required ZIP entries, at the archive root. No other entry is ever opened
// (notably diary.csv, whose URIs are diary-entry URIs, not film URIs).
const (
	RatingsFile   = "ratings.csv"
	WatchedFile   = "watched.csv"
	WatchlistFile = "watchlist.csv"
	LikesFile     = "likes/films.csv"
)

var requiredFiles = []string{RatingsFile, WatchedFile, WatchlistFile, LikesFile}

// ParseFile parses the export ZIP at path.
func ParseFile(path string) (*Export, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	return Parse(f, info.Size())
}

// Parse parses an export ZIP of the given size.
func Parse(r io.ReaderAt, size int64) (*Export, error) {
	zr, err := zip.NewReader(r, size)
	// Entry names are only compared, never extracted, so an insecure path is harmless.
	if err != nil && !errors.Is(err, zip.ErrInsecurePath) {
		return nil, fmt.Errorf("open export zip: %w", err)
	}

	entries := make(map[string]*zip.File, len(requiredFiles))
	for _, f := range zr.File {
		if !slices.Contains(requiredFiles, f.Name) {
			continue
		}
		if entries[f.Name] != nil {
			return nil, fmt.Errorf("export contains %s more than once", f.Name)
		}
		entries[f.Name] = f
	}
	for _, name := range requiredFiles {
		if entries[name] == nil {
			return nil, fmt.Errorf("export is missing %s", name)
		}
	}

	p := &parser{films: make(map[string]filmSource)}
	ex := &Export{
		Ratings:   []Rating{},
		Watched:   []Watched{},
		Watchlist: []WatchlistEntry{},
		Likes:     []Like{},
	}

	err = p.readFile(entries[RatingsFile], ratingsHeader, func(r row) error {
		half, err := parseRating(r.extra[0])
		if err != nil {
			return err
		}
		ex.Ratings = append(ex.Ratings, Rating{LetterboxdURI: r.film.LetterboxdURI, HalfStars: half, RatedOn: r.date})
		return nil
	})
	if err != nil {
		return nil, err
	}
	err = p.readFile(entries[WatchedFile], baseHeader, func(r row) error {
		ex.Watched = append(ex.Watched, Watched{LetterboxdURI: r.film.LetterboxdURI, LoggedOn: r.date})
		return nil
	})
	if err != nil {
		return nil, err
	}
	err = p.readFile(entries[WatchlistFile], baseHeader, func(r row) error {
		ex.Watchlist = append(ex.Watchlist, WatchlistEntry{LetterboxdURI: r.film.LetterboxdURI, AddedOn: r.date})
		return nil
	})
	if err != nil {
		return nil, err
	}
	err = p.readFile(entries[LikesFile], baseHeader, func(r row) error {
		ex.Likes = append(ex.Likes, Like{LetterboxdURI: r.film.LetterboxdURI})
		return nil
	})
	if err != nil {
		return nil, err
	}

	ex.Films = make([]Film, 0, len(p.films))
	for _, src := range p.films {
		ex.Films = append(ex.Films, src.film)
	}
	slices.SortFunc(ex.Films, func(a, b Film) int { return strings.Compare(a.LetterboxdURI, b.LetterboxdURI) })
	return ex, nil
}
