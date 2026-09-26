// Command harbinger imports a Letterboxd export into the harbinger Worker.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/aurlaw/harbinger/cli/internal/export"
	"github.com/aurlaw/harbinger/cli/internal/importer"
	"github.com/aurlaw/harbinger/cli/internal/prompt"
)

const usage = `usage:
  harbinger import [--force] [--no-interactive] [--retry-unmatched] <export.zip>
  harbinger import --dry-run [--json] <export.zip>
  harbinger films [--status pending|matched|ambiguous|unmatched] [--horror | --not-horror] [--search <text>]
  harbinger override include|exclude|clear <letterboxd-uri>

commands:
  import     import a Letterboxd export ZIP into the Worker and match new films on TMDB
  films      list library films (to find URIs for overrides)
  override   set or clear a film's genre override

import flags:
  --dry-run           parse and validate only; offline, no API key needed
  --json              with --dry-run, print the would-be Worker payloads as JSON
  --force             allow an import that would empty a snapshot table
  --no-interactive    never prompt; undecided films are recorded ambiguous/unmatched
  --retry-unmatched   also re-attempt ambiguous and unmatched films

environment:
  HARBINGER_API_KEY   Worker API key (required for everything except --dry-run)
  HARBINGER_API_URL   Worker base URL (default https://harbinger-api.aurlaw.dev)
`

// Exit codes.
const (
	exitOK    = 0
	exitError = 1
	exitUsage = 2
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// deps are the process-level inputs, injectable for tests.
type deps struct {
	stdin          io.Reader
	stdout, stderr io.Writer
	getenv         func(string) string
	isTerminal     func() bool // stdin is a character device
}

func run(args []string, stdout, stderr io.Writer) int {
	return runWith(args, deps{stdin: os.Stdin, stdout: stdout, stderr: stderr, getenv: os.Getenv, isTerminal: stdinIsTerminal})
}

func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func runWith(args []string, d deps) int {
	stdout, stderr := d.stdout, d.stderr
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	switch args[0] {
	case "-h", "-help", "--help", "help":
		fmt.Fprint(stdout, usage)
		return exitOK
	case "import":
		return runImport(args[1:], d)
	case "films":
		return runFilms(args[1:], d)
	case "override":
		return runOverride(args[1:], d)
	default:
		fmt.Fprintf(stderr, "unknown command %q\n\n%s", args[0], usage)
		return exitUsage
	}
}

func runImport(args []string, d deps) int {
	stdout, stderr := d.stdout, d.stderr
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dryRun := fs.Bool("dry-run", false, "")
	asJSON := fs.Bool("json", false, "")
	force := fs.Bool("force", false, "")
	noInteractive := fs.Bool("no-interactive", false, "")
	retryUnmatched := fs.Bool("retry-unmatched", false, "")
	if code, ok := parseFlags(fs, args, d); !ok {
		return code
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "import takes exactly one export path\n\n%s", usage)
		return exitUsage
	}
	if *asJSON && !*dryRun {
		fmt.Fprintf(stderr, "--json requires --dry-run\n\n%s", usage)
		return exitUsage
	}
	path := fs.Arg(0)
	if !*dryRun {
		return liveImport(path, *force, *retryUnmatched, !*noInteractive && d.isTerminal(), d)
	}

	ex, err := export.ParseFile(path)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return exitError
	}

	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(ex); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return exitError
		}
		return exitOK
	}
	printSummary(stdout, filepath.Base(path), ex)
	return exitOK
}

// parseFlags parses args into fs. ok is false when the caller should return code.
func parseFlags(fs *flag.FlagSet, args []string, d deps) (code int, ok bool) {
	err := fs.Parse(args)
	switch {
	case err == nil:
		return 0, true
	case errors.Is(err, flag.ErrHelp):
		fmt.Fprint(d.stdout, usage)
		return exitOK, false
	default:
		fmt.Fprintf(d.stderr, "%v\n\n%s", err, usage)
		return exitUsage, false
	}
}

func liveImport(path string, force, retryUnmatched, interactive bool, d deps) int {
	w, ok := newWorker(d)
	if !ok {
		return exitError
	}
	ex, err := export.ParseFile(path)
	if err != nil {
		fmt.Fprintf(d.stderr, "error: %v\n", err)
		return exitError
	}

	opts := importer.Options{
		SourceFilename: filepath.Base(path),
		Force:          force,
		RetryUnmatched: retryUnmatched,
		Out:            d.stdout,
	}
	if interactive {
		opts.Decider = prompt.New(d.stdin, d.stdout, w.MovieTMDB)
	}
	sum, err := importer.Run(context.Background(), w, ex, opts)
	if sum != nil {
		sum.Print(d.stdout)
	}
	if err != nil {
		fmt.Fprintf(d.stderr, "error: %v\n", err)
		return exitError
	}
	return exitOK
}

func printSummary(w io.Writer, name string, ex *export.Export) {
	fmt.Fprintf(w, "Letterboxd export: %s\n\n", name)
	fmt.Fprintf(w, "  %-12s %5d\n", "ratings", len(ex.Ratings))
	fmt.Fprintf(w, "  %-12s %5d\n", "watched", len(ex.Watched))
	fmt.Fprintf(w, "  %-12s %5d\n", "watchlist", len(ex.Watchlist))
	fmt.Fprintf(w, "  %-12s %5d\n", "likes", len(ex.Likes))
	fmt.Fprintf(w, "  %-12s %5d\n", "unique films", len(ex.Films))

	var buckets [11]int // index = half stars 1–10
	first, last := "", ""
	for _, r := range ex.Ratings {
		buckets[r.HalfStars]++
		if first == "" || r.RatedOn < first {
			first = r.RatedOn
		}
		if r.RatedOn > last {
			last = r.RatedOn
		}
	}

	fmt.Fprintf(w, "\nRatings distribution\n")
	for h := 1; h <= 10; h++ {
		fmt.Fprintf(w, "  ★ %.1f  %5d\n", float64(h)/2, buckets[h])
	}

	if first == "" {
		fmt.Fprintf(w, "\nRating dates  none\n")
	} else {
		fmt.Fprintf(w, "\nRating dates  %s → %s\n", first, last)
	}
}
