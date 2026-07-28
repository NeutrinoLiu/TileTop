# TileTop

Custom macOS desktop widgets, built as native AppKit apps compiled with `swiftc`
(Command Line Tools only — **no Xcode installed on this machine**, so no
`.xcodeproj`, no WidgetKit; don't suggest either).

One process hosts any number of widgets. A menu-bar item (grid icon) is the
widget manager: add/remove widgets, per-widget submenu with Set Size…, Float
on Top, Remove, and type-specific items (Change URL… / Change Folder…).
Widget configs persist as JSON in `UserDefaults` (`widgetConfigs`); window
frames autosave per widget id (`Widget-<uuid>`). All widgets share the visual
style: 16pt continuous-curve rounded corners, hairline border, vibrancy
material, desktop window layer, and a faint centered title (URL host / folder
name) whose position never moves. The full top strip is the drag region;
double-clicking it rolls the widget up into a 24pt capsule title bar and back.
Collapse state and the expanded frame persist in the config.

## Widget 1: Browser widget (implemented)

A WKWebView widget (default/migrated instance shows
`https://app.sqrtwo.com/calendar`). The glass title bar has faint
back/forward buttons (left, enabled via KVO on canGoBack/canGoForward) and a
reload button (right); they hide when the widget is rolled up.

## Widget 2: Folder canvas (implemented)

An icon-grid view of a chosen folder: drag files in (Finder semantics — move
on same volume, copy across volumes, Option forces copy), drag out (copies),
Return renames in place, ⌘⌫ trashes, double-click opens. Right-click gives a
Finder-style context menu (Open, Show in Finder, Rename, Duplicate, Copy,
Move to Trash; on empty space: New Folder, Paste, Show in Finder). A kqueue monitor
(`FolderMonitor`) tracks the folder: renames/moves are followed (config path
updated via `F_GETPATH`), moves to Trash / deletion / permission loss show a
"folder not found" overlay with Choose Folder… / Recreate Folder buttons plus
a 2s poll that auto-reattaches if the folder reappears.

## Build & run

```sh
./build.sh                     # compiles Sources/main.swift -> build/TileTop.app (ad-hoc signed)
open build/TileTop.app
```

Quit the running instance before rebuilding: `pkill -x TileTop`.

## Layout

- `Sources/main.swift` — entry point + `AppDelegate` (widget manager, status-item menu).
- `Sources/WidgetCore.swift` — `WidgetConfig`/`WidgetStore`, `WidgetWindow`,
  `DragHandleView`, `Widget` base class, modal prompt helpers.
- `Sources/BrowserWidget.swift` — web view widget.
- `Sources/FolderWidget.swift` — folder canvas widget + `FolderMonitor`.
- `Resources/` — `AppIcon.icns` + `MenuIconTemplate.png`, copied into the bundle.
- `Info.plist` — copied verbatim into the bundle; `LSUIElement=true` (no Dock icon).
- `build.sh` — creates the bundle by hand (compiles `Sources/*.swift`); `build/` is disposable output.

## Key decisions & gotchas

- **Window level** is `CGWindowLevelForKey(.desktopIconWindow) + 1` — same layer
  as Apple's desktop widgets; app windows cover it, desktop icons sit below.
- **Login persistence** via the default `WKWebsiteDataStore`; cookies survive
  relaunches. A Safari user-agent string is set so OAuth providers (Google)
  don't reject the embedded browser.
- **Borderless window quirks** handled in `WidgetWindow`: `canBecomeKey`
  override (keyboard input for login) and manual ⌘C/V/X/A/Z/Q routing
  (accessory apps have no menu bar, so edit shortcuts don't work otherwise).
- **"Float on Top"** in the status-item menu is a fallback for login flows if
  the desktop layer refuses keyboard focus.
- Window frames are remembered via `setFrameAutosaveName("Widget-<uuid>")`.
- **Per-display placement memory**: each widget stores `homeDisplay` (display
  hardware UUID via `CGDisplayCreateUUIDFromDisplayID`) plus a
  `displayFrames` map, updated only on user-driven moves/resizes
  (`NSEvent.pressedMouseButtons != 0` filters out the system yanking windows
  to the main screen on display disconnect). On
  `didChangeScreenParametersNotification` (debounced 2s) and at launch,
  widgets whose home display is attached but who sit elsewhere are moved
  back to their remembered frame.
- **Login items point at the absolute path** of `build/TileTop.app`.
  `build.sh` recreates that path on every rebuild, which is fine — but
  moving/renaming the project folder breaks autostart.

## Roadmap

- (empty — widgets 1 and 2 plus the manager menu are done)
