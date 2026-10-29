---
id: php-runtime
type: module-design
status: draft
title: PHP runtime and bundled resources
parent: architecture
---

# PHP runtime and bundled resources

## Responsibility

Find every bundled resource and run every child process on behalf of the rest of the app. `Runtime` is the single
choke point for paths and for spawning; `PHPVersions` is the catalogue of PHP builds a site may use.

## Decisions

- **Resources are resolved through the app bundle, not `Bundle.main`.** `wpc` runs the same binary from a symlink,
  where `Bundle.main` points somewhere else, so `Runtime.root` starts from the resolved executable
  (`Runtime.appBundle`) and everything hangs off it: the PHP binary, WordPress, the SQLite integration plugin,
  WP-CLI, the skills, `router.php`, the helper scripts, `mailpit` and `cloudflared`.
- **One PHP is guaranteed, the rest are optional.** 8.4 ships inside the app; 8.1–8.5 follow cPanel's EasyApache 4
  list, and every version but 8.4 is a Homebrew `php@X` formula installed only on user action. `binary(_:)` also
  accepts `opt/php`, because the newest formula is plain `php` and `php@X` is only its alias. A site whose PHP is
  not installed fails with a clear message instead of falling back to another version.
- **Everything that touches a site runs on the site's own PHP.** `Site.phpExecutable()` resolves it, and every
  WP-CLI call (`wp eval-file`, `wpc wp`) uses it, so a site behaves as its chosen version says.
- **Child processes run without a shell**, with the parent environment merged with `WPCENTER_LANG` (so the helpers
  answer in the app's language) and the caller's variables. `exec` returns exit status plus combined output, one
  pipe for both streams so neither buffer can fill and block; `php` turns a non-zero exit into an error carrying
  that output, while `phpStatus` leaves the decision to the caller, because some helpers warn and still print
  their result line.
- **PHP runs with limits sized for real sites** — 512 MB, 256 MB upload and post, 300 s — so imports and WPvivid
  exports do not die on the built-in server's defaults.

## Boundary

Knows nothing about sites, views, live sites or database servers. Everything that spawns a process or names a
bundled path depends on it; no other module may hard-code a path inside the app bundle.
