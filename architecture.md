---
id: architecture
type: architecture-design
status: draft
title: Architecture — one executable, local-only, layered by convention
parent: wp-center
---

# Architecture

## Shape

One executable, three modes chosen in `Main` before any UI is built:

| Selected by | Mode | Entry |
|---|---|---|
| `argv[0]` named `wpc` | CLI | `CLI.run()` — reads the app's preferences through the `local.wpcenter` UserDefaults suite and runs `CFRunLoopRun()`, because the WebKit screenshot needs the main run loop |
| `--selftest` | test suite | `SelfTest.run()` (`selftest`) |
| anything else | GUI | `WPCenterApp` |

`~/.local/bin/wpc` is a symlink to the app binary, so both modes share one codebase, one `sites.json` and one set
of preferences. That sharing is the reason state can be written by two processes at once (`site-lifecycle`).

## Where things live

- `Sources/WPCenter/*.swift` — the whole app: one Swift target, one namespace.
- `Runtime/` — the PHP side (`router.php`, the helper scripts, the mu-plugins) and the agent skills; the build
  copies it to `Contents/Resources/runtime` (`site-helpers`, `agent-files`).- `Plugin/wpcenter-ligacao/` — the WordPress plugin for live sites, zipped into the app by the build
  (`live-plugin`).
- `Localization/` — `en.lproj` holds the English text; `pt-PT.lproj` and `pt.lproj` only mark Portuguese as
  available (`localization`).
- `build.sh` — compiles and assembles `dist/WP Center.app` (`build`).
- `~/Library/Application Support/WP Center/` — state: `sites.json`, `live-sites.json`, `Logs/`,
  `Databases/<formula>/data`.

Resources are located through `Runtime.appBundle`, which resolves the real executable through symlinks;
`Bundle.main` is wrong when the same binary is invoked as `wpc`.

## Modules and edges

Every node below is conceptual — none is a directory. Each has its own spec in `specs/`.

```
   GUI · wpc · --selftest  (entry points, own no state)
        ↓
   interface ──► live-sites ──► live-plugin
        ↓            │
   site-lifecycle ◄──┘ (storage folder only)
     ↓      ↓      ↘
php-runtime  managed-databases  agent-files ──► cli
     ↑
site-helpers ──► site-access, site-status, sharing, transfer
```

- `site-lifecycle` is the core: the site set, its processes and its persistence. Everyone calls it; it knows none
  of them.
- `php-runtime` sits under everything that runs a child process, and is the only place that names a bundled path
  or a PHP helper script.
- `transfer` and `site-status` extend `SiteStore` in their own files instead of owning new state.
- `live-sites` deliberately never calls the local site store — its only shared dependency is `php-runtime`, for
  the bundled plugin zip.

`Engine.swift` holds `Runtime`, `Site`, `SiteStore`, `LocalServer` and `PHPVersions` in one ~1300-line file, so
the map above is the intended boundary rather than the file layout. *Unconfirmed: whether splitting it is wanted.*

## Invariants

1. **localhost only.** No runtime connection leaves the Mac except three things the user starts: a share tunnel, a
   connected live site, and the skills update (which only fetches skill text from GitHub, never a binary). Live sites
   are HTTPS-only, with `localhost`/`127.0.0.1` allowed for testing. Auto-sign-in refuses any request carrying
   `CF-Connecting-IP`, so a share link can never mint a session.
2. **Every process has an owner.** A site server is either a child process of this app or a port bound by the
   same router serving the same folder — nothing else counts as "running", and whatever the app stops, it stops
   as a whole tree.
3. **Ports are per site and checked on both families.** Sites listen on `127.0.0.1` only, never `0.0.0.0`, and a
   port is free only when it binds on both `127.0.0.1` and `::1`.
4. **State is a file the user owns.** `sites.json` and `live-sites.json` are mode `0600` and hold credentials; no
   password is kept anywhere else.
5. **Secrets never travel in argv.** PHP helpers read their inputs from the environment and answer one
   `WPCENTER_RESULT {json}` line.
6. **The app configures WordPress**: generated `wp-config.php`, `WP_ENVIRONMENT_TYPE=local`, automatic core
   updates off.
7. **The UI is main-actor only.** `SiteStore`, `LiveStore`, `CLI` and `SelfTest` are `@MainActor`; slow work
   leaves the main thread through `Task.detached` or a `nonisolated static` helper.
8. **Layers hold by convention, not by the compiler.** `Engine.swift` knows nothing of live sites, views or the
   CLI; `Live.swift` never calls `SiteStore` methods; only `Views.swift` reaches into both presentation files.

Two dependency edges are cycles and are accepted: `Database.swift` calls `L()` from `Engine.swift`, and
`Views.swift` ↔ `LiveViews.swift` share their chrome. Any other backwards edge is a mistake.
