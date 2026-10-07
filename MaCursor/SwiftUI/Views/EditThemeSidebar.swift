import AppKit
import Foundation
import SwiftUI

enum EditThemeSidebarLayout: String {
    case list
    case grid
}

enum EditThemeSidebarModel {
    static let emptyRowPrefix = "empty:"

    enum Row: Identifiable {
        case cursor(CursorModel)
        case empty(identifier: String, displayName: String)

        var id: String {
            switch self {
            case .cursor(let model): return model.id
            case .empty(let identifier, _): return EditThemeSidebarModel.emptyRowPrefix + identifier
            }
        }

        var displayName: String {
            switch self {
            case .cursor(let model): return model.name
            case .empty(_, let displayName): return displayName
            }
        }

        var cursorIdentifier: String {
            switch self {
            case .cursor(let model): return model.identifier
            case .empty(let identifier, _): return identifier
            }
        }

        func matches(query: String) -> Bool {
            displayName.localizedCaseInsensitiveContains(query)
                || cursorIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    static func rows(cursors: [CursorModel],
                     availableTypes: [(identifier: String, name: String)],
                     showAll: Bool,
                     searchText: String = "") -> [Row] {
        let allRows: [Row]
        let present = cursors.map(Row.cursor)
        if showAll {
            let used = Set(cursors.map(\.identifier))
            let empties = availableTypes
                .filter { !used.contains($0.identifier) }
                .map { Row.empty(identifier: $0.identifier, displayName: $0.name) }
            allRows = (present + empties).sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } else {
            allRows = present
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allRows }
        return allRows.filter { $0.matches(query: query) }
    }
}

@MainActor
final class TextEditingFocusCoordinator {
    static let shared = TextEditingFocusCoordinator()

    private var eventMonitor: Any?
    private(set) var interactionCount = 0

    var isMonitoring: Bool { eventMonitor != nil }

    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: NSEvent.EventTypeMask([.leftMouseDown, .keyDown])
        ) { [weak self] (event: NSEvent) -> NSEvent? in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteUserInteraction()
                if event.type == .leftMouseDown {
                    self.handleMouseDown(at: event.locationInWindow, in: event.window)
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func noteUserInteraction() {
        interactionCount += 1
    }

    func handleMouseDown(at locationInWindow: NSPoint, in window: NSWindow?) {
        guard let window,
              let fieldEditor = window.firstResponder as? NSTextView,
              fieldEditor.isFieldEditor else { return }
        let target: NSView = (fieldEditor.delegate as? NSControl) ?? fieldEditor
        let local = target.convert(locationInWindow, from: nil)
        if !target.bounds.contains(local) {
            window.makeFirstResponder(nil)
        }
    }
}

@MainActor
final class EditorTextShortcutCoordinator {
    static let shared = EditorTextShortcutCoordinator()

    private struct WeakEditorWindow {
        weak var window: NSWindow?
    }

    private var registeredWindows: [WeakEditorWindow] = []
    private var eventMonitor: Any?

    var isMonitoring: Bool { eventMonitor != nil }

    var registeredWindowCount: Int {
        registeredWindows.compactMap(\.window).count
    }

    static func editingSelector(
        forCharacters characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Selector? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control),
              let characters else { return nil }

        switch characters.lowercased() {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }

    func register(_ window: NSWindow) {
        pruneReleasedWindows()
        guard !isRegistered(window) else { return }
        registeredWindows.append(WeakEditorWindow(window: window))
        startMonitoring()
    }

    func isRegistered(_ window: NSWindow) -> Bool {
        registeredWindows.contains { $0.window === window }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    @discardableResult
    func performEditingSelector(_ selector: Selector, in window: NSWindow) -> Bool {
        guard isRegistered(window),
              let fieldEditor = window.firstResponder as? NSTextView,
              fieldEditor.isFieldEditor else { return false }
        return NSApp.sendAction(selector, to: fieldEditor, from: nil)
    }

    func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        pruneReleasedWindows()
        guard !registeredWindows.isEmpty else {
            stop()
            return false
        }
        guard let window,
              let selector = Self.editingSelector(
                  forCharacters: event.characters(byApplyingModifiers: .command),
                  modifiers: event.modifierFlags)
        else { return false }
        return performEditingSelector(selector, in: window)
    }

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: NSEvent.EventTypeMask([.keyDown])
        ) { [weak self] (event: NSEvent) -> NSEvent? in
            var handled = false
            MainActor.assumeIsolated {
                handled = self?.handle(event, in: event.window) ?? false
            }
            return handled ? nil : event
        }
    }

    private func pruneReleasedWindows() {
        registeredWindows.removeAll { $0.window == nil }
    }
}

struct SearchFieldView: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldDidSend(_:))
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != prompt {
            nsView.placeholderString = prompt
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            push(field.stringValue)
        }

        @objc func searchFieldDidSend(_ sender: NSSearchField) {
            push(sender.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  !control.stringValue.isEmpty else { return false }
            control.stringValue = ""
            push("")
            return true
        }

        private func push(_ value: String) {
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }
    }
}
