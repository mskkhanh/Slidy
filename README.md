# Slidy

A small, fast macOS app for viewing, lightly editing and presenting `.pptx` slides. Native Swift/AppKit, no dependencies beyond the system `libarchive`.

## Features

- Opens PowerPoint `.pptx` files and renders the slides.
- Edits save straight into the original file (a one-time `name.pptx.bak` backup is kept next to it). Quit is instant, and the app reopens the last file at the last slide.
- Add and edit text, headings, bullet lists and images.
- Fade animations with numbered order badges on the slide: select an object and press ⌘↑ / ⌘↓ to reorder.
- Presentation mode with the same fade steps.
- Pure black editing UI and a display-only night mode (⌘L) that never changes the file.
- Press ⌘/ for the full list of keyboard shortcuts.

## Build

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```bash
./build.sh
```

This creates `Slidy.app` in the project folder. Copy it to `/Applications` to use it.

To regenerate the app icon: `./tools/make-icon.sh`.

## License

MIT, see [LICENSE](LICENSE).
