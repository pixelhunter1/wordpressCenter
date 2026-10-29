---
id: managed-databases
type: module-design
status: draft
title: Managed MariaDB/MySQL servers and the cPanel catalogue
parent: architecture
depends-on: [php-runtime]
---

# Managed databases

## Responsibility

Run the MariaDB/MySQL servers that sites use, and be the single record of which versions a cPanel host can
install.

## Decisions

- **cPanel's table is the catalogue.** `Database.swift` mirrors docs.cpanel.net; the version pickers read it, and
  `--selftest` asserts they still match (`selftest`). A version added in one place must be added in the other.
  Homebrew narrows the list further: MariaDB 10.5 is in cPanel's table and does not exist on Homebrew.
- **One Homebrew formula per version, keg-only.** No database server is bundled. Installing and removing happen
  only on user action, and are refused while a site still uses that version.
- **A fixed port per version and a short socket.** MariaDB uses 3310+, MySQL 3320+, away from 3306 so a MySQL
  already on the Mac keeps working. The socket is `/tmp/wpcenter-<formula>.sock` because Unix socket paths stop at
  104 characters.
- **Root is reachable only through the socket**, with no password and no network login: the servers are for this
  Mac's sites, not for the network.
- **`utf8mb4_unicode_ci` is the server default**, not MySQL 8's `utf8mb4_0900_ai_ci`: MariaDB 10.11 — the cPanel
  default — rejects the latter, and a WPvivid restore into it fails.
- **Each site gets its own database and user**, cPanel-style (`wpc_xxxxxxxxxx`, at most 32 characters), separate
  from the WordPress login and provisioned by `db-check.php` over the root socket.

## Boundary

Depends on `php-runtime` for the PHP that runs the probe. `site-lifecycle` asks it to provision a database and keep
its server up; `transfer` asks it for a target when loading SQL written by another app. It knows nothing of views,
live sites or the CLI.
