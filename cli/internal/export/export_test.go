package export

import (
	"archive/zip"
	"bytes"
	"fmt"
	"maps"
	"slices"
	"strings"
	"testing"
)

const (
	baseHdr    = "Date,Name,Year,Letterboxd URI"
	ratingsHdr = "Date,Name,Year,Letterboxd URI,Rating"
)

// csvFile joins a header and rows with CRLF, like the real export.
func csvFile(header string, rows ...string) string {
	return strings.Join(append([]string{header}, rows...), "\r\n") + "\r\n"
}

// validFiles is a small well-formed export, including a quoted comma title and an en dash title.
func validFiles() map[string]string {
	return map[string]string{
		RatingsFile: csvFile(ratingsHdr,
			`2021-03-11,"As Above, So Below",2014,https://boxd.it/aaa,0.5`,
			`2021-03-12,Mission: Impossible – Fallout,2018,https://boxd.it/bbb,3`,
			`2021-03-13,The Witch,2015,https://boxd.it/ccc,3.0`,
			`2022-01-01,Hereditary,2018,https://boxd.it/ddd,4.5`,
			`2023-06-30,Alien,1979,https://boxd.it/eee,5`,
		),
		WatchedFile: csvFile(baseHdr,
			`2021-03-11,"As Above, So Below",2014,https://boxd.it/aaa`,
			`2021-03-12,Mission: Impossible – Fallout,2018,https://boxd.it/bbb`,
			`2023-06-30,Alien,1979,https://boxd.it/eee`,
			`2024-10-31,Halloween,1978,https://boxd.it/fff`,
		),
		WatchlistFile: csvFile(baseHdr,
			`2025-06-02,Suspiria,1977,https://boxd.it/zzz`,
			`2025-06-03,Alien,1979,https://boxd.it/eee`,
		),
		LikesFile: csvFile(baseHdr,
			`2022-01-02,Hereditary,2018,https://boxd.it/ddd`,
		),
		// Ignored files that must never be read.
		"diary.csv":         csvFile("Date,Name,Year,Letterboxd URI,Rating,Rewatch,Tags,Watched Date", `2021-03-11,Diary Only,2000,https://boxd.it/diary1,3,,,2021-03-11`),
		"reviews.csv":       "garbage",
		"likes/reviews.csv": "garbage",
		"deleted/diary.csv": "garbage",
	}
}

func buildZip(t *testing.T, files map[string]string) *bytes.Reader {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, name := range slices.Sorted(maps.Keys(files)) {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(files[name])); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(buf.Bytes())
}

func parse(t *testing.T, files map[string]string) (*Export, error) {
	t.Helper()
	r := buildZip(t, files)
	return Parse(r, r.Size())
}

func mustParse(t *testing.T, files map[string]string) *Export {
	t.Helper()
	ex, err := parse(t, files)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return ex
}

// expectError asserts Parse fails with a message containing every fragment.
func expectError(t *testing.T, files map[string]string, fragments ...string) {
	t.Helper()
	_, err := parse(t, files)
	if err == nil {
		t.Fatalf("Parse succeeded; want error containing %q", fragments)
	}
	for _, f := range fragments {
		if !strings.Contains(err.Error(), f) {
			t.Errorf("error %q does not contain %q", err, f)
		}
	}
}

