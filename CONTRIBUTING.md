# Contributing to WP Center

Thanks for helping. Bug reports, fixes and small focused features are all welcome.

## Build

See [Requirements](README.md#requirements) for what you need installed (the build copies its runtime from
WordPress Studio; nothing is downloaded). Then:

```bash
./build.sh
open "dist/WP Center.app"
```

A running copy of the app keeps the old binary, so quit it before opening a new build:

```bash
osascript -e 'tell application id "local.wpcenter" to quit'
```

## Test

There is no XCTest target. The end-to-end suite is built into the app:

```bash
"dist/WP Center.app/Contents/MacOS/WPCenter" --selftest
```

It creates real sites in a temporary folder, starts them and checks them over HTTP. Exit code `0` means every check
passed. Please run it before opening a pull request and mention the result.

## Conventions

- **Code comments are in European Portuguese (pt-PT).** Match the style of the surrounding code.
- **UI strings are written in pt-PT, and the pt-PT text is the localization key.** Add the English translation to
  `Localization/en.lproj/Localizable.strings`. `build.sh` lists any key that is missing there.
- Strings built outside a SwiftUI view go through `L("…")`; errors use `AppError("…")`.
- At runtime the app talks only to `localhost`, except when the user explicitly shares a site. Keep it that way.
- Keep pull requests small and explain the *why* in the description.

[CLAUDE.md](CLAUDE.md) has a more detailed tour of the architecture.

## License

By contributing, you agree that your contributions are licensed under the
[GNU General Public License v2.0 or later](LICENSE).
