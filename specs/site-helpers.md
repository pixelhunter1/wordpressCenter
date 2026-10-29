---
id: site-helpers
type: module-design
status: draft
title: PHP helpers and mu-plugins inside a site
parent: architecture
depends-on: [php-runtime]
---

# PHP helpers and mu-plugins inside a site

## Responsibility

The PHP side of the app: the scripts that run inside a WordPress site, and the mu-plugins that make a local site
behave like one served by WP Center.

## The contract

- Scripts run as `wp eval-file <script>` on the site's own PHP and read everything they need from **environment
  variables** — never argv, so neither a secret nor a path shows up in `ps` (`architecture`, invariant 5).
- Each script prints exactly one `WPCENTER_RESULT {json}` line at the end. `SiteStore.decodeResult` requires that
  line and reports its absence as "the WordPress did not answer", quoting the tail of the output.
- The operation and its arguments are named in the environment (`WPCENTER_ACTION`, `WPCENTER_USER`,
  `WPCENTER_TOKEN`, …), so one script can serve several operations.
- The scripts are bundled, not generated: `Runtime/` is copied into the app by the build, and each script's path is
  declared once in `Runtime` — no other Swift code names one.

## The mu-plugins

Copied into `wp-content/mu-plugins` of every site when it is created, started, or prepared for a sign-in:

- `wpcenter-autologin.php` — accepts a one-time sign-in token, only in the `local` environment, only from loopback,
  and never through a share tunnel (a request carrying `CF-Connecting-IP` is refused). The flows live in
  `site-access`.
- `wpcenter-mail.php` — routes `wp_mail()` to Mailpit when its SMTP port answers, and otherwise leaves WordPress
  untouched.
- `wpcenter-share.php` — makes a tunnel request look like the site: detects the tunnel `Host`, sets `HTTPS`,
  defines `WP_HOME`/`WP_SITEURL` and rewrites `http(s)://localhost:<port>` in the response, without touching the
  database (`sharing`).
- `wpcenter-updates.php` — a workaround for a WordPress 7.1 bug where one failed plugin update locks the update
  queue on the Plugins page. Its header carries the reason; delete it once core fixes that.

The mu-plugins never go to a server: the cPanel export leaves them out (`transfer`), because on the destination
they would either do nothing or break the site.

## Boundary

Knows nothing of SwiftUI, site state or live sites. `site-access` and `site-status` call its scripts; the
`site-lifecycle` copies its mu-plugins.