func TestParseHappyPath(t *testing.T) {
	ex := mustParse(t, validFiles())

	wantRatings := []Rating{
		{"https://boxd.it/aaa", 1, "2021-03-11"},
		{"https://boxd.it/bbb", 6, "2021-03-12"},
		{"https://boxd.it/ccc", 6, "2021-03-13"},
		{"https://boxd.it/ddd", 9, "2022-01-01"},
		{"https://boxd.it/eee", 10, "2023-06-30"},
	}
	if !slices.Equal(ex.Ratings, wantRatings) {
		t.Errorf("Ratings = %+v\nwant %+v", ex.Ratings, wantRatings)
	}

	wantWatched := []Watched{
		{"https://boxd.it/aaa", "2021-03-11"},
		{"https://boxd.it/bbb", "2021-03-12"},
		{"https://boxd.it/eee", "2023-06-30"},
		{"https://boxd.it/fff", "2024-10-31"},
	}
	if !slices.Equal(ex.Watched, wantWatched) {
		t.Errorf("Watched = %+v\nwant %+v", ex.Watched, wantWatched)
	}

	// Snapshot slices keep file order (zzz before eee).
	wantWatchlist := []WatchlistEntry{{"https://boxd.it/zzz", "2025-06-02"}, {"https://boxd.it/eee", "2025-06-03"}}
	if !slices.Equal(ex.Watchlist, wantWatchlist) {
		t.Errorf("Watchlist = %+v\nwant %+v", ex.Watchlist, wantWatchlist)
	}
	if want := []Like{{"https://boxd.it/ddd"}}; !slices.Equal(ex.Likes, want) {
		t.Errorf("Likes = %+v, want %+v", ex.Likes, want)
	}

	// De-duplicated union across all four files, sorted by URI; diary.csv ignored.
	wantFilms := []Film{
		{"https://boxd.it/aaa", "As Above, So Below", 2014},
		{"https://boxd.it/bbb", "Mission: Impossible – Fallout", 2018},
		{"https://boxd.it/ccc", "The Witch", 2015},
		{"https://boxd.it/ddd", "Hereditary", 2018},
		{"https://boxd.it/eee", "Alien", 1979},
		{"https://boxd.it/fff", "Halloween", 1978},
		{"https://boxd.it/zzz", "Suspiria", 1977},
	}
	if !slices.Equal(ex.Films, wantFilms) {
		t.Errorf("Films = %+v\nwant %+v", ex.Films, wantFilms)
	}
}

func TestNamesStoredByteForByte(t *testing.T) {
	names := []string{"  Padded  Title ", "Mission: Impossible – Fallout", "Rosemary\u2019s Baby", "Låt den rätte komma in"}
	files := validFiles()
	var rows []string
	for i, n := range names {
		rows = append(rows, fmt.Sprintf(`2020-01-01,"%s",2000,https://boxd.it/n%d`, n, i))
	}
	files[WatchlistFile] = csvFile(baseHdr, rows...)
	ex := mustParse(t, files)
	byURI := make(map[string]string)
	for _, f := range ex.Films {
		byURI[f.LetterboxdURI] = f.Name
	}
	for i, n := range names {
		if got := byURI[fmt.Sprintf("https://boxd.it/n%d", i)]; got != n {
			t.Errorf("name %d = %q, want %q", i, got, n)
		}
	}
}

func TestLeadingBOMTolerated(t *testing.T) {
	files := validFiles()
	files[RatingsFile] = "\uFEFF" + files[RatingsFile]
	files[LikesFile] = "\uFEFF" + files[LikesFile]
	ex := mustParse(t, files)
	if len(ex.Ratings) != 5 || len(ex.Likes) != 1 {
		t.Errorf("got %d ratings, %d likes", len(ex.Ratings), len(ex.Likes))
	}
}

func TestLFLineEndingsAndEmptySnapshots(t *testing.T) {
	files := validFiles()
	files[WatchedFile] = strings.ReplaceAll(files[WatchedFile], "\r\n", "\n")
	files[WatchlistFile] = baseHdr + "\r\n"
	files[LikesFile] = baseHdr
	ex := mustParse(t, files)
	if len(ex.Watched) != 4 || ex.Watchlist == nil || len(ex.Watchlist) != 0 || len(ex.Likes) != 0 {
		t.Errorf("watched=%d watchlist=%v likes=%v", len(ex.Watched), ex.Watchlist, ex.Likes)
	}
}

func TestDiaryIsIgnored(t *testing.T) {
	without := validFiles()
	delete(without, "diary.csv")
	a, b := mustParse(t, validFiles()), mustParse(t, without)
	if !slices.Equal(a.Films, b.Films) || !slices.Equal(a.Ratings, b.Ratings) {
		t.Error("diary.csv changed the output")
	}
}

