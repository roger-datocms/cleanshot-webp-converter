# cleanshot-webp-converter

[CleanShot X](https://cleanshot.com) can save screenshots as WebP, which is small but not accepted everywhere (some GitHub editors, for example). This tiny macOS agent watches for new CleanShot WebP captures and:

1. Re-encodes each capture as PNG and as JPEG (quality 85).
2. Saves the smaller one next to the original. The WebP stays.
3. Replaces the clipboard with the new file, so pasting works everywhere.
4. Shows a small toast for 3 seconds next to CleanShot's Quick Access Overlay (or in its corner when the overlay is off), e.g. "Converted 2026-09-28 5-12-29 PM.webp (142 KB) to JPEG (51 KB)".

Photos and gradients usually end up as JPEG, UI and text as PNG. Captures with transparency (e.g. window shadows) always become PNG, because JPEG can't hold an alpha channel.

## Requirements

- macOS 14 or later.
- Xcode or the Command Line Tools (`xcode-select --install`).
- CleanShot X (direct or Setapp) set to:
  1. **Settings → General → File format: WebP**.
  2. **After capture: Save** and **Copy file to clipboard** both on.

## Install

```sh
git clone https://github.com/roger-datocms/cleanshot-webp-converter.git
cd cleanshot-webp-converter
./install.sh
```

The script builds a release binary, copies it to `~/.local/bin`, and starts it as a launchd agent that runs at login. If macOS asks whether `cleanshot-webp-converter` may access your Downloads folder (or wherever CleanShot saves), click **Allow**.

To update, pull and run `./install.sh` again. To remove everything, run `./install.sh uninstall`.

Logs: `tail -f ~/Library/Logs/cleanshot-webp-converter.log`

## How it works

CleanShot has no plugin or post-capture hook API; its [URL scheme](https://cleanshot.com/docs-api) only triggers captures. So the agent:

1. Reads CleanShot's export folder, file format, and filename template from its preferences, and re-reads them whenever you change them in CleanShot.
2. Watches the export folder for new `.webp` files whose names match the filename template.
3. Converts a file only if the clipboard points at that same file, i.e. CleanShot just copied it. WebPs you download or copy yourself stay untouched.

The agent uses no CPU while idle and about 10 MB of memory.

## Development

```sh
./test.sh                   # swift-testing suite; works with Xcode or Command Line Tools alone
swift build -c release      # binary at .build/release/cleanshot-webp-converter
```

`CleanShotWebPCore` holds the testable logic (settings, template matching, encoding, clipboard). `cleanshot-webp-converter` is the thin watcher executable. Tests use private pasteboards, temp folders, and throwaway preference domains, so they never touch your real clipboard or CleanShot settings.

CleanShot's preference keys (`exportPath`, `screenshotFormat`, `mediaNameTemplate`) are undocumented. If a CleanShot update renames them, change `CleanShotKey` in `Sources/CleanShotWebPCore/CleanShotSettings.swift`.

## License

MIT
