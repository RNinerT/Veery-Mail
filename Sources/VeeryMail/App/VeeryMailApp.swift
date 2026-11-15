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

    /// Quitting during the Undo Send countdown sends the message first instead of losing it.
    /// If sending fails, the quit is cancelled and the message reopens in the composer.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let delivery = MailStore.current?.flushPendingSend() else { return .terminateNow }
        Task { @MainActor in
            let sent = await delivery.value
            NSApp.reply(toApplicationShouldTerminate: sent)
        }
        return .terminateLater
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
            Button("Masked Email…") { store.showMaskedEmail = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}
