# Security Issues: worktree-feature+read-sh-outline vs dev

No security vulnerabilities were identified in this diff.

Specifically checked for and ruled out:

- **Shell/command injection.** `scripts/render_outline.py`'s `call_logseq` invokes `call.sh` via `subprocess.run([CALL_SH, method, json.dumps(args)], ...)` — an argv list, not a shell string, so there is no `shell=True` and no opportunity for method names or argument content (including anything derived from block content resolved from the graph, e.g. text inside a `((uuid))` or `{{embed ...}}` match) to be interpreted as shell syntax. See [scripts/render_outline.py](../../scripts/render_outline.py), lines 38-52.
- **Auth/URL handling regression.** `scripts/call.sh` — which owns the Logseq HTTP endpoint URL, the `LOGSEQ_TOKEN` bearer header, and JSON encoding for the actual network request — is completely untouched by this branch (confirmed via diff: it does not appear in the changed-files list). All new logic in `scripts/render_outline.py` reuses `call.sh` for every network call rather than reimplementing HTTP or auth handling, so there's no new surface for token leakage or malformed request construction.
- **Allow-list bypass via new flags.** `scripts/read.sh`'s new `--raw`/`--depth`/`--ref-depth` flag-parsing loop (lines 41-68) runs, and finishes, strictly before the `method`/allow-list logic (lines 112-142). None of the new flags can affect which methods are permitted, nor can a crafted flag value reach the allow-list check or be mistaken for a method name — the loop only consumes tokens that start with `--`, and the first non-`--` token is treated as `method` regardless of which flags preceded it. A malicious or malformed `--depth`/`--ref-depth` value is caught by the existing numeric regex validation (lines 117-125: `^[0-9]+$`) before use, so it can't be used to inject anything into the `render_outline.py` invocation beyond a plain integer argument.
- **Output escaping.** Text resolved from block content (references, embeds, metadata values) is written to stdout as plain text for the calling agent to read, not interpolated into any shell command, HTML, or other context where injection would be meaningful — the trust boundary here is "text an LLM agent reads," not a context where markup or command injection is exploitable in the traditional sense.

No further action needed for this diff.
