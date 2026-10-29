---
id: cli
type: module-design
status: draft
title: The wpc command
parent: architecture
depends-on: [site-lifecycle, transfer, localization]
---

# The `wpc` command

## Responsibility

Give a shell — and therefore an AI agent — the same powers as the window, on the site of the current folder or the
one named with `--path`.

## Decisions

- **Same binary, different name.** `Main` switches to CLI mode when `argv[0]` is `wpc`, and `~/.local/bin/wpc` is a
  symlink to the app executable, installed and removed by the CLI itself. There is no second target to keep in step.
- **The CLI reads the app's preferences** (the `local.wpcenter` defaults suite), because as `wpc` the process is not
  the app and would otherwise see empty defaults. This is also why the GUI and the CLI can both write `sites.json`
  (`site-lifecycle`).
- **The main run loop, not `dispatchMain()`**: `wpc screenshot` renders through WebKit, which traps outside the main
  CFRunLoop.
- **The commands are the app's operations, not a second API**: `list`, `status [--json]`, `create`, `start`, `stop`,
  `admin`, `login-url`, `logs`, `mail`, `context`, `flush`, `export [--wpcenter]`, `import`, `duplicate`,
  `screenshot`, `wp`. `--json` exists for agents; the human output is pt-PT (`localization`).
- **`wpc wp` is real WP-CLI** on the site's own PHP and database, with stdin and stdout inherited so `wp shell` and
  interactive prompts work, and PHP warnings pushed to stderr so `--json` stays clean.
- **`screenshot` opens only the site itself**: an off-screen `WKWebView` with a non-persistent data store, 1 px per
  point, the full page up to 16000 px, with `--width`, `--viewport` and `--out`. A `wp-admin/…` page goes through
  the one-time sign-in and keeps its own query string.
- **`logs` shows errors, not noise**: the last megabyte of the site log with request lines, server startups and the
  browser's https attempts filtered out, plus `wp-content/debug.log`.
- **`context` and `flush` go through the PHP tools script** (`site-status`), so an agent sees WordPress's own view of
  the site. `flush` deletes transients through the API rather than a `LIKE` query, because SQLite handles `LIKE`
  escapes differently.
- **`--path` is parsed only before the `wp` subcommand**, because after it the flag belongs to WP-CLI.

## Boundary

Depends on `site-lifecycle`, `transfer` and `localization`, and is what `agent-files` tells agents to use. It
contains no SwiftUI.
