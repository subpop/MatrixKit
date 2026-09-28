import Foundation
import MatrixKit

/// Minimal homeserver state for the spec harness.
///
/// The world starts with one seeded user (`alice` / `secret` on the
/// harness host) and mints tokens as logins succeed. Suites add state
/// only through the ops they need — anything unimplemented answers
/// `M_UNRECOGNIZED`, which is itself the spec-correct negative case.
public actor HarnessWorld {
    /// Fixed homeserver name reported in MXIDs.
    public let serverName = "test"

    private struct Account {
        var userId: UserId
        var password: String
        var deviceId: DeviceId
    }

    private struct TokenRecord {
        var userId: UserId
        var deviceId: DeviceId
    }

    private var accounts: [String: Account] = [:]
    private var passwords: [String: String] = [:]
    private var tokens: [String: TokenRecord] = [:]
    private var refreshTokens: [String: String] = [:]
    private var uiaaSessions: Set<String> = []
    private var counter = 0

    /// Token accepted for pre-seeded SSO (`m.login.token`) logins.
    public let ssoLoginToken = "harness-sso-login-token"

    /// Base URL advertised in `.well-known/matrix/client`. Set by the
    /// harness once the loopback port is bound.
    private var publicBaseURL = "http://127.0.0.1"

    public func setPublicBaseURL(_ url: String) {
        publicBaseURL = url
    }

    public func baseURL() -> String {
        publicBaseURL
    }

    public init() {
        let userId = UserId(unchecked: "@alice:test")
        accounts["alice"] = Account(userId: userId, password: "secret", deviceId: DeviceId("ALICEDEVICE"))
        passwords["alice"] = "secret"
        // The seeded session token for suites that skip login.
        tokens["harness-token-alice"] = TokenRecord(userId: userId, deviceId: DeviceId("ALICEDEVICE"))
        refreshTokens["harness-refresh-alice"] = "harness-token-alice"
    }

    // MARK: - Tokens

    /// Mint a fresh token pair for a user/device.
    @discardableResult
    public func mintTokens(userId: UserId, deviceId: DeviceId) -> (access: String, refresh: String) {
        counter += 1
        let access = "harness-token-\(counter)"
        let refresh = "harness-refresh-\(counter)"
        tokens[access] = TokenRecord(userId: userId, deviceId: deviceId)
        refreshTokens[refresh] = access
        return (access, refresh)
    }

    /// The (user, device) a bearer token belongs to, if valid.
    public func record(for token: String) -> (userId: UserId, deviceId: DeviceId)? {
        tokens[token].map { ($0.userId, $0.deviceId) }
    }

    public func isValidToken(_ token: String) -> Bool {
        tokens[token] != nil
    }

    @discardableResult
    public func revoke(_ token: String) -> Bool {
        tokens.removeValue(forKey: token) != nil
    }

    public func revokeAll(for userId: UserId) {
        tokens = tokens.filter { $0.value.userId != userId }
    }

    // MARK: - Auth endpoints

    public func login(_ request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(LoginRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed login request", status: 400)
        }
        switch body.type {
        case "m.login.password":
            let rawUser = body.identifier?.user ?? body.user ?? ""
            let localpart = rawUser.hasPrefix("@") ? String(rawUser.dropFirst().prefix(while: { $0 != ":" })) : rawUser
            guard let account = accounts[localpart], account.password == (body.password ?? "") else {
                return .matrixError(code: "M_FORBIDDEN", message: "Invalid username or password", status: 403)
            }
            let deviceId = body.deviceId ?? DeviceId("HARNESS\(counter + 1)")
            let pair = mintTokens(userId: account.userId, deviceId: deviceId)
            return .json(LoginResponse(userId: account.userId, accessToken: pair.access, refreshToken: pair.refresh, deviceId: deviceId))
        case "m.login.token":
            guard body.token == ssoLoginToken, let account = accounts["alice"] else {
                return .matrixError(code: "M_FORBIDDEN", message: "Invalid login token", status: 403)
            }
            let deviceId = body.deviceId ?? account.deviceId
            let pair = mintTokens(userId: account.userId, deviceId: deviceId)
            return .json(LoginResponse(userId: account.userId, accessToken: pair.access, refreshToken: pair.refresh, deviceId: deviceId))
        default:
            return .matrixError(code: "M_UNKNOWN", message: "Unsupported login type \(body.type)", status: 400)
        }
    }

    public func loginFlows() -> HarnessResponse {
        .json(LoginFlows(flows: [LoginFlow(type: "m.login.password"), LoginFlow(type: "m.login.sso")]))
    }

    public func register(_ request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(RegisterRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed register request", status: 400)
        }
        // First contact (or an unknown session) draws a UIAA challenge.
        guard let auth = body.auth, auth.type == "m.login.dummy", let session = auth.session, uiaaSessions.contains(session) else {
            counter += 1
            let session = "harness-uiaa-\(counter)"
            uiaaSessions.insert(session)
            return .json(UIAAChallenge(flows: [UIAFlow(stages: ["m.login.dummy"])], session: session), status: 401)
        }
        uiaaSessions.remove(session)
        counter += 1
        let localpart = (body.username?.isEmpty == false ? body.username! : "user\(counter)")
        let userId = UserId(unchecked: "@\(localpart):test")
        let deviceId = body.deviceId ?? DeviceId("HARNESS\(counter)")
        accounts[localpart] = Account(userId: userId, password: body.password ?? "", deviceId: deviceId)
        if body.inhibitLogin == true {
            return .json(RegisterResponse(userId: userId))
        }
        let pair = mintTokens(userId: userId, deviceId: deviceId)
        return .json(RegisterResponse(userId: userId, accessToken: pair.access, deviceId: deviceId, refreshToken: pair.refresh))
    }

    public func registerAvailable(_ request: HarnessRequest) -> HarnessResponse {
        let taken = request.query["username"].map { accounts[$0] != nil } ?? false
        return .json(RegisterAvailable(available: !taken))
    }

    public func whoAmI(bearer: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        return .json(WhoAmI(userId: record.userId, deviceId: record.deviceId))
    }

    public func refresh(_ request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(RefreshRequest.self),
            let oldAccess = refreshTokens[body.refreshToken],
            let record = tokens[oldAccess]
        else {
            return .matrixError(code: "M_FORBIDDEN", message: "Invalid refresh token", status: 403)
        }
        let pair = mintTokens(userId: record.userId, deviceId: record.deviceId)
        return .json(LoginResponse(userId: record.userId, accessToken: pair.access, refreshToken: pair.refresh, deviceId: record.deviceId))
    }

    public func logout(bearer: String) -> HarnessResponse {
        guard tokens[bearer] != nil else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        revoke(bearer)
        return .json(EmptyResponse())
    }

    public func logoutAll(bearer: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        revokeAll(for: record.userId)
        return .json(EmptyResponse())
    }

    public func deactivate(bearer: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        revokeAll(for: record.userId)
        return .json(DeactivateAccountResponse(idServerUnbindResult: "success"))
    }

    public func serverVersions() -> HarnessResponse {
        .json(ServerVersions(
            versions: ["v1.1", "v1.2", "v1.13"],
            unstableFeatures: unstableFeatures))
    }

    private var unstableFeatures: [String: Bool] = [:]

    public func setUnstableFeatures(_ features: [String: Bool]) {
        unstableFeatures = features
    }

    // MARK: - Sync

    private var syncCounter = 0
    private var eventCounter = 0
    private var toDeviceQueue: [BasicEvent] = []
    private var deviceChanged: [UserId] = []
    private var deviceLeft: [UserId] = []
    private var otkCount: Int?

    // MARK: - Rooms

    struct WorldRoom {
        var roomId: RoomId
        var name: String?
        var members: [String: Membership]
        var visibility: RoomVisibility
        var aliases: [String]
        var timeline: [MessageEvent]
    }

    private var worldRooms: [String: WorldRoom] = [:]
    private var directoryAliases: [String: String] = [:]
    private var roomCounter = 0

    private func mintRoomID() -> RoomId {
        roomCounter += 1
        return RoomId(unchecked: "!r\(roomCounter):test")
    }

    /// Resolve a room ID or alias path segment to a known room ID.
    private func roomID(for target: String) -> String? {
        let decoded = target.removingPercentEncoding ?? target
        if decoded.hasPrefix("!") { return worldRooms[decoded] == nil ? nil : decoded }
        if decoded.hasPrefix("#") { return directoryAliases[decoded] }
        return nil
    }

    /// Stage a timeline message served on every subsequent sync.
    /// Returns the staged event for assertions.
    @discardableResult
    public func stageMessage(
        roomId: String = "!room:test",
        sender: String = "@alice:test",
        body: String
    ) -> MessageEvent {
        eventCounter += 1
        let event = MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$e\(eventCounter):test"),
            sender: UserId(unchecked: sender),
            originServerTs: 1_700_000_000_000 + eventCounter,
            content: ["msgtype": .string("m.text"), "body": .string(body)])
        if worldRooms[roomId] == nil {
            worldRooms[roomId] = WorldRoom(
                roomId: RoomId(unchecked: roomId),
                members: [:], visibility: .private, aliases: [], timeline: [])
        }
        worldRooms[roomId]?.timeline.append(event)
        return event
    }

    /// Queue a to-device event, drained (in order) by the next sync.
    public func queueToDevice(_ event: BasicEvent) {
        toDeviceQueue.append(event)
    }

    /// Device-list deltas served once, then cleared.
    public func setDeviceLists(changed: [UserId] = [], left: [UserId] = []) {
        deviceChanged = changed
        deviceLeft = left
    }

    public func setOTKCount(_ count: Int?) {
        otkCount = count
    }

    // MARK: - Rooms

    public func createRoom(bearer: String, request: HarnessRequest) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard let body = try? request.decodeBody(CreateRoomRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed createRoom request", status: 400)
        }
        let roomId = mintRoomID()
        var members = [record.userId.value: Membership.join]
        for invitee in body.invite ?? [] {
            members[invitee.value] = .invite
        }
        var aliases: [String] = []
        if let aliasName = body.roomAliasName, !aliasName.isEmpty {
            let alias = "#\(aliasName):test"
            aliases.append(alias)
            directoryAliases[alias] = roomId.value
        }
        worldRooms[roomId.value] = WorldRoom(
            roomId: roomId, name: body.name, members: members,
            visibility: body.visibility ?? .private, aliases: aliases, timeline: [])
        // Real rooms always carry create + creator-membership state.
        _ = storeState(
            roomId: roomId.value, type: "m.room.create", key: "",
            content: ["creator": .string(record.userId.value)],
            sender: record.userId)
        _ = storeState(
            roomId: roomId.value, type: "m.room.member", key: record.userId.value,
            content: ["membership": .string("join")],
            sender: record.userId)
        return .json(CreateRoomResponse(roomId: roomId))
    }

    public func joinRoom(bearer: String, target: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard let roomId = roomID(for: target) else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        worldRooms[roomId]?.members[record.userId.value] = .join
        return .json(JoinResponse(roomId: RoomId(unchecked: roomId)))
    }

    public func knockRoom(bearer: String, target: String) -> HarnessResponse {
        guard tokens[bearer] != nil else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard let roomId = roomID(for: target) else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        return .json(KnockResponse(roomId: RoomId(unchecked: roomId)))
    }

    public func leaveRoom(bearer: String, roomId: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        worldRooms[roomId]?.members[record.userId.value] = .leave
        return .json(EmptyResponse())
    }

    public func forgetRoom(bearer: String, roomId: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        worldRooms[roomId]?.members.removeValue(forKey: record.userId.value)
        return .json(EmptyResponse())
    }

    public func moderate(bearer: String, roomId: String, request: HarnessRequest, membership: Membership) -> HarnessResponse {
        guard tokens[bearer] != nil else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let action = try? request.decodeBody(MembershipAction.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed membership action", status: 400)
        }
        worldRooms[roomId]?.members[action.userId.value] = membership
        return .json(EmptyResponse())
    }

    public func upgradeRoom(bearer: String, roomId: String) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        let replacement = mintRoomID()
        worldRooms[replacement.value] = WorldRoom(
            roomId: replacement, members: [record.userId.value: .join],
            visibility: .private, aliases: [], timeline: [])
        return .json(UpgradeRoomResponse(replacementRoom: replacement))
    }

    public func reportEvent(roomId: String) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        return .json(EmptyResponse())
    }

    public func roomMembers(roomId: String) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        let chunk = room.members.map { user, membership in
            MemberInfo(
                stateKey: user,
                sender: UserId(unchecked: user),
                content: MemberContent(membership: membership))
        }.sorted { $0.stateKey < $1.stateKey }
        return .json(MembersResponse(chunk: chunk))
    }

    public func roomJoinedMembers(roomId: String) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        var joined: [String: JoinedMember] = [:]
        for (user, membership) in room.members where membership == .join {
            joined[user] = JoinedMember()
        }
        return .json(JoinedMembersResponse(joined: joined))
    }

    public func directoryList(filter: String?) -> HarnessResponse {
        var chunk: [PublicRoomEntry] = []
        for room in worldRooms.values.sorted(by: { $0.roomId.value < $1.roomId.value }) {
            if let term = filter, !term.isEmpty {
                let haystack = ([room.roomId.value] + [room.name ?? ""] + room.aliases).joined(separator: " ")
                guard haystack.localizedStandardContains(term) else { continue }
            }
            chunk.append(PublicRoomEntry(
                roomId: room.roomId,
                name: room.name,
                canonicalAlias: room.aliases.first,
                numJoinedMembers: room.members.values.filter { $0 == .join }.count,
                worldReadable: room.visibility == .public))
        }
        return .json(PublicRoomsResponse(chunk: chunk))
    }

    public func roomAliases(roomId: String) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        return .json(RoomAliasesResponse(aliases: room.aliases))
    }

    public func roomVisibility(roomId: String) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        return .json(RoomVisibilityResponse(visibility: room.visibility))
    }

    public func setRoomVisibility(roomId: String, request: HarnessRequest) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let body = try? request.decodeBody([String: RoomVisibility].self),
            let visibility = body["visibility"]
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed visibility", status: 400)
        }
        worldRooms[roomId]?.visibility = visibility
        return .json(EmptyResponse())
    }

    public func publishAlias(_ alias: String, request: HarnessRequest) -> HarnessResponse {
        let decoded = alias.removingPercentEncoding ?? alias
        guard let body = try? request.decodeBody([String: String].self),
            let roomId = body["room_id"], worldRooms[roomId] != nil
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Unknown room", status: 400)
        }
        directoryAliases[decoded] = roomId
        worldRooms[roomId]?.aliases.append(decoded)
        return .json(EmptyResponse())
    }

    public func removeAlias(_ alias: String) -> HarnessResponse {
        let decoded = alias.removingPercentEncoding ?? alias
        guard let roomId = directoryAliases[decoded] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such alias", status: 404)
        }
        directoryAliases.removeValue(forKey: decoded)
        worldRooms[roomId]?.aliases.removeAll { $0 == decoded }
        return .json(EmptyResponse())
    }

    public func resolveAlias(_ alias: String) -> HarnessResponse {
        let decoded = alias.removingPercentEncoding ?? alias
        guard let roomId = directoryAliases[decoded] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such alias", status: 404)
        }
        return .json(AliasResolution(roomId: RoomId(unchecked: roomId), servers: ["test"]))
    }

    public func acceptRoomState(roomId: String) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        return .json(EmptyResponse())
    }

    // MARK: - Messages

    private var wireCounter = 0
    private var relations: [String: [MessageEvent]] = [:]
    private var receipts: [(room: String, type: String, event: String, user: String)] = []
    private var typingState: [String: [String: Bool]] = [:]

    private func mintWireID() -> EventId {
        wireCounter += 1
        return EventId(unchecked: "$w\(wireCounter):test")
    }

    private func senderOf(bearer: String) -> UserId {
        tokens[bearer].map(\.userId) ?? UserId(unchecked: "@alice:test")
    }

    public func sendRoomEvent(
        bearer: String, roomId: String, eventType: String, txnId: String, request: HarnessRequest
    ) -> HarnessResponse {
        if worldRooms[roomId] == nil {
            // Sending vivifies the shell (membership is tracked by the
            // rooms routes); reads still 404 on unknown rooms.
            worldRooms[roomId] = WorldRoom(
                roomId: RoomId(unchecked: roomId),
                members: [:], visibility: .private, aliases: [], timeline: [])
        }
        guard let content = try? request.decodeBody([String: AnyCodable].self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed event", status: 400)
        }
        eventCounter += 1
        let event = MessageEvent(
            type: eventType,
            eventId: mintWireID(),
            sender: senderOf(bearer: bearer),
            originServerTs: 1_700_000_000_000 + eventCounter,
            content: content,
            unsigned: ["transaction_id": .string(txnId)])
        worldRooms[roomId]?.timeline.append(event)
        if let relates = content["m.relates_to"]?.objectValue,
            let relType = relates["rel_type"]?.stringValue,
            let target = relates["event_id"]?.stringValue
                ?? relates["m.in_reply_to"]?.objectValue?["event_id"]?.stringValue
        {
            relations["\(roomId)\n\(target)\n\(relType)", default: []].append(event)
        }
        return .json(SendEventResponse(eventId: event.eventId))
    }

    public func redactEvent(roomId: String, eventId: String) -> HarnessResponse {
        guard var room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let index = room.timeline.firstIndex(where: { $0.eventId.value == eventId }) else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such event", status: 404)
        }
        let redactionId = mintWireID()
        var pruned = room.timeline[index]
        pruned.content = [:]
        pruned.unsigned = ["redacted_because": .object(["event_id": .string(redactionId.value)])]
        room.timeline[index] = pruned
        worldRooms[roomId] = room
        return .json(SendEventResponse(eventId: redactionId))
    }

    public func paginateMessages(roomId: String, query: [String: String]) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        let limit = query["limit"].flatMap(Int.init) ?? 50
        let dir = query["dir"] ?? "b"
        let timeline = room.timeline
        if dir == "f" {
            let start = query["from"].flatMap { $0.hasPrefix("p") ? Int($0.dropFirst()) : nil } ?? 0
            let slice = Array(timeline.dropFirst(start).prefix(limit))
            let end = start + slice.count < timeline.count ? "p\(start + slice.count)" : nil
            return .json(MessagesResponse(start: "p\(start)", end: end, chunk: slice))
        }
        let end = query["from"].flatMap { $0.hasPrefix("p") ? Int($0.dropFirst()) : nil } ?? timeline.count
        let start = max(0, end - limit)
        let slice = Array(timeline[start..<min(end, timeline.count)].reversed())
        return .json(MessagesResponse(
            start: "p\(end)", end: start > 0 ? "p\(start)" : nil, chunk: slice))
    }

    public func fetchEvent(roomId: String, eventId: String) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let event = room.timeline.first(where: { $0.eventId.value == eventId }) else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such event", status: 404)
        }
        return .json(event)
    }

    public func eventContext(roomId: String, eventId: String) -> HarnessResponse {
        guard let room = worldRooms[roomId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let index = room.timeline.firstIndex(where: { $0.eventId.value == eventId }) else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such event", status: 404)
        }
        let timeline = room.timeline
        return .json(ContextResponse(
            eventsBefore: Array(timeline[..<index].reversed()),
            event: timeline[index],
            eventsAfter: Array(timeline[timeline.index(after: index)...]),
            start: index > 0 ? "p0" : nil,
            end: index + 1 < timeline.count ? "p\(timeline.count)" : nil))
    }

    public func eventRelations(roomId: String, target: String, relType: String, eventType: String?) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        let decoded = target.removingPercentEncoding ?? target
        var chunk = relations["\(roomId)\n\(decoded)\n\(relType)"] ?? []
        if let eventType {
            chunk = chunk.filter { $0.type == eventType }
        }
        return .json(RelationsResponse(chunk: Array(chunk.reversed())))
    }

    public func sendTyping(roomId: String, userId: String, request: HarnessRequest) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let body = try? request.decodeBody(TypingRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed typing", status: 400)
        }
        typingState[roomId, default: [:]][userId] = body.typing
        return .json(EmptyResponse())
    }

    public func typingUsers(roomId: String) -> [String] {
        typingState[roomId]?.filter(\.value).map(\.key).sorted() ?? []
    }

    public func sendReceipt(bearer: String, roomId: String, receiptType: String, eventId: String) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        receipts.append((roomId, receiptType, eventId, senderOf(bearer: bearer).value))
        return .json(EmptyResponse())
    }

    public func recordedReceipts() -> [(room: String, type: String, event: String, user: String)] {
        receipts
    }

    // MARK: - Room state

    private var roomState: [String: [String: MessageEvent]] = [:]

    private func storeState(roomId: String, type: String, key: String, content: [String: AnyCodable], sender: UserId) -> MessageEvent {
        eventCounter += 1
        let event = MessageEvent(
            type: type,
            eventId: EventId(unchecked: "$s\(eventCounter):test"),
            sender: sender,
            stateKey: key,
            originServerTs: 1_700_000_000_000 + eventCounter,
            content: content)
        roomState[roomId, default: [:]]["\(type)\n\(key)"] = event
        return event
    }

    public func getRoomState(roomId: String) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        return .json(StateResponse(events: Array(roomState[roomId]?.values ?? [:].values)))
    }

    public func getStateEvent(roomId: String, type: String, key: String) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let event = roomState[roomId]?["\(type)\n\(key)"] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such state", status: 404)
        }
        return .json(AnyCodableDictionary(event.content))
    }

    public func sendStateEvent(
        bearer: String, roomId: String, type: String, key: String, request: HarnessRequest
    ) -> HarnessResponse {
        if worldRooms[roomId] == nil {
            worldRooms[roomId] = WorldRoom(
                roomId: RoomId(unchecked: roomId),
                members: [:], visibility: .private, aliases: [], timeline: [])
        }
        guard let content = try? request.decodeBody([String: AnyCodable].self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed state", status: 400)
        }
        let event = storeState(
            roomId: roomId, type: type, key: key, content: content,
            sender: senderOf(bearer: bearer))
        return .json(SendEventResponse(eventId: event.eventId))
    }

    public func seedRoomState(roomId: String, type: String, key: String, content: [String: AnyCodable]) {
        _ = storeState(
            roomId: roomId, type: type, key: key, content: content,
            sender: UserId(unchecked: "@alice:test"))
    }

    public func spaceHierarchy(spaceId: String) -> HarnessResponse {
        guard let space = worldRooms[spaceId] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        var edges: [SpaceChildState] = []
        for event in (roomState[spaceId] ?? [:]).values where event.type == "m.space.child" {
            guard let child = event.stateKey,
                let via = event.content["via"]?.arrayValue?.compactMap(\.stringValue),
                !via.isEmpty
            else { continue }
            edges.append(SpaceChildState(
                stateKey: child,
                content: SpaceChildContent(
                    via: via,
                    order: event.content["order"]?.stringValue,
                    suggested: event.content["suggested"]?.boolValue),
                originServerTs: event.originServerTs,
                sender: event.sender))
        }
        edges.sort { $0.stateKey < $1.stateKey }
        var rooms = [HierarchyRoom(
            roomId: space.roomId, roomType: "m.space", name: space.name,
            memberCount: space.members.count,
            childrenState: edges.isEmpty ? nil : edges)]
        for edge in edges {
            let child = worldRooms[edge.stateKey]
            rooms.append(HierarchyRoom(
                roomId: RoomId(unchecked: edge.stateKey),
                name: child?.name,
                memberCount: child?.members.count))
        }
        return .json(HierarchyResponse(rooms: rooms))
    }

    // MARK: - Account data

    private var accountData: [String: [String: [String: AnyCodable]]] = [:]
    private var roomAccountData: [String: [String: [String: [String: AnyCodable]]]] = [:]
    private var roomTags: [String: [String: [String: RoomTag]]] = [:]

    public func accountDataGet(user: String, type: String) -> HarnessResponse {
        guard let content = accountData[user]?[type] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such data", status: 404)
        }
        return .json(AnyCodableDictionary(content))
    }

    public func accountDataPut(user: String, type: String, request: HarnessRequest) -> HarnessResponse {
        guard let content = try? request.decodeBody([String: AnyCodable].self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed data", status: 400)
        }
        accountData[user, default: [:]][type] = content
        return .json(EmptyResponse())
    }

    public func roomAccountDataGet(user: String, room: String, type: String) -> HarnessResponse {
        guard let content = roomAccountData[user]?[room]?[type] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such data", status: 404)
        }
        return .json(AnyCodableDictionary(content))
    }

    public func roomAccountDataPut(user: String, room: String, type: String, request: HarnessRequest) -> HarnessResponse {
        guard let content = try? request.decodeBody([String: AnyCodable].self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed data", status: 400)
        }
        roomAccountData[user, default: [:]][room, default: [:]][type] = content
        return .json(EmptyResponse())
    }

    public func setReadMarkers(bearer: String, roomId: String, request: HarnessRequest) -> HarnessResponse {
        guard worldRooms[roomId] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such room", status: 404)
        }
        guard let body = try? request.decodeBody([String: String].self),
            let eventId = body["m.fully_read"]
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed markers", status: 400)
        }
        let user = senderOf(bearer: bearer).value
        roomAccountData[user, default: [:]][roomId, default: [:]][AccountDataClient.fullyReadType] =
            ["event_id": .string(eventId)]
        return .json(EmptyResponse())
    }

    public func tagsGet(user: String, room: String) -> HarnessResponse {
        .json(TagsResponse(tags: roomTags[user]?[room] ?? [:]))
    }

    public func tagPut(user: String, room: String, tag: String, request: HarnessRequest) -> HarnessResponse {
        let order = (try? request.decodeBody(RoomTag.self))?.order
        roomTags[user, default: [:]][room, default: [:]][tag] = RoomTag(order: order)
        return .json(EmptyResponse())
    }

    public func tagDelete(user: String, room: String, tag: String) -> HarnessResponse {
        roomTags[user]?[room]?.removeValue(forKey: tag)
        return .json(EmptyResponse())
    }

    // MARK: - Search

    public func searchMessages(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody([String: AnyCodable].self),
            let categories = body["search_categories"]?.objectValue,
            let roomEvents = categories["room_events"]?.objectValue,
            let term = roomEvents["search_term"]?.stringValue
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed search", status: 400)
        }
        let facet = roomEvents["filter"]?.objectValue
        let roomFilter = facet?["rooms"]?.arrayValue?.compactMap(\.stringValue)
        let senderFilter = facet?["senders"]?.arrayValue?.compactMap(\.stringValue)
        var hits: [SearchResultEntry] = []
        for (roomId, room) in worldRooms {
            if let rooms = roomFilter, !rooms.contains(roomId) { continue }
            for event in room.timeline {
                guard event.type == "m.room.message" else { continue }
                guard let sender = Optional(event.sender.value),
                    senderFilter?.contains(sender) ?? true
                else { continue }
                guard let contentBody = event.content["body"]?.stringValue,
                    contentBody.localizedStandardContains(term)
                else { continue }
                var hit = event
                hit.roomId = RoomId(unchecked: roomId)
                let profile = profiles[sender]
                hits.append(SearchResultEntry(
                    rank: 1.0,
                    result: hit,
                    context: SearchResultContext(profileInfo: [sender: ProfileInfo(
                        displayname: profile?.displayname, avatarUrl: profile?.avatarUrl)])))
            }
        }
        return .json(SearchResponse(searchCategories: SearchCategories(roomEvents:
            RoomEventSearchResult(
                count: hits.count, highlights: [term],
                results: hits, nextBatch: nil))))
    }

    // MARK: - Media

    private var mediaBlobs: [String: Data] = [:]
    private var mediaCounter = 0

    public func mediaUpload(request: HarnessRequest) -> HarnessResponse {
        mediaCounter += 1
        let id = "m\(mediaCounter)"
        mediaBlobs["test/\(id)"] = request.body
        return .json(UploadResponse(contentUri: "mxc://test/\(id)"))
    }

    public func mediaDownload(server: String, media: String) -> HarnessResponse {
        let key = "\(server)/\(media)"
        guard let blob = mediaBlobs[key] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such media", status: 404)
        }
        return .bytes(blob)
    }

    public func seedMedia(server: String = "test", id: String, bytes: Data) {
        mediaBlobs["\(server)/\(id)"] = bytes
    }

    // MARK: - RTC

    public func rtcTransports(baseURL: String) -> HarnessResponse {
        .raw("""
            {"rtc_transports": [
              {"type": "livekit", "livekit_service_url": "\(baseURL)"}
            ]}
            """)
    }

    public func openIDToken() -> HarnessResponse {
        .json(OpenIDToken(
            accessToken: "openid-tok", tokenType: "Bearer",
            matrixServerName: "test", expiresIn: 3600))
    }

    private var delayCounter = 0
    private var delayedSchedules: [(room: String, type: String, delayMs: Int)] = []
    private var delayedCancels: [String] = []

    public func scheduleDelayed(roomId: String, type: String, delayMs: Int) -> HarnessResponse {
        delayCounter += 1
        delayedSchedules.append((roomId, type, delayMs))
        return .raw(#"{"delay_id":"d\#(delayCounter)"}"#)
    }

    public func cancelDelayed(id: String) -> HarnessResponse {
        delayedCancels.append(id)
        return .json(EmptyResponse())
    }

    public func recordedDelayedSchedules() -> [(room: String, type: String, delayMs: Int)] {
        delayedSchedules
    }

    public func recordedDelayedCancels() -> [String] {
        delayedCancels
    }

    public func sfuToken() -> HarnessResponse {
        .raw(#"{"url": "wss://livekit.test", "jwt": "livekit-jwt"}"#)
    }

    // MARK: - OIDC issuer (loopback)

    private var issuerBase = "http://127.0.0.1"
    private var devicePollsLeft: [String: Int] = [:]
    private var deviceDenyNext = false
    private var revokedTokens: [String] = []

    public func setIssuerBase(_ url: String) {
        issuerBase = url
    }

    public func authMetadata() -> HarnessResponse {
        .json(AuthMetadata(
            issuer: "\(issuerBase)/issuer",
            authorizationEndpoint: "\(issuerBase)/issuer/auth",
            tokenEndpoint: "\(issuerBase)/issuer/token",
            registrationEndpoint: "\(issuerBase)/issuer/register",
            revocationEndpoint: "\(issuerBase)/issuer/revoke",
            deviceAuthorizationEndpoint: "\(issuerBase)/issuer/device",
            codeChallengeMethodsSupported: ["S256"],
            grantTypesSupported: [
                "authorization_code", "refresh_token",
                "urn:ietf:params:oauth:grant-type:device_code",
            ]))
    }

    public func issuerRegister() -> HarnessResponse {
        .json(OIDCRegistrationResponse(clientId: "harness-client"))
    }

    public func issuerDevice() -> HarnessResponse {
        let code = "dev-\(devicePollsLeft.count + 1)"
        devicePollsLeft[code] = 1
        return .json(DeviceAuthorizationResponse(
            deviceCode: code,
            userCode: "WDJB-MJHT",
            verificationURI: "\(issuerBase)/link",
            verificationURIComplete: "\(issuerBase)/link?user_code=WDJB-MJHT",
            expiresIn: 300,
            interval: 1))
    }

    /// The next device flow denies authorization instead of approving.
    public func denyNextDeviceFlow() {
        deviceDenyNext = true
    }

    private func oidcTokens(deviceId: String = "OIDCDEV") -> OIDCTokenResponse {
        OIDCTokenResponse(
            accessToken: "oidc-access-\(deviceId)",
            tokenType: "Bearer",
            expiresIn: 299,
            refreshToken: "oidc-refresh",
            scope: "urn:matrix:client:api:* urn:matrix:client:device:\(deviceId)",
            deviceId: deviceId)
    }

    /// Issued OIDC access tokens act as sessions (whoami + bearer auth),
    /// like a real issuer-backed homeserver.
    private func adoptOIDCTokens(_ response: OIDCTokenResponse) {
        if let refresh = response.refreshToken {
            refreshTokens[refresh] = response.accessToken
        }
        if let device = response.deviceId {
            tokens[response.accessToken] = TokenRecord(
                userId: UserId(unchecked: "@alice:test"), deviceId: DeviceId(device))
        }
    }

    public func issuerToken(request: HarnessRequest) -> HarnessResponse {
        let form = request.formBody
        switch form["grant_type"] {
        case "urn:ietf:params:oauth:grant-type:device_code":
            guard let code = form["device_code"], devicePollsLeft[code] != nil else {
                return .raw(#"{"error":"expired_token"}"#, status: 400)
            }
            if deviceDenyNext {
                deviceDenyNext = false
                devicePollsLeft.removeValue(forKey: code)
                return .raw(#"{"error":"access_denied"}"#, status: 400)
            }
            if devicePollsLeft[code, default: 0] > 0 {
                devicePollsLeft[code, default: 0] -= 1
                return .raw(#"{"error":"authorization_pending"}"#, status: 400)
            }
            devicePollsLeft.removeValue(forKey: code)
            let tokens = oidcTokens()
            adoptOIDCTokens(tokens)
            return .json(tokens)
        case "refresh_token":
            guard form["refresh_token"] == "oidc-refresh" else {
                return .raw(#"{"error":"invalid_grant"}"#, status: 400)
            }
            let tokens = oidcTokens()
            adoptOIDCTokens(tokens)
            return .json(tokens)
        case "authorization_code":
            guard form["code"] != nil else {
                return .raw(#"{"error":"invalid_grant"}"#, status: 400)
            }
            let tokens = oidcTokens()
            adoptOIDCTokens(tokens)
            return .json(tokens)
        default:
            return .raw(#"{"error":"unsupported_grant_type"}"#, status: 400)
        }
    }

    public func issuerRevoke(request: HarnessRequest) -> HarnessResponse {
        if let token = request.formBody["token"] {
            revokedTokens.append(token)
        }
        return .raw("{}", status: 200)
    }

    public func recordedRevocations() -> [String] {
        revokedTokens
    }

    // MARK: - Sliding sync

    private var slidingCounter = 0
    private var slidingToDeviceBatch = 0

    public func handleSlidingSync() -> HarnessResponse {
        slidingCounter += 1
        var rooms: [String: SlidingSyncRoom] = [:]
        for (roomId, room) in worldRooms {
            rooms[roomId] = SlidingSyncRoom(
                name: room.name, timeline: room.timeline, limited: false)
        }
        var extensions: [String: AnyCodable] = [:]
        var typingRooms: [String: AnyCodable] = [:]
        for (room, users) in typingState {
            let typing = users.filter(\.value).map(\.key).sorted()
            guard !typing.isEmpty else { continue }
            typingRooms[room] = .object([
                "user_ids": .array(typing.map(AnyCodable.string))
            ])
        }
        if !typingRooms.isEmpty {
            extensions["typing"] = .object(["rooms": .object(typingRooms)])
        }
        if !toDeviceQueue.isEmpty {
            slidingToDeviceBatch += 1
            var events: [AnyCodable] = []
            for event in toDeviceQueue {
                if let data = try? JSONEncoder().encode(event),
                    let value = try? JSONDecoder().decode(AnyCodable.self, from: data)
                {
                    events.append(value)
                }
            }
            extensions["to_device"] = .object([
                "events": .array(events),
                "next_batch": .string("td\(slidingToDeviceBatch)"),
            ])
            toDeviceQueue = []
        }
        if !deviceChanged.isEmpty || !deviceLeft.isEmpty {
            extensions["e2ee"] = .object(["device_lists": .object([
                "changed": .array(deviceChanged.map { .string($0.value) }),
                "left": .array(deviceLeft.map { .string($0.value) }),
            ])])
            deviceChanged = []
            deviceLeft = []
        }
        return .json(SlidingSyncResponse(
            pos: "p\(slidingCounter)", rooms: rooms,
            extensions: extensions.isEmpty ? nil : extensions))
    }

    // MARK: - Devices & capabilities

    private var devices: [String: DeviceEntry] = [
        "ALICEDEVICE": DeviceEntry(deviceId: DeviceId("ALICEDEVICE"), displayName: "Test Device")
    ]

    public func seedDevice(_ entry: DeviceEntry) {
        devices[entry.deviceId.value] = entry
    }

    public func devicesList() -> HarnessResponse {
        .json(DevicesResponse(devices: devices.values.sorted { $0.deviceId.value < $1.deviceId.value }))
    }

    public func deviceGet(_ device: String) -> HarnessResponse {
        guard let entry = devices[device] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such device", status: 404)
        }
        return .json(entry)
    }

    public func deviceRename(_ device: String, request: HarnessRequest) -> HarnessResponse {
        guard devices[device] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such device", status: 404)
        }
        guard let body = try? request.decodeBody(RenameDeviceRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed rename", status: 400)
        }
        devices[device]?.displayName = body.displayName
        return .json(EmptyResponse())
    }

    public func deviceDelete(_ device: String) -> HarnessResponse {
        guard devices.removeValue(forKey: device) != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such device", status: 404)
        }
        return .json(EmptyResponse())
    }

    public func capabilitiesGet() -> HarnessResponse {
        .json(ServerCapabilities(roomVersions: RoomVersionsCapability(
            default: "11", available: ["11": "Stable"])))
    }

    // MARK: - To-device

    private var toDeviceSends: [(type: String, txn: String, body: Data)] = []

    public func toDeviceSend(type: String, txn: String, request: HarnessRequest) -> HarnessResponse {
        toDeviceSends.append((type, txn, request.body))
        return .json(EmptyResponse())
    }

    public func recordedToDeviceSends() -> [(type: String, txn: String, body: Data)] {
        toDeviceSends
    }

    // MARK: - Key backup

    private var backupVersions: [String: BackupVersionInfo] = [:]
    private var backupKeys: [String: [String: [String: BackupSessionData]]] = [:]
    private var backupCounter = 0

    public func backupVersionGet() -> HarnessResponse {
        guard let current = backupVersions.values.sorted(by: { $0.version ?? "" < $1.version ?? "" }).last else {
            return .matrixError(code: "M_NOT_FOUND", message: "No backup", status: 404)
        }
        return .json(current)
    }

    public func backupVersionCreate(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody([String: AnyCodable].self),
            body["algorithm"]?.stringValue == KeyBackup.algorithm
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed backup", status: 400)
        }
        backupCounter += 1
        let version = "\(backupCounter)"
        backupVersions[version] = BackupVersionInfo(
            version: version, algorithm: KeyBackup.algorithm,
            authData: body["auth_data"]?.objectValue, count: 0, etag: "e0")
        return .raw(#"{"version":"\#(version)"}"#)
    }

    public func backupVersionDelete(_ version: String) -> HarnessResponse {
        guard backupVersions.removeValue(forKey: version) != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such backup", status: 404)
        }
        backupKeys.removeValue(forKey: version)
        return .json(EmptyResponse())
    }

    public func backupKeysPut(version: String, request: HarnessRequest) -> HarnessResponse {
        guard backupVersions[version] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such backup", status: 404)
        }
        struct Upload: Decodable {
            var rooms: [String: BackupRoomSessions]
        }
        guard let upload = try? request.decodeBody(Upload.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed keys", status: 400)
        }
        for (room, sessions) in upload.rooms {
            for (session, entry) in sessions.sessions {
                backupKeys[version, default: [:]][room, default: [:]][session] = entry
            }
        }
        let count = backupKeys[version]?.values.flatMap(\.values).count ?? 0
        backupVersions[version]?.count = count
        return .json(EmptyResponse())
    }

    public func backupKeysGet(version: String) -> HarnessResponse {
        guard backupVersions[version] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such backup", status: 404)
        }
        struct Download: Encodable {
            var rooms: [String: BackupRoomSessions]
        }
        var rooms: [String: BackupRoomSessions] = [:]
        for (room, sessions) in backupKeys[version] ?? [:] {
            rooms[room] = BackupRoomSessions(sessions: sessions)
        }
        return .json(Download(rooms: rooms))
    }

    public func backupSessionGet(version: String, room: String, session: String) -> HarnessResponse {
        guard backupVersions[version] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such backup", status: 404)
        }
        guard let entry = backupKeys[version]?[room]?[session] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such session", status: 404)
        }
        return .json(entry)
    }

    // MARK: - Profiles

    private var profiles: [String: UserProfile] = [
        "@alice:test": UserProfile(displayname: "Alice")
    ]
    private var presenceMap: [String: UserPresence] = [:]

    public func profileGet(user: String) -> HarnessResponse {
        .json(profiles[user] ?? UserProfile())
    }

    public func profileDisplayNameGet(user: String) -> HarnessResponse {
        .json(DisplayNameResponse(displayname: profiles[user]?.displayname))
    }

    public func profileAvatarGet(user: String) -> HarnessResponse {
        .json(AvatarURLResponse(avatarUrl: profiles[user]?.avatarUrl))
    }

    public func profilePutDisplayName(user: String, request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(DisplayNameResponse.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed name", status: 400)
        }
        var profile = profiles[user] ?? UserProfile()
        profile.displayname = body.displayname
        profiles[user] = profile
        return .json(EmptyResponse())
    }

    public func profilePutAvatar(user: String, request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(AvatarURLResponse.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed avatar", status: 400)
        }
        var profile = profiles[user] ?? UserProfile()
        profile.avatarUrl = body.avatarUrl
        profiles[user] = profile
        return .json(EmptyResponse())
    }

    public func presenceGet(user: String) -> HarnessResponse {
        .json(presenceMap[user] ?? UserPresence(presence: .offline))
    }

    public func presencePut(user: String, request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(SetPresenceRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed presence", status: 400)
        }
        presenceMap[user] = UserPresence(presence: body.presence, statusMessage: body.statusMessage)
        return .json(EmptyResponse())
    }

    public func directorySearch(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(UserDirectoryRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed search", status: 400)
        }
        var results: [UserDirectoryEntry] = []
        for user in profiles.keys.sorted() {
            let profile = profiles[user]
            let haystack = user + " " + (profile?.displayname ?? "")
            guard haystack.localizedStandardContains(body.searchTerm) else { continue }
            results.append(UserDirectoryEntry(
                userId: UserId(unchecked: user),
                displayName: profile?.displayname,
                avatarUrl: profile?.avatarUrl))
        }
        if let limit = body.limit, results.count > limit {
            return .json(UserDirectoryResponse(results: Array(results.prefix(limit)), limited: true))
        }
        return .json(UserDirectoryResponse(results: results, limited: false))
    }

    // MARK: - Push

    private var pushers: [Pusher] = []

    private static func defaultRule(
        _ id: String, enabled: Bool = true,
        actions: [AnyCodable] = [.string("notify")],
        pattern: String? = nil
    ) -> PushRule {
        PushRule(ruleId: id, isDefault: true, enabled: enabled, actions: actions, pattern: pattern)
    }

    /// Synapse-shaped default ruleset: the IDs `NotificationSettings`
    /// toggles expect, so actor tests exercise real read-modify-write.
    private var pushRules: [String: [String: PushRule]] = [
        "override": [
            ".m.rule.master": PushRule(ruleId: ".m.rule.master", isDefault: true, enabled: false),
            ".m.rule.roomnotif": defaultRule(".m.rule.roomnotif"),
            ".m.rule.call": defaultRule(".m.rule.call"),
            ".m.rule.invite_for_me": defaultRule(".m.rule.invite_for_me"),
            ".m.rule.is_room_mention": defaultRule(".m.rule.is_room_mention"),
            ".m.rule.is_user_mention": defaultRule(".m.rule.is_user_mention"),
            ".m.rule.contains_display_name": defaultRule(".m.rule.contains_display_name"),
        ],
        "content": [
            ".m.rule.contains_user_name": defaultRule(
                ".m.rule.contains_user_name", pattern: "alice"),
        ],
        "underride": [
            ".m.rule.message": defaultRule(".m.rule.message"),
            ".m.rule.encrypted": defaultRule(".m.rule.encrypted"),
            ".m.rule.room_one_to_one": defaultRule(".m.rule.room_one_to_one"),
            ".m.rule.encrypted_room_one_to_one": defaultRule(".m.rule.encrypted_room_one_to_one"),
            ".m.rule.poll_start": defaultRule(".m.rule.poll_start"),
            ".m.rule.poll_start_one_to_one": defaultRule(".m.rule.poll_start_one_to_one"),
            ".org.matrix.msc3381.poll_start": defaultRule(".org.matrix.msc3381.poll_start"),
            ".org.matrix.msc3381.poll_start_one_to_one": defaultRule(
                ".org.matrix.msc3381.poll_start_one_to_one"),
        ],
    ]

    public func pushersGet() -> HarnessResponse {
        .json(PushersResponse(pushers: pushers))
    }

    public func pusherSet(request: HarnessRequest) -> HarnessResponse {
        guard let pusher = try? request.decodeBody(Pusher.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed pusher", status: 400)
        }
        pushers.removeAll { $0.pushkey == pusher.pushkey }
        pushers.append(pusher)
        return .json(EmptyResponse())
    }

    public func pushRulesetGet() -> HarnessResponse {
        .json(PushRuleset(global: Dictionary(
            uniqueKeysWithValues: pushRules.map { ($0.key, Array($0.value.values)) })))
    }

    public func pushRuleGet(kind: String, id: String) -> HarnessResponse {
        guard let rule = pushRules[kind]?[id] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such rule", status: 404)
        }
        return .json(rule)
    }

    public func pushRuleEnabled(kind: String, id: String, request: HarnessRequest) -> HarnessResponse {
        guard pushRules[kind]?[id] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such rule", status: 404)
        }
        guard let body = try? request.decodeBody(EnabledState.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed flag", status: 400)
        }
        pushRules[kind]?[id]?.enabled = body.enabled
        return .json(EmptyResponse())
    }

    public func pushRuleDelete(kind: String, id: String) -> HarnessResponse {
        guard pushRules[kind]?.removeValue(forKey: id) != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such rule", status: 404)
        }
        return .json(EmptyResponse())
    }

    private func decodeActions(_ body: [String: AnyCodable]) -> [PushAction]? {
        guard let value = body["actions"],
            let data = try? JSONEncoder().encode(value),
            let actions = try? JSONDecoder().decode([PushAction].self, from: data)
        else { return nil }
        return actions
    }

    public func pushRulePut(kind: String, id: String, request: HarnessRequest, pattern: String? = nil) -> HarnessResponse {
        guard let body = try? request.decodeBody([String: AnyCodable].self),
            let actions = decodeActions(body)
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed rule", status: 400)
        }
        var conditions: [AnyCodable]?
        if let raw = body["conditions"]?.arrayValue {
            conditions = raw
        }
        pushRules[kind, default: [:]][id] = PushRule(
            ruleId: id, enabled: true, conditions: conditions,
            actions: encodeActions(actions), pattern: pattern ?? id)
        return .json(EmptyResponse())
    }

    private func encodeActions(_ actions: [PushAction]) -> [AnyCodable] {
        actions.map { action in
            guard let data = try? JSONEncoder().encode(action),
                let raw = try? JSONDecoder().decode(AnyCodable.self, from: data)
            else { return .string("notify") }
            return raw
        }
    }

    public func pushRuleActionsGet(kind: String, id: String) -> HarnessResponse {
        guard let rule = pushRules[kind]?[id] else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such rule", status: 404)
        }
        return .json(RuleActionsResponse(actions: rule.actions.compactMap { action in
            guard let data = try? JSONEncoder().encode(action),
                let parsed = try? JSONDecoder().decode(PushAction.self, from: data)
            else { return nil }
            return parsed
        }))
    }

    public func pushRuleActionsPut(kind: String, id: String, request: HarnessRequest) -> HarnessResponse {
        guard pushRules[kind]?[id] != nil else {
            return .matrixError(code: "M_NOT_FOUND", message: "No such rule", status: 404)
        }
        guard let body = try? request.decodeBody([String: AnyCodable].self),
            let actions = decodeActions(body)
        else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed actions", status: 400)
        }
        pushRules[kind]?[id]?.actions = encodeActions(actions)
        return .json(EmptyResponse())
    }

    // MARK: - Keys

    private var keyDevices: [String: [String: DeviceKeys]] = [:]
    private var keyOTKs: [String: [String: [String: ClaimedOneTimeKey]]] = [:]
    private var signingKeys: [String: UploadSigningKeysRequest] = [:]

    public func uploadKeys(bearer: String, request: HarnessRequest) -> HarnessResponse {
        guard let record = tokens[bearer] else {
            return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
        }
        guard let body = try? request.decodeBody(UploadDeviceKeysRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed upload", status: 400)
        }
        let user = body.deviceKeys?.userId ?? record.userId.value
        var total = 0
        if let deviceKeys = body.deviceKeys {
            keyDevices[user, default: [:]][deviceKeys.deviceId] = deviceKeys
            if let oneTime = body.oneTimeKeys {
                for (keyId, value) in oneTime {
                    guard
                        let obj = value.objectValue,
                        let key = obj["key"]?.stringValue,
                        let sigs = obj["signatures"]?.objectValue
                    else { continue }
                    var sigMap: [String: [String: String]] = [:]
                    for (u, inner) in sigs {
                        var m: [String: String] = [:]
                        for (k, v) in inner.objectValue ?? [:] {
                            if let s = v.stringValue { m[k] = s }
                        }
                        sigMap[u] = m
                    }
                    keyOTKs[user, default: [:]][deviceKeys.deviceId, default: [:]][keyId] =
                        ClaimedOneTimeKey(key: key, signatures: sigMap)
                    total += 1
                }
            }
        }
        return .json(UploadDeviceKeysResponse(oneTimeKeyCounts: ["signed_curve25519": total]))
    }

    public func uploadSigningKeys(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(UploadSigningKeysRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed signing keys", status: 400)
        }
        if let master = body.masterKey {
            signingKeys[master.userId] = body
        }
        return .json(EmptyResponse())
    }

    public func uploadSignatures(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(UploadSignaturesRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed signatures", status: 400)
        }
        for (user, devices) in body.signed {
            for (device, signed) in devices {
                guard var stored = keyDevices[user]?[device] else { continue }
                for (signer, sigs) in signed.signatures {
                    for (keyId, sig) in sigs {
                        stored.signatures[signer, default: [:]][keyId] = sig
                    }
                }
                keyDevices[user]?[device] = stored
            }
        }
        return .json(UploadSignaturesResponse())
    }

    public func queryKeys(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(KeyQueryRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed query", status: 400)
        }
        var out: [String: [String: DeviceKeys]] = [:]
        for (user, devices) in body.deviceKeys {
            let known = keyDevices[user] ?? [:]
            if devices.isEmpty {
                out[user] = known
            } else {
                out[user] = known.filter { devices.contains($0.key) }
            }
        }
        var master: [String: CrossSigningKey] = [:]
        var selfSigning: [String: CrossSigningKey] = [:]
        var userSigning: [String: CrossSigningKey] = [:]
        for user in body.deviceKeys.keys {
            if let keys = signingKeys[user] {
                if let k = keys.masterKey { master[user] = k }
                if let k = keys.selfSigningKey { selfSigning[user] = k }
                if let k = keys.userSigningKey { userSigning[user] = k }
            }
        }
        return .json(KeyQueryResponse(
            deviceKeys: out,
            masterKeys: master.isEmpty ? nil : master,
            selfSigningKeys: selfSigning.isEmpty ? nil : selfSigning,
            userSigningKeys: userSigning.isEmpty ? nil : userSigning))
    }

    public func claimKeys(request: HarnessRequest) -> HarnessResponse {
        guard let body = try? request.decodeBody(ClaimKeysRequest.self) else {
            return .matrixError(code: "M_BAD_JSON", message: "Malformed claim", status: 400)
        }
        var out: [String: [String: [String: ClaimedOneTimeKey]]] = [:]
        for (user, devices) in body.oneTimeKeys {
            for (device, _) in devices {
                let deviceId: String
                if device == "*" {
                    guard let first = keyOTKs[user]?.first(where: { !$0.value.isEmpty }) else { continue }
                    deviceId = first.key
                } else {
                    deviceId = device
                }
                guard var pool = keyOTKs[user]?[deviceId], !pool.isEmpty else { continue }
                let keyId = pool.keys.sorted().first!
                let claimed = pool.removeValue(forKey: keyId)!
                keyOTKs[user]?[deviceId] = pool
                out[user, default: [:]][deviceId, default: [:]][keyId] = claimed
            }
        }
        return .json(ClaimKeysResponse(oneTimeKeys: out))
    }

    public func handleSync(bearer: String, since: String?) -> HarnessResponse {
        syncCounter += 1
        let batch = "s\(syncCounter)"
        let user = tokens[bearer]?.userId.value
        var join: [String: JoinedRoomSync] = [:]
        var invite: [String: InvitedRoomSync] = [:]
        var leave: [String: LeftRoomSync] = [:]
        for (roomId, room) in worldRooms {
            guard !room.timeline.isEmpty || !room.members.isEmpty else { continue }
            switch user.map({ room.members[$0] }) {
            case .invite:
                invite[roomId] = InvitedRoomSync(inviteState: InviteState(events: [
                    StrippedStateEvent(
                        type: "m.room.member", stateKey: user ?? "",
                        sender: UserId(unchecked: user ?? "@alice:test"),
                        content: ["membership": .string("invite")]),
                ]))
                continue
            case .leave, .ban:
                leave[roomId] = LeftRoomSync(timeline: TimelineChunk(events: room.timeline))
                continue
            default:
                break
            }
            var state: [MessageEvent] = []
            for (member, membership) in room.members.sorted(by: { $0.key < $1.key }) {
                eventCounter += 1
                state.append(MessageEvent(
                    type: "m.room.member",
                    eventId: EventId(unchecked: "$s\(eventCounter):test"),
                    sender: UserId(unchecked: member),
                    stateKey: member,
                    originServerTs: 1_700_000_000_000,
                    content: [
                        "membership": .string(membership.rawValue),
                        "displayname": .string(member),
                    ]))
            }
            // Room state written through the state API rides along, as on
            // real servers (this is how name/topic/avatar changes land).
            state += (roomState[roomId] ?? [:]).values.sorted { $0.eventId.value < $1.eventId.value }
            // Room account data (tags, read markers) rides along too.
            let accountEvents = (roomAccountData.values.flatMap { perUser in
                perUser[roomId]?.map { type, content in
                    BasicEvent(type: type, content: content)
                } ?? []
            }).sorted { $0.type < $1.type }
            join[roomId] = JoinedRoomSync(
                timeline: TimelineChunk(events: room.timeline),
                state: state.isEmpty ? nil : StateChunk(events: state),
                accountData: accountEvents.isEmpty ? nil : AccountDataChunk(events: accountEvents))
        }
        let toDevice = ToDeviceChunk(events: toDeviceQueue)
        toDeviceQueue = []
        let lists: DeviceLists? =
            (deviceChanged.isEmpty && deviceLeft.isEmpty)
            ? nil : DeviceLists(changed: deviceChanged, left: deviceLeft)
        deviceChanged = []
        deviceLeft = []
        return .json(SyncResponse(
            nextBatch: batch,
            rooms: SyncRooms(join: join, invite: invite, leave: leave),
            toDevice: toDevice,
            deviceLists: lists,
            deviceOneTimeKeysCount: otkCount.map { ["signed_curve25519": $0] }))
    }

    /// `.well-known/matrix/client` pointing at this harness. Lets
    /// `resolveHomeserver` exercise the adopt-and-validate path against
    /// loopback instead of burning connect timeouts on dead hosts.
    public func wellKnown() -> HarnessResponse {
        .raw(#"{"m.homeserver":{"base_url":"\#(publicBaseURL)"}}"#)
    }
}
