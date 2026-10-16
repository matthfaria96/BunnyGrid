# CLAUDE.md

BunnyGrid: native macOS database client (Swift 6, SwiftUI + AppKit), SwiftPM package. See README.md for layout and docs/ROADMAP.md for phases.

## Build

The active developer dir on this machine is the Command Line Tools, so prefix commands with Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build && swift test
scripts/bundle.sh debug     # build/BunnyGrid.app
```

Visual check without touching the user's saved connections or driving the mouse:

```sh
BUNNYGRID_DATA_DIR=<scratch dir> build/BunnyGrid.app/Contents/MacOS/BunnyGrid Resources/Samples/demo.sqlite --open-table customers
```
then capture the window with `screencapture -l <windowID>`. Debug-only flags: `--demo-edits`, `--focus-cell`, `--show-objects`.

The UI mirrors Navicat Premium's layout (see the user's reference screenshot): keep new features in the same places (main toolbar, navigator tree, Objects tab, table toolbar/footer, status bar, AI pane). Never copy Navicat's artwork; use SF Symbols.
The AI Assistant calls the Messages API over raw HTTP (`Sources/BunnyGridCore/AI`), default model `claude-opus-5-5`, with `fallbacks: "default"`.

## Rules

- Beekeeper Studio (`../Clones/beekeeper-studio`) is GPL-3: use it as an architecture reference only; do not copy or translate its code unless the user decides to license BunnyGrid as GPL-3.
- Navicat reference is `../Clones/Navicat Premium/SPEC.md` (public bundle metadata only). Don't decompile Navicat.
- `BunnyGridCore` has no UI imports; every engine implements `DatabaseDriver` as an actor. Engine-specific SQL lives in the driver or `SQLDialect`.
- UI state types are `@MainActor @Observable`. Passwords only in the Keychain, never in `connections.json`.
- New core behavior gets Swift Testing tests in `Tests/BunnyGridCoreTests`.
