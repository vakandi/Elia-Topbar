# Main Icon Dropdown Analysis & Fix Proposal

**Problem**: The EliaTopBar main menu bar icon requires 10-20 clicks to open the dropdown, which is unacceptable for a native macOS app. This analysis identifies the root causes and proposes a complete fix.

## Root Cause Analysis

### 1. `mainItemClicked` runs synchronously during AppKit runloop tracking

```swift
@objc private func mainItemClicked(_ sender: NSStatusBarButton) {
    // ... early returns ...
    
    if let menu = mainMenu {
        isMenuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)  // ← SYNCHRONOUS runloop conflict
        let popSucceeded = isMenuOpen == false || menu.numberOfItems > 0
        isMenuOpen = false
        if !popSucceeded || statusItem.button?.window == nil {
            // fallback path
            statusItem.menu = mainMenu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.statusItem.menu = nil }
        }
        throttledSetupMenu()
    }
}
```

**Problem**: `menu.popUp(positioning:at:in:)` is called from a `leftMouseUp` action while AppKit's event tracking is still active on the default `NSRunLoop.commonModes`. This creates a runloop conflict where the menu may not receive or process the click properly. On some macOS versions, window configurations (sleep/wake, display changes) invalidate `button.window`, causing the popUp to silently fail.

### 2. Hit-test geometry on icon photos zone is fragile

```swift
if iconPhotoCount > 0, point.x >= iconPhotosStartX,
   point.x < iconPhotosStartX + CGFloat(iconPhotoCount) * iconCellWidth {
    // ... navigate to subworker log popover ...
    return  // ← early return, click consumed but nothing else happens
}
```

**Problem**: The hit-test uses `iconPhotosStartX` and `iconCellWidth` which are computed from `UserDefaults` (`fleetPhotosSide`, `fleetLeftPad`) and dynamic `subworkerManager.subworkers`. If:
- User changes "Agent photos side" setting
- A subworker starts/stops (changing `sortedRunningNames()` order)
- The app wakes from sleep and `ensureStatusItemAlive` hasn't fully recalibrated

The geometry check fails silently — the click is "consumed" by the `if` guard but no menu appears, so the user clicks again. Over 10-20 attempts until the geometry happens to align.

### 3. `ensureStatusItemAlive` is a best-effort repair, not a guarantee

```swift
private func ensureStatusItemAlive() {
    let buttonWasNil = statusItem.button == nil
    let windowWasNil = statusItem.button?.window == nil
    if buttonWasNil || windowWasNil {
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
    guard let button = statusItem.button else { return }
    let needsReinstall = button.target !== self || button.action != #selector(mainItemClicked(_:))
    if needsReinstall {
        button.target = self
        button.action = #selector(mainItemClicked(_:))
    }
    button.sendAction(on: [.leftMouseUp])  // ← only leftMouseUp
}
```

**Problem**: 
- `ensureStatusItemAlive` only runs on `mainItemClicked` entry and `handleBecomeActive`/`handleSystemWake` notifications
- It sets `button.target` and `button.action` but **does not** add `leftMouseDown` as an additional trigger
- If macOS has already invalidated the target/action pair (common after sleep/window reconfig), the click is silently swallowed
- The method checks `button.target !== self || button.action != #selector(mainItemClicked(_:))` but does not re-apply `sendAction(on:)` with both mouse events

### 4. No `leftMouseDown` fallback

The entire flow relies on a single `leftMouseUp` event. On macOS, some window configurations or accessibility settings can cause `leftMouseUp` to not fire or be deferred. Adding `leftMouseDown` as a secondary trigger (or using `button.performClick(nil)` which sends both) provides a reliable fallback.

## Solution Proposal

### Fix 1: Add `leftMouseDown` to the sendAction trigger

Change `ensureStatusItemAlive` and the initial setup to register both `leftMouseUp` and `leftMouseDown`:

```swift
// In ensureStatusItemAlive(), replace:
button.sendAction(on: [.leftMouseUp])

// With:
button.sendAction(on: [.leftMouseUp, .leftMouseDown])
```

Also update the initial `setupStatusItem()` which currently does:
```swift
button.sendAction(on: [.leftMouseUp])
```

### Fix 2: Replace `menu.popUp` with `statusItem.menu` assignment + `performClick`

The most reliable way to show a menu on macOS is to assign it to `statusItem.menu` and trigger a click, rather than calling `popUp` synchronously during runloop tracking.

Replace the `mainItemClicked` menu presentation block:

