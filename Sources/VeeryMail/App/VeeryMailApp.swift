import AppKit
import VeeryMailCore
import SwiftUI

@main
struct VeeryMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MailStore()
    @AppStorage("appearance") private var appearance = "dark"

    var body: some Scene {
        WindowGroup("Veery Mail", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { store.composeMailto($0) }
                .veeryTheme(appearance)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { MailCommands(store: store) }

        // Each message being written gets its own movable window.
        WindowGroup("New Message", id: "compose", for: UUID.self) { $id in
            if let id {
                ComposeWindow(id: id)
                    .environment(store)
                    .veeryTheme(appearance)
            }
        }
        .defaultSize(width: 720, height: 640)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(store)
                .veeryTheme(appearance)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched via `swift run` there is no bundle; make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting never loses mail:
    /// - messages still in their Undo window are sent now or kept for the next launch (the user chooses);
    /// - open compose windows with unsaved edits are saved to Drafts first, and a failed save cancels the quit
    ///   unless the user chooses to quit anyway;
    /// - a send already in progress gets a moment to finish; if it can't, it is checked on next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = MailStore.current else { return .terminateNow }
        let queued = store.outbox.items.filter { if case .queued = $0.state { return true } else { return false } }
        let dirty = store.composeDrafts.keys.filter { id in
            guard let d = store.composeDrafts[id] else { return false }
            return !d.isEmpty && store.isDirty(id)
        }
        if queued.isEmpty && dirty.isEmpty && store.outbox.submittingCount == 0 { return .terminateNow }

        var sendQueued = false
        if !queued.isEmpty {
            let alert = NSAlert()
            alert.messageText = queued.count == 1 ? "A message is waiting to send." : "\(queued.count) messages are waiting to send."
            alert.informativeText = "Send now, or keep them in Veery Mail’s outbox and decide the next time you open it."
            alert.addButton(withTitle: "Send Now and Quit")
            alert.addButton(withTitle: "Keep for Later and Quit")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: sendQueued = true
            case .alertSecondButtonReturn: sendQueued = false
            default: return .terminateCancel
            }
        }

        Task { @MainActor in
            NSApp.reply(toApplicationShouldTerminate: await Self.prepareToQuit(store, sendQueued: sendQueued, queued: queued, dirty: dirty))
        }
        return .terminateLater
    }

    private static func prepareToQuit(_ store: MailStore, sendQueued: Bool, queued: [OutboxItem], dirty: [UUID]) async -> Bool {
        if sendQueued {
            for item in queued { store.outbox.sendNow(item.id) }
        } else {
            store.outbox.suspendForQuit()
        }
        var failedSaves = 0
        for id in dirty where !(await store.saveDraft(id)) { failedSaves += 1 }
        if failedSaves > 0 {
            let alert = NSAlert()
            alert.messageText = failedSaves == 1 ? "A draft couldn’t be saved." : "\(failedSaves) drafts couldn’t be saved."
            alert.informativeText = "Quitting now will lose the unsaved changes in \(failedSaves == 1 ? "that window" : "those windows")."
            alert.addButton(withTitle: "Keep Open")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return false }
        }
        if !(await store.outbox.waitForInFlight(timeout: 20)) {
            // Left as "submitting" on disk; the next launch asks Fastmail whether it went out.
            store.outbox.suspendForQuit()
        }
        return true
    }
}

struct MailCommands: Commands {
    let store: MailStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { store.compose() }
                .keyboardShortcut("n")
        }
        CommandMenu("Message") {
            Button("Reply") { store.reply(all: false) }
                .keyboardShortcut("r")
                .disabled(store.thread.isEmpty)
            Button("Reply All") { store.reply(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.thread.isEmpty)
            Button("Forward") { store.forward() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.thread.isEmpty)
            Divider()
            Button("Archive") { store.archive() }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(store.selection.isEmpty)
            Button("Move to Trash") { store.trash() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(store.selection.isEmpty)
            Button("Delete Permanently…") { store.requestPermanentDelete() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(store.selection.isEmpty)
            Button("Mark as Spam") { store.markSpam() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Toggle Read") { store.toggleRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Toggle Flag") { store.toggleFlag() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Summarize with AI") { store.ai.summarize(store.thread) }
                .keyboardShortcut("y", modifiers: [.command, .option])
                .disabled(store.thread.isEmpty || !(store.ai.isEnabled || store.isDemo))
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger List Text") { ListFormat.adjustFontSize(by: 1) }
                .keyboardShortcut("=")
            Button("Smaller List Text") { ListFormat.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Button("Default List Text Size") {
                ListFormat.resetFontSizes()
            }
            .keyboardShortcut("0")
            Divider()
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { store.showCommandPalette = true }
                .keyboardShortcut("k")
            Button("Refresh") { Task { await store.syncNow() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            if store.supportsMaskedEmail || store.isDemo {
                Button("Masked Email…") { store.showMaskedEmail = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}
