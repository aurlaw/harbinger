package normalize

import "testing"

func TestTitleEquivalents(t *testing.T) {
	cases := []struct {
		name string
		a, b string
	}{
		{"en dash vs hyphen and case", "Mission: Impossible – Fallout", "mission: impossible - fallout"},
		{"em dash", "Alien\u2014Covenant", "alien-covenant"},
		{"curly vs straight apostrophe", "Rosemary\u2019s Baby", "Rosemary's Baby"},
		{"left single quote", "\u2018Salem\u2019s Lot", "'Salem's Lot"},
		{"curly double quotes", "The \u201CThing\u201D", `the "thing"`},
		{"whitespace", "  The\t\tWitch \u00A0 (2015)\n", "the witch (2015)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ka, kb := Title(tc.a), Title(tc.b)
			if ka != kb {
				t.Errorf("Title(%q) = %q, Title(%q) = %q; want equal", tc.a, ka, tc.b, kb)
			}
		})
	}
}

func TestTitleExact(t *testing.T) {
	cases := map[string]string{
		"Mission: Impossible – Fallout":   "mission: impossible - fallout",
		" \u00A0As Above,\u2003So Below ": "as above, so below",
		"":                                "",
		"   ":                             "",
	}
	for in, want := range cases {
		if got := Title(in); got != want {
			t.Errorf("Title(%q) = %q, want %q", in, got, want)
		}
	}
}
