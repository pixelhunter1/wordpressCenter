---
id: interface
type: module-design
status: draft
title: The SwiftUI surface
parent: architecture
depends-on: [site-lifecycle, transfer, live-sites, cli, localization]
---

# The SwiftUI surface

## Responsibility

The window: sidebar, the card-based site detail, the sheets that create and move sites, the settings, and the live
sites section. It renders and collects input; it decides nothing.

## Decisions

- **Cards, not tabs.** A site detail is a column of cards — start/stop and the address, access, status and storage,
  export, sharing — so a user sees what a site is and can do the common things without hunting through a tab bar.
- **Live sites never mix with local sites.** They get their own sidebar section, overview and detail view, because
  they are on the internet and the local ones are not (`live-sites`).
- **Every stateful thing lives in the stores.** The views call `SiteStore`/`LiveStore` and read their `@Published`
  state; what they hold themselves is presentation only — the selection, the search text, whether a sheet is open.
- **Strings are pt-PT literals inside the view**, so the compiler extracts them; text built outside a view goes
  through `L()` (`localization`). The shared chrome — `StatusText`, `ErrorText`, `Banner`, `SheetHeader`,
  `SheetFooter` — keeps idle, busy and failed looking the same everywhere.
- **Settings are keys, not copies.** Every preference is declared once in `Prefs` and read through `@AppStorage`
  with the same key, so the window and `wpc` cannot disagree (`cli`).
- **Destructive or networked actions show their work first.** Definições → Habilidades opens a sheet that lists, per
  upstream, the commit it is on and the commit it would move to, with what changes per skill; nothing is fetched
  beyond that click and nothing is applied until the user confirms (`agent-files`). When the check finds nothing to
  apply, the sheet says so and offers only to close — no disabled **Atualizar** next to it, because two buttons for
  one state read as a contradiction.
- **The menu bar extra is optional** (`Prefs.showMenuBarKey`), for starting and stopping a site without the window;
  the window keeps the site list, the commands (⌘N for a new site) and the settings.

## Boundary

The only file that knows both `live-sites` and the local store. `LiveViews` is split out but shares the same chrome
with this one, which is the accepted cycle in `architecture`. It depends on `site-lifecycle`, `transfer`,
`live-sites`, `cli` (the symlink toggle in the settings) and `localization`.
