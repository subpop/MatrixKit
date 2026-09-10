/// Raw-mode line editor for mx: history, cursor movement, repaint.
///
/// `readLine` can't do arrows or history, so the editor drives the
/// terminal directly: on a TTY it switches stdin to raw mode (no
/// canonical processing, no echo) and interprets bytes itself —
/// printable text, Backspace/Delete, arrows, Home/End, plus a few
/// Emacs keys (Ctrl+A/E/K/U, Ctrl+L redraw, Ctrl+C clear, Ctrl+D EOF).
///
/// All REPL output funnels through `emit`, which repaints the
/// half-typed line after any print, so live sync messages landing
/// mid-typing never destroy input. When stdin is not a TTY (pipes,
/// tests) — or off Darwin, where termios differs — everything degrades
/// to plain `readLine`/`print`.
import Foundation

/// Print through the line editor, preserving half-typed input.
/// Mirrors `print`'s signature for mechanical call-site replacement.
func emit(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    LineEditor.shared.write(
        items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
}

/// Short `[1:58 PM]`-style stamp for console messages and the prompt.
func timestamp() -> String {
    "[\(Date().formatted(date: .omitted, time: .shortened))]"
}

#if canImport(Darwin)
import Darwin

/// Single owner of stdin. `@unchecked Sendable`: every mutable field is
/// guarded by `lock`, and blocking reads happen off the MainActor.
final class LineEditor: @unchecked Sendable {
    static let shared = LineEditor()

    private let lock = NSLock()
    private let tty: Bool
    private var originalTermios = termios()
    private var rawActive = false

    /// Editing state, meaningful only while `reading`.
    private var reading = false
    private var prompt = ""
    private var buffer: [Character] = []
    private var cursor = 0
    private var recordHistory = true

    /// Session-only command history (never touches disk).
    private var history: [String] = []
    private var historyIndex: Int?
    private var draft: [Character] = []

    private init() {
        tty = isatty(STDIN_FILENO) != 0
    }

    // MARK: - Raw mode

    func enableRawMode() {
        guard tty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !rawActive else { return }
        var raw = termios()
        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else { return }
        raw = originalTermios
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
        rawActive = true
    }

    func disableRawMode() {
        lock.lock()
        defer { lock.unlock() }
        guard rawActive else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        rawActive = false
    }

    // MARK: - Output gate

    /// Write text, repainting the in-progress input line when one is active.
    func write(_ text: String, terminator: String = "\n") {
        lock.lock()
        defer { lock.unlock() }
        if reading {
            var out = "\r\u{1B}[K" + text + terminator + prompt + String(buffer)
            let back = buffer.count - cursor
            if back > 0 { out += "\u{1B}[\(back)D" }
            writeRaw(out)
        } else {
            writeRaw(text + terminator)
        }
    }

    private func writeRaw(_ text: String) {
        // Raw mode disables ONLCR, so LF no longer implies CR and
        // multi-line output stair-steps down the screen. Translate
        // lone LFs while raw. Always called with `lock` held.
        var cooked = text
        if rawActive {
            cooked = cooked.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
        }
        fputs(cooked, stdout)
        fflush(stdout)
    }

    // MARK: - Line reading

    /// Read one line, blocking the calling thread. Returns nil on EOF
    /// (Ctrl+D on an empty line, or closed stdin).
    func readLine(prompt: String, recordHistory: Bool = true, leadingNewline: Bool = true) -> String? {
        guard tty else { return Swift.readLine(strippingNewline: true) }
        enableRawMode()
        lock.lock()
        if leadingNewline { writeRaw("\n") }
        reading = true
        self.prompt = prompt
        self.recordHistory = recordHistory
        buffer = []
        cursor = 0
        historyIndex = nil
        draft = []
        renderLocked()
        lock.unlock()

        var pending: [UInt8] = []
        while true {
            guard let byte = readByte(timeoutMs: -1) else {
                lock.lock()
                reading = false
                writeRaw("\r\n")
                lock.unlock()
                return nil
            }
            // Escape sequences do their own (timed) reads; keep the
            // lock free so prints aren't stalled by a lone ESC.
            if byte == 0x1B {
                let key = readEscapeKey()
                lock.lock()
                applyEscapeKey(key)
                renderLocked()
                lock.unlock()
                continue
            }
            lock.lock()
            let result = consume(byte, pending: &pending)
            lock.unlock()
            switch result {
            case .continued:
                continue
            case .submit(let line):
                return line
            case .eof:
                return nil
            }
        }
    }

    private enum ReadResult {
        case continued
        case submit(String)
        case eof
    }

    /// Handle one input byte. Lock must be held.
    private func consume(_ byte: UInt8, pending: inout [UInt8]) -> ReadResult {
        switch byte {
        case 0x03:  // Ctrl+C — clear the line
            buffer = []
            cursor = 0
            historyIndex = nil
            renderLocked()
        case 0x04:  // Ctrl+D — EOF on empty, else delete under cursor
            if buffer.isEmpty {
                reading = false
                writeRaw("\r\n")
                return .eof
            }
            if cursor < buffer.count { buffer.remove(at: cursor) }
            renderLocked()
        case 0x0A, 0x0D:  // Enter — accept the line
            let line = String(buffer)
            pushHistory(line)
            var out = ""
            let ahead = buffer.count - cursor
            if ahead > 0 { out += "\u{1B}[\(ahead)C" }
            out += "\n"
            writeRaw(out)
            reading = false
            return .submit(line)
        case 0x7F, 0x08:  // Backspace (DEL or BS)
            if cursor > 0 {
                buffer.remove(at: cursor - 1)
                cursor -= 1
            }
            renderLocked()
        case 0x01:  // Ctrl+A — start of line
            cursor = 0
            renderLocked()
        case 0x05:  // Ctrl+E — end of line
            cursor = buffer.count
            renderLocked()
        case 0x15:  // Ctrl+U — kill to start
            buffer.removeFirst(cursor)
            cursor = 0
            renderLocked()
        case 0x0B:  // Ctrl+K — kill to end
            buffer.removeLast(buffer.count - cursor)
            renderLocked()
        case 0x0C:  // Ctrl+L — redraw
            renderLocked()
        case 0x00..<0x20, 0x09:  // Other controls / tab: ignore
            break
        default:
            // Accumulate UTF-8: continuation bytes don't decode alone,
            // so this naturally waits for the full sequence (≤4 bytes).
            pending.append(byte)
            if let text = String(bytes: pending, encoding: .utf8) {
                pending = []
                buffer.insert(contentsOf: text, at: cursor)
                cursor += text.count
                renderLocked()
            } else if pending.count > 4 {
                pending = []
            }
        }
        return .continued
    }

    // MARK: - Escape keys

    private enum EscapeKey {
        case up, down, left, right, home, end, delete, unknown
    }

    /// Read the rest of an escape sequence (called after ESC).
    /// Timed reads: a lone ESC yields `.unknown` instead of hanging.
    private func readEscapeKey() -> EscapeKey {
        guard let second = readByte(timeoutMs: 100) else { return .unknown }
        if second == UInt8(ascii: "O") {
            switch readByte(timeoutMs: 100) {
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            default: return .unknown
            }
        }
        guard second == UInt8(ascii: "[") else { return .unknown }
        switch readByte(timeoutMs: 100) {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "1"), UInt8(ascii: "7"):
            _ = readByte(timeoutMs: 100)  // expect `~` (home)
            return .home
        case UInt8(ascii: "3"):
            _ = readByte(timeoutMs: 100)  // expect `~` (delete)
            return .delete
        case UInt8(ascii: "4"), UInt8(ascii: "8"):
            _ = readByte(timeoutMs: 100)  // expect `~` (end)
            return .end
        default: return .unknown
        }
    }

    /// Apply a parsed escape key. Lock must be held; caller re-renders.
    private func applyEscapeKey(_ key: EscapeKey) {
        switch key {
        case .unknown:
            break
        case .left:
            if cursor > 0 { cursor -= 1 }
        case .right:
            if cursor < buffer.count { cursor += 1 }
        case .home:
            cursor = 0
        case .end:
            cursor = buffer.count
        case .delete:
            if cursor < buffer.count { buffer.remove(at: cursor) }
        case .up:
            historyUp()
        case .down:
            historyDown()
        }
    }

    // MARK: - History

    private func pushHistory(_ line: String) {
        guard recordHistory else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, history.last != line else { return }
        history.append(line)
        if history.count > 200 { history.removeFirst(history.count - 200) }
    }

    private func historyUp() {
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            draft = buffer
            historyIndex = history.count - 1
        } else if historyIndex! > 0 {
            historyIndex! -= 1
        } else {
            return
        }
        buffer = Array(history[historyIndex!])
        cursor = buffer.count
    }

    private func historyDown() {
        guard let i = historyIndex else { return }
        if i + 1 < history.count {
            historyIndex = i + 1
            buffer = Array(history[i + 1])
            cursor = buffer.count
        } else {
            historyIndex = nil
            buffer = draft
            cursor = buffer.count
        }
    }

    /// Re-render prompt + buffer + cursor. Lock must be held.
    private func renderLocked() {
        var out = "\r\u{1B}[K" + prompt + String(buffer)
        let back = buffer.count - cursor
        if back > 0 { out += "\u{1B}[\(back)D" }
        writeRaw(out)
    }

    // MARK: - Byte input

    /// Read one byte, waiting up to `timeoutMs` (`-1` = forever).
    /// Nil on timeout, EOF, or error.
    private func readByte(timeoutMs: Int32) -> UInt8? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }
}

#else

/// Non-Darwin fallback: no raw mode, plain `readLine`/`print`.
final class LineEditor: @unchecked Sendable {
    static let shared = LineEditor()
    private init() {}

    func enableRawMode() {}
    func disableRawMode() {}

    func write(_ text: String, terminator: String = "\n") {
        print(text, terminator: terminator)
        fflush(stdout)
    }

    func readLine(prompt: String, recordHistory: Bool = true, leadingNewline: Bool = true) -> String? {
        if leadingNewline { print() }
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine(strippingNewline: true)
    }
}

#endif
