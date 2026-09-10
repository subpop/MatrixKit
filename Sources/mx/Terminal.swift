/// ANSI terminal output helpers for mx.
import Foundation
import MatrixKit

/// ANSI color/style codes.
enum ANSI {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let cyan = "\u{1B}[36m"
}

/// Wrap text in an ANSI style, always resetting after.
func styled(_ text: String, _ code: String) -> String {
    "\(code)\(text)\(ANSI.reset)"
}

func printError(_ message: String) {
    emit("\(styled(timestamp(), ANSI.dim)) " + styled("Error: \(message)", ANSI.bold + ANSI.red))
}

func printInfo(_ message: String) {
    emit("\(styled(timestamp(), ANSI.dim)) " + styled(message, ANSI.dim))
}

/// Encode a value as compact JSON for display.
func json(_ value: some Encodable) -> String {
    (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "?"
}

/// Format a Matrix event for terminal display. Returns nil for events
/// that should be skipped (typing, receipts, ...).
func formatEvent(_ event: MessageEvent, localUser: UserId?) -> String? {
    let sender = event.sender.localpart ?? event.sender.value
    let who =
        event.sender == localUser
        ? styled(sender, ANSI.bold + ANSI.yellow)
        : styled(sender, ANSI.bold + ANSI.green)
    let time = styled(
        event.timestamp.formatted(date: .omitted, time: .shortened), ANSI.dim)

    switch EventType(rawValue: event.type) {
    case .roomMessage:
        guard let content = event.messageContent else { return nil }
        let body: String
        switch content.msgtype {
        case .text, .emote, .notice:
            body = content.body
        case .image, .video, .audio, .file:
            body = "[\(content.msgtype.rawValue): \(content.body)]"
        case .location:
            body = "[location: \(content.body)]"
        }
        if content.msgtype == .emote {
            return "\(time) * \(who) \(body)"
        }
        return "\(time) <\(who)> \(body)"
    case .redaction:
        return "\(time) \(who) redacted an event"
    case .sticker:
        let body = event.content["body"]?.stringValue ?? "sticker"
        return "\(time) \(who) sent a sticker: \(body)"
    case .pollStart:
        let question = event.content["question"]?.objectValue?["org.matrix.msc1767.text"]?.stringValue
            ?? "poll"
        return "\(time) \(who) started a poll: \(question)"
    case .callMember:
        return "\(time) \(styled("\(sender) updated call participation", ANSI.dim))"
    case .roomMember:
        let membership = event.content["membership"]?.stringValue ?? "?"
        let target = event.stateKey ?? event.sender.value
        return "\(time) \(styled("\(target) \(membership)", ANSI.dim))"
    case .roomName:
        let name = event.content["name"]?.stringValue ?? ""
        return "\(time) \(styled("Room renamed to \"\(name)\"", ANSI.dim))"
    case .roomTopic:
        return "\(time) \(styled("Topic changed", ANSI.dim))"
    case .roomCreate, .roomAvatar, .roomPowerLevels, .roomEncryption, .roomTombstone,
        .roomCanonicalAlias, .roomPinnedEvents, .roomJoinRules, .roomHistoryVisibility,
        .roomServerACL:
        return "\(time) \(styled("\(sender) updated \(event.type)", ANSI.dim))"
    case .reaction, .typing, .receipt, .presence, .fullyRead, .tag, .custom, .unknown:
        return nil
    }
}

/// Print the help text listing all commands.
func printHelp() {
    emit(
        """
        Commands:
          login <homeserver> <user> <password>  Log in (e.g. login https://matrix.org @alice:matrix.org secret)
          login-oauth <homeserver>            OIDC device login (no password; code + URL)
          restore                             Restore the saved OIDC session
          logout                                Log out
          rooms                                 List joined rooms and invites
          join <room-id-or-alias>               Join a room
          open <number-or-room-id>              Open a room (shows recent timeline)
          back                                  Leave the current room view
          send <text>                           Send a message to the open room
          esend <text>                          Send end-to-end encrypted to the open room
          sharekey                              Re-share the Megolm session with joined members
          reply <n|$event-id> <text>            Reply to a message by list number or event ID
          react <n|$event-id> <emoji>           React to a message
          members                               List members of the open room
          topic [new topic]                     Show or set the room topic
          leave                                 Leave the open room
          verify <user-id> [device-id]          Verify a user/device via SAS emoji
          crosssign                             Generate + upload cross-signing keys
          crosssign-import <file>               Import cross-signing keys from backup
          export-crosssign <file>               Export cross-signing keys to backup (0600)
          fetch-secrets [device-id]             Request cross-signing secrets from a device
          recover <key-or-passphrase>           Unlock 4S secret storage (Es… key or passphrase)
          show-secret <name>                    Decrypt a stored secret (truncated; needs recover first)
          backup-restore                        Download + import backed-up megolm sessions
           identity                              Show server identity vs local keys
           pushrules [room-id]                   Show per-room notification modes
          debug [on|off]                        Toggle HTTP debug logging
          help                                  Show this help
          quit                                  Exit

        Launch options: --log-file <path>  Write logs to a file instead of the console
                        --log-level <level>  trace, debug, info, notice, warning, error, critical
                        --cache <backend>    sqlite, swiftdata, or auto (default)
        """)
}
