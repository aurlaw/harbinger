// Package normalize builds comparison keys for matching Letterboxd titles
// against TMDB. Keys are never stored; films.name keeps the exported name.
package normalize

import "strings"

var punctuation = strings.NewReplacer(
	"\u2013", "-", // en dash
	"\u2014", "-", // em dash
	"\u2018", "'", // left single quote
	"\u2019", "'", // right single quote / apostrophe
	"\u201C", `"`, // left double quote
	"\u201D", `"`, // right double quote
)

// Title returns the matching key for s: dashes and curly quotes straightened,
// Unicode whitespace runs collapsed to one space, trimmed, and lowercased.
func Title(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(punctuation.Replace(s)), " "))
}
