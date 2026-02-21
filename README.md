# Floe

A lightweight tiling window manager for macOS.

## Features

- **BSP Tiling** — Automatic binary-space-partition window tiling with configurable gaps and split ratios
- **Focus Follows Mouse** — Automatically focus windows under the cursor with configurable delay
- **Hotkeys** — Global keyboard shortcuts for space navigation, window movement, and tiling controls
- **Per-App Rules** — Exclude specific apps from tiling or focus-follows-mouse

## Requirements

- macOS 26 (Tahoe) or later
- Swift 6.2+
- Accessibility access (prompted on first launch)

## Build & Run

```bash
swift build
swift run Floe
```

## Configuration

Floe reads its configuration from `~/.config/floe/config.yaml`. A default config is created on first launch. The settings UI is available from the menu bar icon.

### Example config

```yaml
focusFollowsMouse:
  enabled: true
  delay: 10
  ignoreApps: []

hotkeys:
  enabled: true
  bindings:
    - hotkey:
        modifiers: [cmd]
        key: "1"
      action:
        focusSpace: 1
    - hotkey:
        modifiers: [ctrl]
        key: "1"
      action:
        moveWindowToSpaceAndReturn: 1

tiling:
  enabled: true
  gaps:
    inner: 8
    outer: 8
  splitRatio: 0.5
  autoBalance: true
  rules:
    - app: MyWallpaper
      tiled: false

debug: false
```

### Hotkey Actions

| Action | Description |
|---|---|
| `focusSpace: N` | Switch to space N |
| `focusSpaceNext` | Switch to next space |
| `focusSpacePrev` | Switch to previous space |
| `moveWindowToSpace: N` | Move focused window to space N |
| `moveWindowToSpaceAndReturn: N` | Move focused window to space N, then return |
| `moveWindowToSpaceNext` | Move focused window to next space |
| `moveWindowToSpacePrev` | Move focused window to previous space |
| `toggleTiling` | Toggle window tiling on/off |
| `balanceWindows` | Re-balance all tiled windows equally |
| `increaseSplitRatio` | Increase main area split ratio |
| `decreaseSplitRatio` | Decrease main area split ratio |

### Modifiers

`cmd`, `alt`, `ctrl`, `shift`

## License

MIT License — see [LICENSE](LICENSE) for details.

Copyright (c) 2026 Jonas Drechsel — [jonasdrechsel.com](https://jonasdrechsel.com)
