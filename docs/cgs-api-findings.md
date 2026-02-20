# Space API Findings (macOS 26 / Darwin 25.2)

## CGS Private APIs

### CGSManagedDisplaySetCurrentSpace

Does **not** switch the active space. Instead it temporarily composites all windows
from the target space onto the current space, overlaying existing windows. A manual
space switch (e.g. three-finger swipe) restores everything to its original space.
Potentially useful as a "peek at another space" feature.

### CGSAddWindowsToSpaces / CGSRemoveWindowsFromSpaces

No visible effect without SIP disabled. Matches Hammerspoon issue #3698: these APIs
silently no-op on macOS 15+ (Sequoia and later). Windows "blink" but stay on their
original space.

With SIP disabled these APIs still work. Amethyst uses them (add first, then remove —
ordering matters per Amethyst #1174) but reports degraded behaviour on Sequoia: the
user is automatically switched to the target space instead of staying in place.

### CGS API Summary

| API | SIP enabled | SIP disabled |
|-----|-------------|--------------|
| `CGSManagedDisplaySetCurrentSpace` | Composites only (no real switch) | Composites only |
| `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` | Silent no-op | Works, but auto-follows on macOS 15+ |
| `CGSCopySpacesForWindows` | Works (read-only) | Works |
| `CGSManagedDisplayGetCurrentSpace` | Works (read-only) | Works |

## Approach: Mouse-Drag Simulation (no SIP required)

macOS has a native behaviour: when you hold a window (mouse-down on the title bar) and
switch spaces via Mission Control shortcuts, the window travels with you to the new
space. We exploit this programmatically:

1. Read the focused window's frame via the Accessibility API (`AXUIElement`).
2. Post a synthetic `CGEvent.leftMouseDown` at the title bar centre.
3. Post a synthetic `Ctrl+Number` (or `Ctrl+Arrow`) keyboard event to trigger the
   Mission Control space switch.
4. Wait for the transition animation (~400 ms).
5. Post a synthetic `CGEvent.leftMouseUp` to release.

This uses only public APIs (`CGEvent`, Accessibility), requires no SIP changes, and
works on all tested macOS versions (Sequoia 15.x, macOS 26).

**Trade-offs:**
- The user is switched to the target space (same as the manual drag behaviour).
- Requires timing delays (~200 ms mouse-down, ~400 ms animation).
- Does not work on fullscreen or minimised windows.
- Requires "Switch to Desktop N" shortcuts enabled in System Settings for indexed moves.

## Other Projects' Approaches

| Project | Approach | SIP required | macOS 15+ status |
|---------|----------|--------------|------------------|
| **Yabai** | SkyLight.framework private APIs | Yes | Works only with SIP disabled |
| **Amethyst** | `CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces` | Partially | Degraded: auto-follows to target space |
| **Hammerspoon** | `CGSAddWindowsToSpaces` via `hs.spaces` | No (but broken) | Returns `true` but no-ops |
| **AeroSpace** | Emulated workspaces (moves windows off-screen) | No | Works, but bypasses native Spaces entirely |

### Key GitHub Issues

- [Hammerspoon #3698](https://github.com/Hammerspoon/hammerspoon/issues/3698) — `moveWindowToSpace` silently no-ops on Sequoia
- [Hammerspoon #235](https://github.com/Hammerspoon/hammerspoon/issues/235) — mouse-drag workaround discussion
- [Amethyst #1713](https://github.com/ianyh/Amethyst/issues/1713) — throw-to-space behaviour changed on Sequoia
- [Amethyst #1701](https://github.com/ianyh/Amethyst/issues/1701) — feature broken on Sequoia 15.0
