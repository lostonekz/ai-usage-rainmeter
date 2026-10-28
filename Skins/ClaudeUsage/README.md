# AI Usage Monitor

Rainmeter widget showing Claude and Codex/ChatGPT usage limits side by side.

Reads the Claude figures from the usage API, using the OAuth token in your
local Claude Code install (`~/.claude/.credentials.json`), and the Codex ones
from Codex's own session log (`~/.codex/sessions`). Either provider works on
its own; if one is unavailable the widget says so instead of showing zeroes.
The Codex numbers are a snapshot of your last Codex turn, and the plan badge
carries their age.

**Settings** — right-click for refresh interval and size presets. Colours,
thresholds and the master `Scale` live in `@Resources\Variables.inc`.

**Troubleshooting, data sources and privacy notes:** see the full README in the
project repository.

Original *Claude Usage Monitor* by **JayDeeAU** (Joe Demian @ Codemian), which
grants no licence and is all rights reserved. Only this fork's own changes are
offered under MIT. Not open source — see LICENSE in the project repository.
