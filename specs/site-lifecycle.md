---
id: site-lifecycle
type: module-design
status: draft
title: Site lifecycle — sites.json, ports and owned processes
parent: architecture
depends-on: [php-runtime, managed-databases, agent-files, site-helpers]
---

# Site lifecycle

## Responsibility

Own the set of local sites and their running processes: the single source of truth for what exists, where it
lives, which port it holds and whether it is up.

## Decisions

- **`sites.json` is the database.** No store and no server: one JSON array, written atomically and chmod `0600`
  because it holds each site's admin password. A record carries the name, folder, port, admin credentials,
  WordPress version, database, creation date and PHP version (`nil` on records older than per-site PHP, which means
  the bundled 8.4).
- **Two processes write it, so a save adopts first.** The GUI and `wpc` mutate the same file. Every save re-reads
  the disk and takes in sites whose ids this process has never seen; ids it has known — including ones it deleted —
  are never taken back. That yields "a site created by the other process shows up" and "a site deleted here does
  not come back", and accepts what it cannot prevent: a rename or a setting changed by the other process is
  overwritten by this process's next save. The GUI also re-adopts on a timer, so `wpc create` appears without a
  relaunch.
- **Running means "this app started it" or "the port is busy".** A server started by `wpc` counts, so the GUI shows
  it running. `isPortFree` binds `127.0.0.1` and `::1` with `SO_REUSEADDR` before declaring a port free: Studio
  listens on `::1` only, browsers resolve `localhost` to IPv6 first, and a `TIME_WAIT` socket must not make a
  stopped site look busy.
- **Stopping ends the tree.** The built-in server runs `PHP_CLI_SERVER_WORKERS=4` and those workers survive a
  SIGTERM to the master, so stopping goes through `pkill -P`. A server this process does not own is found by
  matching `lsof` and `ps` against both the router path and the site's folder.
- **A site is always `127.0.0.1:<port>`**, never `0.0.0.0` — localhost-only is an `architecture` invariant.
- **Lifecycle follows the preferences**: start on launch, stop on quit, keep running when the window closes, open at
  login. The views read the setting; this module applies it.
- **Mailpit is a sidecar.** It starts with the first site on `127.0.0.1:1025`/`8025` unless 1025 is already taken,
  in which case the running instance is reused and the app only opens its UI (`site-helpers` routes the mail).

## Boundary

Depends on `php-runtime` (PHP binary, router), `managed-databases` (a site's database is provisioned and kept
alive through it), `site-helpers` (its mu-plugins are copied into the site) and `agent-files` (written on create
and rename). It knows nothing of live sites, views or the CLI: those call it.

`transfer` and `site-status` extend the same store from their own files; `site-access` and `sharing` call it.
