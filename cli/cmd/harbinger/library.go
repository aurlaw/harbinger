package main

import (
	"cmp"
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"

	"github.com/aurlaw/harbinger/cli/internal/api"
	"github.com/aurlaw/harbinger/cli/internal/normalize"
)

const (
	envAPIKey = "HARBINGER_API_KEY"
	envAPIURL = "HARBINGER_API_URL"
)

// newWorker builds the Worker client from the environment. On failure it has
// already printed the reason; the key itself is never printed.
func newWorker(d deps) (api.Worker, bool) {
	key := d.getenv(envAPIKey)
	if key == "" {
		fmt.Fprintf(d.stderr, "%s is not set\n", envAPIKey)
		return nil, false
	}
	base := cmp.Or(d.getenv(envAPIURL), api.DefaultBaseURL)
	c, err := api.NewClient(base, key)
	if err != nil {
		fmt.Fprintf(d.stderr, "error: %s: %v\n", envAPIURL, err)
		return nil, false
	}
	return c, true
}

var statuses = []string{api.StatusPending, api.StatusMatched, api.StatusAmbiguous, api.StatusUnmatched}

func runFilms(args []string, d deps) int {
	fs := flag.NewFlagSet("films", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	status := fs.String("status", "", "")
	horror := fs.Bool("horror", false, "")
	notHorror := fs.Bool("not-horror", false, "")
	search := fs.String("search", "", "")
	if code, ok := parseFlags(fs, args, d); !ok {
		return code
	}
	switch {
	case fs.NArg() != 0:
		fmt.Fprintf(d.stderr, "films takes no arguments\n\n%s", usage)
		return exitUsage
	case *horror && *notHorror:
		fmt.Fprintf(d.stderr, "--horror and --not-horror are mutually exclusive\n\n%s", usage)
		return exitUsage
	case *status != "" && !slices.Contains(statuses, *status):
		fmt.Fprintf(d.stderr, "--status must be one of %s\n\n%s", strings.Join(statuses, ", "), usage)
		return exitUsage
	}

	w, ok := newWorker(d)
	if !ok {
		return exitError
	}
	films, err := w.ListFilms(context.Background())
	if err != nil {
		fmt.Fprintf(d.stderr, "error: %v\n", err)
		return exitError
	}

	key := normalize.Title(*search)
	films = slices.DeleteFunc(films, func(f api.LibraryFilm) bool {
		return (*status != "" && f.MatchStatus != *status) ||
			(*horror && !f.EffectiveHorror()) ||
			(*notHorror && f.EffectiveHorror()) ||
			(key != "" && !strings.Contains(normalize.Title(f.Name), key))
	})
	slices.SortFunc(films, func(a, b api.LibraryFilm) int {
		return cmp.Or(
			cmp.Compare(normalize.Title(a.Name), normalize.Title(b.Name)),
			cmp.Compare(a.Year, b.Year),
			cmp.Compare(a.LetterboxdURI, b.LetterboxdURI),
		)
	})
	for _, f := range films {
		fmt.Fprintln(d.stdout, filmLine(f))
	}
	return exitOK
}

var overrideActions = map[string]*string{
	"include": ptr(api.OverrideInclude),
	"exclude": ptr(api.OverrideExclude),
	"clear":   nil,
}

func ptr(s string) *string { return &s }

func runOverride(args []string, d deps) int {
	fs := flag.NewFlagSet("override", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if code, ok := parseFlags(fs, args, d); !ok {
		return code
	}
	if fs.NArg() != 2 {
		fmt.Fprintf(d.stderr, "override takes an action and a Letterboxd URI\n\n%s", usage)
		return exitUsage
	}
	action, uri := fs.Arg(0), fs.Arg(1)
	value, known := overrideActions[action]
	if !known {
		fmt.Fprintf(d.stderr, "unknown override action %q (want include, exclude, or clear)\n\n%s", action, usage)
		return exitUsage
	}

	w, ok := newWorker(d)
	if !ok {
		return exitError
	}
	film, err := w.SetOverride(context.Background(), uri, value)
	if api.IsAPIError(err, http.StatusNotFound, "") {
		fmt.Fprintf(d.stderr, "no film with URI %s\n", uri)
		return exitError
	}
	if err != nil {
		fmt.Fprintf(d.stderr, "error: %v\n", err)
		return exitError
	}
	fmt.Fprintln(d.stdout, filmLine(film))
	return exitOK
}

// filmLine renders one film: effective horror marker, name, year, status,
// override (if any), URI.
func filmLine(f api.LibraryFilm) string {
	marker := "-"
	if f.EffectiveHorror() {
		marker = "H"
	}
	s := fmt.Sprintf("%s  %s (%d)  %s", marker, f.Name, f.Year, f.MatchStatus)
	if f.GenreOverride != nil {
		s += "  override:" + *f.GenreOverride
	}
	return s + "  " + f.LetterboxdURI
}
