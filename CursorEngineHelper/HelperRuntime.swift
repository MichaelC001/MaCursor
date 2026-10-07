import AppKit
import Carbon
import SystemConfiguration

private func helperHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID(signature: 0, id: 0)
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard result == noErr else { return result }
    let runtime = Unmanaged<HelperRuntime>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated {
        runtime.hotKeyPressed(signature: hotKey.signature, id: hotKey.id)
    }
}

private func helperConsoleUserCallback(
    _ store: SCDynamicStore, _ changedKeys: CFArray, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let user = SCDynamicStoreCopyConsoleUser(store, nil, nil) as String?
    let runtime = Unmanaged<HelperRuntime>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { runtime.consoleUserChanged(user) }
}

private func helperNotificationCallback(
    _ center: CFNotificationCenter?, _ context: UnsafeMutableRawPointer?, _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?, _ userInfo: CFDictionary?
) {
    guard let context, let name else { return }
    let notification = name.rawValue as String
    let runtime = Unmanaged<HelperRuntime>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { runtime.notificationReceived(notification) }
}

private func helperDisplayCallback(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let runtime = Unmanaged<HelperRuntime>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { runtime.displayChanged() }
}

@MainActor
final class HelperRuntime {
    private static let hotKeySignature: OSType = 0x4D414352
    private var registeredThemes: [UInt32: String] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var store: SCDynamicStore?
    private var consoleSource: CFRunLoopSource?
    private var appearanceObservation: NSKeyValueObservation?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?
    private var displayRegistered = false
    private var running = false
    private var displayDebounce = HelperEventPolicy.DisplayDebounce()
    private var displayTimer: DispatchSourceTimer?
    private var activationTimer: DispatchSourceTimer?
    private var menuBarController: MenuBarController?
    private let focusController = MACFocusFollowsMouseController(trustCheck: HelperTrustProbe.isTrusted)
    private let autoSwitchSchedule = MACAutoSwitchScheduleTimer()

