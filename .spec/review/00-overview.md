# Code Review: worktree-feature+read-sh-outline vs dev

**Reviewer:** Claude Code\
**Date:** 2026-07-13\
**Scope:** Full worktree-feature+read-sh-outline branch relative to dev\
**Stats:** 3 commits, 4 files changed, ~357 additions, ~10 deletions

## Summary

This branch replaces `read.sh`'s raw-JSON output with a human-readable text outline, so an agent calling the `logseq-api` skill no longer has to manually parse Logseq's block-tree/datalog JSON shapes. The core of the change is a new `scripts/render_outline.py`, a stdin-driven renderer that walks either a block tree (`--mode tree`) or datalog query rows (`--mode query`), resolving inline `((uuid))` references and `{{embed ((uuid))}}` block embeds along the way by shelling back out to the existing `call.sh` for extra `getBlock` lookups (cached per-run). `read.sh` gained `--raw` (bypass rendering entirely), `--depth N` (how many levels of nested embeds fully expand), and `--ref-depth N` (a cycle guard for chains of "reference to a reference" blocks, which are otherwise always chased to their final text regardless of `--depth`). `SKILL.md` and `README.md` were updated to describe the new default output and flags.

The design is sound and the plumbing is careful in places that matter: `call.sh` itself is untouched (all new logic lives in the new script), the `read.sh` allow-list check still happens before any flag-driven behavior can affect it, and the bash pipe was written to avoid masking `call.sh` failures behind a misleading "(no results)" from the Python side. The reference-chain-resolution work in particular shows real iteration — an earlier version's chain-detection matched on raw multi-line block content, which the author caught didn't work because Logseq appends a trailing `id:: <uuid>` property line to any referenced block, and fixed it to match on `first_line(content)` instead.

However, there are several issues that should be addressed.

## Issue Summary

| Severity    | Count | Key Issues |
|-------------|-------|------------|
| CRITICAL    | 0     | — |
| HIGH        | 1     | Embed-beyond-depth-budget fallback text gets reprocessed as a fresh reference, corrupting output with nested brackets |
| MEDIUM      | 3     | Pointer-block chain resolution silently drops any real content beyond the first line, no subprocess timeout can hang the whole render, no committed regression tests despite the original plan specifying a fixture suite |
| LOW         | 5     | `TREE_METHODS` coverage gap for other block-shaped methods, duplicated bash lookup-loop boilerplate, Python-style `True`/`False`/`None` in metadata output, module docstring not updated for ref-chain behavior, inconsistent unresolved-reference/embed message wording |

Detailed findings are in the following files:
- [Bug Issues](./01-bugs.md)
- [Refactoring Suggestions](./02-refactoring.md)
- [Security Issues](./03-security.md)
- [Style & Documentation Issues](./04-style-docs.md)