func TestLargeExport(t *testing.T) {
	const n = 5000
	ratings := make([]string, 0, n)
	watched := make([]string, 0, n)
	for i := range n {
		rating := []string{"0.5", "1", "1.5", "2.0", "2.5", "3", "3.5", "4", "4.5", "5"}[i%10]
		ratings = append(ratings, fmt.Sprintf(`2021-01-01,"Film, No. %d",%d,https://boxd.it/f%05d,%s`, i, 1900+i%100, i, rating))
		watched = append(watched, fmt.Sprintf(`2021-01-02,"Film, No. %d",%d,https://boxd.it/f%05d`, i, 1900+i%100, i))
	}
	files := validFiles()
	files[RatingsFile] = csvFile(ratingsHdr, ratings...)
	files[WatchedFile] = csvFile(baseHdr, watched...)
	files[WatchlistFile] = baseHdr + "\r\n"
	files[LikesFile] = csvFile(baseHdr, `2022-01-01,"Film, No. 42",1942,https://boxd.it/f00042`)

	ex := mustParse(t, files)
	if len(ex.Ratings) != n || len(ex.Watched) != n || len(ex.Films) != n {
		t.Fatalf("ratings=%d watched=%d films=%d, want %d each", len(ex.Ratings), len(ex.Watched), len(ex.Films), n)
	}
	for i, r := range ex.Ratings {
		if want := i%10 + 1; r.HalfStars != want {
			t.Fatalf("rating %d half stars = %d, want %d", i, r.HalfStars, want)
		}
	}
	if !slices.IsSortedFunc(ex.Films, func(a, b Film) int { return strings.Compare(a.LetterboxdURI, b.LetterboxdURI) }) {
		t.Error("films not sorted by URI")
	}
	if ex.Films[42] != (Film{"https://boxd.it/f00042", "Film, No. 42", 1942}) {
		t.Errorf("films[42] = %+v", ex.Films[42])
	}
}

func TestRatingValues(t *testing.T) {
	valid := map[string]int{"0.5": 1, "1": 2, "1.0": 2, "1.5": 3, "2": 4, "2.5": 5, "3": 6, "3.0": 6, "3.5": 7, "4": 8, "4.5": 9, "5": 10, "5.0": 10}
	for s, want := range valid {
		if got, err := parseRating(s); err != nil || got != want {
			t.Errorf("parseRating(%q) = %d, %v; want %d", s, got, err, want)
		}
	}
	for _, s := range []string{"0", "0.0", "5.5", "2.25", "four", "", " 3", "3.50", "-1", "10"} {
		if _, err := parseRating(s); err == nil {
			t.Errorf("parseRating(%q) succeeded; want error", s)
		}
	}
}

// withFirstRow replaces line 2 (the first data row) of file in validFiles.
func withFirstRow(file, row string) map[string]string {
	files := validFiles()
	lines := strings.Split(files[file], "\r\n")
	lines[1] = row
	files[file] = strings.Join(lines, "\r\n")
	return files
}