```swift
// OLD (problematic):
if let menu = mainMenu {
    isMenuOpen = true
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    let popSucceeded = isMenuOpen == false || menu.numberOfItems > 0
    isMenuOpen = false
    if !popSucceeded || statusItem.button?.window == nil {
        statusItem.menu = mainMenu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.statusItem.menu = nil }
    }
    throttledSetupMenu()
}

// NEW (reliable):
if let menu = mainMenu {
    statusItem.menu = menu  // Assign menu to status item
    statusItem.button?.performClick(nil)  // This sends both leftMouseUp + leftMouseDown
    // Do NOT clear the menu immediately — let it stay until the user makes a selection or clicks elsewhere
    // Optional: clear after a brief delay if no selection made
    throttledSetupMenu()
}
```

**Why this works**: `performClick(nil)` is the native AppKit way to programmatically trigger the status bar menu. It sends both `leftMouseDown` and `leftMouseUp` events to the button, which the status item interprets as a menu request. Assigning `statusItem.menu = menu` ensures the menu is properly retained by the system. This approach avoids the runloop conflict entirely because the menu presentation happens through the status item's established infrastructure, not a custom `popUp` call.

### Fix 3: Robust hit-test with fallback

Improve the icon photo hit-test to always fall through to the main menu if the geometry check doesn't clearly match:

```swift
// In mainItemClicked, replace the photo-zone check:
if iconPhotoCount > 0 {
    let clickPoint = point.x
    let inPhotoZone = iconPhotosStartX <= clickPoint &&
                      clickPoint < iconPhotosStartX + CGFloat(iconPhotoCount) * iconCellWidth
    
    if inPhotoZone && iconPhotoCount > 0 {
        let idx = min(max(Int((clickPoint - iconPhotosStartX) / iconCellWidth), 0), iconPhotoCount - 1)
        let names = subworkerManager.sortedRunningNames()
        guard idx < names.count else { /* fall through to main menu */ }
        let name = names[idx]
        
        if let popover = subworkerLogPopover,
           subworkerLogPopoverName == name,
           popover.isShown {
            popover.performClose(nil)
            subworkerLogPopover = nil
            subworkerLogPopoverName = nil
            return
        }
        showSubworkerLogPopover(for: name, button: sender)
        return
    }
}

// If we reach here, the click was not on a photo zone — show main menu
if let menu = mainMenu {
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
}
```

### Fix 4: Ensure `ensureStatusItemAlive` is called on every relevant event

Add `ensureStatusItemAlive` calls to additional notification handlers:

```swift
// In viewDidLoad or init, also register for these:
NotificationCenter.default.addObserver(self, selector: #selector(handleSystemWake(_:)),
                                       name: NSWorkspace.didWakeNotification, object: nil)
NotificationCenter.default.addObserver(self, selector: #selector(handleSystemWake(_:)),
                                       name: NSWorkspace.willSleepNotification, object: nil)

// Ensure the method is also called after any status item recreation
private func healAfterWake() {
    ensureStatusItemAlive()
    // Also re-apply the full menu setup
    setupMenu()
}
```

### Fix 5: Add `leftMouseDown` to the initial button action setup

In `setupStatusItem()` (called on launch and on reconnect), ensure both mouse events are registered:

```swift
private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
        button.target = self
        button.action = #selector(mainItemClicked(_:))
        // ← CRITICAL: Both mouse events for reliability
        button.sendAction(on: [.leftMouseUp, .leftMouseDown])
    }
    startIconPulseObserver()
    updateStatusIcon()
}
```

## Summary of Changes

| File | Change | Why |
|------|--------|-----|
| `EliaTopBar/Sources/EliaTopBarApp.swift` `setupStatusItem()` | `button.sendAction(on: [.leftMouseUp, .leftMouseDown])` | Two-event trigger prevents missed clicks on window reconfig |
| `EliaTopBar/Sources/EliaTopBarApp.swift` `ensureStatusItemAlive()` | Same `sendAction` update + re-apply after sleep/wake | Guarantees target/action is fresh on every wake |
| `EliaTopBar/Sources/EliaTopBarApp.swift` `mainItemClicked()` | Replace `menu.popUp(positioning:at:in:)` with `statusItem.menu = menu; button.performClick(nil)` | Avoids runloop conflict; uses native AppKit menu presentation |
| `EliaTopBar/Sources/EliaTopBarApp.swift` `mainItemClicked()` | Improve photo-zone hit-test to fall through to main menu | Prevents silent click consumption when geometry is slightly off |
| `EliaTopBar/Sources/EliaTopBarApp.swift` `healAfterWake()` | Call `ensureStatusItemAlive()` + `setupMenu()` | Fixes state after sleep/window changes |

## Expected Result After Fix

- **1 click** opens the main dropdown menu reliably
- **0-1 clicks** on the photo zone navigates to the subworker log popover
- **Sleep/wake** cycles do not break the menu — `ensureStatusItemAlive` + `healAfterWake` restore state
- **Settings changes** (agent photos side, padding) are immediately reflected without requiring reopen
- The "10-20 clicks" problem is eliminated entirely