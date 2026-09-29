# cleanshot-webp-converter

[CleanShot X](https://cleanshot.com) can save screenshots as WebP, which is small but not accepted everywhere (some GitHub editors, for example). This tiny macOS agent watches for CleanShot saving or copying a WebP capture (new captures, Annotate edits, and re-copies from CleanShot's history) and:

1. Re-encodes each capture as PNG and as JPEG (quality 85).
2. For fresh captures and edits, saves the smaller one next to the original. The WebP stays.
3. If CleanShot copied it, replaces the clipboard with the new file, so pasting works everywhere.
4. Shows a small toast for 3 seconds next to CleanShot's Quick Access Overlay (or in its corner when the overlay is off), e.g. "Converted 2026-09-28 5-12-29 PM.webp (142 KB) to JPEG (51 KB)".

Photos and gradients usually end up as JPEG, UI and text as PNG. Captures with transparency (e.g. window shadows) always become PNG, because JPEG can't hold an alpha channel.

## Requirements

- macOS 14 or later.
- Xcode or the Command Line Tools (`xcode-select --install`).
- CleanShot X (direct or Setapp) set to:
  1. **Settings → General → File format: WebP**.
  2. **After capture: Save** and/or **Copy file to clipboard** on. With only Save, you get the converted file; with Copy, the clipboard is converted too.

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

1. Reads CleanShot's export folder, file format, filename template, and overlay edge from its preferences, and re-reads them whenever you change them in CleanShot.
2. Watches both ways CleanShot hands over a capture:
   - **Clipboard:** checks its change counter 4 times a second (macOS has no clipboard notification). It reads the clipboard only when it holds a file link, never text.
   - **Export folder:** FSEvents reports saves. A save that CleanShot doesn't also copy within 1.5 seconds gets its conversion saved, and the clipboard is left alone.

   Both share a record of converted file versions, so a capture that's saved and copied converts once.
3. Acts only on a `.webp` in CleanShot's export folder or its history storage (`~/Library/Application Support/CleanShot/media`) whose name matches the filename template. The clipboard doesn't record which app copied a file, so location and name identify CleanShot's files. A WebP you download elsewhere stays untouched.
4. For a copied WebP, picks what to do by how recently it was saved:
   - **Fresh capture or Annotate edit** (saved in the last 30 seconds): saves the conversion next to it, replacing an earlier one, and copies that file. If the conversion on disk already holds identical bytes, it isn't rewritten, so its timestamps stay put and the SSD isn't written to.
   - **Re-copy of an older capture** (e.g. from CleanShot's history): converts on the clipboard only. It reuses an up-to-date conversion on disk if there is one; otherwise the clipboard gets just the image data and nothing is written.

The agent uses no measurable CPU while idle and about 50 MB of memory (mostly AppKit, for the toast).

## Development

```sh
./test.sh                   # swift-testing suite; works with Xcode or Command Line Tools alone
swift build -c release      # binary at .build/release/cleanshot-webp-converter
```

`CleanShotWebPCore` holds the testable logic (settings, template matching, encoding, clipboard). `cleanshot-webp-converter` is the thin watcher executable. Tests use private pasteboards, temp folders, and throwaway preference domains, so they never touch your real clipboard or CleanShot settings.

CleanShot's preference keys (`exportPath`, `screenshotFormat`, `mediaNameTemplate`) are undocumented. If a CleanShot update renames them, change `CleanShotKey` in `Sources/CleanShotWebPCore/CleanShotSettings.swift`.

## License

MIT
