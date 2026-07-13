---
name: logseq-api
description: Read from and write to a locally running Logseq knowledge base over its HTTP Plugin API. Use whenever the user asks to check, read, search, or recall something "in Logseq" or "in my notes", or asks to log/save/write up a report, summary, journal entry, or artifact of the current work into Logseq. Also covers listing/querying TODOs, tasks, or pages, and appending structured content to today's journal. Trigger on phrases like "check my logseq", "what do my notes say about X", "log this in logseq", "write up a report on Y in logseq", "add this to today's journal", even if the user doesn't name the exact API.
allowed-tools:
  - Bash(~/.claude/skills/logseq-api/scripts/read.sh *)
---

# Logseq HTTP API

Logseq exposes a local HTTP API that mirrors its [Plugin API](https://plugins-doc.logseq.com/) — one endpoint, JSON-RPC-style method names namespaced as `logseq.App.*`, `logseq.Editor.*`, `logseq.DB.*`. This skill covers the two things you'll do with it almost every time: pulling a page into context, and writing a structured artifact back into the graph (usually today's journal).

## Active graph

<<<LOGSEQ-GRAPH
!`~/.claude/skills/logseq-api/scripts/read.sh logseq.App.getCurrentGraph 2>/dev/null`
LOGSEQ-GRAPH

If this block is empty or shows an error, the HTTP server probably isn't running or the token is stale — tell the user rather than retrying blindly (same failure mode as the auth errors mentioned below). Otherwise it's `{url, name, path}` for the active graph; `name` is what deep links need.

## Setup (one-time, done by the human)

The user enables this once in Logseq itself: Settings > Features > "Enable HTTP APIs server", then the 🔌/API icon in the toolbar > "Start server", then generates a token. The token is exported as the `LOGSEQ_TOKEN` env var in your shell — you don't need to fetch or manage it. If a call fails with an auth error, that's a signal to tell the user the server may not be running or the token is stale, not something to work around.

## Making calls

Two scripts, both wrapping the same HTTP endpoint — pick based on whether the call mutates the graph:

- `scripts/read.sh <method> [json-args-array]` — for anything that only reads/queries. It checks the method against a hardcoded allow-list before forwarding to `call.sh`, and refuses anything not on it. **Prefer this for every read** — because it can't mutate by construction, it's auto-approved by this skill's `allowed-tools` (the `read.sh` entries in the frontmatter), so using it means the user isn't interrupted for routine lookups.
- `scripts/call.sh <method> [json-args-array]` — the underlying caller, handles the endpoint URL, auth header, and JSON encoding. Use it directly for anything mutating (`appendBlockInPage`, `insertBatchBlock`, etc) — those should prompt for approval, that's intentional, don't try to route around it.

Don't hand-roll curl for either case; the scripts already got the escaping and error handling right.

```
scripts/read.sh logseq.App.getCurrentGraph
scripts/read.sh logseq.Editor.getPageBlocksTree '["vpn"]'
scripts/call.sh logseq.Editor.appendBlockInPage '["Jul 9th, 2026", "# Report title"]'
```

The second argument, when present, must be a JSON array — it becomes the method's `args`. Omit it for zero-arg methods.

If a method you need isn't on `read.sh`'s allow-list but is genuinely just a getter, add it to `READ_ONLY_METHODS` in that script rather than falling back to `call.sh` for it — that keeps the allow-list accurate for next time instead of quietly working around it. Don't add anything you're not sure is side-effect-free; the list is deliberately conservative (see the comment at the top of `read.sh` for why it can't just be a `logseq.App.*`-style namespace wildcard).

## Workflow 1: reading a page into context

When asked to check, read, or recall something from Logseq:

1. Call `getPageBlocksTree` with the page name: `scripts/read.sh logseq.Editor.getPageBlocksTree '["Page Name"]'`. This returns the full block tree already nested (each block's `children` array holds its sub-blocks) and each block already carries a `level` field, so you don't need to reconstruct depth from `parent`/`left` refs yourself — just walk the tree and indent by `level`, or recursion depth.
2. Read `content` for each block — it's raw markdown, including `key:: value` property lines and Logseq macros like `{{query ...}}` sitting as blocks in their own right. Render it as an indented outline rather than a flat dump so the structure (headers, sub-points) survives.
3. Watch for `marker` on task blocks — `TODO`, `DOING`, `DONE`, `NOW`, `LATER`, and cancellation as either `CANCELED` or `CANCELLED` (both spellings show up in real graphs; check for both when filtering).
4. Blocks with empty `content` are blank-line separators Logseq inserts between sections — safe to skip when rendering, not an error.

If the ask is broader than "read this page" — cross-page search, filtering by property or tag, "find all my open TODOs about X" — reach for `logseq.DB.datascriptQuery` (also on `read.sh`'s allow-list) instead of fetching whole pages and filtering client-side. See `references/datascript-query.md` for the query schema and field reference.

## Workflow 2: writing a structured artifact

When asked to log, save, or write up something (a report, a summary of work just done, a journal entry):

1. **Pick the target page.** Default to today's journal unless the user names a page. Compute the journal page name yourself from the current date — you already know today's date from your own context, no need to query for it. Format: `"MMM Dth, YYYY"`, ordinal day, **no zero-padding** — e.g. `"Jul 9th, 2026"`, `"Jul 1st, 2026"`, `"Jul 23rd, 2026"`. The 11th/12th/13th are the irregular case that take "th" instead of "st"/"nd"/"rd" (so do all other `*11`, `*12`, `*13`). Use this original-case form for API calls; Logseq stores the lowercased version internally as `:block/name` but that's not what you pass in.
2. **Create the top-level block.** `logseq.Editor.appendBlockInPage(pageName, content)` — pass a single markdown heading as content, e.g. `"# Perf test report — join order optimization"`. This creates the page if it doesn't exist (harmless for a journal page that's already there) and returns the new block, including its `uuid` — grab that for the next step.
3. **Insert the structure underneath it.** `logseq.Editor.insertBatchBlock(blockUuid, batchTree, {"sibling": false})` where `batchTree` is an array of `{content, children?}` nodes, nested as deep as you need. `sibling: false` is what makes the tree nest *under* the target block rather than land next to it — if content shows up flat/next-to instead of nested, that option is the first thing to check. A successful call returns `null` — that's success, not a failure signal.
4. **Give it real structure**, not a wall of bullets. This is the whole point of the workflow: use markdown headers (`##`, `###`) for sections like Goal, Methodology, Results, Conclusion, each as its own block with its detail as children. Match the structure to what was actually done — don't force a fixed template onto a two-line status update.

## Other useful methods

- `logseq.App.getCurrentGraph` → `{url, name, path}`. `name` is the graph name needed for deep links.
- `logseq.Editor.getPage(pageNameOrJournalDate)` → page metadata including `uuid` and `journalDay`, if you need to confirm a page exists before writing to it.
- Deep link: `logseq://graph/<graph-name>?block-id=<uuid>` opens Logseq at a specific block. Handy to hand back to the user after writing an artifact, but it only works reliably if Logseq is already running — treat it as a nice-to-have in your response, not something to depend on.

## Reference

- `references/datascript-query.md` — the block/page schema and query patterns for `logseq.DB.datascriptQuery`, for anything beyond a single-page read.
