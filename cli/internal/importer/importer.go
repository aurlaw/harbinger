// Package importer runs a live import: upsert films, replace the snapshot,
// then match new films on TMDB and record the results.
package importer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/aurlaw/harbinger/cli/internal/api"
	"github.com/aurlaw/harbinger/cli/internal/export"
	"github.com/aurlaw/harbinger/cli/internal/match"
	"github.com/aurlaw/harbinger/cli/internal/prompt"
)

// MatchBatchSize is how many match results are posted per request.
const MatchBatchSize = 25

// Decider resolves films the matcher couldn't (prompt.Prompter satisfies it).
type Decider interface {
	Ask(ctx context.Context, name string, year int, candidates []api.SearchResult) (prompt.Decision, error)
}

type Options struct {
	SourceFilename string
	Force          bool
	RetryUnmatched bool    // also re-attempt ambiguous and unmatched films
	Decider        Decider // nil = non-interactive
	Out            io.Writer
}

// EmptySnapshotError is the Worker's 409 empty_snapshot guard.
type EmptySnapshotError struct{ Message string }

func (e *EmptySnapshotError) Error() string {
	return e.Message + "\nre-run with --force if this is intentional"
}

// Summary describes a finished (or quit) import.
type Summary struct {
	SourceFilename string
	Import         api.ImportResult

	Attempted, Auto, Chosen, Ambiguous, Unmatched, Pending int
	Quit                                                   bool

	Library    *Library // nil if the final film list couldn't be fetched
	LibraryErr error
}

type Library struct {
	Films, Horror, Ambiguous, Unmatched int
}

// Run executes the import pipeline. The snapshot is replaced before any
// matching, so quitting or failing mid-match never loses the import.
func Run(ctx context.Context, w api.Worker, ex *export.Export, opts Options) (*Summary, error) {
	out := opts.Out
	if out == nil {
		out = io.Discard
	}

	if _, err := w.UpsertFilms(ctx, ex.Films); err != nil {
		return nil, fmt.Errorf("upsert films: %w", err)
	}

	imp, err := w.Import(ctx, api.ImportRequest{
		SourceFilename: opts.SourceFilename,
		Force:          opts.Force,
		Ratings:        ex.Ratings,
		Watched:        ex.Watched,
		Watchlist:      ex.Watchlist,
		Likes:          ex.Likes,
	})
	var apiErr *api.APIError
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusConflict && apiErr.Code == "empty_snapshot" {
		return nil, &EmptySnapshotError{Message: apiErr.Message}
	}
	if err != nil {
		return nil, fmt.Errorf("import snapshot: %w", err)
	}
	sum := &Summary{SourceFilename: opts.SourceFilename, Import: imp}

	films, err := w.ListFilms(ctx)
	if err != nil {
		return sum, fmt.Errorf("list films: %w", err)
	}
	todo := selectFilms(films, opts.RetryUnmatched)
	sum.Attempted = len(todo)

	m := &matcher{w: w, out: out, decider: opts.Decider, sum: sum}
	loopErr := m.matchAll(ctx, todo)
	// Always flush what was decided, even after quit or an error.
	if err := m.flush(ctx); err != nil {
		return sum, errors.Join(loopErr, fmt.Errorf("record matches: %w", err))
	}
	if loopErr != nil {
		return sum, loopErr
	}

	if films, err := w.ListFilms(ctx); err != nil {
		sum.LibraryErr = err
	} else {
		sum.Library = countLibrary(films)
	}
	return sum, nil
}

func selectFilms(films []api.LibraryFilm, retryUnmatched bool) []api.LibraryFilm {
	var todo []api.LibraryFilm
	for _, f := range films {
		switch f.MatchStatus {
		case api.StatusPending:
			todo = append(todo, f)
		case api.StatusAmbiguous, api.StatusUnmatched:
			if retryUnmatched {
				todo = append(todo, f)
			}
		}
	}
	return todo
}

func countLibrary(films []api.LibraryFilm) *Library {
	lib := &Library{Films: len(films)}
	for _, f := range films {
		if f.EffectiveHorror() {
			lib.Horror++
		}
		switch f.MatchStatus {
		case api.StatusAmbiguous:
			lib.Ambiguous++
		case api.StatusUnmatched:
			lib.Unmatched++
		}
	}
	return lib
}

type matcher struct {
	w       api.Worker
	out     io.Writer
	decider Decider
	sum     *Summary
	batch   []api.Match
}

