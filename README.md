# Slidy

A small, fast macOS app for viewing, lightly editing and presenting `.pptx` slides. Native Swift/AppKit, no dependencies beyond the system `libarchive`.

## Features

- Opens PowerPoint `.pptx` files and renders the slides.
- Edits save straight into the original file. Quit is instant, and the app reopens the last file at the last slide.
- Every bullet and numbered list always uses one standard line spacing (line height 1.94 × the font size): applied automatically when a deck is opened and whenever a slide is shown, and saved by autosave.
- Add and edit text, headings, bullet and numbered lists (type `1` + Space or `-` + Space) and images (inserted pictures get slightly rounded corners).
- Fade animations with numbered order badges on the slide: select an object and press ⇧↑ / ⇧↓ to reorder.
- F on a table fades the table in first, then the text of each cell, left to right and top to bottom. A .pptx table can only be animated as a whole, so each cell's text moves into its own text box over the cell (the slide looks the same; the group still selects, moves and deletes together; ⌘Z undoes it).
- ⌥⌘↑ / ⌥⌘↓ move the selected object one layer forward / backward per press (a table moves as a whole).
- ⌘G groups the selected Fade effects (one number, link icon); ⇧↑/⇧↓ reorders them (⌘↑/↓ switches slides); ⌘↑/↓ switches slides (or, with the slide list focused, moves the selected slide up/down in the deck); ⌘S hides / shows the sidebar (three small buttons at its top right: recent files, slides, hide / show; the last stays visible when the sidebar is collapsed).
- ⌘B makes the selected text bold (or the whole text of the selected objects).
- Pinch to zoom around the pointer (⌘0 fits the slide); moving or resizing objects shows alignment guides that snap to other objects and the slide edges/centre (hold ⌘ to move freely).
- Press Delete (⌫) in the slide list to delete the selected slide (notes and unused media go too; ⌘Z restores everything).
- ⌘1 (or ⌘E) shows the recent files, ⌘2 the slides of the current file; the matching buttons sit at the top left of the sidebar, the hide / show button at its top right.
- In the recent files list double-click a name to rename the file on disk (only the part before .pptx can change; Return confirms, Esc cancels).
- Press Return in the slide list to add a slide after the selected one, with a heading and text box styled like the deck's other content slides; the new boxes fit their text and grow or shrink as you type (saved as auto-fit, so PowerPoint agrees).
- Drag slide thumbnails in the left column to reorder slides (saved into the file; ⌘Z undoes it).
- Click a table to select the whole table: drag it to move it, Delete removes it, ⌘Z undoes either; double-click a cell to edit its text.
- Copy objects or a table (⌘C) and paste them (⌘V) on any slide, keeping their look and position; ⌘Z undoes the paste.
- Double-click a picture to crop it (drag the handles, Return applies, Esc cancels). Saved as a standard crop, corners stay rounded.
- Select all (⌘A) then F clears every Fade on the slide; select a group and press F to add Fade yourself. ⌘Z undoes it.
- One click (wand button, top right) applies Fade, top to bottom, to the slides that have no effect yet and leaves the slides you animated by hand alone. On every slide it also shrinks plain text boxes (no fill, no outline) to their text, without moving the text, so each order badge sits right above its text. A short report says what changed; ⌘Z undoes it.
- Presentation mode with the same fade steps (Play button or ⌘F). The slide number shows small at the bottom left; press delete (⌫) to go back to the previous slide, shown complete. ⌘↓ / ⌘↑ jump to the next / previous slide, also shown complete.
- Pure black editing UI and a display-only night mode (⌘L) that never changes the file.
- Press ⌘/ for the keyboard shortcuts that are special to Slidy.

## Build

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```bash
./build.sh
```

This creates `Slidy.app` in the project folder. Copy it to `/Applications` to use it.

To regenerate the app icon: `./tools/make-icon.sh`.

To smoke-test a build without touching the installed app's recent files or open document: `./tools/smoke.sh deck.pptx` (runs a private copy with its own preferences).

## License

MIT, see [LICENSE](LICENSE).

## Project layout

```
Sources/Slidy/
  AppDelegate.swift              window, state, launch/quit
  AppDelegate+Menus.swift        menu bar, toolbar and sidebar buttons, shortcut sheet
  AppDelegate+SlideList.swift    left column: thumbnails and recent files
  AppDelegate+Document.swift     open, autosave, undo, status
  AppDelegate+Editing.swift      insert, paste, layer order, delete
  AppDelegate+Fade.swift         Fade: toggle, tables, groups, order, the wand button
  AppDelegate+Slides.swift       slides in the deck: move, add, delete, restore
  AppDelegate+Presenting.swift   full-screen presentation
  Canvas.swift                   the slide canvas: state, zoom, selection, keys, playback
  Canvas+Drag.swift              mouse: select, drag, resize, snapping guides
  Canvas+TextEditing.swift       the inline editor and its caret
  Canvas+Crop.swift              crop mode for pictures
  Canvas+OrderBadges.swift       the Fade order numbers
  ObjectViews.swift              one object's view and the slide surface
  InlineTextView.swift           the text editor view (lists, bold, whole accents)
  Overlays.swift                 selection overlay, order numbers, crop handles, slide counter
  TextLayout.swift               paragraph layout shared by canvas, thumbnails and editor
  SlideModel.swift               Slide, SlideItem, Paragraph (parsed from the pptx XML)
  Presentation.swift             opening the .pptx: parts, themes, parsing
  Presentation+Text.swift        text edits: content, list spacing, bold
  Presentation+TextFit.swift     text box size: grow, auto-fit, trim
  Presentation+TableText.swift   cell text split into text boxes
  Presentation+Insert.swift      new text boxes and pictures
  Presentation+Saving.swift      Fade timing and saving
  SlideInsert.swift              adding, removing and reordering slides in the package
  ObjectClipboard.swift          copy / paste of objects
  NightMode.swift                display-only night colors
  Shortcuts.swift                the ⌘/ shortcut list (single source)
  Windows.swift, XML.swift, GrayRowView.swift   small helpers
  Verification*.swift            debug-only headless checks (`--verify`, `--drive`, `--snap`, `--memory`)
tools/
  smoke.sh                       opens a deck in a private copy of the app
  regress.sh                     runs every headless scenario on the decks in .fixtures/ and prints one report;
                                 diff two reports to see what a change did
```
