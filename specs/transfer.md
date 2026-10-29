---
id: transfer
type: module-design
status: draft
title: Moving sites by file — cPanel export, WP Center export/import, duplicate
parent: architecture
depends-on: [php-runtime, managed-databases, site-lifecycle]
---

# Moving sites by file

## Responsibility

Move a site in and out of WP Center using nothing but files: the cPanel backup, the archive another Mac can
import, and the sources it recognises (WP Center, Studio, Local, WPvivid). Duplicating is the same pair of
operations pointed at a sibling folder.

## Decisions

- **Two exports, because the destinations differ.**
  - *cPanel* (`exportForCPanel`) drives the WPvivid plugin already installed in the site, so the archive is exactly
    what the destination's WPvivid expects. It loads admin first, because WPvivid registers its database hooks only
    inside `is_admin()`; turns off the plugin's pruning for the duration; rewrites `utf8mb4_0900_*` tables when
    MariaDB could not restore them; moves the zips to the export folder and drops the entry from WPvivid's list.
  - *Another WP Center* (`exportForWPCenter`) writes one `<folder>-<date>.zip`: the site as `site/` (renamed with
    `tar -s`, so the folder is not copied), `database.sql` for MariaDB/MySQL (SQLite already lives inside the site)
    and `wpcenter.json` with format, app version, name, PHP, WordPress version, URL and engine/version.
    **No password is written into it.**
- **What a cPanel backup leaves out**: Studio's leftovers (`mu-plugins/sqlite-database-integration/`,
    `99-studio-loader.php`), development mu-plugins (`mu-plugins/dev-*`), WP Center's own mu-plugins
    (`mu-plugins/wpcenter-`), the agent files at the root (`AGENTS.md`, `CLAUDE.md`, `WPCENTER.md`, `STUDIO.md`,
    `DESIGN.md`, `PRODUCT.md`), the app's own `.wpcenter/` folder (old skill copies) and `.mcp.json`, which carries a
    localhost address and an application password from this Mac. An `AGENTS.md` inside a theme is kept. WPvivid
    builds full paths with a double slash (`…/site//AGENTS.md`), so every pattern uses `/+`.
- **An import recognises the source by its marker file**, peeked from the zip index (`zipinfo` + `unzip -p`) so the
  sheet can show the source and a name before anything is written: `wpcenter.json`, `wpvivid_package_info.json`,
  `local-site.json`, `meta.json`. A WPvivid backup is unpacked from its sibling parts, each inner zip landing at the
  site root, in `wp-content/` or in `sql/` according to its name.
- **An import always produces a working local site**: Studio's SQLite drop-in is removed when the site goes to a
  managed server, the database is provisioned and loaded, only the four `DB_*` constants change (or a
  `wp-config.php` is generated, with the table prefix read from the SQL), the local environment type and the update
  lock are added, and the first administrator gets a password nobody knows — reset through `site-access` if it
  fails, so the site is never left locked.
- **URLs are swapped with one `wp search-replace --regex` per old host** (`https?:(\\*/)\1<host>`), which also
  catches JSON-escaped and double-escaped URLs (Breakdance). Every import step runs on the bundled PHP with
  `--skip-plugins --skip-themes`, because the site's own PHP may not be installed yet.
- **The engine stays what it was** for a WP Center source, when that engine and version are installed; anything else
  goes to the managed server from Preferences, else the first installed one. `utf8mb4_0900_*` collations are
  rewritten to `utf8mb4_unicode_ci` before loading.
- **Duplicate is export + import into the original's parent folder**, so the copy keeps engine, version and PHP, and
  gets a new address and password.

## Boundary

Extends `site-lifecycle`'s store from its own file instead of owning state; depends on `managed-databases` to load
SQL and on `php-runtime` for the bundled PHP. The views, the CLI (`wpc export`, `wpc import`, `wpc duplicate`) and
`--selftest` call it.

## Known limitations

Duplicate goes through a temporary `.zip`: on a site of several gigabytes, copying the folder and the database
directly would be faster. Noted in the code and accepted.
