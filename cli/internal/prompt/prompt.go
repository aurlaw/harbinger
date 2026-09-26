// Package prompt asks the user to resolve a film the matcher couldn't decide.
// It reads and writes only the injected io.Reader / io.Writer.
package prompt

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/aurlaw/harbinger/cli/internal/api"
	"github.com/aurlaw/harbinger/cli/internal/match"
)

// MovieFunc fetches /tmdb/movie/{id} (api.Worker.MovieTMDB satisfies it).
type MovieFunc func(ctx context.Context, id int) (json.RawMessage, error)

// Action is what the user chose.
type Action int

const (
	Choose Action = iota // matched a listed candidate
	Manual               // matched a TMDB ID they typed
	Skip                 // leave unresolved
	Quit                 // stop matching
)

// Decision is the user's answer for one film.
type Decision struct {
	Action    Action
	Candidate api.SearchResult // Choose
	TMDBID    int              // Manual
	Movie     json.RawMessage  // Manual: the /tmdb/movie body, already fetched
}

// overviewRunes is the overview length shown per candidate.
const overviewRunes = 60

// Prompter asks questions on in/out. One Prompter serves a whole import so
// buffered input isn't lost between films.
type Prompter struct {
	in    *bufio.Scanner
	out   io.Writer
	movie MovieFunc
}

func New(in io.Reader, out io.Writer, movie MovieFunc) *Prompter {
	return &Prompter{in: bufio.NewScanner(in), out: out, movie: movie}
}

// Ask shows the candidates for name (year) and returns the user's decision.
// EOF on input is treated as Quit.
func (p *Prompter) Ask(ctx context.Context, name string, year int, candidates []api.SearchResult) (Decision, error) {
	fmt.Fprintf(p.out, "? No confident match for %q (%d)\n", name, year)
	if len(candidates) == 0 {
		fmt.Fprintln(p.out, "  (no TMDB results)")
	}
	for i, c := range candidates {
		fmt.Fprintf(p.out, "  %d) %s\n", i+1, describe(c))
	}

	options := "[m] enter TMDB ID · [s] skip · [q] quit matching"
	if n := len(candidates); n == 1 {
		options = "[1] choose · " + options
	} else if n > 1 {
		options = fmt.Sprintf("[1-%d] choose · %s", n, options)
	}

	for {
		fmt.Fprintf(p.out, "  %s\n> ", options)
		line, ok := p.readLine()
		if !ok {
			fmt.Fprintln(p.out)
			return Decision{Action: Quit}, nil
		}
		switch line {
		case "s", "S":
			return Decision{Action: Skip}, nil
		case "q", "Q":
			return Decision{Action: Quit}, nil
		case "m", "M":
			d, done := p.manual(ctx)
			if done {
				return d, nil
			}
			continue
		}
		if n, err := strconv.Atoi(line); err == nil && n >= 1 && n <= len(candidates) {
			return Decision{Action: Choose, Candidate: candidates[n-1]}, nil
		}
		fmt.Fprintf(p.out, "  %q isn't an option\n", line)
	}
}

// manual reads a TMDB ID and fetches it. done is false when the user should
// be asked again (bad ID, not found, lookup failure).
func (p *Prompter) manual(ctx context.Context) (d Decision, done bool) {
	fmt.Fprint(p.out, "  TMDB ID: ")
	line, ok := p.readLine()
	if !ok {
		fmt.Fprintln(p.out)
		return Decision{Action: Quit}, true
	}
	id, err := strconv.Atoi(line)
	if err != nil || id < 1 || strconv.Itoa(id) != line {
		fmt.Fprintf(p.out, "  %q isn't a TMDB ID\n", line)
		return Decision{}, false
	}
	movie, err := p.movie(ctx, id)
	switch {
	case api.IsAPIError(err, 404, ""):
		fmt.Fprintf(p.out, "  no TMDB movie with ID %d\n", id)
		return Decision{}, false
	case err != nil:
		fmt.Fprintf(p.out, "  TMDB lookup failed: %v\n", err)
		return Decision{}, false
	}
	return Decision{Action: Manual, TMDBID: id, Movie: movie}, true
}

func (p *Prompter) readLine() (string, bool) {
	if !p.in.Scan() {
		return "", false
	}
	return strings.TrimSpace(p.in.Text()), true
}

// describe renders "Title (Year) — overview… [horror]".
func describe(c api.SearchResult) string {
	year := "????"
	if y, ok := match.ReleaseYear(c); ok {
		year = strconv.Itoa(y)
	}
	s := fmt.Sprintf("%s (%s)", c.Title, year)
	if c.OriginalTitle != "" && c.OriginalTitle != c.Title {
		s += fmt.Sprintf(" [%s]", c.OriginalTitle)
	}
	if o := truncate(strings.Join(strings.Fields(c.Overview), " "), overviewRunes); o != "" {
		s += " — " + o
	}
	if c.IsHorror() {
		s += " [horror]"
	}
	return s
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return strings.TrimSpace(string(r[:n-1])) + "…"
}
