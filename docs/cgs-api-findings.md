# Space API Findings (macOS 26 / Darwin 25.2)

## CGS Private APIs

### CGSManagedDisplaySetCurrentSpace (Space Switching)

Does **not** switch the active space. Instead it temporarily composites all windows
from the target space onto the current space, overlaying existing windows. A manual
space switch (e.g. three-finger swipe) restores everything to its original space.

**Root cause (from yabai source):** A proper space switch requires four steps,
all executed *inside the Dock process*:

1. `SLSShowSpaces(connection, [destSpaceID])` — reveal destination space windows
2. `SLSHideSpaces(connection, [sourceSpaceID])` — hide source space windows
3. `SLSManagedDisplaySetCurrentSpace(connection, display, destSpaceID)` — update
   the current space
4. Set the Dock's internal `_currentSpace` ivar on the corresponding
   `_displaySpaces` object

Steps 1–3 can be called from any process, but step 4 requires code injection into
the Dock process (yabai does this via its scripting addition, a shared library
loaded into Dock's address space).  Without step 4, the Dock doesn't know the space
changed, so everything reverts on the next real space event.

**Conclusion:** Space switching via CGS is not practical without Dock injection.
Keyboard simulation (Ctrl+N / Ctrl+Arrow) is the reliable cross-version approach.

### SLSMoveWindowsToManagedSpace (Window Movement)

The primary API yabai uses to move windows between spaces. Called from within the
Dock process in yabai's scripting addition, but also works when called from our
process (with SIP disabled).

On macOS 14.5+ / 15+, this API is broken without a workaround. Yabai falls back to:

```c
SLSSpaceSetCompatID(connection, targetSpace, 0x79616265);  // "yabe"
SLSSetWindowListWorkspace(connection, &windowID, 1, 0x79616265);
SLSSpaceSetCompatID(connection, targetSpace, 0x0);
```

This compat-ID workaround assigns a temporary workspace identifier to the target
space, moves the window to that workspace, then clears the identifier.

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
| `CGSManagedDisplaySetCurrentSpace` | Composites only (no real switch) | Composites only (needs Dock injection) |
| `SLSMoveWindowsToManagedSpace` | No-op | Works (needs compat-ID workaround on 15+) |
| `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` | Silent no-op | Works, but auto-follows on macOS 15+ |
| `CGSCopySpacesForWindows` | Works (read-only) | Works |
| `CGSManagedDisplayGetCurrentSpace` | Works (read-only) | Works |

## Our Implementation

| Operation | Method | SIP required |
|-----------|--------|--------------|
| **Space switching** | Keyboard simulation (Ctrl+N / Ctrl+Arrow) | No |
| **Window movement** (default) | Mouse-drag simulation | No |
| **Window movement** (CGS mode) | `SLSMoveWindowsToManagedSpace` + compat-ID fallback | Yes |

## Approach: Mouse-Drag Simulation (no SIP required)

macOS has a native behaviour: when you hold a window (mouse-down on the title bar) and
switch spaces via Mission Control shortcuts, the window travels with you to the new
space. We exploit this programmatically:

1. Read the focused window's frame via the Accessibility API (`AXUIElement`).
2. Post a synthetic `CGEvent.leftMouseDown` at the title bar centre.
3. Post a small `CGEvent.leftMouseDragged` to initiate the grab.
4. Post synthetic `Ctrl+Arrow` key-down / key-up to trigger the space switch.
5. Post a synthetic `CGEvent.leftMouseUp` to release.

This uses only public APIs (`CGEvent`, Accessibility), requires no SIP changes, and
works on all tested macOS versions (Sequoia 15.x, macOS 26).

**Trade-offs:**
- The user is switched to the target space (same as the manual drag behaviour).
- Requires minimal timing delays (~50 ms between events with animations disabled).
- Does not work on fullscreen or minimised windows.
- Requires "Switch to Desktop N" shortcuts enabled in System Settings for indexed moves.

## Other Projects' Approaches

| Project | Approach | SIP required | macOS 15+ status |
|---------|----------|--------------|------------------|
| **Yabai** | SkyLight.framework scripting addition injected into Dock | Yes | Works with compat-ID workaround |
| **Amethyst** | `CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces` | Partially | Degraded: auto-follows to target space |
| **Hammerspoon** | `CGSAddWindowsToSpaces` via `hs.spaces` | No (but broken) | Returns `true` but no-ops |
| **AeroSpace** | Emulated workspaces (moves windows off-screen) | No | Works, but bypasses native Spaces entirely |

### Key GitHub Issues

- [Hammerspoon #3698](https://github.com/Hammerspoon/hammerspoon/issues/3698) — `moveWindowToSpace` silently no-ops on Sequoia
- [Hammerspoon #235](https://github.com/Hammerspoon/hammerspoon/issues/235) — mouse-drag workaround discussion
- [Amethyst #1713](https://github.com/ianyh/Amethyst/issues/1713) — throw-to-space behaviour changed on Sequoia
- [Amethyst #1701](https://github.com/ianyh/Amethyst/issues/1701) — feature broken on Sequoia 15.0
