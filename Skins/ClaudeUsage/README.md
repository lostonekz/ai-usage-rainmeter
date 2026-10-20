# AI Usage Monitor

Rainmeter widget showing Claude and Codex/ChatGPT usage limits side by side.

Reads OAuth tokens from your local Claude Code (`~/.claude/.credentials.json`)
and Codex (`~/.codex/auth.json`) installs, queries each provider's usage
endpoint, and renders the result. Either provider works on its own; if one is
unavailable the widget says so instead of showing zeroes.

**Settings** — right-click for refresh interval and size presets. Colours,
thresholds and the master `Scale` live in `@Resources\Variables.inc`.

**Troubleshooting, data sources and privacy notes:** see the full README in the
project repository.

Original *Claude Usage Monitor* by **JayDeeAU** (Joe Demian @ Codemian).
MIT licensed.