    func run() {
        MACPreferences.set(MACHelperBuildIdentityAtPath(Bundle.main.executablePath),
                           forKey: MACPreferences.helperBuildKey)
        defer { stop() }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var storeContext = SCDynamicStoreContext(version: 0, info: context,
                                               retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "com.apple.dts.ConsoleUser" as CFString,
                                              helperConsoleUserCallback, &storeContext) else {
            print("Failed to create SCDynamicStore")
            return
        }
        self.store = store
        let key = SCDynamicStoreKeyCreateConsoleUser(nil)
        guard SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            print("Failed to create console-user notifications")
            return
        }
        consoleSource = source
        running = true

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        appearanceObservation = application.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.systemAppearanceChanged() }
        }
        observeDistributed("AppleInterfaceThemeChangedNotification")
        let displayResult = CGDisplayRegisterReconfigurationCallback(helperDisplayCallback, context)
        displayRegistered = displayResult == .success
        if !displayRegistered { print("Failed to register display callback: \(displayResult.rawValue)") }

        let systemDefaultPath = MACCursorCapture.systemDefaultPath
        if !FileManager.default.fileExists(atPath: systemDefaultPath) {
            MACCursorCapture.shared.capture(to: systemDefaultPath)
        }
        MACAutoSwitchEffects.shared.recoverBaseThemeIfNeeded()
        applyStoredTheme(for: NSUserName())
        MACCursorActions.shared.assertPreferredCursorScale()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                       object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundleID) }
        })
        registerHotKeys()
        observeDistributed("MACShortcutsDidChange")
        observeDistributed(Notification.Name.MACAutoSwitchDidChange.rawValue)
        observeDistributed(Notification.Name.MACMenuBarDidChange.rawValue)
        observeDistributed(Notification.Name.MACFocusFollowsMouseDidChange.rawValue)
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.running == true else { return }
                self?.focusController.noteSpaceChange()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeFromSleep() }
        })
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: application, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }

        MACAutoSwitchEffects.shared.applyIfNeeded()
        MACMenuBarState.shared.noteForegroundBundleID(foregroundBundleID())
        MACAutoSwitchEffects.shared.handleFrontmostApp(foregroundBundleID())
        autoSwitchSchedule.start()
        focusController.start()
        focusController.syncTrust()
        menuBarController = MenuBarController()
        menuBarController?.applyVisibility()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        application.run()
    }

    private func stop() {
        let wasRunning = running
        running = false
        displayTimer?.cancel()
        activationTimer?.cancel()
        displayTimer = nil
        activationTimer = nil
        autoSwitchSchedule.stop()
        displayDebounce = HelperEventPolicy.DisplayDebounce()
        unregisterHotKeys()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        let context = Unmanaged.passUnretained(self).toOpaque()
        if displayRegistered { CGDisplayRemoveReconfigurationCallback(helperDisplayCallback, context) }
        displayRegistered = false
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDistributedCenter(), context)
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        if let consoleSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), consoleSource, .defaultMode)
            CFRunLoopSourceInvalidate(consoleSource)
        }
        consoleSource = nil
        store = nil
        if wasRunning { focusController.stop() }
    }

    private func observeDistributed(_ name: String) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(), helperNotificationCallback,
                                        name as CFString, nil, .deliverImmediately)
    }

    fileprivate func notificationReceived(_ name: String) {
        guard running else { return }
        switch name {
        case "AppleInterfaceThemeChangedNotification":
            DispatchQueue.main.async { [weak self] in self?.systemAppearanceChanged() }
        case "MACShortcutsDidChange":
            CFPreferencesSynchronize(MACPreferences.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            unregisterHotKeys()
            registerHotKeys()
        case Notification.Name.MACAutoSwitchDidChange.rawValue:
            applyAutoSwitchAndRefresh()
            MACAutoSwitchEffects.shared.handleFrontmostApp(foregroundBundleID())
            autoSwitchSchedule.reschedule()
        case Notification.Name.MACMenuBarDidChange.rawValue:
            menuBarController?.applyVisibility()
        case Notification.Name.MACFocusFollowsMouseDidChange.rawValue:
            focusController.configDidChange()
        default:
            break
        }
    }

    private func systemAppearanceChanged() {
        guard running, MACAutoSwitchMatchesSystemAppearance(MACAutoSwitchEffects.shared.readConfig()) else { return }
        applyAutoSwitchAndRefresh()
    }

    private func foregroundBundleID() -> String? {
        HelperEventPolicy.foregroundBundleID(cached: MACMenuBarState.shared.lastForegroundBundleID,
                                            live: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func applyStoredTheme(for user: String) {
        guard let home = NSHomeDirectoryForUser(user),
              let identifier = MACPreferences.value(forKey: MACPreferences.appliedCursorKey,
                                                   user: user as CFString,
                                                   host: kCFPreferencesCurrentHost) as? String else { return }
        let directory = (home as NSString).appendingPathComponent("Library/Application Support/MaCursor/cursors")
        let path = ((directory as NSString).appendingPathComponent(identifier) as NSString).appendingPathExtension("cursor")
        if let path, !MACCursorActions.shared.applyTheme(atPath: path) { print("Failed to apply stored Cape for \(user)") }
    }

    fileprivate func consoleUserChanged(_ user: String?) {
        guard running, let user else { return }
        if user == "loginwindow" {
            focusController.stop()
            return
        }
        MACAutoSwitchEffects.shared.clearAppOverride()
        applyStoredTheme(for: user)
        MACAutoSwitchEffects.shared.applyIfNeeded()
        MACAutoSwitchEffects.shared.handleFrontmostApp(foregroundBundleID())
        MACCursorActions.shared.assertPreferredCursorScale()
        focusController.stop()
        focusController.start()
    }

    private func appActivated(_ bundleID: String?) {
        guard running else { return }
        HelperEventPolicy.handleActivation(
            bundleID: bundleID, consumeRecentRaise: focusController.consumeRecentRaise,
            noteForeground: MACMenuBarState.shared.noteForegroundBundleID, cancelDwell: focusController.cancelPendingRaise,
            scheduleReassert: { bundleID, delay in
                activationTimer?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler { [weak self, weak timer] in
                    MainActor.assumeIsolated {
                        guard let self, let timer, self.running, self.activationTimer === timer else { return }
                        self.activationTimer = nil
                        timer.cancel()
                        MACAutoSwitchEffects.shared.handleFrontmostApp(bundleID)
                        MACCursorActions.shared.finalizeApply(scaleBump: MACCursorDefinitions.refreshScaleBumpSmall)
                    }
                }
                activationTimer = timer
                timer.resume()
            }
        )
    }

    fileprivate func displayChanged() {
        guard running else { return }
        displayTimer?.cancel()
        let deadline = displayDebounce.replaceDeadline(at: .now())
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.displayDebounce.consume(deadline) else { return }
                self.displayTimer?.cancel()
                self.displayTimer = nil
                MACAutoSwitchEffects.shared.clearAppOverride()
                self.applyStoredTheme(for: NSUserName())
                MACAutoSwitchEffects.shared.applyIfNeeded()
                MACAutoSwitchEffects.shared.handleFrontmostApp(self.foregroundBundleID())
                MACCursorActions.shared.assertPreferredCursorScale()
            }
        }
        displayTimer = timer
        timer.resume()
    }

    private func applyAutoSwitchAndRefresh() {
        if MACAutoSwitchEffects.shared.applyIfNeeded() { MACAutoSwitchEffects.shared.forceVisualRefresh() }
    }

    private func wokeFromSleep() {
        guard running else { return }
        applyAutoSwitchAndRefresh()
        MACAutoSwitchEffects.shared.handleFrontmostApp(foregroundBundleID())
        MACCursorActions.shared.assertPreferredCursorScale()
        autoSwitchSchedule.reschedule()
        focusController.stop()
        focusController.start()
    }

    private func registerHotKeys() {
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), helperHotKeyCallback, 1, &eventType,
                                             Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            if result != noErr { print("Failed to install Carbon event handler: \(result)") }
        }
        for shortcut in HelperEventPolicy.shortcuts(from: MACPreferences.value(forKey: MACPreferences.favoriteCursorsKey)) {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.hotKeySignature, id: shortcut.id)
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                            GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                print("Failed to register hotkey \(shortcut.id): \(result)")
                continue
            }
            registeredThemes[shortcut.id] = shortcut.themeIdentifier
            hotKeyRefs.append(reference)
        }
    }

    private func unregisterHotKeys() {
        for reference in hotKeyRefs {
            let result = UnregisterEventHotKey(reference)
            if result != noErr { print("Failed to unregister hotkey: \(result)") }
        }
        hotKeyRefs.removeAll()
        registeredThemes.removeAll()
    }

    fileprivate func hotKeyPressed(signature: OSType, id: UInt32) -> OSStatus {
        guard running, signature == Self.hotKeySignature, let identifier = registeredThemes[id] else {
            return OSStatus(eventNotHandledErr)
        }
        if MenuBarService.applyTheme(identifier) {
            MACAutoSwitchEffects.shared.forceVisualRefresh()
        } else {
            print("Failed to apply Cape for hotkey \(id)")
        }
        return noErr
    }
}
