# Space API Findings (macOS 26 and 27)

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
| **Space switching** | Synthetic Dock swipe gesture, fallback Ctrl+N | No |
| **Window movement** | Bridged `SLSBridgedMoveWindowsToManagedSpaceOperation` | No |

The former mouse-drag simulation (grab the title bar, press Ctrl+N, release) is
removed: it was timing-sensitive, often missed the title bar, and always dragged the
user along to the target space. It is still in git history (`308877a`).

## Approach: Bridged Window-Management Operations (macOS 26+)

SkyLight on Tahoe contains a family of `SLSBridged*Operation` classes (subclasses of
`SLSAsynchronousBridgedWindowManagementOperation` /
`SLSSynchronousBridgedWindowManagementOperation`). They are `NSCoding` objects that
SkyLight forwards to the Dock, which executes them with its own WindowServer rights.
That is why they work with SIP enabled and need no code injection.

```objc
id op = [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:@[@(wid)] spaceID:sid];
SLSPerformAsynchronousBridgedWindowManagementOperation(op);
```

`SLSPerformAsynchronousBridgedWindowManagementOperation` has internal linkage, so
`dlsym` cannot find it. We resolve
`__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation`
by walking SkyLight's `LC_SYMTAB` at runtime (`findLocalSymbol` in
`CGSSpaceService.swift`, same technique as yabai's `macho_dlsym.h`).

Verified on macOS 26.5.2 (arm64): a window owned by another process moves in ~12 ms,
the active space does not change. yabai uses the same path since 7.1.25 (May 2026).

Other bridged operations exist (`ManagedDisplaySetCurrentSpace`, `Show/HideSpaces`,
`SpaceCreate/Destroy`, `MoveManagedSpaceToDisplayIndex`, …) but are untested; they may
not update the Dock's own space model.

## What Changed in macOS 27

Checked on macOS 27.0.1 (26A434). The bridged window move and the space queries
work unchanged. Two things broke:

- **Dock swipes.** WindowServer drops a synthetic Dock swipe unless it carries the
  IOHIDEvent a real trackpad swipe has. `DockSwipe.swift` appends a fluid-touch gesture
  event (plus a velocity event on Ended) to the CGEvent's serialized data under field
  4205 and posts a companion gesture event (type 29). The sign of "next desktop" follows
  the natural scrolling setting. Ported from
  [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT).
  Swiping past the last desktop wedges the Dock (black screen), so never overshoot.
- **Mission Control.** Its UI moved from the Dock into the WindowManager process. The
  identifiers (`mc.display`, `mc.spaces.list`, `mc.spaces.add`, `AXRemoveDesktop`) are
  the same, but there's no `mc` group around them, and the Dock keeps an empty `mc`
  group with a zero frame.

The macOS 27 SDK also makes SwiftUI's `@State` a macro whose plugin ships only with
Xcode, so Floe uses it through a type alias (`ViewState`) to build with the Command
Line Tools.

## Creating, Removing and Moving Desktops

Tested on macOS 26.5.2:

| Operation | Result |
|-----------|--------|
| `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` | WindowServer moves the space, **the Dock doesn't** — Mission Control keeps showing the old layout. Unusable. |
| `SLSBridgedSpaceCreateOperation` (sync) | Returns a space ID, but the space isn't attached to any display (and can't be attached with the move op). Unusable. |
| Mission Control via Accessibility | Works and keeps the Dock consistent. |

Mission Control exposes language-independent identifiers while open:
`mc` → `mc.display` (one per display, AX frame = display bounds) → `mc.spaces` →
`mc.spaces.list` (desktop buttons with an `AXRemoveDesktop` action) and
`mc.spaces.add` (add-desktop button). `MissionControl.swift` opens Mission Control,
presses these and closes it again. There is no Dock-consistent way to move a desktop
to another display without injection, so desktop layouts create/remove desktops and
move *windows* instead.

On disconnect macOS destroys each external display's first desktop and appends the
remaining ones to the main display; on reconnect it creates one fresh desktop on the
external display and leaves the others where they are.

## Accessibility and Other Spaces

`kAXWindowsAttribute` only lists an app's windows on currently visible spaces.
To act on a window elsewhere, find it with `CGWindowListCopyWindowInfo(.optionAll)` +
`SLSCopySpacesForWindows`, move it or switch to its space, then fetch the AX element.

## Approach: Dock Swipe Gesture (space switching)

Posting a `kCGSEventDockControl` event with `kIOHIDEventTypeDockSwipe`, a Began/Ended
phase pair and a velocity of ±9999 switches one space instantly (no animation). One
pair per step in Mission Control order (fullscreen spaces count). The Dock applies the
swipe to the display under the cursor, so the cursor is warped to the target display
first when needed. Technique from BetterTouchTool / InstantSpaceSwitcher, used by yabai
since 7.1.19.

Needs the posting process to be Accessibility-trusted; untrusted processes have their
synthetic events silently dropped. Ctrl+N remains as fallback (desktops 1–10 only, and
only if the shortcuts are enabled in System Settings).

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
