# Floe

Floe is a tiling window manager for macOS 26 that works with System Integrity Protection (SIP) left on. It tiles your windows on every display, focuses the window under the mouse and switches desktops instantly.

https://github.com/user-attachments/assets/5d0ffbd8-4222-4b7d-9b62-0dad385cac75

- **Tiling.** Windows share each display and retile as soon as you open, move or resize one. Drop a window onto another to swap them, or hold Control and drag to resize.
- **Desktops.** Hotkeys switch desktops instantly and send windows to other desktops, on any monitor.
- **App switcher.** fn+key jumps to an app, fn+shift+key pulls its window onto the desktop you're on.
- **Stable desktop numbers.** When you plug a monitor in or out, every window goes back to its desktop number.

<!-- GIF 2: switching desktops and sending a window to another desktop
![Desktops](docs/media/desktops.gif)
-->

<!-- GIF 3: fn app switcher, jumping to an app and pulling its window over
![App switcher](docs/media/app-switcher.gif)
-->

## Install

You need macOS 26 and Xcode 26.

```bash
git clone https://github.com/Buecherfresser/floe.git && cd floe
./scripts/build-release.sh
cp -R dist/Floe.app /Applications/ && open /Applications/Floe.app
```

Floe asks for Accessibility access on first launch.

## Configure

Open Settings from the Floe icon in the menu bar, which covers everything except adding hotkeys. Floe saves your settings to `~/.config/floe/config.yaml`, where you add hotkeys and can change anything else too. [docs/configuration.md](docs/configuration.md) walks through both.

## License

MIT License, see [LICENSE](LICENSE). Copyright (c) 2026 Jonas Drechsel ([jonasdrechsel.com](https://jonasdrechsel.com))
