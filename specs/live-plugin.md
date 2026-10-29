---
id: live-plugin
type: submodule-design
status: draft
title: WP Center Ligação — the WordPress side of live sites
parent: live-sites
---

# WP Center Ligação

## Responsibility

The WordPress side of `live-sites`: one plugin, installed on the published site, that answers the app's REST calls
and signs a person into wp-admin.

## Contract

Routes under `wpcenter/v1`, all restricted to administrators (`update_plugins`, plus `install_plugins` for the
self-update):

- `GET status` — WordPress, plugin and theme versions, the plugins and themes that have an update, the count of
  pending translation updates, whether the site is writable, and the plugin's own version. `?force=1` clears the
  update cache first.
- `POST update` — `{plugins, themes, core}`, and `translations: true` since 1.3, run through WordPress's own
  `Plugin_Upgrader`, `Theme_Upgrader`, `Core_Upgrader` and `Language_Pack_Upgrader`, with per-item `errors`. After a
  core update the in-memory `$wp_version` is stale, so the response overrides `wordpress`/`core`.
- `POST login` — a one-time code valid for 60 s, stored only as a SHA-256 transient and issued over HTTPS only
  (except for a `local` site). The app opens `/wp-admin/?wpcenter_entrar=<code>`; against an older plugin it falls
  back to the normal login screen.
- `POST self-update` — takes the bundled zip as an `application/zip` body and reinstalls itself with
  `overwrite_package`, refusing a zip holding anything outside `wpcenter-ligacao/`.

## Decisions

- **Authentication is WordPress's own**: an application password the user approves in the browser and can revoke in
  the profile. The plugin stores no credentials and has no settings screen.
- **The plugin ships inside the app.** `build.sh` zips it (`--norsrc --noextattr`, so no `._` files) and writes
  `wpcenter-ligacao.version` from the header, which is what the app compares against the version a site reports.
- **Bump `Version:` on every change.** A site only receives the new zip when its plugin is older than the bundled
  one, and a plugin older than 1.3 cannot update itself.

## Boundary

Owned by `live-sites`: it is the only caller, and the plugin knows nothing about local sites, the app's state or
any site in particular.
