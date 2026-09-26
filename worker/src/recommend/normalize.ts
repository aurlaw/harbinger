// TS port of the CLI's normalize.Title. Keys are for comparison only; never stored.

// Character classes are built from code points so the source stays ASCII.
const charClass = (codes: number[], flags = "g") => new RegExp(`[${String.fromCodePoint(...codes)}]+`, flags);

const PUNCTUATION: [RegExp, string][] = [
  [charClass([0x2013, 0x2014]), "-"], // en / em dash
  [charClass([0x2018, 0x2019]), "'"], // curly single quotes
  [charClass([0x201c, 0x201d]), '"'], // curly double quotes
];

// Unicode White_Space: the set Go's strings.Fields splits on.
const WHITESPACE = charClass([
  0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680,
  ...Array.from({ length: 11 }, (_, i) => 0x2000 + i), // U+2000..U+200A
  0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
]);

/** Dashes and curly quotes straightened, whitespace runs collapsed, trimmed, lowercased. */
export function normalizeTitle(s: string): string {
  let out = s;
  // One replacement per character, not per run (the "+" in charClass would merge "--").
  for (const [pattern, replacement] of PUNCTUATION) out = out.replace(pattern, (run) => replacement.repeat(run.length));
  return out.replace(WHITESPACE, " ").trim().toLowerCase();
}
