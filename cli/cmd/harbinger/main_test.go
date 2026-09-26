package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	baseHdr    = "Date,Name,Year,Letterboxd URI"
	ratingsHdr = baseHdr + ",Rating"
)

var validFiles = map[string]string{
	"ratings.csv": ratingsHdr + "\r\n" +
		"2021-03-11,\"As Above, So Below\",2014,https://boxd.it/aaa,3\r\n" +
		"2026-09-20,Hereditary,2018,https://boxd.it/ddd,4.5\r\n" +
		"2023-01-01,Alien,1979,https://boxd.it/eee,4\r\n",
	"watched.csv": baseHdr + "\r\n" +
		"2021-03-11,\"As Above, So Below\",2014,https://boxd.it/aaa\r\n" +
		"2024-10-31,Halloween,1978,https://boxd.it/fff\r\n",
	"watchlist.csv":   baseHdr + "\r\n2025-06-02,Suspiria,1977,https://boxd.it/zzz\r\n",
	"likes/films.csv": baseHdr + "\r\n2026-09-21,Hereditary,2018,https://boxd.it/ddd\r\n",
}

// writeZip writes files as a ZIP in a temp dir and returns its path.
func writeZip(t *testing.T, files map[string]string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "letterboxd-test.zip")
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func runCLI(args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	code = run(args, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestDryRunSummary(t *testing.T) {
	code, out, errOut := runCLI("import", "--dry-run", writeZip(t, validFiles))
	if code != exitOK || errOut != "" {
		t.Fatalf("exit %d, stderr %q", code, errOut)
	}
	want := `Letterboxd export: letterboxd-test.zip

  ratings          3
  watched          2
  watchlist        1
  likes            1
  unique films     5

Ratings distribution
  ★ 0.5      0
  ★ 1.0      0
  ★ 1.5      0
  ★ 2.0      0
  ★ 2.5      0
  ★ 3.0      1
  ★ 3.5      0
  ★ 4.0      1
  ★ 4.5      1
  ★ 5.0      0

Rating dates  2021-03-11 → 2026-09-20
`
	if out != want {
		t.Errorf("summary:\n%s\nwant:\n%s", out, want)
	}
}

func TestDryRunJSON(t *testing.T) {
	code, out, errOut := runCLI("import", "--dry-run", "--json", writeZip(t, validFiles))
	if code != exitOK || errOut != "" {
		t.Fatalf("exit %d, stderr %q", code, errOut)
	}
	var got map[string][]map[string]any
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out)
	}
	wantKeys := map[string][]string{
		"films":     {"letterboxd_uri", "name", "year"},
		"ratings":   {"letterboxd_uri", "half_stars", "rated_on"},
		"watched":   {"letterboxd_uri", "logged_on"},
		"watchlist": {"letterboxd_uri", "added_on"},
		"likes":     {"letterboxd_uri"},
	}
	if len(got) != len(wantKeys) {
		t.Errorf("top-level keys = %v", got)
	}
	for section, keys := range wantKeys {
		items := got[section]
		if len(items) == 0 {
			t.Errorf("%s is empty", section)
			continue
		}
		for _, item := range items {
			if len(item) != len(keys) {
				t.Errorf("%s item %v: want keys %v", section, item, keys)
			}
			for _, k := range keys {
				if _, ok := item[k]; !ok {
					t.Errorf("%s item %v missing %q", section, item, k)
				}
			}
		}
	}
	if r := got["ratings"][2]; r["half_stars"] != float64(8) || r["rated_on"] != "2023-01-01" {
		t.Errorf("ratings[2] = %v", r)
	}
	if f := got["films"][0]; f["name"] != "As Above, So Below" || f["year"] != float64(2014) {
		t.Errorf("films[0] = %v", f)
	}
}

func TestImportWithoutDryRun(t *testing.T) {
	code, out, errOut := runCLI("import", writeZip(t, validFiles))
	if code != exitError || out != "" || !strings.Contains(errOut, "live import is not implemented yet (Phase C2)") {
		t.Errorf("exit %d, stdout %q, stderr %q", code, out, errOut)
	}
}

func TestUsageErrors(t *testing.T) {
	path := writeZip(t, validFiles)
	for _, args := range [][]string{
		{},
		{"export"},
		{"import"},
		{"import", "--dry-run"},
		{"import", "--dry-run", path, "extra"},
		{"import", "--bogus", path},
	} {
		code, out, errOut := runCLI(args...)
		if code != exitUsage || out != "" || !strings.Contains(errOut, "usage:") {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", args, code, out, errOut)
		}
	}
}

func TestHelp(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"-h"}, {"import", "--help"}} {
		code, out, errOut := runCLI(args...)
		if code != exitOK || !strings.Contains(out, "harbinger import --dry-run") || errOut != "" {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", args, code, out, errOut)
		}
	}
}

func TestInvalidExport(t *testing.T) {
	files := maps.Clone(validFiles)
	files["watched.csv"] = baseHdr + "\r\n2021-03-11,Bad,abc,https://boxd.it/aaa\r\n"
	for _, args := range [][]string{
		{"import", "--dry-run", writeZip(t, files)},
		{"import", "--dry-run", "--json", writeZip(t, files)},
		{"import", "--dry-run", filepath.Join(t.TempDir(), "missing.zip")},
	} {
		code, out, errOut := runCLI(args...)
		if code != exitError || out != "" || !strings.HasPrefix(errOut, "error: ") {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", args, code, out, errOut)
		}
	}
	_, _, errOut := runCLI("import", "--dry-run", writeZip(t, files))
	if !strings.Contains(errOut, "watched.csv line 2") {
		t.Errorf("stderr %q does not name file and line", errOut)
	}
}
