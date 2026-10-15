// The Bitbucket token (F-PR-3): the environment first, then the keychain (service `griiy`,
// account `bitbucket`, `email\ntoken`). One Atlassian account per Mac user.
import AppKit
import GriiyCore
import Security

enum Secrets {
    /// What saving couldn't put in the keychain: kept for this run only.
    // ponytail: a window opened from ⌘K is another process and asks again. Hand it over in the
    // environment if a keychain that refuses ever turns up.
    private static var memory: BitbucketAuth?

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "griiy",
        kSecAttrAccount as String: "bitbucket",
    ]

    /// Set in the environment: a token typed into the form would never be the one used.
    static var fromEnvironment: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["BITBUCKET_EMAIL"]?.isEmpty == false && env["BITBUCKET_API_TOKEN"]?.isEmpty == false
    }

    static var bitbucket: BitbucketAuth? {
        let env = ProcessInfo.processInfo.environment
        if fromEnvironment, let email = env["BITBUCKET_EMAIL"], let token = env["BITBUCKET_API_TOKEN"] {
            return BitbucketAuth(email: email, token: token)
        }
        if let memory { return memory }
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        let parts = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 ? BitbucketAuth(email: parts[0], token: parts[1]) : nil
    }

    /// Saves or replaces the token; false when the keychain refused it (then it lasts this run).
    @discardableResult
    static func save(_ auth: BitbucketAuth) -> Bool {
        let data = Data("\(auth.email)\n\(auth.token)".utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        memory = status == errSecSuccess ? nil : auth
        return status == errSecSuccess
    }
}

/// Asks for the Atlassian email and API token in two sheets on `window`: getting a token (the
/// browser), then pasting it. `done` gets them, or nil on Cancel.
@MainActor
func askBitbucketToken(_ window: NSWindow, _ done: @escaping (BitbucketAuth?) -> Void) {
    let start = NSAlert()
    start.messageText = "Bitbucket needs an API token"
    start.informativeText = """
        griiy reads pull requests through Bitbucket's API, with a token from your Atlassian account.

        In the browser, choose Create API token with scopes → Bitbucket, give it read:pullrequest:bitbucket and read:repository:bitbucket, and copy it.
        """
    start.addButton(withTitle: "Create Token in Browser")
    start.addButton(withTitle: "I Have a Token")
    start.addButton(withTitle: "Cancel")
    start.beginSheetModal(for: window) { response in
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") {
                NSWorkspace.shared.open(url)
            }
            pasteBitbucketToken(window, done)
        case .alertSecondButtonReturn: pasteBitbucketToken(window, done)
        default: done(nil)
        }
    }
}

@MainActor
private func pasteBitbucketToken(_ window: NSWindow, _ done: @escaping (BitbucketAuth?) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Paste your token"
    alert.informativeText = "griiy keeps it in your keychain."
    let email = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
    email.placeholderString = "Atlassian email"
    email.stringValue = Secrets.bitbucket?.email ?? ""
    let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    token.placeholderString = "API token"
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
    for v in [email, token] { box.addSubview(v) }
    alert.accessoryView = box
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = email.stringValue.isEmpty ? email : token
    alert.beginSheetModal(for: window) { response in
        let e = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !e.isEmpty, !t.isEmpty else { return done(nil) }
        done(BitbucketAuth(email: e, token: t))
    }
}
