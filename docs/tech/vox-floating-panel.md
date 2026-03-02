# Vox Launcher -- Floating Panel Implementation Notes

> Vox-specific application notes. Full technical guide: `Learning/macOS Development/nspanel-floating-panels.md`

---

## Current State: StatusOverlay

Vox's `StatusOverlay` is a borderless `NSWindow` (not an NSPanel) used for the recording/processing/done indicator. It works but has limitations:

- Uses `NSWindow` with `.borderless` style instead of `NSPanel` with `.nonactivatingPanel`
- Positioned via `NSScreen.main` (screen with key window, not necessarily where the user is looking)
- Uses `orderFrontRegardless()` for display, which is fine for a non-interactive overlay
- Already has correct: `NSVisualEffectView` blur, fade animations, pulse/writing indicators, `ignoresMouseEvents = true`

**What to change:** Migrate StatusOverlay to `NSPanel` with `.nonactivatingPanel` for better system integration -- gains `collectionBehavior` options (`.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.transient`), proper Space/Mission Control behavior, and consistent window management.

---

## New: LauncherPanel (Spotlight-Style)

For Launcher mode, Vox needs a second panel type -- a Spotlight-style input bar with text field.

**Requirements:**

- `NSPanel` with `.nonactivatingPanel`, `.titled`, `.fullSizeContentView`
- `canBecomeKey = true`, `canBecomeMain = false`
- `hidesOnDeactivate = true` (auto-dismiss when user clicks elsewhere)
- Text field gets immediate focus on show (use `DispatchQueue.main.async` after `makeKeyAndOrderFront`)
- Escape dismisses, Return submits
- Spring scale+fade animation on show/hide (see generic guide Section 3)
- Position: upper-third center of the mouse cursor's screen
- Must set up Edit menu for Cmd+C/V/X/A (Vox is LSUIElement -- `setupEditMenu()` already exists)

**Positioning:**

```swift
// Use screenWithMouse() instead of NSScreen.main
func screenWithMouse() -> NSScreen {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
        ?? NSScreen.main ?? NSScreen.screens[0]
}
```

---

## Push-to-Talk Timing (Vox-Specific)

Vox's Carbon hotkey approach (`kEventHotKeyPressed` / `kEventHotKeyReleased`) is correct for hold-to-talk. No changes needed to the hotkey mechanism itself.

**Timing values currently in use:**

- **Minimum recording check:** `fileSize < 16000` (~0.5s) prevents accidental tap transcriptions
- **Key repeat debounce:** Must track press state because Carbon auto-repeats `kEventHotKeyPressed`
- **Audio tail:** Add 50-100ms delay after key release before stopping the recorder, to avoid cutting off the last syllable. This should be tunable.

---

## Multi-Display

**Current:** Vox uses `NSScreen.main` for StatusOverlay positioning.

**Change to:** `screenWithMouse()` -- the user expects the overlay/panel to appear on the screen they are looking at (where the cursor is). This matters for both StatusOverlay and the new LauncherPanel.

For StatusOverlay's bottom-center position:

```swift
let screen = screenWithMouse()
let screenFrame = screen.visibleFrame
let x = screenFrame.midX - panel.frame.width / 2
let y = screenFrame.origin.y + 80
panel.setFrameOrigin(NSPoint(x: x, y: y))
```

---

## Carbon Hotkey Integration

Vox already uses Carbon for global hotkeys. Key points specific to Vox's implementation:

- Carbon is the right choice -- it natively supports keyUp/keyDown which is essential for hold-to-talk
- Single hotkey per registration via `RegisterEventHotKey`
- C-function callback required (already implemented in AppDelegate)
- No permissions needed (unlike CGEvent tap which needs Input Monitoring)
- If modernizing later, CGEvent tap is the equivalent with same capabilities but requires Input Monitoring permission

**Do NOT switch to `NSEvent.addGlobalMonitorForEvents`** -- it cannot reliably detect key release for global events, which breaks hold-to-talk.

---

## Accessibility

Vox-specific accessibility requirements:

1. **StatusOverlay:** Currently non-interactive (`ignoresMouseEvents = true`). Should still post `NSAccessibility.post(element:notification:)` for `.windowCreated` / state changes so VoiceOver can announce recording/processing/done states.

2. **LauncherPanel:** Must include `.titled` in style mask (even though title bar is hidden) so VoiceOver identifies it as a window. Set `panel.setAccessibilityRole(.dialog)` and label the search field with `setAccessibilityLabel("Vox Search")`.

3. **Existing windows (HistoryWindowController, BlackBoxWindowController):** These correctly use `NSApp.activate(ignoringOtherApps: true)` since they are full app windows, not floating panels. No changes needed.

4. **Permissions:** Vox already requests Accessibility permission at startup via `AXIsProcessTrustedWithOptions` (used by `PasteHelper.swift` for text insertion). The same permission covers reading selected text via `kAXSelectedTextAttribute` for future "modify selection" features.

---

## Selection Capture (Future)

For a "modify selected text" feature, Vox already has the Accessibility permission needed. The flow:

1. User selects text in any app
2. User presses hotkey
3. Vox reads selected text via `AXUIElementCopyAttributeValue` with `kAXSelectedTextAttribute`
4. Vox shows floating panel with the text + editing options
5. User speaks modification instruction
6. Vox replaces the selection via `kAXSelectedTextAttribute`

See generic guide Section 10 for the full `SelectionCapture` implementation code.

---

*Last updated: 2026-03-01*
