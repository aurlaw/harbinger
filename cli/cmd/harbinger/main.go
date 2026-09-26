// Command harbinger imports a Letterboxd export into the harbinger Worker.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/aurlaw/harbinger/cli/internal/export"
)

const usage = `usage:
  harbinger import --dry-run [--json] <export.zip>

commands:
  import   parse a Letterboxd export ZIP

import flags:
  --dry-run   parse and validate only (required until Phase C2)
  --json      with --dry-run, print the would-be Worker payloads as JSON
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

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	switch args[0] {
	case "-h", "-help", "--help", "help":
		fmt.Fprint(stdout, usage)
		return exitOK
	case "import":
		return runImport(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command %q\n\n%s", args[0], usage)
		return exitUsage
	}
}

func runImport(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dryRun := fs.Bool("dry-run", false, "")
	asJSON := fs.Bool("json", false, "")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(stdout, usage)
			return exitOK
		}
		fmt.Fprintf(stderr, "%v\n\n%s", err, usage)
		return exitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintf(stderr, "import takes exactly one export path\n\n%s", usage)
		return exitUsage
	}
	if !*dryRun {
		fmt.Fprintln(stderr, "live import is not implemented yet (Phase C2)")
		return exitError
	}

	path := fs.Arg(0)
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
