import Foundation

/// One Client-Server API endpoint from the Matrix spec.
///
/// Generated rows come from `Tools/spec-registry/gen_spec_registry.py`,
/// which reads the official `matrix-org/matrix-spec`
/// `data/api/client-server/*.yaml` files at the pinned release in
/// `Tools/spec-registry/SPEC_VERSION`. Hand-added rows (below the
/// generated block) cover harness-only needs and must be moved into
/// the generator's extras file instead of accumulating here.
public struct SpecEndpoint: Hashable, Sendable {
    /// Uppercase HTTP method (`GET`, `POST`, …).
    public var method: String
    /// Path with `{param}` placeholders for dynamic segments.
    public var pathTemplate: String
    /// Whether the spec requires `Authorization: Bearer` on this endpoint.
    /// (`GET /versions` is served with or without a token; the registry
    /// records it as not required.)
    public var requiresAuth: Bool
    /// Spec source file (e.g. `login.yaml`), for traceability.
    public var sourceFile: String

    public init(method: String, pathTemplate: String, requiresAuth: Bool, sourceFile: String) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.requiresAuth = requiresAuth
        self.sourceFile = sourceFile
    }
}

/// The pinned-spec endpoint registry. Every request the harness
/// receives is matched against this table: unknown method+path pairs
/// are spec violations, and auth mismatches fail the suite.
public enum SpecRegistry {
    /// Pinned spec release. Must match `Tools/spec-registry/SPEC_VERSION`.
    public static let specVersion = "v1.19"

