import AppKit
import Combine
import SwiftUI

enum PresentationSurface: Equatable {
    case popover
    case standaloneWindow
}

/// Presentation actions shared by the menu-bar popover and standalone window.
@MainActor
final class WindowPresentationModel: ObservableObject {
    @Published private(set) var isPopoverPinned = false
    @Published var selectedTab: PanelTab = .overview
    var onPopoverPinnedChange: ((Bool) -> Void)?
    var onOpenStandaloneWindow: (() -> Void)?

    func togglePopoverPinned() {
        isPopoverPinned.toggle()
        onPopoverPinnedChange?(isPopoverPinned)
    }

    func openStandaloneWindow() {
        onOpenStandaloneWindow?()
    }
}

/// Owns the status item, pinnable popover, standalone native window, and app menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private static let popoverWidth: CGFloat = 520
    private static let popoverHeight: CGFloat = 640
    private let store = ModemStore()
    private let presentation = WindowPresentationModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var appWindow: NSWindow?
    private var statusContextMenu: NSMenu?
    private var stateObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        presentation.onPopoverPinnedChange = { [weak self] pinned in
            self?.applyPopoverPinnedState(pinned)
        }
        presentation.onOpenStandaloneWindow = { [weak self] in
            self?.openStandaloneWindow()
        }
        stateObservation = store.$state.sink { [weak self] state in
            self?.updateStatusItem(for: state)
        }
        settingsObservation = store.$settings
            .map(\.preferredLanguage)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.configureMainMenu()
                self.appWindow?.title = localized("app.name")
                self.updateStatusItem(for: self.store.state)
            }
        updateStatusItem(for: store.state)
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func configureStatusItem() {
        // Let AppKit persist the position selected by Command-dragging the
        // menu-bar item. Without a stable autosave name, every fresh launch
        // places the item at the right edge and the anchored popover follows it.
        statusItem.autosaveName = "ing.fuyaoskyrocket.ec25toolbox.status-item"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: Self.popoverWidth, height: Self.popoverHeight)
        popover.contentViewController = makeHostingController(surface: .popover)
        popover.contentViewController?.preferredContentSize = popover.contentSize
    }

    private func makeHostingController(surface: PresentationSurface) -> NSViewController {
        let controller = NSHostingController(rootView: StatusWindowView(surface: surface)
            .environmentObject(store)
            .environmentObject(presentation))
        // NSPopover already draws the frame and arrow with its native material.
        // Keeping the hosting view transparent makes the content sample that
        // same material instead of placing a second, mismatched SwiftUI layer
        // over only the rectangular content area.
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
    }

    private func makeAppWindow() -> NSWindow {
        let defaultFrame = defaultStandaloneWindowFrame()
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentViewController = makeHostingController(surface: .standaloneWindow)
        window.delegate = self
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 600)
        window.collectionBehavior = [.participatesInCycle]
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        let restored = window.setFrameUsingName("EC25ToolboxStandaloneWindow")
        if !restored || window.frame.width < 720 || window.frame.height < 600 {
            window.setFrame(defaultFrame, display: false)
        }
        window.setFrameAutosaveName("EC25ToolboxStandaloneWindow")
        return window
    }

    private func defaultStandaloneWindowFrame() -> NSRect {
        let visibleFrame = statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let width = min(860, visibleFrame.width)
        let height = min(760, visibleFrame.height)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc private func openFromMenu(_ sender: Any?) {
        // Let AppKit finish dismissing the status-item menu before presenting
        // another transient window from the same menu-bar anchor.
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    @objc private func terminateApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func selectPanelTab(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let tab = PanelTab(rawValue: rawValue),
              tab != .estk || store.state.estk.availability.shouldShowTab else { return }
        presentation.selectedTab = tab
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectPanelTab(_:)),
              let rawValue = menuItem.representedObject as? String,
              let tab = PanelTab(rawValue: rawValue) else { return true }
        menuItem.state = presentation.selectedTab == tab ? .on : .off
        return tab != .estk || store.state.estk.availability.shouldShowTab
    }

    private func showContextMenu() {
        // A translucent NSMenu samples whatever is behind it. Close the main
        // popover synchronously so its tab labels cannot bleed through the
        // menu material or compete for the same status-item anchor.
        if popover.isShown {
            let restoresAnimation = popover.animates
            popover.animates = false
            popover.close()
            popover.animates = restoresAnimation
        }

        let menu = NSMenu()
        menu.delegate = self
        let openItem = NSMenuItem(
            title: localized("action.open_window"),
            action: #selector(openFromMenu(_:)),
            keyEquivalent: ""
        )
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        openItem.image?.isTemplate = true
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: localized("action.quit"),
            action: #selector(terminateApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.image?.isTemplate = true
        quitItem.target = self
        menu.addItem(quitItem)

        // Assign the menu only for this right-click presentation. NSStatusItem
        // then owns native positioning, safe-area clamping, and menu chrome.
        statusContextMenu = menu
        statusItem.menu = menu
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self,
                  let menu,
                  self.statusContextMenu === menu,
                  let button = self.statusItem.button else { return }
            button.performClick(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusContextMenu else { return }
        statusItem.menu = nil
        statusContextMenu = nil
    }

    private func applyPopoverPinnedState(_ pinned: Bool) {
        popover.behavior = pinned ? .applicationDefined : .transient
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if appWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openStandaloneWindow() {
        popover.performClose(nil)
        if appWindow == nil {
            appWindow = makeAppWindow()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appWindow?.makeKeyAndOrderFront(nil)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: localized("app.name"))

        let appMenu = NSMenu(title: localized("app.name"))
        appMenu.addItem(menuItem("menu.about", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        let servicesItem = menuItem("menu.services", action: nil)
        let servicesMenu = NSMenu(title: localized("menu.services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("menu.hide", action: #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = menuItem("menu.hide_others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(menuItem("menu.show_all", action: #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        let quit = menuItem("action.quit", action: #selector(terminateApplication(_:)), key: "q")
        quit.target = self
        appMenu.addItem(quit)
        mainMenu.addItem(rootMenuItem(title: localized("app.name"), submenu: appMenu))

        let fileMenu = NSMenu(title: localized("menu.file"))
        fileMenu.addItem(menuItem("menu.close", action: #selector(NSWindow.performClose(_:)), key: "w"))
        mainMenu.addItem(rootMenuItem(title: localized("menu.file"), submenu: fileMenu))

        let editMenu = NSMenu(title: localized("menu.edit"))
        editMenu.addItem(menuItem("menu.undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(menuItem("menu.redo", action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("menu.cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem("menu.copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem("menu.paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem("menu.select_all", action: #selector(NSText.selectAll(_:)), key: "a"))
        mainMenu.addItem(rootMenuItem(title: localized("menu.edit"), submenu: editMenu))

        let viewMenu = NSMenu(title: localized("menu.view"))
        for (index, tab) in PanelTab.allCases.enumerated() {
            let item = NSMenuItem(
                title: tab.title,
                action: #selector(selectPanelTab(_:)),
                keyEquivalent: String(index + 1)
            )
            item.target = self
            item.representedObject = tab.rawValue
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let fullScreen = menuItem("menu.full_screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        mainMenu.addItem(rootMenuItem(title: localized("menu.view"), submenu: viewMenu))

        let windowMenu = NSMenu(title: localized("menu.window"))
        windowMenu.addItem(menuItem("menu.minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(menuItem("menu.zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("menu.bring_all_to_front", action: #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(rootMenuItem(title: localized("menu.window"), submenu: windowMenu))

        let helpMenu = NSMenu(title: localized("menu.help"))
        mainMenu.addItem(rootMenuItem(title: localized("menu.help"), submenu: helpMenu))
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    private func rootMenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func menuItem(_ titleKey: String, action: Selector?, key: String = "") -> NSMenuItem {
        NSMenuItem(title: localized(titleKey), action: action, keyEquivalent: key)
    }

    private func updateStatusItem(for state: ModemState) {
        guard let button = statusItem.button else { return }
        let image: NSImage?
        if state.connected {
            let level = Double(min(max(state.info.signal.bars, 0), 4)) / 4.0
            image = NSImage(
                systemSymbolName: "cellularbars",
                variableValue: level,
                accessibilityDescription: store.menuBarAccessibilityLabel
            )
        } else {
            image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: store.menuBarAccessibilityLabel
            )
        }
        image?.isTemplate = true
        button.image = image
        button.toolTip = store.menuBarAccessibilityLabel
        button.setAccessibilityLabel(store.menuBarAccessibilityLabel)
    }
}
