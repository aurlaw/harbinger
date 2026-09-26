package prompt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/aurlaw/harbinger/cli/internal/api"
)

func candidate(id int, title, date, overview string, genres ...int) api.SearchResult {
	return api.SearchResult{TMDBID: id, Title: title, OriginalTitle: title, ReleaseDate: &date, Overview: overview, GenreIDs: genres}
}

var things = []api.SearchResult{
	candidate(1091, "The Thing", "1982-06-25", "In remote Antarctica, a group of American research scientists are disturbed by a dog.", 27, 9648),
	candidate(60935, "The Thing", "2011-10-12", "Prequel.", 27),
	candidate(10785, "The Thing from Another World", "1951-04-06", ""),
}

// movies fakes /tmdb/movie: known IDs return a body, others 404.
type movies struct {
	calls []int
	fail  error
}

func (m *movies) get(_ context.Context, id int) (json.RawMessage, error) {
	m.calls = append(m.calls, id)
	if m.fail != nil {
		return nil, m.fail
	}
	if id == 999 {
		return nil, &api.APIError{Status: 404, Code: "not_found", Message: "Not found"}
	}
	return json.RawMessage(`{"tmdb_id":` + itoa(id) + `,"is_horror":true}`), nil
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func ask(t *testing.T, input string, cands []api.SearchResult, m *movies) (Decision, string) {
	t.Helper()
	if m == nil {
		m = &movies{}
	}
	var out bytes.Buffer
	d, err := New(strings.NewReader(input), &out, m.get).Ask(t.Context(), "The Thing", 1982, cands)
	if err != nil {
		t.Fatal(err)
	}
	return d, out.String()
}

func TestChooseSecond(t *testing.T) {
	d, out := ask(t, "2\n", things, nil)
	if d.Action != Choose || d.Candidate.TMDBID != 60935 {
		t.Fatalf("decision = %+v", d)
	}
	for _, want := range []string{
		`? No confident match for "The Thing" (1982)`,
		"  1) The Thing (1982) — In remote Antarctica, a group of American research scientis… [horror]",
		"  2) The Thing (2011) — Prequel. [horror]",
		"  3) The Thing from Another World (1951)\n",
		"[1-3] choose · [m] enter TMDB ID · [s] skip · [q] quit matching",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestManualID(t *testing.T) {
	m := &movies{}
	d, _ := ask(t, "m\n1091\n", things, m)
	if d.Action != Manual || d.TMDBID != 1091 || string(d.Movie) != `{"tmdb_id":1091,"is_horror":true}` {
		t.Fatalf("decision = %+v", d)
	}
	if len(m.calls) != 1 || m.calls[0] != 1091 {
		t.Errorf("movie calls = %v", m.calls)
	}
}

func TestManualUnknownIDReprompts(t *testing.T) {
	m := &movies{}
	d, out := ask(t, "m\n999\nm\n1091\n", things, m)
	if d.Action != Manual || d.TMDBID != 1091 {
		t.Fatalf("decision = %+v", d)
	}
	if !strings.Contains(out, "no TMDB movie with ID 999") {
		t.Errorf("output missing not-found message:\n%s", out)
	}
	if len(m.calls) != 2 {
		t.Errorf("movie calls = %v", m.calls)
	}
}

func TestManualBadInputAndFailure(t *testing.T) {
	m := &movies{}
	d, out := ask(t, "m\nabc\nm\n0\nm\n0123\ns\n", nil, m)
	if d.Action != Skip || len(m.calls) != 0 {
		t.Fatalf("decision = %+v, calls = %v", d, m.calls)
	}
	if strings.Count(out, "isn't a TMDB ID") != 3 {
		t.Errorf("output:\n%s", out)
	}

	m = &movies{fail: errors.New("worker down")}
	d, out = ask(t, "m\n5\nq\n", nil, m)
	if d.Action != Quit || !strings.Contains(out, "TMDB lookup failed: worker down") {
		t.Errorf("decision = %+v, output:\n%s", d, out)
	}
}

func TestSkip(t *testing.T) {
	if d, _ := ask(t, "s\n", things, nil); d.Action != Skip {
		t.Errorf("with candidates: %+v", d)
	}
	d, out := ask(t, "s\n", nil, nil)
	if d.Action != Skip {
		t.Errorf("without candidates: %+v", d)
	}
	if !strings.Contains(out, "(no TMDB results)") || strings.Contains(out, "choose") {
		t.Errorf("empty list should offer only m/s/q:\n%s", out)
	}
	if !strings.Contains(out, "[m] enter TMDB ID · [s] skip · [q] quit matching") {
		t.Errorf("output:\n%s", out)
	}
}

func TestInvalidInputReprompts(t *testing.T) {
	d, out := ask(t, "\n0\n4\nx\n 1 \n", things, nil)
	if d.Action != Choose || d.Candidate.TMDBID != 1091 {
		t.Fatalf("decision = %+v", d)
	}
	if n := strings.Count(out, "isn't an option"); n != 4 {
		t.Errorf("rejections = %d, want 4:\n%s", n, out)
	}
	if n := strings.Count(out, "\n> "); n != 5 {
		t.Errorf("prompts = %d, want 5", n)
	}
}

func TestEOFQuits(t *testing.T) {
	for _, input := range []string{"", "x\n", "m\n"} {
		if d, _ := ask(t, input, things, nil); d.Action != Quit {
			t.Errorf("input %q: %+v, want Quit", input, d)
		}
	}
	if d, _ := ask(t, "q\n", things, nil); d.Action != Quit {
		t.Errorf("q: %+v", d)
	}
}

func TestPrompterKeepsBufferedInput(t *testing.T) {
	var out bytes.Buffer
	p := New(strings.NewReader("1\n2\ns\n"), &out, (&movies{}).get)
	var got []Decision
	for range 3 {
		d, err := p.Ask(t.Context(), "The Thing", 1982, things)
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, d)
	}
	if got[0].Candidate.TMDBID != 1091 || got[1].Candidate.TMDBID != 60935 || got[2].Action != Skip {
		t.Errorf("decisions = %+v", got)
	}
}

func TestDescribeOriginalTitle(t *testing.T) {
	c := candidate(1, "Let the Right One In", "2008-01-26", "")
	c.OriginalTitle = "Låt den rätte komma in"
	if got := describe(c); got != "Let the Right One In (2008) [Låt den rätte komma in]" {
		t.Errorf("describe = %q", got)
	}
	c.ReleaseDate = nil
	if got := describe(c); !strings.Contains(got, "(????)") {
		t.Errorf("describe without date = %q", got)
	}
}
