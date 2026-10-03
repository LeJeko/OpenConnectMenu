import Foundation

// Localisation : l'anglais est la langue par défaut, le français est utilisé si le système est en français.
// Les clés de Localizable.strings sont les textes anglais eux-mêmes ; macOS choisit la traduction
// d'après les langues préférées de l'utilisateur parmi celles déclarées dans CFBundleLocalizations.

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

/// Traduit les réponses du helper : un code (« oc_exited »…), suivi éventuellement d'un détail
/// (sortie d'openconnect, message système) sur les lignes suivantes, laissé tel quel.
enum HelperText {
    static func localized(_ raw: String) -> String {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts.first ?? "")
        let detail = parts.count > 1 ? String(parts[1]) : ""
        let text: String
        switch code {
        case "invalid_settings":        text = L("Invalid settings: check server, username, password and TOTP secret.")
        case "oc_missing":              text = L("openconnect (or its vpnc-script) was not found.")
        case "oc_not_approved":         text = L("openconnect has not been approved yet.")
        case "oc_changed":              text = L("openconnect or vpnc-script has changed since it was approved (Homebrew update?).")
        case "oc_trusted":              text = L("openconnect is approved.")
        case "runtime_dir_failed":      text = L("Could not create the temporary directory.")
        case "config_write_failed":     text = L("Could not write the temporary configuration.")
        case "log_unavailable":         text = L("The log file is not accessible.")
        case "launch_failed":           text = L("Could not launch openconnect.")
        case "oc_exited":               text = L("openconnect stopped.")
        case "timeout":                 text = L("Timed out.")
        case "disconnect_unresponsive": text = L("openconnect is not responding and the tunnel state is unknown.")
        case "oc_not_stopped":          text = L("The openconnect process did not stop.")
        case "admin_not_confirmed":     text = L("Administrator rights were not confirmed.")
        case "oc_unreadable":           text = L("Could not read openconnect or vpnc-script.")
        case "write_failed":            text = L("Could not save the approval.")
        case "helper_unreachable":      text = L("The helper is not reachable.")
        case "bad_request":             text = L("Invalid request.")
        case "connected", "already_connected": text = L("Connected.")
        case "disconnected":            text = L("Disconnected.")
        case "approved":                text = L("openconnect approved.")
        default: return raw   // message inconnu (ancien helper) : affiché tel quel
        }
        return detail.isEmpty ? text : text + "\n" + detail
    }
}