    // BEGIN GENERATED — do not edit by hand.
    // Regenerate with: python3 Tools/spec-registry/gen_spec_registry.py
    public static let endpoints: [SpecEndpoint] = [
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/devices/{deviceId}", requiresAuth: true, sourceFile: "device_management.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/directory/room/{roomAlias}", requiresAuth: true, sourceFile: "directory.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/profile/{userId}/{keyName}", requiresAuth: true, sourceFile: "profile.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/room_keys/keys", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/room_keys/keys/{roomId}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/room_keys/keys/{roomId}/{sessionId}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/room_keys/version/{version}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "DELETE", pathTemplate: "/_matrix/client/v3/user/{userId}/rooms/{roomId}/tags/{tag}", requiresAuth: true, sourceFile: "tags.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/.well-known/matrix/client", requiresAuth: false, sourceFile: "wellknown.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/.well-known/matrix/policy_server", requiresAuth: false, sourceFile: "policy_server.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/.well-known/matrix/support", requiresAuth: false, sourceFile: "support.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports", requiresAuth: true, sourceFile: "MSC4143 unstable (harness)"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/admin/lock/{userId}", requiresAuth: true, sourceFile: "admin.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/admin/suspend/{userId}", requiresAuth: true, sourceFile: "admin.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/auth_metadata", requiresAuth: false, sourceFile: "oauth_server_metadata.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/auth_metadata", requiresAuth: false, sourceFile: "oauth_server_metadata.yaml (post-v1.13, MSC3861)"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/media/config", requiresAuth: true, sourceFile: "authed-content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/media/download/{serverName}/{mediaId}", requiresAuth: true, sourceFile: "authed-content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/media/download/{serverName}/{mediaId}/{fileName}", requiresAuth: true, sourceFile: "authed-content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/media/preview_url", requiresAuth: true, sourceFile: "authed-content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/media/thumbnail/{serverName}/{mediaId}", requiresAuth: true, sourceFile: "authed-content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/mutual_rooms", requiresAuth: true, sourceFile: "mutual_rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/register/m.login.registration_token/validity", requiresAuth: false, sourceFile: "registration_tokens.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/room_summary/{roomIdOrAlias}", requiresAuth: false, sourceFile: "room_summary.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rooms/{roomId}/hierarchy", requiresAuth: true, sourceFile: "space_hierarchy.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rooms/{roomId}/relations/{eventId}", requiresAuth: true, sourceFile: "relations.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}", requiresAuth: true, sourceFile: "relations.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}/{eventType}", requiresAuth: true, sourceFile: "relations.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rooms/{roomId}/threads", requiresAuth: true, sourceFile: "threads_list.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rooms/{roomId}/timestamp_to_event", requiresAuth: true, sourceFile: "room_event_by_timestamp.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v1/rtc/transports", requiresAuth: true, sourceFile: "MSC4143 (harness)"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/account/3pid", requiresAuth: true, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/account/whoami", requiresAuth: true, sourceFile: "whoami.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/admin/whois/{userId}", requiresAuth: true, sourceFile: "admin.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/capabilities", requiresAuth: true, sourceFile: "capabilities.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/devices", requiresAuth: true, sourceFile: "device_management.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/devices/{deviceId}", requiresAuth: true, sourceFile: "device_management.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/directory/list/room/{roomId}", requiresAuth: false, sourceFile: "list_public_rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/directory/room/{roomAlias}", requiresAuth: false, sourceFile: "directory.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/events", requiresAuth: true, sourceFile: "old_sync.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/events", requiresAuth: true, sourceFile: "peeking_events.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/events/{eventId}", requiresAuth: true, sourceFile: "old_sync.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/initialSync", requiresAuth: true, sourceFile: "old_sync.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/joined_rooms", requiresAuth: true, sourceFile: "list_joined_rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/keys/changes", requiresAuth: true, sourceFile: "keys.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/login", requiresAuth: false, sourceFile: "login.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/login/sso/redirect", requiresAuth: false, sourceFile: "sso_login_redirect.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/login/sso/redirect/{idpId}", requiresAuth: false, sourceFile: "sso_login_redirect.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/notifications", requiresAuth: true, sourceFile: "notifications.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/presence/{userId}/status", requiresAuth: true, sourceFile: "presence.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/profile/{userId}", requiresAuth: false, sourceFile: "profile.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/profile/{userId}/{keyName}", requiresAuth: false, sourceFile: "profile.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/publicRooms", requiresAuth: false, sourceFile: "list_public_rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/pushers", requiresAuth: true, sourceFile: "pusher.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/pushrules/", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/pushrules/global/", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}/actions", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}/enabled", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/register/available", requiresAuth: false, sourceFile: "registration.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/room_keys/keys", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/room_keys/keys/{roomId}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/room_keys/keys/{roomId}/{sessionId}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/room_keys/version", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/room_keys/version/{version}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/aliases", requiresAuth: true, sourceFile: "directory.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/context/{eventId}", requiresAuth: true, sourceFile: "event_context.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/event/{eventId}", requiresAuth: true, sourceFile: "rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/initialSync", requiresAuth: true, sourceFile: "room_initial_sync.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/joined_members", requiresAuth: true, sourceFile: "rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/members", requiresAuth: true, sourceFile: "rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/messages", requiresAuth: true, sourceFile: "message_pagination.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/state", requiresAuth: true, sourceFile: "rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}", requiresAuth: true, sourceFile: "rooms.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/sync", requiresAuth: true, sourceFile: "sync.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/thirdparty/location", requiresAuth: true, sourceFile: "third_party_lookup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/thirdparty/location/{protocol}", requiresAuth: true, sourceFile: "third_party_lookup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/thirdparty/protocol/{protocol}", requiresAuth: true, sourceFile: "third_party_lookup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/thirdparty/protocols", requiresAuth: true, sourceFile: "third_party_lookup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/thirdparty/user", requiresAuth: true, sourceFile: "third_party_lookup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/thirdparty/user/{protocol}", requiresAuth: true, sourceFile: "third_party_lookup.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/user/{userId}/account_data/{type}", requiresAuth: true, sourceFile: "account-data.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/user/{userId}/filter/{filterId}", requiresAuth: true, sourceFile: "filter.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}", requiresAuth: true, sourceFile: "account-data.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/user/{userId}/rooms/{roomId}/tags", requiresAuth: true, sourceFile: "tags.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/v3/voip/turnServer", requiresAuth: true, sourceFile: "voip.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/client/versions", requiresAuth: false, sourceFile: "versions.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/config", requiresAuth: true, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/download/{serverName}/{mediaId}", requiresAuth: false, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/download/{serverName}/{mediaId}", requiresAuth: false, sourceFile: "legacy fallback (pre-MSC3916 servers)"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/download/{serverName}/{mediaId}/{fileName}", requiresAuth: false, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/preview_url", requiresAuth: true, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/thumbnail/{serverName}/{mediaId}", requiresAuth: false, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "GET", pathTemplate: "/_matrix/media/v3/thumbnail/{serverName}/{mediaId}", requiresAuth: false, sourceFile: "legacy fallback (pre-MSC3916 servers)"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/unstable/org.matrix.msc4140/delayed_events/{delayId}", requiresAuth: true, sourceFile: "MSC4140 unstable (harness)"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync", requiresAuth: true, sourceFile: "MSC4186 unstable endpoint"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v1/appservice/{appserviceId}/ping", requiresAuth: false, sourceFile: "appservice_ping.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v1/login/get_token", requiresAuth: true, sourceFile: "login_token.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid", requiresAuth: true, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid/add", requiresAuth: true, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid/bind", requiresAuth: true, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid/delete", requiresAuth: true, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid/email/requestToken", requiresAuth: false, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid/msisdn/requestToken", requiresAuth: false, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/3pid/unbind", requiresAuth: true, sourceFile: "administrative_contact.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/deactivate", requiresAuth: false, sourceFile: "account_deactivation.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/password", requiresAuth: false, sourceFile: "password_management.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/password/email/requestToken", requiresAuth: false, sourceFile: "password_management.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/account/password/msisdn/requestToken", requiresAuth: false, sourceFile: "password_management.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/createRoom", requiresAuth: true, sourceFile: "create_room.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/delete_devices", requiresAuth: true, sourceFile: "device_management.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/join/{roomIdOrAlias}", requiresAuth: true, sourceFile: "joining.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/keys/claim", requiresAuth: true, sourceFile: "keys.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/keys/device_signing/upload", requiresAuth: true, sourceFile: "cross_signing.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/keys/query", requiresAuth: true, sourceFile: "keys.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/keys/signatures/upload", requiresAuth: true, sourceFile: "cross_signing.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/keys/upload", requiresAuth: true, sourceFile: "keys.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/knock/{roomIdOrAlias}", requiresAuth: true, sourceFile: "knocking.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/login", requiresAuth: false, sourceFile: "login.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/logout", requiresAuth: true, sourceFile: "logout.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/logout/all", requiresAuth: true, sourceFile: "logout.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/publicRooms", requiresAuth: true, sourceFile: "list_public_rooms.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/pushers/set", requiresAuth: true, sourceFile: "pusher.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/refresh", requiresAuth: false, sourceFile: "refresh.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/register", requiresAuth: false, sourceFile: "registration.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/register/email/requestToken", requiresAuth: false, sourceFile: "registration.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/register/msisdn/requestToken", requiresAuth: false, sourceFile: "registration.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/room_keys/version", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/ban", requiresAuth: true, sourceFile: "banning.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/forget", requiresAuth: true, sourceFile: "leaving.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/invite", requiresAuth: true, sourceFile: "inviting.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/invite", requiresAuth: true, sourceFile: "third_party_membership.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/join", requiresAuth: true, sourceFile: "joining.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/kick", requiresAuth: true, sourceFile: "kicking.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/leave", requiresAuth: true, sourceFile: "leaving.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/read_markers", requiresAuth: true, sourceFile: "read_markers.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId}", requiresAuth: true, sourceFile: "receipts.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/report", requiresAuth: true, sourceFile: "report_content.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/report/{eventId}", requiresAuth: true, sourceFile: "report_content.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/unban", requiresAuth: true, sourceFile: "banning.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/upgrade", requiresAuth: true, sourceFile: "room_upgrades.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/search", requiresAuth: true, sourceFile: "search.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/user/{userId}/filter", requiresAuth: true, sourceFile: "filter.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/user/{userId}/openid/request_token", requiresAuth: true, sourceFile: "openid.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/user_directory/search", requiresAuth: true, sourceFile: "users.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/client/v3/users/{userId}/report", requiresAuth: true, sourceFile: "report_content.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/media/v1/create", requiresAuth: true, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/_matrix/media/v3/upload", requiresAuth: true, sourceFile: "content-repo.yaml"),
        SpecEndpoint(method: "POST", pathTemplate: "/get_token", requiresAuth: false, sourceFile: "LiveKit SFU (harness loopback)"),
        SpecEndpoint(method: "POST", pathTemplate: "/issuer/device", requiresAuth: false, sourceFile: "RFC8628 issuer (harness loopback)"),
        SpecEndpoint(method: "POST", pathTemplate: "/issuer/register", requiresAuth: false, sourceFile: "RFC7591 issuer (harness loopback)"),
        SpecEndpoint(method: "POST", pathTemplate: "/issuer/revoke", requiresAuth: false, sourceFile: "RFC7009 issuer (harness loopback)"),
        SpecEndpoint(method: "POST", pathTemplate: "/issuer/token", requiresAuth: false, sourceFile: "RFC6749 issuer (harness loopback)"),
        SpecEndpoint(method: "POST", pathTemplate: "/sfu/get", requiresAuth: false, sourceFile: "LiveKit SFU (harness loopback)"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v1/admin/lock/{userId}", requiresAuth: true, sourceFile: "admin.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v1/admin/suspend/{userId}", requiresAuth: true, sourceFile: "admin.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/devices/{deviceId}", requiresAuth: true, sourceFile: "device_management.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/directory/list/appservice/{networkId}/{roomId}", requiresAuth: false, sourceFile: "appservice_room_directory.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/directory/list/room/{roomId}", requiresAuth: true, sourceFile: "list_public_rooms.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/directory/room/{roomAlias}", requiresAuth: true, sourceFile: "directory.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/presence/{userId}/status", requiresAuth: true, sourceFile: "presence.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/profile/{userId}/{keyName}", requiresAuth: true, sourceFile: "profile.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}/actions", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/pushrules/global/{kind}/{ruleId}/enabled", requiresAuth: true, sourceFile: "pushrules.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/room_keys/keys", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/room_keys/keys/{roomId}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/room_keys/keys/{roomId}/{sessionId}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/room_keys/version/{version}", requiresAuth: true, sourceFile: "key_backup.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}", requiresAuth: true, sourceFile: "redaction.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}", requiresAuth: true, sourceFile: "room_send.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/state/{eventType}/", requiresAuth: true, sourceFile: "overrides.json (empty state key)"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}", requiresAuth: true, sourceFile: "room_state.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/rooms/{roomId}/typing/{userId}", requiresAuth: true, sourceFile: "typing.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/sendToDevice/{eventType}/{txnId}", requiresAuth: true, sourceFile: "to_device.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/user/{userId}/account_data/{type}", requiresAuth: true, sourceFile: "account-data.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}", requiresAuth: true, sourceFile: "account-data.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/client/v3/user/{userId}/rooms/{roomId}/tags/{tag}", requiresAuth: true, sourceFile: "tags.yaml"),
        SpecEndpoint(method: "PUT", pathTemplate: "/_matrix/media/v3/upload/{serverName}/{mediaId}", requiresAuth: true, sourceFile: "content-repo.yaml"),
    ];
    // END GENERATED

    /// Match a request against the registry. Template segments in
    /// `{braces}` match any single path segment.
    public static func match(method: String, path: String) -> SpecEndpoint? {
        // Exact hits first (no allocation on the common path).
        if let exact = endpoints.first(where: { $0.method == method && $0.pathTemplate == path }) {
            return exact
        }
        let wanted = path.split(separator: "/", omittingEmptySubsequences: false)
        return endpoints.first { endpoint in
            guard endpoint.method == method else { return false }
            let template = endpoint.pathTemplate.split(separator: "/", omittingEmptySubsequences: false)
            guard template.count == wanted.count else { return false }
            return zip(template, wanted).allSatisfy { part, segment in
                (part.hasPrefix("{") && part.hasSuffix("}")) || part == segment
            }
        }
    }
}
