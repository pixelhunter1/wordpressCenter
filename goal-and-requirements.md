---
id: wp-center
type: goal-and-requirements
status: draft
title: WP Center — local WordPress sites on a Mac, ready for cPanel
---

# WP Center

## Goal

A native macOS app that creates and runs WordPress sites with nothing outside `localhost`, and gives each of
them a predictable path to a cPanel server: the database engine, database version and PHP version the host can
install, and a backup the host can restore.

## Problem

WordPress Studio did the local part well but carried a service layer behind it — a WordPress.com account, sync,
AI, telemetry, forced core updates — none of which a developer building a site for a cPanel host wants. WP
Center keeps the local workflow and drops the services, so the only connections that leave the Mac are the ones
the user starts.

## Audience

Freelancers and small agencies who build WordPress sites on a Mac and restore them on cPanel/WHM hosting.

*Unconfirmed: inferred from the README and from the feature set (cPanel parity, WPvivid export). The user was not
asked.*

## Capabilities

- Create a fully installed WordPress site in one step, with a random admin password and the agent files of
  `agent-files` already in place.
- Run each site on its own `127.0.0.1` port; start, stop, open, rename, duplicate and delete it (`site-lifecycle`).
- Pick per site the PHP version (8.1–8.5) and the database — SQLite, or a managed MariaDB/MySQL in a version
  cPanel installs (`php-runtime`, `managed-databases`).
- Sign in to wp-admin without typing a password (`site-access`).
- Report the updates WordPress already knows about, whether debug mode is on, how much space each area uses, and
  prune old backups (`site-status`).
- Export to cPanel through the site's own WPvivid plugin; export and import a whole site as one file; import
  Studio, Local and WPvivid exports (`transfer`).
- Catch every email the site sends in a bundled Mailpit inbox.
- Share a site through a temporary Cloudflare tunnel while the link is open (`sharing`).
- Connect published WordPress sites, see their versions and pending updates, update them, and open their wp-admin
  already signed in (`live-sites`).
- Give a CLI (`wpc`) and per-site agent instructions, so an AI agent can do all of the above on the user's behalf
  (`cli`, `agent-files`).

## Non-goals

Excluded by decision:

- **No external service.** No account, no sync, no AI, no telemetry, no crash reporting, no automatic app update.
  At runtime the app talks to `localhost` only, except the two connections the user starts: a share tunnel and a
  connected live site (`sharing`, `live-sites`).
- **The app fetches nothing on its own.** At runtime and at build the pieces come from the developer's own machine
  (Studio's resources, Homebrew formulas, `Vendor/`); nothing is fetched at launch. Two things do go to the internet,
  and both are started by a person: `Scripts/update-skills.sh`, run by hand by the developer to bump the bundled
  skills and the impeccable engine (`agent-files`, `build`), and the *Procurar atualizações* button in Definições →
  Habilidades, which fetches skill text from GitHub only when clicked and never a binary.
- **No host control panel.** Sites are local and single-user; the app does not manage a server, a multisite
  network, or anyone else's account.
- **Only what cPanel installs.** PHP and database versions outside the tables of `managed-databases` are out of
  scope, even when Homebrew offers them.

Inferred, not confirmed: **macOS on Apple silicon only** — the bundled PHP, `mailpit` and `cloudflared` are arm64
and the build produces no other architecture.

## Principles

- **The host is the target.** A feature that makes a site behave on the Mac in a way the server cannot reproduce
  is wrong, even when it is more convenient.
- **The app owns WordPress's configuration.** It writes `wp-config.php`, marks the site `local` and disables
  automatic core updates, so no background update contacts wordpress.org mid-request. Updating by hand in the
  dashboard still works.
- **No secret in a command line**, and none in a world-readable file: child processes take secrets through the
  environment, state files are owner-only.
- **Reversibility by files.** Everything the user creates can be exported, imported or duplicated with the app
  alone; nothing depends on an account.
- **Portuguese first.** pt-PT text is the source and the localization key, with English beside it
  (`localization`).
