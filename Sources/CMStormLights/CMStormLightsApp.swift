import AppKit
import SwiftUI

@main
struct CMStormLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = KeyboardLightController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.lightsOn ? "lightbulb.fill" : "lightbulb")
                .accessibilityLabel(controller.lightsOn ? "Keyboard lights on" : "Keyboard lights off")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardLightController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyboardLightController.shared.restoreScrollLockKeys()
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: KeyboardLightController

    var body: some View {
        Toggle("Keyboard Lights", isOn: $controller.lightsOn)
            .keyboardShortcut("l")

        Divider()

        if controller.permission != .granted {
            Text("⚠️ Input Monitoring permission needed")
            Button("Open Privacy & Security Settings…") {
                controller.openInputMonitoringSettings()
            }
            Button("Relaunch CMStorm Lights") {
                controller.relaunch()
            }
            Divider()
        }

        Text("Keyboards")
        if controller.keyboards.isEmpty {
            Text("No external keyboards with LEDs found")
        } else {
            ForEach(controller.keyboards) { keyboard in
                Toggle(label(for: keyboard), isOn: Binding(
                    get: { controller.isEnabled(keyboard) },
                    set: { controller.setEnabled($0, for: keyboard) }
                ))
            }
        }

        Divider()

        Picker("Backlight LED", selection: $controller.target) {
            ForEach(LEDTarget.allCases) { target in
                Text(target.title).tag(target)
            }
        }
        Toggle("Scroll Lock Key Toggles Lights", isOn: $controller.scrollLockToggles)
        Toggle("Keep Lights On (Reapply Every Few Seconds)", isOn: $controller.keepAlive)
        Toggle("Launch at Login", isOn: Binding(
            get: { controller.launchAtLogin },
            set: { controller.launchAtLogin = $0 }
        ))

        if let error = controller.lastError {
            Divider()
            Text(error)
        }

        Divider()

        Button("Copy Diagnostics") {
            controller.copyDiagnostics()
        }
        Button("About CMStorm Lights") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("Quit CMStorm Lights") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func label(for keyboard: Keyboard) -> String {
        keyboard.supports(controller.target)
            ? keyboard.name
            : "\(keyboard.name) (no \(controller.target.shortName) LED)"
    }
}
