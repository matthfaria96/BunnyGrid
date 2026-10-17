# CLAUDE.md

BunnyGrid: native macOS database client (Swift 6, SwiftUI + AppKit), SwiftPM package. See README.md for layout and docs/ROADMAP.md for phases.

## Build

The active developer dir on this machine is the Command Line Tools, so prefix commands with Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build && swift test
scripts/bundle.sh debug     # build/BunnyGrid.app (compiles Resources/AppIcon.icon with actool)
scripts/preview-icon.sh <dir>   # render the icon in every appearance
```

Visual check without touching the user's saved connections or driving the mouse:

```sh
BUNNYGRID_DATA_DIR=<scratch dir> build/BunnyGrid.app/Contents/MacOS/BunnyGrid Resources/Samples/demo.sqlite --open-table customers
```
then capture the window with `screencapture -l <windowID>`. Debug-only flags: `--demo-edits`, `--focus-cell`, `--show-objects`.

The UI mirrors Navicat Premium's layout (see the user's reference screenshot): keep new features in the same places (main toolbar, navigator tree, Objects tab, table toolbar/footer, status bar, AI pane). Never copy Navicat's artwork; use SF Symbols.
The AI Assistant talks to Claude (Messages API, default `claude-opus-5-5`, `fallbacks: "default"`) or ChatGPT (OpenAI Responses API, default `gpt-6-astra`, `store: false`), both over raw HTTP (`Sources/BunnyGridCore/AI`). Chat history is stored in Messages-API block shape; `OpenAIClient.input(fromMessages:)` converts it. The platform is picked from the toolbar avatar (`Views/AIAccountView.swift`). Debug flags: `--account-menu`, `--ai-pane`, `-aiProvider chatgpt`.

## Rules

- Beekeeper Studio (`../Clones/beekeeper-studio`) is GPL-3: use it as an architecture reference only; do not copy or translate its code unless the user decides to license BunnyGrid as GPL-3.
- Navicat reference is `../Clones/Navicat Premium/SPEC.md` (public bundle metadata only). Don't decompile Navicat.
- `BunnyGridCore` has no UI imports; every engine implements `DatabaseDriver` as an actor. Engine-specific SQL lives in the driver or `SQLDialect`.
- UI state types are `@MainActor @Observable`. Passwords only in the Keychain, never in `connections.json`.
- New core behavior gets Swift Testing tests in `Tests/BunnyGridCoreTests`.
