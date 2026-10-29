---
id: sharing
type: module-design
status: draft
title: Sharing a site through a Cloudflare Quick Tunnel
parent: architecture
depends-on: [site-lifecycle, site-helpers]
---

# Sharing a site through a Cloudflare Quick Tunnel

## Responsibility

Give a local site a temporary public https address, so a client can see work in progress. This is one of the two
runtime exceptions to localhost-only, and it exists only while the user keeps it open.

## Decisions

- **A Quick Tunnel, no account.** `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:<port>`, with the
  binary bundled, so there is nothing to install and no Cloudflare account or token is involved.
- **The address is read from the log.** Cloudflared writes `https://….trycloudflare.com` to
  `Logs/<site-id>-partilha.log` — a file, not a pipe, because an unread pipe fills and blocks the tunnel.
- **The app waits for the name to resolve through DNS-over-HTTPS on 1.1.1.1**, not through the system resolver: an
  early plain lookup gets negatively cached by the router for minutes and the link then looks broken.
- **A share starts the site** if it is stopped, and it ends when the user terminates it, when the site stops, and
  always when the app quits.
- **A share link can never sign anyone in.** Tunnel requests arrive from loopback, so the auto-sign-in mu-plugin
  refuses any request carrying `CF-Connecting-IP` (`site-access`).
- **The site's own URLs are rewritten per request, not in the database.** `wpcenter-share.php` sees the tunnel
  `Host`, sets `HTTPS`, defines `WP_HOME`/`WP_SITEURL` and swaps `http(s)://localhost:<port>` in the response, so the
  database still holds local URLs when the share ends.

## Boundary

Depends on `site-lifecycle` (a running site and the log folder) and `site-helpers` (the mu-plugin), plus
`php-runtime` for the bundled `cloudflared`. Nothing else may open an outbound tunnel.
