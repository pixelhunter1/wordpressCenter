# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

WP Center is a native macOS (SwiftUI) app for local WordPress sites, rebuilt from WordPress Studio without any external services (no WordPress.com, sync, AI, telemetry, updates). The only network target at runtime is `localhost`. Code comments are European Portuguese (pt-PT). UI strings are written in pt-PT and translated to English (see Localization below).

## Commands

```bash
./build.sh                                              # build dist/WP Center.app
"dist/WP Center.app/Contents/MacOS/WPCenter" --selftest # end-to-end test suite (exit 0 = all pass)
open "dist/WP Center.app"                               # run the GUI
```

- `build.sh` copies the PHP runtime, WordPress, the SQLite plugin, WP-CLI and three skills **from the installed Studio app** (`/Applications/Studio.app`, override with `STUDIO=`). Nothing is downloaded.
- Toolchain quirks, both handled in `build.sh`: `swift build` is broken in the current Command Line Tools (SwiftPM fails to load), so the build calls `swiftc` directly on `Sources/WPCenter/*.swift`. Swift 6.3 doesn't compile against the macOS 27 SDK, so `SDKROOT` is set to the newest `MacOSX26.*.sdk`. `Package.swift` exists only to open the project in Xcode.
- Code compiles in Swift 5 language mode: bare `/regex/` literals are not enabled, so use `#/.../#`.
- There is no XCTest target and no linter. `--selftest` (`SelfTest` in `App.swift`) is the test suite: it creates real sites in a temp dir (SQLite, plus every managed MariaDB/MySQL version installed via Homebrew whose port is free), starts them, makes HTTP requests and checks login, access reset, rename, collations and stop behaviour. To run a subset, temporarily edit `SelfTest.run()`.
- A running GUI keeps the old binary. Quit it (`osascript -e 'tell application id "local.wpcenter" to quit'`) before reopening after a build.

## Architecture

**One executable, three modes** (`Main` in `App.swift`):
- the GUI (`WPCenterApp`);
- the CLI `wpc`, selected when `argv[0]` is `wpc` (a symlink `~/.local/bin/wpc` → the app binary). In CLI mode `UserDefaults.standard.addSuite(named: "local.wpcenter")` makes it read the app's preferences;
- `--selftest`.

**Runtime lookup.** `Runtime.root` resolves the real executable through symlinks (`Runtime.appBundle`) because `Bundle.main` is wrong when invoked as `wpc`. Everything lives in `Contents/Resources/runtime/`: the native `php`, `wordpress`, `sqlite-database-integration`, `wp-cli.phar`, `skills/` and the scripts from `Runtime/`.

**`SiteStore` (`Engine.swift`, `@MainActor`) is the core.**
- State lives in `~/Library/Application Support/WP Center/`: `sites.json` (mode 0600, contains passwords), `Logs/<site-id>.log`, `Databases/<formula>/data`.
- Each site is served by `php -S 127.0.0.1:<port> router.php` with `PHP_CLI_SERVER_WORKERS=4`. The workers survive a SIGTERM to the master, so stopping goes through `terminateTree` (`pkill -P`).
- "Running" means either an owned `Process` or a bound port. `isPortFree` binds both 127.0.0.1 and ::1, because Studio listens on ::1 and browsers resolve `localhost` to IPv6 first. It sets `SO_REUSEADDR` so that TIME_WAIT sockets don't make a stopped site look running.
- The generated `wp-config.php` sets `AUTOMATIC_UPDATER_DISABLED`. The bundled WordPress lags behind Studio releases, and a background core update would contact wordpress.org and answer 503 "Maintenance" mid-request (it used to break `--selftest`). Users can still update manually from the dashboard.
- Servers started by another process (app ↔ `wpc`) are stopped by matching `lsof`/`ps` output against the router path and the site path.

