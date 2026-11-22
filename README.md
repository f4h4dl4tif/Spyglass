# Spyglass

A native SwiftUI file browser for macOS, built to sit alongside Finder, with cleanup, Mac health, Apple Intelligence, Shortcuts actions, routines and 69 on-device tools.
Universal (Apple Silicon + Intel), macOS 14+, no dependencies. The download is 2.9 MB.

## Build
    ./build.sh            # debug-ish release build into build/Spyglass.app
    ./package.sh          # universal .pkg, .dmg and .zip into dist/

## Layout
- `Core/` file model, Spotlight queries + plain-English parser, undo-able file operations (Activity)
- `Views/` Home, browser (grid/list/columns, tabs, path bar, inspector), search, cleanup, space map, health, apps, organize/assistant
- `Tools/` tool catalog and all tool implementations (PDFKit, ImageIO, Vision, AVFoundation, CryptoKit)
- `App/` app entry, menus/shortcuts, global hotkeys, menu bar extra, Quick Search panel, Settings

## Shortcuts / Siri
`build.sh` runs `Scripts/intents-metadata.sh`, which uses Xcode's `appintentsmetadataprocessor` on the
compiler's const values (`.build/Spyglass.swiftconstvalues`) to embed `Metadata.appintents`. Without Xcode the
app still builds; it just has no Shortcuts actions.
