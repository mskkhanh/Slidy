# Slidy

A small, fast macOS app for viewing, lightly editing and presenting `.pptx` slides. Native Swift/AppKit, no dependencies beyond the system `libarchive`.

## Features

- Opens PowerPoint `.pptx` files and renders the slides.
- Edits save straight into the original file. Quit is instant, and the app reopens the last file at the last slide.
- Add and edit text, headings, bullet lists and images.
- Fade animations with numbered order badges on the slide: select an object and press ⌘↑ / ⌘↓ to reorder.
- ⌘G groups the selected Fade effects (one number, link icon); ⌥⌘↑/↓ reorders them; ⌘↑/↓ switches slides (or, with the slide list focused, moves the selected slide up/down in the deck); ⌘B hides the left sidebar.
- Pinch to zoom around the pointer (⌘0 fits the slide); moving or resizing objects shows alignment guides that snap to other objects and the slide edges/centre (hold ⌘ to move freely).
- Select all (⌘A) then F clears every Fade on the slide; select a group and press F to add Fade yourself. ⌘Z undoes it.
- One click (wand button, top right) applies Fade to every object on every slide, top to bottom. ⌘Z undoes it.
- Presentation mode with the same fade steps (Play button or ⌘F). The slide number shows small at the bottom left; press delete (⌫) to go back to the previous slide, shown complete. ⌘↓ / ⌘↑ jump to the next / previous slide, also shown complete.
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

## Project layout

```
Sources/Slidy/
  AppDelegate.swift            window, state, launch/quit
  AppDelegate+Menus.swift      menu bar, toolbar buttons, shortcut sheet
  AppDelegate+SlideList.swift  left column: thumbnails and recent files
  AppDelegate+Document.swift   open, autosave, undo, status
  AppDelegate+Editing.swift    insert, paste, delete, order, Fade actions
  AppDelegate+Presenting.swift full-screen presentation
  Canvas.swift                 the slide canvas (selection, drag, inline edit, playback)
  ObjectViews.swift            object/surface/editor views, order badges, slide counter
  TextLayout.swift             paragraph layout shared by canvas, thumbnails and editor
  SlideModel.swift             Slide, SlideItem, Paragraph (parsed from the pptx XML)
  Presentation.swift           opening and saving the .pptx, themes, images
  Editing.swift                edits written back into the XML, in-place save
  NightMode.swift              display-only night colors
  Shortcuts.swift              the ⌘/ shortcut list (single source)
  Verification.swift           debug-only headless checks: `--verify deck.pptx out/`, `--memory deck.pptx`
```
