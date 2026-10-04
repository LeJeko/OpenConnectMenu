import SwiftUI
import Combine

/// State of the helper, as shown in the settings.
enum HelperDisplayState {
    case enabled, unreachable, requiresApproval, notEnabled
}

/// What the "General" tab reads and does. The app wires it to its real actions; the tests supply fake
/// ones. Every action takes effect immediately: it does not go through Save / Cancel.
struct GeneralActions {
    var helperState: () -> HelperDisplayState
    /// Enables the helper, or opens System Settings if it is waiting for the user's approval.
    var enableHelper: () -> Void
    var repairHelper: () -> Void
    var uninstallHelper: () -> Void
    var isLoginItemEnabled: () -> Bool
    var setLoginItem: (Bool) -> Void
    var showLog: () -> Void
    var version: String
}

struct GeneralSettingsView: View {
    let actions: GeneralActions

    /// States change outside the window (helper repairing itself, login item changed in System
    /// Settings…): we re-read every second, and after each action.
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = tick                         // dependency: a change of `tick` re-evaluates the view
        let state = actions.helperState()    // re-read on every refresh
        Form {
            Section("Application") {
                Toggle("Open at login", isOn: Binding(
                    get: { actions.isLoginItemEnabled() },
                    set: { actions.setLoginItem($0); tick += 1 }))
                LabeledContent("Version") { Text(verbatim: actions.version).foregroundStyle(.secondary) }
            }

            Section {
                LabeledContent("Status") { Label(statusText(state), systemImage: statusSymbol(state)).foregroundStyle(statusColor(state)) }
                HStack {
                    switch state {
                    case .notEnabled:
                        Button("Enable helper…") { run(actions.enableHelper) }
                    case .requiresApproval:
                        Button("Open Login Items…") { run(actions.enableHelper) }
                    case .unreachable:
                        Button("Repair helper…") { run(actions.repairHelper) }
                        Button("Uninstall helper") { run(actions.uninstallHelper) }
                    case .enabled:
                        Button("Uninstall helper") { run(actions.uninstallHelper) }
                    }
                    Spacer()
                }
            } header: {
                Text("Helper")
            } footer: {
                Text("The helper runs as administrator to start and stop the VPN, so that you are not asked for a password each time.")
            }

            Section("Log") {
                HStack {
                    Button("Show log") { actions.showLog() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in tick += 1 }
    }

    private func run(_ action: () -> Void) {
        action()
        tick += 1
    }

    private func statusText(_ s: HelperDisplayState) -> String {
        switch s {
        case .enabled: return L("Helper enabled")
        case .unreachable: return L("Helper not reachable")
        case .requiresApproval: return L("Helper needs approval in System Settings")
        case .notEnabled: return L("Helper not enabled")
        }
    }

    private func statusSymbol(_ s: HelperDisplayState) -> String {
        s == .enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ s: HelperDisplayState) -> Color {
        s == .enabled ? .green : .orange
    }
}
