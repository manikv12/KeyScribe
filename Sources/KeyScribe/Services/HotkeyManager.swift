import AppKit
import Foundation

final class HoldToTalkManager {
    typealias Action = () -> Void

    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private let keyCode: UInt16
    private let modifiers: NSEvent.ModifierFlags
    private let onStart: Action
    private let onStop: Action

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var flagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var localFlagsMonitor: Any?
    private var releaseWatchdog: DispatchSourceTimer?
    private var active = false

    private var isModifierOnlyShortcut: Bool {
        keyCode == UInt16.max
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, onStart: @escaping Action, onStop: @escaping Action) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
        self.onStart = onStart
        self.onStop = onStop
    }

    deinit {
        stop()
    }

    func start() {
        if Thread.isMainThread {
            startOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startOnMain()
            }
        }
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.sync {
                self.stopOnMain()
            }
        }
    }

    private func startOnMain() {
        stopOnMain()

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleFlagsChanged(event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        if isModifierOnlyShortcut {
            return
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event: event, isDown: true)
            }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event, isDown: true)
            return event
        }

        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event: event, isDown: false)
            }
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handle(event: event, isDown: false)
            return event
        }
    }

    private func stopOnMain() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
        if let localKeyUpMonitor {
            NSEvent.removeMonitor(localKeyUpMonitor)
            self.localKeyUpMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        stopWatchdog()
        active = false
    }

    private func normalizedModifiers(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(Self.supportedModifiers)
    }

    private func isConfiguredShortcutDown(_ event: NSEvent) -> Bool {
        let eventKey = event.keyCode
        let eventMods = normalizedModifiers(from: event)
        return eventKey == keyCode && eventMods.isSuperset(of: modifiers)
    }

    private func handle(event: NSEvent, isDown: Bool) {
        if isDown {
            guard isConfiguredShortcutDown(event) else { return }
            if event.isARepeat { return }
            if !active {
                active = true
                startWatchdog()
                onStart()
            }
        } else if active && event.keyCode == keyCode {
            active = false
            stopWatchdog()
            onStop()
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentMods = normalizedModifiers(from: event)

        if isModifierOnlyShortcut {
            if currentMods.isSuperset(of: modifiers) {
                if !active {
                    active = true
                    startWatchdog()
                    onStart()
                }
            } else if active {
                active = false
                stopWatchdog()
                onStop()
            }
            return
        }

        if active && !currentMods.isSuperset(of: modifiers) {
            active = false
            stopWatchdog()
            onStop()
        }
    }

    private func startWatchdog() {
        stopWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            if !self.isShortcutPhysicallyHeld() {
                self.active = false
                self.stopWatchdog()
                self.onStop()
            }
        }
        releaseWatchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        releaseWatchdog?.cancel()
        releaseWatchdog = nil
    }

    private func isShortcutPhysicallyHeld() -> Bool {
        let source: CGEventSourceStateID = .combinedSessionState

        if !isModifierOnlyShortcut,
           !CGEventSource.keyState(source, key: CGKeyCode(keyCode)) {
            return false
        }

        if modifiers.contains(.command) {
            let left = CGEventSource.keyState(source, key: 55)
            let right = CGEventSource.keyState(source, key: 54)
            if !(left || right) { return false }
        }

        if modifiers.contains(.option) {
            let left = CGEventSource.keyState(source, key: 58)
            let right = CGEventSource.keyState(source, key: 61)
            if !(left || right) { return false }
        }

        if modifiers.contains(.control) {
            let left = CGEventSource.keyState(source, key: 59)
            let right = CGEventSource.keyState(source, key: 62)
            if !(left || right) { return false }
        }

        if modifiers.contains(.shift) {
            let left = CGEventSource.keyState(source, key: 56)
            let right = CGEventSource.keyState(source, key: 60)
            if !(left || right) { return false }
        }

        if modifiers.contains(.function),
           !CGEventSource.keyState(source, key: 63) {
            return false
        }

        return true
    }
}
