package export

import (
	"archive/zip"
	"bytes"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"time"
)

// MaxEntryBytes caps each required entry's uncompressed size.
const MaxEntryBytes = 20 << 20

const (
	uriPrefix = "https://boxd.it/"
	minYear   = 1870
	maxYear   = 2100
)

var (
	baseHeader    = []string{"Date", "Name", "Year", "Letterboxd URI"}
	ratingsHeader = append(slices.Clone(baseHeader), "Rating")
)

// halfStars maps each accepted Rating string ("0.5" … "5", whole numbers with
// or without ".0") to half stars 1–10.
var halfStars = func() map[string]int {
	m := make(map[string]int, 15)
	for h := 1; h <= 10; h++ {
		if h%2 == 0 {
			m[strconv.Itoa(h/2)] = h
			m[strconv.Itoa(h/2)+".0"] = h
		} else {
			m[strconv.Itoa(h/2)+".5"] = h
		}
	}
	return m
}()

// row is one validated CSV record: the four shared columns plus any extras.
type row struct {
	date  string
	film  Film
	extra []string
}

type filmSource struct {
	film Film
	file string
	line int
}

// parser accumulates the film union across files and checks it stays consistent.
type parser struct {
	films map[string]filmSource
}

// readFile validates f's header and every row, calling handle for each row in
// file order. Errors name the file and, where applicable, the line.
func (p *parser) readFile(f *zip.File, header []string, handle func(row) error) error {
	name := f.Name
	tooBig := fmt.Errorf("%s: exceeds %d MB uncompressed", name, MaxEntryBytes>>20)
	if f.UncompressedSize64 > MaxEntryBytes {
		return tooBig
	}
	rc, err := f.Open()
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	defer rc.Close()
	// The header's size can lie; enforce the cap on the bytes actually read.
	data, err := io.ReadAll(io.LimitReader(rc, MaxEntryBytes+1))
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if len(data) > MaxEntryBytes {
		return tooBig
	}

	cr := csv.NewReader(bytes.NewReader(data))
	cr.FieldsPerRecord = -1 // field count is checked below with a clearer message

	got, err := cr.Read()
	if errors.Is(err, io.EOF) {
		return fmt.Errorf("%s: file is empty; expected header %q", name, strings.Join(header, ","))
	}
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if len(got) > 0 {
		got[0] = strings.TrimPrefix(got[0], "\uFEFF")
	}
	if !slices.Equal(got, header) {
		return fmt.Errorf("%s line 1: unexpected header: expected %q, got %q",
			name, strings.Join(header, ","), strings.Join(got, ","))
	}

	seen := make(map[string]int)
	for {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", name, err) // csv.ParseError carries the line
		}
		line, _ := cr.FieldPos(0)
		if len(rec) != len(header) {
			return fmt.Errorf("%s line %d: expected %d fields, got %d", name, line, len(header), len(rec))
		}
		r, err := parseRow(rec)
		if err != nil {
			return fmt.Errorf("%s line %d: %w", name, line, err)
		}
		uri := r.film.LetterboxdURI
		if first, dup := seen[uri]; dup {
			return fmt.Errorf("%s line %d: duplicate Letterboxd URI %s (also on line %d)", name, line, uri, first)
		}
		seen[uri] = line
		if err := p.addFilm(filmSource{film: r.film, file: name, line: line}); err != nil {
			return err
		}
		if err := handle(r); err != nil {
			return fmt.Errorf("%s line %d: %w", name, line, err)
		}
	}
}

// addFilm adds to the union, rejecting a URI whose name or year differs between rows.
func (p *parser) addFilm(src filmSource) error {
	prev, ok := p.films[src.film.LetterboxdURI]
	if !ok {
		p.films[src.film.LetterboxdURI] = src
		return nil
	}
	if prev.film != src.film {
		return fmt.Errorf("%s line %d: inconsistent export: %s is %q (%d) here but %q (%d) in %s line %d",
			src.file, src.line, src.film.LetterboxdURI, src.film.Name, src.film.Year,
			prev.film.Name, prev.film.Year, prev.file, prev.line)
	}
	return nil
}

// parseRow validates the shared Date, Name, Year, Letterboxd URI columns.
func parseRow(rec []string) (row, error) {
	date, name, yearField, uriField := rec[0], rec[1], rec[2], rec[3]

	if _, err := time.Parse(time.DateOnly, date); err != nil {
		return row{}, fmt.Errorf("Date %q is not a valid YYYY-MM-DD date", date)
	}
	if strings.TrimSpace(name) == "" {
		return row{}, errors.New("Name is empty")
	}
	year, err := parseYear(yearField)
	if err != nil {
		return row{}, err
	}
	uri := strings.TrimSpace(uriField)
	if !strings.HasPrefix(uri, uriPrefix) || len(uri) == len(uriPrefix) {
		return row{}, fmt.Errorf("Letterboxd URI %q must be %s followed by a film code", uriField, uriPrefix)
	}

	return row{
		date:  date,
		film:  Film{LetterboxdURI: uri, Name: name, Year: year},
		extra: rec[4:],
	}, nil
}

func parseYear(s string) (int, error) {
	y, err := strconv.Atoi(s)
	// Round-tripping rejects signs and leading zeros.
	if err != nil || strconv.Itoa(y) != s || y < minYear || y > maxYear {
		return 0, fmt.Errorf("Year %q must be an integer between %d and %d", s, minYear, maxYear)
	}
	return y, nil
}

func parseRating(s string) (int, error) {
	h, ok := halfStars[s]
	if !ok {
		return 0, fmt.Errorf("Rating %q must be 0.5 to 5 in half steps", s)
	}
	return h, nil
}