func TestRejections(t *testing.T) {
	cases := []struct {
		name      string
		files     func() map[string]string
		fragments []string
	}{
		{"missing ratings.csv", func() map[string]string { f := validFiles(); delete(f, RatingsFile); return f }, []string{"missing ratings.csv"}},
		{"missing likes/films.csv", func() map[string]string { f := validFiles(); delete(f, LikesFile); return f }, []string{"missing likes/films.csv"}},
		{"likes at wrong path", func() map[string]string {
			f := validFiles()
			f["films.csv"] = f[LikesFile]
			delete(f, LikesFile)
			return f
		}, []string{"missing likes/films.csv"}},
		{"wrong header column name", func() map[string]string {
			f := validFiles()
			f[WatchedFile] = strings.Replace(f[WatchedFile], "Letterboxd URI", "URI", 1)
			return f
		}, []string{"watched.csv line 1", "unexpected header", `"Date,Name,Year,Letterboxd URI"`}},
		{"extra header column", func() map[string]string {
			f := validFiles()
			f[WatchlistFile] = strings.Replace(f[WatchlistFile], baseHdr, baseHdr+",Tags", 1)
			return f
		}, []string{"watchlist.csv line 1", "unexpected header"}},
		{"empty file", func() map[string]string { f := validFiles(); f[LikesFile] = ""; return f }, []string{"likes/films.csv", "empty"}},
		{"wrong field count", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,Film,2014`)
		}, []string{"watched.csv line 2", "expected 4 fields, got 3"}},
		{"extra field", func() map[string]string {
			return withFirstRow(RatingsFile, `2021-03-11,Film,2014,https://boxd.it/aaa,3,x`)
		}, []string{"ratings.csv line 2", "expected 5 fields, got 6"}},
		{"empty year", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,"As Above, So Below",,https://boxd.it/aaa`)
		}, []string{"watched.csv line 2", "Year"}},
		{"year abc", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,"As Above, So Below",abc,https://boxd.it/aaa`)
		}, []string{"watched.csv line 2", "Year"}},
		{"year 1500", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,"As Above, So Below",1500,https://boxd.it/aaa`)
		}, []string{"watched.csv line 2", "Year"}},
		{"date 2021-13-01", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-13-01,"As Above, So Below",2014,https://boxd.it/aaa`)
		}, []string{"watched.csv line 2", "Date"}},
		{"date 11/03/2021", func() map[string]string {
			return withFirstRow(RatingsFile, `11/03/2021,"As Above, So Below",2014,https://boxd.it/aaa,3`)
		}, []string{"ratings.csv line 2", "Date"}},
		{"uri wrong prefix", func() map[string]string {
			return withFirstRow(LikesFile, `2022-01-02,Hereditary,2018,https://letterboxd.com/film/hereditary/`)
		}, []string{"likes/films.csv line 2", "Letterboxd URI"}},
		{"uri no code", func() map[string]string {
			return withFirstRow(LikesFile, `2022-01-02,Hereditary,2018,https://boxd.it/`)
		}, []string{"likes/films.csv line 2", "Letterboxd URI"}},
		{"empty name", func() map[string]string {
			return withFirstRow(WatchlistFile, `2025-06-02,  ,1977,https://boxd.it/zzz`)
		}, []string{"watchlist.csv line 2", "Name is empty"}},
		{"duplicate uri in ratings", func() map[string]string {
			f := validFiles()
			f[RatingsFile] = csvFile(ratingsHdr,
				`2021-03-11,"As Above, So Below",2014,https://boxd.it/aaa,3`,
				`2021-03-12,The Witch,2015,https://boxd.it/ccc,3`,
				`2021-03-13,"As Above, So Below",2014,https://boxd.it/aaa,4`,
			)
			return f
		}, []string{"ratings.csv line 4", "duplicate", "https://boxd.it/aaa", "line 2"}},
		{"different name across files", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,As Above So Below,2014,https://boxd.it/aaa`)
		}, []string{"watched.csv line 2", "inconsistent", "ratings.csv line 2"}},
		{"different year across files", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,"As Above, So Below",2015,https://boxd.it/aaa`)
		}, []string{"watched.csv line 2", "inconsistent", "ratings.csv line 2"}},
		{"malformed quoting", func() map[string]string {
			return withFirstRow(WatchedFile, `2021-03-11,"As Above, So Below,2014,https://boxd.it/aaa`)
		}, []string{"watched.csv", "line"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) { expectError(t, tc.files(), tc.fragments...) })
	}

	for _, rating := range []string{"0", "5.5", "2.25", "four", ""} {
		t.Run("rating "+rating, func(t *testing.T) {
			files := withFirstRow(RatingsFile, `2021-03-11,"As Above, So Below",2014,https://boxd.it/aaa,`+rating)
			expectError(t, files, "ratings.csv line 2", "Rating")
		})
	}
}

func TestEntryOverSizeLimit(t *testing.T) {
	files := validFiles()
	// Valid rows padded past the cap; deflate keeps the ZIP itself small.
	row := `2021-03-11,Pad,2000,https://boxd.it/p`
	var b strings.Builder
	b.WriteString(baseHdr + "\r\n")
	for i := 0; b.Len() <= MaxEntryBytes; i++ {
		fmt.Fprintf(&b, "%s%07d\r\n", row, i)
	}
	files[WatchlistFile] = b.String()
	expectError(t, files, "watchlist.csv", "exceeds 20 MB")
}

func TestParseFileMissing(t *testing.T) {
	if _, err := ParseFile(t.TempDir() + "/nope.zip"); err == nil {
		t.Error("ParseFile on a missing path succeeded")
	}
}

func TestNotAZip(t *testing.T) {
	r := bytes.NewReader([]byte("not a zip"))
	if _, err := Parse(r, r.Size()); err == nil {
		t.Error("Parse on non-zip succeeded")
	}
}
