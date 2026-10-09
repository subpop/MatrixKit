import os

/// Unified-logging subsystem shared by every MatrixKit product.
///
/// One subsystem for the whole SDK; the per-component loggers below
/// categorize by commonality. In Console.app (or
/// `log stream --predicate 'subsystem == "app.subpop.MatrixKit"'`)
/// one predicate captures every SDK line; add
/// `category == "Transport"` (and friends) to narrow to a component.
let matrixKitSubsystem = "app.subpop.MatrixKit"

/// Per-component loggers for the MatrixKit SDK.
///
/// Message convention: a short summary followed by `key=value` pairs,
/// e.g. `RoomCrypto sent key request user=<hash> session=<hash>`.
/// Structural values (methods, paths, statuses, counts, error
/// descriptions) log `.public`; identifiers (users, rooms, devices,
/// sessions, transactions) log `.private(mask: .hash)` so flows stay
/// correlatable without exposing identifiers; bodies and headers log
/// fully `.private` (with the SDK's token redaction as defense in
/// depth).
enum MatrixKitLog {
    /// Raw HTTP traffic: request/response lines, headers, bodies.
    static let transport = Logger(subsystem: matrixKitSubsystem, category: "Transport")
    /// Long-poll v2 sync loop (`SyncConnection`).
    static let syncConnection = Logger(
        subsystem: matrixKitSubsystem, category: "SyncConnection")
    /// v2 sync engine (`SyncClient`).
    static let sync = Logger(subsystem: matrixKitSubsystem, category: "SyncClient")
    /// Sliding sync engine (`SlidingSyncClient`).
    static let slidingSync = Logger(
        subsystem: matrixKitSubsystem, category: "SlidingSyncClient")
    /// Message send confirmations (`MessageClient`).
    static let messages = Logger(subsystem: matrixKitSubsystem, category: "Messages")
    /// Olm sessions and Megolm room keys (`OlmConnector`, `RoomCrypto`).
    static let crypto = Logger(subsystem: matrixKitSubsystem, category: "Crypto")
    /// SAS verification flows (`VerificationMonitor`).
    static let verification = Logger(
        subsystem: matrixKitSubsystem, category: "Verification")
}
