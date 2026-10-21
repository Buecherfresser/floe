# Configuring Floe

You set Floe up in Settings: click the Floe icon in the menu bar and choose Settings. Changes apply right away. Floe saves everything to `~/.config/floe/config.yaml`, so you can edit that file instead if you prefer, and it's where you add hotkeys.

## Settings

### Focus follows mouse

Turn it on or off, set how long the cursor rests on a window before that window gets focus, and list apps that never get focus this way.

### Hotkeys

Turn hotkeys on or off and see the ones you have. To add or change a hotkey, edit the [config file](#hotkeys-in-the-config-file).

### App switcher

Turn on "Use fn as app switcher" to jump to an app with fn+key and pull its window onto your desktop with fn+shift+key. Floe also sets "Press 🌐 key to" in System Settings > Keyboard to "Do Nothing", because otherwise that action fires after every fn shortcut. Turning the switcher off restores your previous choice.

The list starts with shortcuts for Spotify, Safari, Chrome, Claude, Terminal, Finder, Discord, Outlook, Teams, Cursor, Obsidian, Postman and Slack. To add an app, type a key into "Key", then pick a running app from "Add App…" or choose one from your Applications folder.

### Tiling

Turn tiling on, then set the gap between windows and the gap at the screen edge. With "Auto-balance" on, every window on a display gets the same space. With it off, the first window takes the split ratio share of the screen and each further window splits what's left. Under app rules you add apps by name and choose whether they're tiled or always float.

### Desktop layouts

Turn on "Manage desktops per monitor setup" and set how many desktops each monitor gets, for one, two and three monitors. Monitor 1 is your main display, the others follow from left to right, and Settings shows which desktop numbers each monitor ends up with. When monitors come and go, Floe adds or removes desktops to match and moves every window back to its desktop number. It opens Mission Control for a moment to do that, so you see it flash. "Apply Now" applies the layout for the monitors connected right now.

With several monitors this needs "Displays have separate Spaces" turned on in System Settings > Desktop & Dock.

### Advanced

"Debug logging" writes detailed messages, see [Troubleshooting](#troubleshooting).

## Config file

Floe creates `~/.config/floe/config.yaml` with the defaults on first launch and picks up changes as soon as you save the file. If the file has a mistake, Floe keeps the settings it had and, before it next writes the file, saves your version as `config.yaml.broken`. You can leave out any section you don't need, and Floe uses the defaults for it.

This example turns everything on and adds a few hotkeys:

```yaml
focusFollowsMouse:
  enabled: true
  delay: 10            # milliseconds before the window under the cursor gets focus
  ignoreApps: []       # app names, for example [Finder]

hotkeys:
  enabled: true
  bindings:
    - hotkey: { modifiers: [alt], key: "1" }
      action: { focusSpace: 1 }
    - hotkey: { modifiers: [alt], key: "2" }
      action: { focusSpace: 2 }
    - hotkey: { modifiers: [alt, shift], key: "1" }
      action: { moveWindowToSpaceAndReturn: 1 }
    - hotkey: { modifiers: [alt], key: right }
      action: focusSpaceNext
    - hotkey: { modifiers: [alt], key: b }
      action: balanceWindows

tiling:
  enabled: true
  gaps:
    inner: 8           # pixels between windows
    outer: 8           # pixels between windows and the screen edge
  splitRatio: 0.5
  autoBalance: true
  rules:
    - app: MyWallpaper # app name as shown in the menu bar
      tiled: false

appSwitcher:
  enabled: true
  apps:
    - key: t
      bundleID: com.apple.Terminal
      name: Terminal
    - key: b
      bundleID: com.apple.Safari
      name: Safari

desktopLayouts:
  enabled: true
  layouts:
    - monitors: 1
      desktops: [9]
    - monitors: 2
      desktops: [9, 9]
    - monitors: 3
      desktops: [9, 6, 6]

debug: false
```

Layouts for more than three monitors go into `desktopLayouts.layouts` the same way.

### Hotkeys in the config file

Each entry under `hotkeys.bindings` pairs a key combination with an action. The app switcher creates its fn bindings for you, so you only add those by hand for extra combinations.

| Action | What it does |
|---|---|
| `focusSpace: N` | Switch to desktop N |
| `focusSpaceNext` | Switch to the next desktop on this monitor |
| `focusSpacePrev` | Switch to the previous desktop on this monitor |
| `moveWindowToSpace: N` | Move the focused window to desktop N and go with it |
| `moveWindowToSpaceNext` | Move the focused window to the next desktop and go with it |
| `moveWindowToSpacePrev` | Move the focused window to the previous desktop and go with it |
| `moveWindowToSpaceAndReturn: N` | Move the focused window to desktop N and stay here |
| `moveWindowToSpaceNextAndReturn` | Move the focused window to the next desktop and stay here |
| `moveWindowToSpacePrevAndReturn` | Move the focused window to the previous desktop and stay here |
| `focusApp: <bundle ID>` | Bring the app's last used window to the front, switching desktops if needed, or open the app |
| `pullApp: <bundle ID>` | Move the app's last used window onto this desktop and focus it, or open the app |
| `toggleTiling` | Turn tiling on or off |
| `balanceWindows` | Undo your manual resizes and retry windows that floated |
| `increaseSplitRatio` | Give the first window 5% more space (with `autoBalance: false`) |
| `decreaseSplitRatio` | Give the first window 5% less space (with `autoBalance: false`) |

Modifiers are `cmd`, `alt`, `ctrl`, `shift` and `fn`. Keys are letters, digits, symbols such as `-` or `[`, `return`, `tab`, `space`, `delete`, `escape`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown` and `f1` to `f12`. A matched hotkey goes only to Floe.

## Troubleshooting

Set `debug: true` (or "Debug logging" in Settings) for detailed messages, then watch them with:

```bash
log stream --level debug --predicate 'subsystem == "com.jonasdrechsel.floe"'
```

If switching desktops fails, Floe falls back to Control+number. That covers desktops 1 to 10 and needs the "Switch to Desktop" shortcuts turned on in System Settings > Keyboard > Keyboard Shortcuts > Mission Control.
