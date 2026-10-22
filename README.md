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

Floe needs macOS 26. Pick one of three ways; each one keeps Floe up to date by itself.

**Install script.** Builds Floe on your Mac with Apple's Command Line Tools (the script offers to install them) and puts it into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/Buecherfresser/floe/main/scripts/install.sh | bash
```

**Homebrew.** Builds Floe the same way, and `brew upgrade` covers it like everything else:

```bash
brew install buecherfresser/floe/floe
ln -sfn "$(brew --prefix)/opt/floe/Floe.app" /Applications/Floe.app
floe-sign "$(brew --prefix)/opt/floe/Floe.app"
```

**Download.** Get the DMG from the [latest release](https://github.com/Buecherfresser/floe/releases/latest) and drag Floe into Applications. Floe isn't notarized by Apple yet, so macOS blocks the first launch: open System Settings › Privacy & Security and click "Open Anyway" next to Floe.

Floe asks for Accessibility access on first launch and opens at login from then on. The install script and `floe-sign` sign Floe with a certificate of your own, so macOS keeps that permission across updates. Setting the certificate up asks for your password once.

To build from a checkout instead, run `./scripts/install.sh --source .`.

## Configure

Out of the box, Floe tiles your windows, ⌃1–9 switches desktops and ⌃⇧1–9 sends the focused window there. Everything else, including your own hotkeys, is in Settings: click the Floe icon in the menu bar. Floe saves your settings to `~/.config/floe/config.yaml` if you'd rather edit a file. [docs/configuration.md](docs/configuration.md) walks through both.

## License

MIT License, see [LICENSE](LICENSE). Copyright (c) 2026 Jonas Drechsel ([jonasdrechsel.com](https://jonasdrechsel.com))
