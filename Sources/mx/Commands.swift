/// REPL command parsing for mx.
import MatrixKit

enum Command: Sendable {
    case login(homeserver: String, user: String, password: String)
    case loginOAuth(homeserver: String)
    case restore
    case logout
    case rooms
    case join(target: String)
    case open(target: String)
    case back
    case send(text: String)
    case esend(text: String)
    case sharekey
    case reply(ref: String, text: String)
    case react(ref: String, key: String)
    case members
    case topic(newTopic: String?)
    case leave
    case verify(user: String, device: String?)
    case crosssign
    case crosssignImport(path: String)
    case exportCrosssign(path: String)
    case fetchSecrets(device: String?)
    case recover(secret: String)
    case showSecret(name: String)
    case backupRestore
    case identity
    case pushrules(room: String?)
    case debug(enabled: Bool?)
    case help
    case quit
}

/// Parse a raw input line into a command. Returns nil for blank lines
/// or on parse errors (already reported to the terminal).
func parseCommand(_ line: String) -> Command? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let (word, rest) = splitFirstWord(trimmed)
    switch word.lowercased() {
    case "login":
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            printError("Usage: login <homeserver> <user> <password>")
            return nil
        }
        return .login(
            homeserver: String(parts[0]), user: String(parts[1]),
            password: String(parts[2]))
    case "login-oauth":
        guard !rest.isEmpty else {
            printError("Usage: login-oauth <homeserver>")
            return nil
        }
        return .loginOAuth(homeserver: rest)
    case "restore":
        return .restore
    case "logout":
        return .logout
    case "rooms":
        return .rooms
    case "join":
        guard !rest.isEmpty else {
            printError("Usage: join <room-id-or-alias>")
            return nil
        }
        return .join(target: rest)
    case "open":
        guard !rest.isEmpty else {
            printError("Usage: open <number-or-room-id>")
            return nil
        }
        return .open(target: rest)
    case "back":
        return .back
    case "send":
        guard !rest.isEmpty else {
            printError("Usage: send <text>")
            return nil
        }
        return .send(text: rest)
    case "esend":
        guard !rest.isEmpty else {
            printError("Usage: esend <text>")
            return nil
        }
        return .esend(text: rest)
    case "sharekey":
        return .sharekey
    case "reply":
        let (ref, text) = splitFirstWord(rest)
        guard !ref.isEmpty, !text.isEmpty else {
            printError("Usage: reply <n|$event-id> <text>")
            return nil
        }
        return .reply(ref: ref, text: text)
    case "react":
        let (ref, key) = splitFirstWord(rest)
        guard !ref.isEmpty, !key.isEmpty else {
            printError("Usage: react <n|$event-id> <emoji>")
            return nil
        }
        return .react(ref: ref, key: key)
    case "members":
        return .members
    case "topic":
        return .topic(newTopic: rest.isEmpty ? nil : rest)
    case "leave":
        return .leave
    case "verify":
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 1, parts.count <= 2 else {
            printError("Usage: verify <user-id> [device-id]")
            return nil
        }
        return .verify(
            user: String(parts[0]),
            device: parts.count == 2 ? String(parts[1]) : nil)
    case "crosssign":
        return .crosssign
    case "crosssign-import":
        guard !rest.isEmpty else {
            printError("Usage: crosssign-import <backup-file>")
            return nil
        }
        return .crosssignImport(path: rest)
    case "export-crosssign":
        guard !rest.isEmpty else {
            printError("Usage: export-crosssign <backup-file>")
            return nil
        }
        return .exportCrosssign(path: rest)
    case "fetch-secrets":
        return .fetchSecrets(device: rest.isEmpty ? nil : rest)
    case "recover":
        guard !rest.isEmpty else {
            printError("Usage: recover <recovery-key-or-passphrase>")
            return nil
        }
        return .recover(secret: rest)
    case "show-secret":
        guard !rest.isEmpty else {
            printError("Usage: show-secret <secret-name> (e.g. m.cross_signing.master)")
            return nil
        }
        return .showSecret(name: rest)
    case "backup-restore":
        return .backupRestore
    case "identity":
        return .identity
    case "pushrules":
        return .pushrules(room: rest.isEmpty ? nil : rest)
    case "debug":
        switch rest.lowercased() {
        case "on": return .debug(enabled: true)
        case "off": return .debug(enabled: false)
        case "": return .debug(enabled: nil)
        default:
            printError("Usage: debug [on|off]")
            return nil
        }
    case "help":
        return .help
    case "quit", "exit":
        return .quit
    default:
        printError("Unknown command: \(word). Type 'help' for a list.")
        return nil
    }
}

/// Split "word rest of line" into ("word", "rest of line").
private func splitFirstWord(_ line: String) -> (String, String) {
    guard let space = line.firstIndex(of: " ") else { return (line, "") }
    let word = String(line[..<space])
    let rest = String(line[line.index(after: space)...])
        .trimmingCharacters(in: .whitespaces)
    return (word, rest)
}
