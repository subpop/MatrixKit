import Foundation
import Observation

/// Observable user profile: display name, avatar, and update actions.
@Observable @MainActor
public final class ObservableUserProfile {
    /// The profiled user's Matrix ID.
    public let userId: UserId
    /// Display name from the last `load()`. Nil until loaded or unset.
    public private(set) var displayName: String?
    /// Avatar MXC URI from the last `load()`. Resolve bytes via `avatarData()`.
    public private(set) var avatarURL: MXCURI?
    /// True while a `load()` request is in flight (for spinners).
    public private(set) var isLoading: Bool

    private let profiles: ProfileClient
    private let media: MediaClient
    private let localUser: UserId?

    /// Whether this profile belongs to the logged-in user (editable).
    public var isOwn: Bool { userId == localUser }

    init(userId: UserId, profiles: ProfileClient, media: MediaClient, localUser: UserId?) {
        self.userId = userId
        self.profiles = profiles
        self.media = media
        self.localUser = localUser
        self.isLoading = false
    }

    /// Load (or reload) from the server.
    public func load() async throws {
        isLoading = true
        defer { isLoading = false }
        let profile = try await profiles.getProfile(userId)
        displayName = profile.displayname
        avatarURL = profile.avatarMXC
    }

    /// Update own display name.
    public func updateDisplayName(_ name: String) async throws {
        guard isOwn else { return }
        try await profiles.setDisplayName(userId, name: name)
        displayName = name
    }

    /// Upload new avatar bytes and set as own avatar.
    public func updateAvatar(data: Data, mimeType: String) async throws {
        guard isOwn else { return }
        let uri = try await media.upload(data, mimeType: mimeType)
        try await profiles.setAvatarURL(userId, url: uri)
        avatarURL = uri
    }

    /// Download avatar bytes, if an avatar is set.
    public func avatarData() async throws -> Data? {
        guard let avatarURL else { return nil }
        return try await media.download(avatarURL)
    }
}
