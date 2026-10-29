---
id: selftest
type: module-design
status: draft
title: The --selftest suite
parent: architecture
depends-on: [site-lifecycle, site-access, transfer, sharing, managed-databases]
---

# The `--selftest` suite

## Responsibility

The only automated test: prove that the app can really create, serve, move and stop WordPress sites on this Mac.

## Decisions

- **End to end, not unit.** There is no XCTest target; `SelfTest` creates real sites in a temporary folder and checks
  them over HTTP. The build has no test harness (`build`), and what breaks in this app is the interaction with PHP,
  WordPress and MariaDB — which only a real site exercises.
- **It covers every engine and PHP version the Mac can run**: SQLite, every installed managed MariaDB/MySQL on a free
  port, and an extra SQLite site on every installed Homebrew PHP, checking `X-Powered-By`. A version that is not
  installed is skipped, not failed.
- **It covers the paths that are hard to see**: one-time sign-in code reuse, credential reset, rename, collation
  conversion, starting and stopping a server created by another process, the export → import round trip, a
  multi-part WPvivid import, the share `Host` header and the `CF-Connecting-IP` refusal, `wp_mail` to Mailpit, the
  agent files and skills being present, foreign-site adoption, the escaping rules of `wp-config.php`, and a skill
  edited inside a site ending up in `.wpcenter/skills-anteriores/` with the bundled copy in place (`agent-files`).
- **The skills updater is tested without the network**: a fetched copy that wins over the bundle (and is discarded
  when the bundle is newer), `wp-center` always coming from the bundle, the patch list re-applied to freshly fetched
  text (twice, since it must be idempotent), and a folder compared with itself counting as no change.
- **It asserts the database pickers against `Database.swift`**, so the cPanel table and the version pickers cannot
  drift (`managed-databases`).
- **The exit code is the result**: `0` when every check passed, `1` otherwise; each check prints ✓ or ✗ in pt-PT.
- **It must be run before a pull request**, and a subset is run by temporarily editing `SelfTest.run()`.

## Boundary

Drives `site-lifecycle`, `site-access`, `transfer`, `sharing` and `managed-databases`. It never touches a user's real
sites: everything happens under a temporary folder.

## Known limitations

It needs the corresponding Homebrew formulas installed to cover those versions, and it runs nowhere automatically —
the suite is manual, so a regression is only caught when someone remembers to run it.
