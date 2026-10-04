import Foundation

/// App-side detection of openconnect and Homebrew (same locations as the helper).
enum Homebrew {
    static let installCommand = "brew install openconnect"
    static let website = "https://brew.sh"

    static var openConnectInstalled: Bool {
        ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var brewInstalled: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
