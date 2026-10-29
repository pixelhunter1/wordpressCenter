---
id: localization
type: module-design
status: draft
title: Localization — pt-PT text as the key
parent: architecture
---

# Localization

## Responsibility

Keep one text — Portuguese — as the source of every string, and still show the app in English on a Mac that is not
Portuguese.

## Decisions

- **The pt-PT text is the key.** SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`) are extracted by the
  compiler, and `Localization/en.lproj/Localizable.strings` maps each one to English. No invented key names, and no
  constants table to keep in step with a separate strings file.
- **`pt-PT.lproj` and `pt.lproj` are empty on purpose**: they only mark Portuguese as available, and `pt-PT` makes
  macOS use Portugal's wording for its own controls ("Procurar", not Brazil's "Buscar"). `CFBundleDevelopmentRegion`
  is `en`, so every other language gets English.
- **Strings built outside a view go through `L()`**, which resolves against `Runtime.appBundle` so `wpc` finds the
  translations too. A plain `String` handed to `Text` is shown verbatim and is therefore never translated — the
  usual source of a half-translated screen.
- **Errors translate themselves**: `AppError("…")` is taken as a key, `AppError(verbatim:)` for text that is already
  final, such as command output. That keeps `do`/`catch` sites free of `L()` noise.
- **Plurals are written as two sentences**, never with an `"s"` ternary, because a translated sentence needs the whole
  sentence.
- **The build lists the missing keys**: `build.sh` extracts them with `swiftc -emit-localized-strings` and warns about
  any that `en.lproj` does not carry, so a new screen cannot ship silently untranslated (`build`).
- **Not everything is translated, by decision**: the files written into a site (`agent-files`), the `--selftest`
  output and the code comments stay pt-PT.

## Boundary

Used by everything that shows text — `interface`, `cli` — and by every module that raises an error (`site-lifecycle`,
`transfer`, `site-access`). Only `Localization/` holds the translations; `L()` and `AppError` are the only ways in.
