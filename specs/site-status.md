---
id: site-status
type: module-design
status: draft
title: Site status and storage reporting
parent: architecture
depends-on: [site-helpers, site-lifecycle]
---

# Site status and storage reporting

## Responsibility

Say what a site already knows about itself — updates, debug mode — and how much room it takes, without going online
and without blocking the window.

## Decisions

- **Updates come from WordPress's own cache.** `wpcenter-tools.php health` reads the `update_*` transients and the
  core version, never wordpress.org, so the card works offline and the site's existence is never advertised.
- **Only while the site is running**: the helper runs inside the site, and a stopped site has nothing to ask.
- **Space is measured off the main thread**, in one walk of the folder, classified by prefix: uploads, plugins,
  WPvivid backups, the SQLite `database/` folder, and everything else. The folder goes through `realpath` because
  the enumerator reports `/private/var/…` where `resolvingSymlinksInPath` strips `/private`.
- **A MariaDB/MySQL site's database size is the size of its data directory** under `Databases/<formula>/data`, not a
  sum of tables: it is what the disk really holds.
- **Old backups are deleted through WPvivid, not just from disk.** Backups are grouped by `wpvivid-<id>`; "delete
  the old ones" trashes all but the newest and removes them from WPvivid's list, so the plugin never offers a
  restore from something gone.

## Boundary

Depends on `site-helpers` for the tool script and on `site-lifecycle`. Its results are read by the views and by
`wpc status`; the only thing it changes in a site is the backup pruning the user asks for.
