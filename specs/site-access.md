---
id: site-access
type: module-design
status: draft
title: Signing in to wp-admin and resetting credentials
parent: architecture
depends-on: [site-helpers, site-lifecycle]
---

# Signing in to wp-admin and resetting credentials

## Responsibility

Get a person into wp-admin without typing a password, and recover a site whose credentials no longer work.

## Decisions

- **A one-time code, not a stored session.** `adminLoginURL` mints 32 random bytes, has the site keep only their
  SHA-256 hash in a 60-second transient, and returns
  `http://localhost:<port>/wp-admin/<page>?wpcenter_login=<token>`. The mu-plugin consumes it, so a link cannot be
  replayed and the admin password never appears in a URL.
- **The page keeps its own query string.** A page such as `post.php?post=1&action=edit` keeps its parameters; the
  token is appended to them, never substituted.
- **The code works only where it can be trusted**: the `local` environment and a loopback request. A share tunnel
  is refused outright, and when auto-sign-in fails the app opens the normal login screen instead of an error page.
- **Opening wp-admin starts the site** if it is stopped.
- **The same script resets credentials.** `wpcenter-access.php` verifies the stored password and sets a new one;
  that is how an imported site gets a fresh admin password (`transfer`).

## Boundary

Depends on `site-helpers` for the script and its mu-plugin, and on `site-lifecycle` for a site that is up with its
database running. The CLI exposes it as `wpc login-url` and `wpc admin`; the views use it for the WP Admin button.