**PHP versions (`PHPVersions`, `Engine.swift`).** Each site stores `phpVersion` (nil on older sites means the bundled 8.4). Versions 8.1–8.5 follow cPanel's EasyApache 4. 8.4 is the bundled `runtime/php`; the others are Homebrew `php@X` formulas, installed or removed only on user action (Settings → Advanced, or Install in the New Site sheet). `binary(_:)` also accepts `opt/php` when `php@X` is only an alias of the newest formula. Everything that runs a site (`start`, WP-CLI calls, `wpc wp`) goes through `site.phpExecutable()`, which throws a clear error if that version isn't installed. `--selftest` runs an extra SQLite site on every Homebrew PHP that is already installed and checks `X-Powered-By`.

**Managed databases (`LocalServer`).**
- Binaries are versioned, keg-only Homebrew formulas (`mariadb@10.11`, `mysql@8.4`, …).
- Each version has a fixed port (3310+ for MariaDB, 3320+ for MySQL) and a socket at `/tmp/wpcenter-<formula>.sock`. Unix sockets have a 104-character limit, so keep the socket path short.
- Data dirs are initialised with root, no password, reachable only through the socket. Servers start with `--collation-server=utf8mb4_unicode_ci`, because MySQL 8's default `utf8mb4_0900_ai_ci` is rejected by MariaDB 10.11 (the cPanel default) and breaks WPvivid restores.
- Each site gets its own random database and user in cPanel style (`wpc_xxxxxxxxxx`, at most 32 characters), separate from the WordPress login. `db-check.php` provisions them through the root socket.

**PHP helper scripts (`Runtime/*.php`)** run inside the site with `wp eval-file`.
- Inputs come from **environment variables**, never argv, so secrets don't show in `ps`.
- Each script prints one `WPCENTER_RESULT {json}` line, which Swift decodes.
- Scripts:
  - `wpcenter-access.php`: login token, credential check, password reset.
  - `wpcenter-collation.php`: finds or converts `utf8mb4_0900_*` tables.
  - `wpvivid-export.php`: the cPanel export.
- Supporting files:
  - `wpcenter-autologin.php`: a mu-plugin copied into every site. It accepts a one-time, 60-second token stored only as a SHA-256 transient, and only works in the `local` environment and from loopback.
  - `db-check.php`: tests the DB connection and provisions the database and user.
  - `router.php`: the router for PHP's built-in server.

**Export to cPanel** drives the WPvivid plugin installed in the site, so the backup format always matches the WPvivid on the server.
- WPvivid only registers its DB-dump hooks under `is_admin()`, so the script calls `load_admin()`.
- WPvivid applies `exclude_regex` to full paths built with a double slash (`…/site//AGENTS.md`), so exclusion patterns use `/+`.
- Pruning of the oldest backups is disabled for the duration of the export.
- The resulting zips are moved to the export folder (Downloads by default) and the entry is removed from WPvivid's backup list.
- Excluded from the backup: leftovers from Studio imports, `mu-plugins/dev-*`, the WP Center mu-plugin and the agent files. WPvivid's restore ignores `wp-config.php` and `db.php` on the target server.

**Email (Mailpit).** `build.sh` bundles the Homebrew `mailpit` binary (single file, system libs only), so users install nothing. `ensureMailpit()` starts it on site start (SMTP `127.0.0.1:1025`, UI `127.0.0.1:8025`, DB in the state dir) unless port 1025 is already taken, in which case the existing Mailpit is reused. `wpcenter-mail.php` (mu-plugin, copied like the autologin one and excluded from export by the `mu-plugins/wpcenter-` rule) routes `wp_mail()` there, only in the `local` environment and only when the port answers.