func (m *matcher) matchAll(ctx context.Context, todo []api.LibraryFilm) error {
	for i, film := range todo {
		fmt.Fprintf(m.out, "[%d/%d] %s (%d) … ", i+1, len(todo), film.Name, film.Year)
		quit, err := m.matchOne(ctx, film)
		if err != nil {
			return err
		}
		if quit {
			m.sum.Quit = true
			m.sum.Pending += len(todo) - i // this film and every one not reached
			return nil
		}
		if len(m.batch) >= MatchBatchSize {
			if err := m.flush(ctx); err != nil {
				return fmt.Errorf("record matches: %w", err)
			}
		}
	}
	return nil
}

// matchOne resolves one film. TMDB failures leave it pending (not an error);
// only a failing Decider aborts the run.
func (m *matcher) matchOne(ctx context.Context, film api.LibraryFilm) (quit bool, err error) {
	res, err := match.Find(ctx, m.w.SearchTMDB, film.Name, film.Year)
	if err != nil {
		m.leavePending(err)
		return false, nil
	}
	if res.Auto != nil {
		if m.record(ctx, film, res.Auto.TMDBID, nil) {
			m.sum.Auto++
			fmt.Fprintln(m.out, "matched")
		}
		return false, nil
	}

	unresolved := api.StatusUnmatched
	if len(res.Candidates) > 0 {
		unresolved = api.StatusAmbiguous
	}
	if m.decider == nil {
		m.recordUnresolved(film, unresolved)
		return false, nil
	}

	fmt.Fprintln(m.out, "needs a decision")
	d, err := m.decider.Ask(ctx, film.Name, film.Year, res.Candidates)
	if err != nil {
		return false, fmt.Errorf("prompt: %w", err)
	}
	switch d.Action {
	case prompt.Choose, prompt.Manual:
		id, movie := d.Candidate.TMDBID, json.RawMessage(nil)
		if d.Action == prompt.Manual {
			id, movie = d.TMDBID, d.Movie
		}
		fmt.Fprint(m.out, "  → ")
		if m.record(ctx, film, id, movie) {
			m.sum.Chosen++
			fmt.Fprintln(m.out, "matched")
		}
	case prompt.Skip:
		fmt.Fprint(m.out, "  → ")
		m.recordUnresolved(film, unresolved)
	case prompt.Quit:
		fmt.Fprintln(m.out, "  → quit matching")
		return true, nil
	}
	return false, nil
}

// record queues a matched result, fetching the movie body unless already
// fetched. Returns false (film left pending) if TMDB fails.
func (m *matcher) record(ctx context.Context, film api.LibraryFilm, tmdbID int, movie json.RawMessage) bool {
	if movie == nil {
		var err error
		if movie, err = m.w.MovieTMDB(ctx, tmdbID); err != nil {
			m.leavePending(err)
			return false
		}
	}
	horror, err := api.MovieIsHorror(movie)
	if err != nil {
		m.leavePending(err)
		return false
	}
	m.batch = append(m.batch, api.Matched(film.LetterboxdURI, tmdbID, horror, movie))
	return true
}

func (m *matcher) recordUnresolved(film api.LibraryFilm, status string) {
	m.batch = append(m.batch, api.Unresolved(film.LetterboxdURI, status))
	if status == api.StatusAmbiguous {
		m.sum.Ambiguous++
	} else {
		m.sum.Unmatched++
	}
	fmt.Fprintln(m.out, status)
}

func (m *matcher) leavePending(err error) {
	m.sum.Pending++
	fmt.Fprintf(m.out, "left pending (%v)\n", err)
}

func (m *matcher) flush(ctx context.Context) error {
	if len(m.batch) == 0 {
		return nil
	}
	if _, err := m.w.RecordMatches(ctx, m.batch); err != nil {
		return err
	}
	m.batch = nil
	return nil
}

// Print writes the import summary.
func (s *Summary) Print(w io.Writer) {
	fmt.Fprintf(w, "\nImport #%d from %s\n", s.Import.ImportID, s.SourceFilename)
	fmt.Fprintf(w, "  snapshot   ratings %d · watched %d · watchlist %d · likes %d · new films %d\n",
		s.Import.Ratings, s.Import.Watched, s.Import.Watchlist, s.Import.Likes, s.Import.NewFilms)
	if s.Attempted == 0 {
		fmt.Fprintln(w, "  matching   nothing to match")
	} else {
		fmt.Fprintf(w, "  matching   %d attempted · %d auto · %d chosen · %d ambiguous · %d unmatched · %d left pending\n",
			s.Attempted, s.Auto, s.Chosen, s.Ambiguous, s.Unmatched, s.Pending)
	}
	if s.Library != nil {
		fmt.Fprintf(w, "  library    %d films · %d horror · %d ambiguous · %d unmatched\n",
			s.Library.Films, s.Library.Horror, s.Library.Ambiguous, s.Library.Unmatched)
	} else if s.LibraryErr != nil {
		fmt.Fprintf(w, "  library    unavailable (%v)\n", s.LibraryErr)
	}
}
