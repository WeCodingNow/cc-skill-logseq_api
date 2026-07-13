# logseq-api

A Claude Code [skill](https://docs.claude.com/en/docs/claude-code/skills) for reading from and writing to a locally running [Logseq](https://logseq.com/) knowledge base over its HTTP Plugin API.

Two workflows it's built for:
- **Reading a page for context** — "what do my notes say about X", "check my logseq for Y"
- **Writing a structured artifact** — "log this in logseq", "write up a report on the perf test in today's journal"

See [`SKILL.md`](./SKILL.md) for the actual instructions Claude follows; this file is just about installing and using the skill itself.

## Install

This repo *is* the skill — Claude Code loads a skill from a directory containing a `SKILL.md`. To make it available globally, symlink it into your skills directory:

```sh
ln -s /path/to/cc-skill-logseq_api ~/.claude/skills/logseq-api
```

## Requirements

- Logseq running locally with the HTTP APIs server enabled: Settings > Features > "Enable HTTP APIs server", then the 🔌/API icon in the toolbar > "Start server", then generate a token.
- That token exported as `LOGSEQ_TOKEN` in your shell environment.
- `curl` and `jq` on `PATH` (used by `scripts/call.sh`).
- `python3` on `PATH` (used by `scripts/read.sh` to render the default text outline; `--raw` doesn't need it).

## Layout

```
SKILL.md                     - the skill itself: workflows, conventions, when to use which script
scripts/call.sh               - low-level caller: auth header + JSON encoding, used for any API call
scripts/read.sh                - call.sh wrapped with a hardcoded allow-list of non-mutating methods
scripts/render_outline.py      - text-outline renderer read.sh pipes into by default (--raw skips it)
references/datascript-query.md - block/page schema + query patterns for logseq.DB.datascriptQuery
```

## Reducing permission prompts for reads

`scripts/read.sh` only forwards calls whose method is on a curated read-only allow-list (see the comment at the top of the script for why that list can't just be a `logseq.App.*`-style namespace wildcard — some methods in the same namespaces as safe getters are destructive, e.g. `quit`, `relaunch`, `execGitCommand`). Because it can't mutate the graph by construction, it's safe to auto-approve, while `call.sh` — used directly for mutating calls like `appendBlockInPage` or `insertBatchBlock` — keeps prompting as normal.

The skill's own `allowed-tools` frontmatter grants that auto-approval for `read.sh` (and only `read.sh`) while the skill is active — so for the standard symlink install (`~/.claude/skills/logseq-api`) it works out of the box, scoped to when the skill is in use rather than globally.

## Injected graph context

On load, the skill injects the output of `logseq.App.getCurrentGraph` via [dynamic context](https://code.claude.com/docs/en/skills#inject-dynamic-context), so the active graph (and, implicitly, whether the HTTP server is up) is in front of Claude immediately — no manual first call, and an empty/error block is an early signal that the server isn't running or the token is stale.
