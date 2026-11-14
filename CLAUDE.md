# ai-usage-rainmeter

A Rainmeter widget showing Claude and Codex/ChatGPT usage side by side.
`README.md` covers what it shows and where each number comes from.

## Shipping protocol

Every change ships this way, in this order. No step is skipped because a change
looks small.

### 1. PR

Branch from `main`, commit, push, open a pull request. Never commit straight to
`main`.

### 2. CI

The checks on that PR must be green before it merges
(`.github/workflows/ci.yml`):

- **gitleaks** — fails on a leaked credential. A value that only looks like a
  secret is annotated in place with `# gitleaks:allow` and a reason, not
  excluded wholesale.
- The fetch script **parses on both Windows PowerShell 5.1 and PowerShell 7**.
  It has to run under either.
- The two `Version=` values **agree**.
- **`build.ps1` produces a package with a valid RMSKIN trailer.**

### 3. Release

- Bump `Version=` in **both** `RMSKIN.ini` and
  `Skins/ClaudeUsage/ClaudeUsage.ini`. CI fails if they disagree.
- **If anything changed visually, reshoot `Skins/ClaudeUsage/preview.png`.**
  Shoot it against both live providers, with the background forced opaque so
  the capture backdrop does not tint the panel. A release never ships a preview
  of an older layout — if the skin looks different, the picture is retaken
  before the tag is cut.
- Run `build.ps1`. It appends the 16-byte trailer Rainmeter requires; a
  hand-zipped folder is rejected as an invalid package.
- Tag `vX.Y.Z` — annotated, titled `AI Usage Monitor X.Y.Z`.
- Publish a GitHub release on that tag with the built `.rmskin` attached.

### 4. Tell the site

Message the Claude session working in `C:\Claude\gabrielrossetto.com` so it
updates the site's release links. **The release is not finished until that
message has been sent.**

## Things that bite

- The version lives in **two** files and they must match.
- `Skins/ClaudeUsage/@Resources/Variables.inc` holds the user's own settings
  (`Scale`, `RefreshInterval`, colours). Never overwrite a deployed copy of it.
- The skin parses `usage.json` with two **positional** WebParser regexes, so the
  order of the keys the script writes is load-bearing. `breakdown` is still
  emitted although nothing displays it, because dropping it would renumber the
  groups and break the parse.
- A String meter with empty text collapses to zero height, and rows are stacked
  with `Y=...R` measured from the previous meter's bottom edge — so a blank
  field pulls the next row on top of it. Any field that can come back empty
  gets a placeholder instead (see `New-Row`).
- Text is not clipped by the card: the background shape is fixed at
  `WidgetWidth` while `DynamicWindowSize=1` lets the window grow, so an
  over-long row just draws past the edge onto the desktop. Check a row's width
  against `WidgetWidth - WidgetPadding` before adding to it.
- `dist/` is gitignored. Release assets are uploaded, not committed.
