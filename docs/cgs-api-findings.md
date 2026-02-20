# CGS Private API Findings (macOS 26 / Darwin 25.2)

## CGSManagedDisplaySetCurrentSpace

Does **not** switch the active space. Instead it temporarily composites all windows
from the target space onto the current space, overlaying existing windows. A manual
space switch (e.g. three-finger swipe) restores everything to its original space.
Potentially useful as a "peek at another space" feature.

## CGSAddWindowsToSpaces / CGSRemoveWindowsFromSpaces

No visible effect. Matches Hammerspoon issue #3698: these APIs silently no-op on
macOS 15+ (Sequoia and later). Windows "blink" but stay on their original space.

## Conclusion

All CGS space-manipulation APIs appear neutered without SIP disabled on modern macOS.
Space switching and window movement require an alternative approach (keyboard shortcut
simulation, accessibility-based Mission Control interaction, or mouse-drag simulation).
