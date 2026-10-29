# Configuring Floe

You set Floe up in Settings: click the Floe icon in the menu bar and choose Settings. Changes apply right away. Floe saves everything to `~/.config/floe/config.yaml`, so you can edit that file instead if you prefer.

Out of the box, Floe tiles your windows, ⌃1–9 switches desktops and ⌃⇧1–9 sends the focused window to that desktop. Focus follows mouse, the app switcher and desktop layouts start off.

## Settings

### General

Floe shows whether it has Accessibility access and opens at login, which you can turn off here. Under "Checks" it lists anything on your Mac that gets in its way, such as another window manager like yabai or skhd still running, "Displays have separate Spaces" being off, or macOS edge tiling being on, each with what to do about it. The same warnings appear in the menu bar menu.

This tab also has focus follows mouse (on or off, how long the cursor rests on a window before it gets focus, and apps that never get focus this way), debug logging and the version number.

### Tiling

Turn tiling on, then set the gap between windows and the gap at the screen edge. With "Give every window the same space" on, every window on a display gets the same share. With it off, the first window takes the share you set and each further window splits what's left. Under "Apps that always float" you add apps that Floe leaves alone. Fixed-size windows like System Settings float on their own.

### Hotkeys

Each shortcut has a key combination and an action. Click the combination and press the keys you want (Esc cancels), then pick the action from the list, and the desktop number if the action needs one. "Add Shortcut" adds a row and starts recording right away. A warning sign marks combinations used twice.

### App switcher

Turn on "Use fn as app switcher" to jump to an app with fn+key and pull its window onto your desktop with fn+shift+key. Floe also sets "Press 🌐 key to" in System Settings > Keyboard to "Do Nothing", because otherwise that action fires after every fn shortcut. Turning the switcher off restores your previous choice.

The list starts with shortcuts for Spotify, Safari, Chrome, Claude, Terminal, Finder, Discord, Outlook, Teams, Cursor, Obsidian, Postman and Slack. To add an app, type a key, then pick a running app from "Add App…" or choose one from your Applications folder.

### Desktops

Turn on "Keep desktop numbers per monitor setup" and set how many desktops each monitor gets, for one, two and three monitors. Monitor 1 is your main display, the others follow from left to right, and Settings shows which desktop numbers each monitor ends up with. When monitors come and go, Floe adds or removes desktops to match and moves every window back to its desktop number. It opens Mission Control for a moment to do that, so you see it flash. "Apply Now" applies the layout for the monitors connected right now.

With several monitors this needs "Displays have separate Spaces" turned on in System Settings > Desktop & Dock.

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

appDesktops:
  enabled: true
  apps:
    - bundleID: com.apple.Safari
      desktop: 2
      name: Safari     # optional, just for you

debug: false
```

Layouts for more than three monitors go into `desktopLayouts.layouts` the same way.

### Apps on their own desktop

`appDesktops` opens an app's windows on a fixed desktop number, counted across monitors the same way as the desktop hotkeys. Every new window of the app goes there: the first one after launch, and ones you open later, such as with ⌘N. If the app was in front when the window opened, Floe switches to that desktop with it. A window that opens by itself in the background goes there without taking you along.

Windows that are already open when Floe starts stay where they are, and a window you move to another desktop stays there too. Pulling an app with fn+shift+key still brings its new window to the desktop you're on. A desktop number your current monitors don't have is skipped.

Apps are matched by bundle ID. To find an app's, run `osascript -e 'id of app "Spark Desktop"'`. This works for Chrome web apps like Google Chat too, which have their own bundle ID.

### Hotkeys in the config file

Each entry under `hotkeys.bindings` pairs a key combination with an action, the same as a row in the Hotkeys tab. The app switcher creates its fn bindings for you, so you only add those by hand for extra combinations.

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
