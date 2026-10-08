// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// Geometry only: never reads menu titles, opens menus or requests permission.
/// Run off-main. Missing geometry fails closed rather than covering a menu.
enum NotchMenuBarSpace {
    static func measure(pid: pid_t, geometry: NotchGeometry, primaryTop: CGFloat,
                        ownWindow: Int, apps: [pid_t]) -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let rawMenu = value(app, kAXMenuBarAttribute),
              CFGetTypeID(rawMenu) == AXUIElementGetTypeID() else { return nil }
        let menu = unsafeBitCast(rawMenu, to: AXUIElement.self)
        guard let rawItems = value(menu, kAXChildrenAttribute),
              CFGetTypeID(rawItems) == CFArrayGetTypeID(),
              let items = rawItems as? [AXUIElement], !items.isEmpty, items.count <= 64 else { return nil }
        let deadline = Date().addingTimeInterval(0.25)
        var menuItems: [CGRect] = []
        for item in items {
            guard Date() < deadline, let rect = frame(item, primaryTop: primaryTop) else { return nil }
            menuItems.append(rect)
        }
        var statusItems: [CGRect] = []
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? Int, number != ownWindow,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer >= Int(CGWindowLevelForKey(.statusWindow)),
                  layer <= Int(CGWindowLevelForKey(.statusWindow)) + 1,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 0, width < geometry.screen.width - 2,
                  height > 0, height <= geometry.menuBarHeight + 2 else { continue }
            statusItems.append(CGRect(x: x, y: primaryTop - y - height, width: width, height: height))
        }
        if statusItems.isEmpty {
            // Items the menu bar ran out of room for sit hidden under the camera.
            let camera = geometry.screen.midX - geometry.cameraWidth / 2...geometry.screen.midX + geometry.cameraWidth / 2
            guard let extras = extrasItems(apps: apps, primaryTop: primaryTop) else { return nil }
            statusItems = extras.filter { geometry.cameraWidth <= 0 || !camera.overlaps($0.minX...$0.maxX) }
        }
        // AX may describe only another display's menu bar. Require an item on
        // the selected display before status items can further constrain it.
        return NotchMenuBarLayout.measuredSideRoom(screen: geometry.screen, cameraWidth: geometry.cameraWidth,
                                                   barHeight: geometry.menuBarHeight,
                                                   menuItems: menuItems, statusItems: statusItems)
    }

    // Touched only from the menu-space queue, one read at a time.
    private static var extrasOwners: [pid_t]?
    private static var extrasPending: [pid_t] = []
    private static var extrasFoundOwners: [pid_t] = []
    private static var extrasScanned = Date.distantPast

    /// Where macOS draws status items itself rather than in a window per item,
    /// each app's extras menu bar still reports them. Asking every running app
    /// takes longer than one read may, so the apps that own one are found over
    /// as many reads as that needs, again every few seconds; until the first
    /// pass ends, where the items are is unknown.
    private static func extrasItems(apps: [pid_t], primaryTop: CGFloat) -> [CGRect]? {
        let deadline = Date().addingTimeInterval(0.2)
        if extrasPending.isEmpty, Date().timeIntervalSince(extrasScanned) > 10 {
            extrasPending = apps
            extrasFoundOwners = []
        }
        while !extrasPending.isEmpty, Date() < deadline {
            let pid = extrasPending.removeFirst()
            if extrasBar(pid) != nil { extrasFoundOwners.append(pid) }
            if extrasPending.isEmpty {
                extrasOwners = extrasFoundOwners
                extrasScanned = Date()
            }
        }
        guard let owners = extrasOwners else { return nil }
        var found: [CGRect] = []
        for pid in owners {
            guard let bar = extrasBar(pid), let rawItems = value(bar, kAXChildrenAttribute),
                  CFGetTypeID(rawItems) == CFArrayGetTypeID(), let items = rawItems as? [AXUIElement] else { continue }
            found += items.prefix(64).compactMap { frame($0, primaryTop: primaryTop) }
        }
        return found
    }

    private static func extrasBar(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let raw = value(app, kAXExtrasMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func frame(_ element: AXUIElement, primaryTop: CGFloat) -> CGRect? {
        guard let rawPosition = value(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = value(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(rawPosition, to: AXValue.self)
        let size = unsafeBitCast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(x: point.x, y: primaryTop - point.y - dimensions.height,
                      width: dimensions.width, height: dimensions.height)
    }
}
