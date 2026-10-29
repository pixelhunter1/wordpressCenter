---
id: live-sites
type: module-design
status: draft
title: Connected live sites — status, updates and sign-in
parent: architecture
depends-on: [live-plugin]
---

# Connected live sites

## Responsibility

Let a published WordPress site be watched and updated from the app: its versions and pending updates in one table,
updates applied to one site or to all of them, and WP Admin opened already signed in. This is the second runtime
exception to localhost-only.

## Decisions

- **HTTPS only**, with `localhost`/`127.0.0.1` allowed for testing against a local site, where application
  passwords work over http while the site is in the `local` environment. The check lives in one place and applies
  to the address typed, to a redirect target and to every call.
- **No admin password reaches the app.** Connecting discovers the REST index (`/wp-json/`, then `?rest_route=/`),
  opens `authorize-application.php` with `success_url=wpcenter://ligar?pedido=<nonce>`, and the browser hands the
  approved application password back through the `wpcenter` URL scheme. A callback whose nonce is not the pending
  one is ignored. WordPress `urlencode`s the values, so a `+` is a space.
- **Credentials live in `live-sites.json` (mode `0600`)**, beside the local sites' file. They used to be in the
  Keychain, but the app is ad-hoc signed: every build looked like a new app and macOS asked for the Mac password
  once per site. The Keychain is now only read to migrate an old connection.
- **Live sites are a separate world.** They have their own sidebar section, overview and detail views, and never
  mix with local sites. `LiveStore` does not call the local site store at all; it borrows only its storage folder,
  for the export directory choice.
- **The icon is the bundled WordPress symbol**, never the site's favicon: the app does not fetch a site's assets.
- **The plugin keeps itself current.** On every refresh the app sends its bundled plugin zip to a site whose plugin
  is at least 1.3 and older than the app's own, and asks for a one-time manual update when it is older than 1.3.
- **Updates run on the site through WordPress's own upgraders**, with the failure reported per item so one licensed
  plugin cannot hide the rest.

## Boundary

Depends on `live-plugin` for the contract and on `php-runtime` for the bundled zip and its version. The views
render it; no other module does.

## Known limitations

The ad-hoc signature is the reason credentials are stored in a file rather than the Keychain (see above); if the app
is ever signed with a stable identity, the Keychain becomes the better home.
