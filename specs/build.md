---
id: build
type: module-design
status: draft
title: Building dist/WP Center.app
parent: architecture
depends-on: [live-plugin, localization, agent-files]
---

# Building dist/WP Center.app

## Responsibility

Turn the sources plus the developer's own machine into one app bundle with every binary it needs inside it.

## Decisions

- **`swiftc` directly, not SwiftPM.** `swift build` fails to load SwiftPM in the current Command Line Tools, so
  `build.sh` compiles `Sources/WPCenter/*.swift` in a single invocation. `Package.swift` exists only so the project
  opens in Xcode.
- **`SDKROOT` is pinned to the newest `MacOSX26.*.sdk`**, because Swift 6.3 from the Command Line Tools cannot compile
  against the macOS 27 SDK. Both quirks are marked in the script and are to be removed when the toolchain catches up.
- **Swift 5 language mode**, so bare `/regex/` literals are unavailable and the code uses `#/…/#`.
- **The runtime comes from the developer, never from the network.** PHP, WordPress, the SQLite integration plugin
  and WP-CLI are copied from `Vendor/studio` (gitignored, itself a copy of Studio's resources), the helper scripts and
  mu-plugins from `Runtime/`; `mailpit` and `cloudflared` come from Homebrew. Nothing is fetched here.
- **The agent skills come pre-pinned, not from Studio.** `Runtime/skills/` is copied whole, and the build is not what
  updates it: `Scripts/update-skills.sh` (`agent-files`) is the only thing that talks to GitHub, and it is run by the
  developer beforehand. It also fetches the impeccable engine (`Vendor/impeccable`) from the release matching the
  skill's `scripts/VERSION`, verified against the digest list the skill itself carries.
- **Local patches to upstream skills are applied here and cannot fail silently.** `Scripts/patch-skill.pl` replaces
  exact text and the build fails when a target is gone — the skills in the tree stay identical to their upstream, so
  the diff of an update is only what upstream changed. The rules live in `Runtime/skills/patches.json`, which the app
  reads too (`agent-files`).
- **The skills manifest ships with the app, stamped.** The build copies `Runtime/skills/upstreams.json` in, adds the
  build date and the engine version it actually bundled, so the app can compare its copy with one it fetched later
  (`agent-files`).
- **The live plugin is zipped here**, with `--norsrc --noextattr` so no `._` files reach a server, and
  `wpcenter-ligacao.version` is written from its header (`live-plugin`).
- **The app is ad-hoc signed** (`codesign --sign -`): it runs locally without a developer identity, and as far as the
  Keychain is concerned every build is a new app (`live-sites`).
- **The build checks the translations** and lists keys missing from `en.lproj` (`localization`).

## Boundary

Depends on `live-plugin` (zipped), `agent-files` (skills copied, patches applied) and `localization` (key check). Its
output is what `selftest` runs and what the user opens.

## Known limitations

A running GUI keeps the old binary: the app has to be quit before a new build is opened, or the user is quietly
running the previous code.