**Sharing (Cloudflare Quick Tunnel).** The only network target besides `localhost`, and only on user action. `build.sh` bundles `cloudflared` from Homebrew. `SiteStore.share` runs `cloudflared tunnel --url http://127.0.0.1:<port>` with its output in `Logs/<site-id>-partilha.log`, reads the `https://….trycloudflare.com` URL from there, then waits for the name to resolve through DoH on 1.1.1.1 (an early system DNS lookup gets negatively cached by the router for minutes). Shares close on Terminate, on site stop and always on app quit. `wpcenter-share.php` (mu-plugin) detects the tunnel `Host`, sets `HTTPS`, defines `WP_HOME`/`WP_SITEURL` and swaps `http(s)://localhost:<port>` in the response, without touching the database. Tunnel requests arrive from 127.0.0.1, so the autologin refuses any request carrying `CF-Connecting-IP`.

**Import from a Studio / Local export file (`Import.swift`).** Neither app needs to be installed. `importSite(from:name:)` unpacks the .zip or .tar.gz with `/usr/bin/tar` (bsdtar reads both) into a temp dir, then finds the content, even when it sits inside one top-level folder.
- Studio export (`studio export`): `wp-content/`, `wp-config.php`, `sql/*.sql` (MySQL syntax) and `meta.json` (`phpVersion`, `siteUrl`). There is no WordPress core, so the bundled one is used. A SQLite `db.php` drop-in is removed.
- Local export: the site folder (`app/public/` with the full WordPress, `app/sql/*.sql`, `conf/`) plus `local-site.json` (`services.php.version`).
- The SQL always goes to a managed MariaDB/MySQL server: the default from Preferences, or else the first one installed. `utf8mb4_0900_*` collations are rewritten to `utf8mb4_unicode_ci` before loading, because MariaDB rejects them. Only the four `DB_*` constants in the export's `wp-config.php` change. Without a wp-config one is generated, with the table prefix read from the SQL.
- URLs are swapped with one `wp search-replace --regex` per old host, `https?:(\\*/)\1<host>`, which also catches JSON-escaped and double-escaped (Breakdance) URLs. The import steps run on the bundled PHP with `--skip-plugins --skip-themes`, because the site's PHP may not be installed yet. The first admin gets a new password. `wpc import <file> [--name "Name"]` does the same from the terminal.

**Per-site agent files.** `writeAgentFiles` writes `AGENTS.md`, `CLAUDE.md`, `WPCENTER.md` and `.claude|.agents/skills` into each site, only when they're missing. They tell agents to use `wpc wp` instead of a system `wp`.

**Localization.** The pt-PT source text is the key: SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`) are translated automatically. Strings built outside a view go through `L("…")` (`Engine.swift`), which uses `Runtime.appBundle` so `wpc` finds the translations, and `AppError("…")` translates itself (`AppError(verbatim:)` for text that is already final, such as command output). A `String` passed to `Text`/`Label` is shown verbatim, so wrap it in `L` where it is built. Write plurals as two sentences, not with `"s"` ternaries. `Localization/en.lproj/Localizable.strings` holds the English text; `pt-PT.lproj` and `pt.lproj` are empty and only mark Portuguese as available (pt-PT so system controls use Portugal’s wording, e.g. "Procurar", not Brazil’s "Buscar"). Macs in Portuguese get Portuguese and every other language gets en (`CFBundleDevelopmentRegion` = en). `build.sh` extracts keys with `swiftc -emit-localized-strings` and lists any key missing from en. AGENTS.md/WPCENTER.md for sites and `--selftest` output stay in pt-PT.

**Other places to know:**
- `Database.swift` holds the cPanel & WHM supported-version table (sourced from docs.cpanel.net). `--selftest` asserts that the version pickers match it, so keep the two in sync.
- `Preferences.swift` (`Prefs`) holds every UserDefaults key, shared with `@AppStorage` in the views. It also holds launch/quit behaviour, login item (`SMAppService`), default DB and browser/editor/terminal choice.
- `Views.swift` holds all the SwiftUI views: the sidebar, the card-based site detail, the New Site sheet, the cPanel reference sheet and the tabbed Settings.
