import Foundation
import MatrixKit

/// A request the harness recorded, for assertions on what the SDK sent
/// (paths, methods, auth placement, bodies).
public struct RecordedRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var hadBearer: Bool
    public var body: Data

    public init(method: String, path: String, query: [String: String], hadBearer: Bool, body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.hadBearer = hadBearer
        self.body = body
    }
}

/// A spec-compliance failure observed by the harness.
public enum SpecViolation: Sendable, CustomStringConvertible {
    /// The SDK hit a method+path the pinned spec does not define.
    case unknownEndpoint(method: String, path: String)
    /// The SDK hit a spec endpoint the world does not implement yet —
    /// a test-authoring gap, reported the same way so suites fail loudly.
    case missingRoute(method: String, path: String)

    public var description: String {
        switch self {
        case .unknownEndpoint(let method, let path):
            return "unknown endpoint \(method) \(path) (not in spec \(SpecRegistry.specVersion))"
        case .missingRoute(let method, let path):
            return "unimplemented route \(method) \(path) (spec-known, world lacks it)"
        }
    }
}

/// Request log, violation ledger, and one-shot response overrides.
public actor HarnessRecorder {
    public private(set) var requests: [RecordedRequest] = []
    public private(set) var violations: [SpecViolation] = []
    private var overrides: [(method: String, path: String, response: HarnessResponse)] = []

    public init() {}

    func record(_ request: RecordedRequest) {
        requests.append(request)
    }

    func violate(_ violation: SpecViolation) {
        violations.append(violation)
    }

    /// Serve `response` for the next request to exactly `method` + `path`,
    /// bypassing world routing. Consumed once. Powers error-mapping and
    /// malformed-body tables without world support.
    public func setOverride(method: String, path: String, response: HarnessResponse) {
        overrides.append((method, path, response))
    }

    func takeOverride(method: String, path: String) -> HarnessResponse? {
        guard let index = overrides.firstIndex(where: { $0.method == method && $0.path == path }) else {
            return nil
        }
        return overrides.remove(at: index).response
    }

    public func reset() {
        requests = []
        violations = []
        overrides = []
    }
}

/// The spec-compliance harness: an in-process homeserver the real
/// `MatrixTransport` talks to over loopback.
///
/// ```swift
/// let harness = try await Harness.start()
/// defer { await harness.stop() }
/// let (auth, session, transport) = await harness.authClient()
/// defer { try? await transport.shutdown() }
/// ```
public actor Harness {
    public let baseURL: URL
    public let world: HarnessWorld
    public let recorder: HarnessRecorder
    private let server: HarnessServer
    /// Transports handed out by `authClient()`. `shutdownClients()` (called
    /// by `withHarness`) tears them down even when a test throws mid-way —
    /// an un-shutdown transport traps on deinit and kills the test run.
    private var clients: [MatrixTransport] = []

    private init(baseURL: URL, world: HarnessWorld, recorder: HarnessRecorder, server: HarnessServer) {
        self.baseURL = baseURL
        self.world = world
        self.recorder = recorder
        self.server = server
    }

    /// Start the server on an ephemeral loopback port.
    public static func start() async throws -> Harness {
        let world = HarnessWorld()
        let recorder = HarnessRecorder()
        let server = HarnessServer(router: makeRouter(world: world, recorder: recorder))
        let port = try await server.start()
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        await world.setPublicBaseURL(baseURL.absoluteString)
        await world.setIssuerBase(baseURL.absoluteString)
        return Harness(
            baseURL: baseURL,
            world: world,
            recorder: recorder,
            server: server
        )
    }

    public func stop() async {
        await shutdownClients()
        await server.stop()
    }

    /// Shut down every handed-out transport. Safe to call twice.
    public func shutdownClients() async {
        for transport in clients {
            try? await transport.shutdown()
        }
        clients = []
    }

    /// An `AuthClient` wired to this harness, with a session carrying
    /// `token` (default: the seeded alice session). The transport is
    /// owned by the harness and shut down by `shutdownClients()`.
    public func authClient(token: String? = "harness-token-alice") -> (auth: AuthClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (AuthClient(transport: transport, session: session), session, transport)
    }

    /// A `SyncClient` wired to this harness, with its own store.
    /// The transport is owned by the harness (`shutdownClients`).
    public func syncClient(
        token: String? = "harness-token-alice"
    ) -> (sync: SyncClient, connection: SyncConnection, store: StateStore, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        let store = StateStore()
        let connection = SyncConnection(transport: transport, session: session)
        let sync = SyncClient(connection: connection, store: store, session: session)
        return (sync, connection, store, session, transport)
    }

    /// A `RoomClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func roomClient(
        token: String? = "harness-token-alice"
    ) -> (rooms: RoomClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (RoomClient(transport: transport, session: session), session, transport)
    }

    /// Register an externally created transport for shutdown with the
    /// harness (peers built by hand in multi-device tests).
    public func trackTransport(_ transport: MatrixTransport) {
        clients.append(transport)
    }

    /// A `MessageClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func messageClient(
        token: String? = "harness-token-alice"
    ) -> (messages: MessageClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (MessageClient(transport: transport, session: session), session, transport)
    }

    /// A `RoomStateClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func roomStateClient(
        token: String? = "harness-token-alice"
    ) -> (state: RoomStateClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (RoomStateClient(transport: transport, session: session), session, transport)
    }

    /// An `AccountDataClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func accountDataClient(
        token: String? = "harness-token-alice"
    ) -> (accountData: AccountDataClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (AccountDataClient(transport: transport, session: session), session, transport)
    }

    /// A `KeyClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func keyClient(
        token: String? = "harness-token-alice"
    ) -> (keys: KeyClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (KeyClient(transport: transport, session: session), session, transport)
    }

    /// A `ProfileClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func profileClient(
        token: String? = "harness-token-alice"
    ) -> (profile: ProfileClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (ProfileClient(transport: transport, session: session), session, transport)
    }

    /// A `PushClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func pushClient(
        token: String? = "harness-token-alice"
    ) -> (push: PushClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (PushClient(transport: transport, session: session), session, transport)
    }

    /// A `MediaClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func mediaClient(
        token: String? = "harness-token-alice"
    ) -> (media: MediaClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (MediaClient(transport: transport, session: session), session, transport)
    }

    /// A `SearchClient` wired to this harness, with its own store.
    /// The transport is owned by the harness (`shutdownClients`).
    public func searchClient(
        token: String? = "harness-token-alice"
    ) -> (search: SearchClient, store: StateStore, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        let store = StateStore()
        return (SearchClient(transport: transport, session: session, store: store), store, session, transport)
    }

    /// A `KeyBackup` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func backupClient(
        token: String? = "harness-token-alice"
    ) -> (backup: KeyBackup, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (KeyBackup(transport: transport, session: session), session, transport)
    }

    /// A `ToDeviceClient` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func toDeviceClient(
        token: String? = "harness-token-alice"
    ) -> (toDevice: ToDeviceClient, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (ToDeviceClient(transport: transport, session: session), session, transport)
    }

    /// A `CrossSigning` wired to this harness.
    /// The transport is owned by the harness (`shutdownClients`).
    public func crossSigning(
        token: String? = "harness-token-alice"
    ) -> (crossSigning: CrossSigning, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        return (CrossSigning(transport: transport, session: session), session, transport)
    }

    /// An `OIDCClient` wired to this harness (issuer endpoints loop back).
    /// The transport is owned by the harness (`shutdownClients`).
    public func oidcClient() -> (oidc: OIDCClient, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        return (OIDCClient(transport: transport), transport)
    }

    /// A `SpacesClient` wired to this harness, with its own store.
    /// The transport is owned by the harness (`shutdownClients`).
    public func spacesClient(
        token: String? = "harness-token-alice"
    ) -> (spaces: SpacesClient, store: StateStore, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        let store = StateStore()
        return (SpacesClient(transport: transport, session: session, store: store), store, session, transport)
    }

    /// A `SlidingSyncClient` wired to this harness, with its own store.
    /// The transport is owned by the harness (`shutdownClients`).
    public func slidingSyncClient(
        token: String? = "harness-token-alice"
    ) -> (sliding: SlidingSyncClient, store: StateStore, session: Session, transport: MatrixTransport) {
        let transport = MatrixTransport(homeserver: baseURL)
        clients.append(transport)
        let session = Session(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: token ?? ""
        )
        let store = StateStore()
        return (SlidingSyncClient(transport: transport, session: session, store: store), store, session, transport)
    }

    /// A client with no credentials — SDK calls must throw
    /// `.notAuthenticated` before touching the network.
    public func unauthenticatedClient() -> (auth: AuthClient, session: Session, transport: MatrixTransport) {
        authClient(token: nil)
    }

    public var requests: [RecordedRequest] {
        get async { await recorder.requests }
    }

    public var violations: [SpecViolation] {
        get async { await recorder.violations }
    }

    public func setOverride(method: String, path: String, response: HarnessResponse) async {
        await recorder.setOverride(method: method, path: path, response: response)
    }
}

// MARK: - Router

private func makeRouter(world: HarnessWorld, recorder: HarnessRecorder) -> @Sendable (HarnessRequest) async -> HarnessResponse {
    { request in
        await recorder.record(RecordedRequest(
            method: request.method,
            path: request.path,
            query: request.query,
            hadBearer: request.bearer != nil,
            body: request.body
        ))
        if let stub = await recorder.takeOverride(method: request.method, path: request.path) {
            return stub
        }
        guard let endpoint = SpecRegistry.match(method: request.method, path: request.path) else {
            await recorder.violate(.unknownEndpoint(method: request.method, path: request.path))
            return .matrixError(code: "M_UNRECOGNIZED", message: "Unrecognized request", status: 404)
        }
        // Spec auth gate: endpoints the registry marks authenticated
        // require a bearer the world recognises.
        if endpoint.requiresAuth {
            guard let bearer = request.bearer else {
                return .matrixError(code: "M_MISSING_TOKEN", message: "Missing access token", status: 401)
            }
            guard await world.isValidToken(bearer) else {
                return .matrixError(code: "M_UNKNOWN_TOKEN", message: "Unrecognised access token", status: 401)
            }
        }
        return await dispatch(request, world: world, recorder: recorder)
    }
}

/// Route a spec-known request to the world. Unknown-to-the-world
/// endpoints are violations (not silent fixtures) so suites fail
/// loudly until the world grows the behavior they need.
private func dispatch(_ request: HarnessRequest, world: HarnessWorld, recorder: HarnessRecorder) async -> HarnessResponse {
    switch (request.method, request.path) {
    case ("POST", "/_matrix/client/v3/login"):
        return await world.login(request)
    case ("GET", "/_matrix/client/v3/login"):
        return await world.loginFlows()
    case ("POST", "/_matrix/client/v3/register"):
        return await world.register(request)
    case ("GET", "/_matrix/client/v3/register/available"):
        return await world.registerAvailable(request)
    case ("POST", "/_matrix/client/v3/refresh"):
        return await world.refresh(request)
    case ("POST", "/_matrix/client/v3/logout"):
        return await world.logout(bearer: request.bearer ?? "")
    case ("POST", "/_matrix/client/v3/logout/all"):
        return await world.logoutAll(bearer: request.bearer ?? "")
    case ("POST", "/_matrix/client/v3/account/deactivate"):
        return await world.deactivate(bearer: request.bearer ?? "")
    case ("GET", "/_matrix/client/v3/account/whoami"):
        return await world.whoAmI(bearer: request.bearer ?? "")
    case ("GET", "/_matrix/client/versions"):
        return await world.serverVersions()
    case ("GET", "/_matrix/client/v3/sync"):
        return await world.handleSync(bearer: request.bearer ?? "", since: request.query["since"])
    case ("GET", "/.well-known/matrix/client"):
        return await world.wellKnown()
    default:
        if let response = await dispatchRooms(request, world: world) {
            return response
        }
        await recorder.violate(.missingRoute(method: request.method, path: request.path))
        return .matrixError(code: "M_UNRECOGNIZED", message: "Unrecognized request", status: 404)
    }
}

/// Room-lifecycle routes with `{param}` segments. Returns nil when the
/// request is not a room route (falls through to the violation ledger).
private func dispatchRooms(_ request: HarnessRequest, world: HarnessWorld) async -> HarnessResponse? {
    let bearer = request.bearer ?? ""
    let base = "/_matrix/client/v3"
    let path = request.path
    func remainder(after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
    func roomID(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }
    // /user/... routes (account data, tags): disjoint prefix, handled
    // before the method switch so one branch never swallows another.
    if ["GET", "PUT", "DELETE"].contains(request.method),
        let rest = remainder(after: "\(base)/user/")
    {
        let parts = rest
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let user = parts[0].removingPercentEncoding ?? parts[0]
        // /user/{u}/account_data/{type}
        if parts.count == 3, parts[1] == "account_data" {
            let type = parts[2].removingPercentEncoding ?? parts[2]
            return request.method == "GET"
                ? await world.accountDataGet(user: user, type: type)
                : await world.accountDataPut(user: user, type: type, request: request)
        }
        // /user/{u}/rooms/{r}/account_data/{type}
        if parts.count == 5, parts[1] == "rooms", parts[3] == "account_data" {
            let room = roomID(parts[2])
            let type = parts[4].removingPercentEncoding ?? parts[4]
            return request.method == "GET"
                ? await world.roomAccountDataGet(user: user, room: room, type: type)
                : await world.roomAccountDataPut(user: user, room: room, type: type, request: request)
        }
        // /user/{u}/rooms/{r}/tags[/{tag}]
        if parts.count >= 4, parts[1] == "rooms", parts[3] == "tags" {
            let room = roomID(parts[2])
            if parts.count == 4, request.method == "GET" {
                return await world.tagsGet(user: user, room: room)
            }
            if parts.count == 5 {
                let tag = parts[4].removingPercentEncoding ?? parts[4]
                if request.method == "PUT" {
                    return await world.tagPut(user: user, room: room, tag: tag, request: request)
                }
                if request.method == "DELETE" {
                    return await world.tagDelete(user: user, room: room, tag: tag)
                }
            }
        }
        return nil
    }
    switch request.method {
    case "POST" where path == "\(base)/keys/upload":
        return await world.uploadKeys(bearer: bearer, request: request)
    case "POST" where path == "\(base)/keys/device_signing/upload":
        return await world.uploadSigningKeys(request: request)
    case "POST" where path == "\(base)/keys/signatures/upload":
        return await world.uploadSignatures(request: request)
    case "POST" where path == "\(base)/keys/query":
        return await world.queryKeys(request: request)
    case "POST" where path == "\(base)/keys/claim":
        return await world.claimKeys(request: request)
    case "GET" where path == "\(base)/pushers":
        return await world.pushersGet()
    case "POST" where path == "\(base)/pushers/set":
        return await world.pusherSet(request: request)
    case "GET" where path == "\(base)/pushrules/":
        return await world.pushRulesetGet()
    case "POST" where path == "\(base)/user_directory/search":
        return await world.directorySearch(request: request)
    case "POST" where path == "\(base)/search":
        return await world.searchMessages(request: request)
    case "POST" where path == "/_matrix/media/v3/upload":
        return await world.mediaUpload(request: request)
    case "GET" where path == "/_matrix/client/v1/rtc/transports":
        return await world.rtcTransports(baseURL: await world.baseURL())
    case "GET" where path == "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports":
        return await world.rtcTransports(baseURL: await world.baseURL())
    case "POST" where path == "/sfu/get":
        return await world.sfuToken()
    case "POST" where path == "/get_token":
        return await world.sfuToken()
    case "POST" where path == "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync":
        return await world.handleSlidingSync()
    case "GET" where path == "\(base)/devices":
        return await world.devicesList()
    case "GET" where path == "\(base)/capabilities":
        return await world.capabilitiesGet()
    case "GET" where path == "/_matrix/client/v1/auth_metadata":
        return await world.authMetadata()
    case "POST" where path == "/issuer/register":
        return await world.issuerRegister()
    case "POST" where path == "/issuer/device":
        return await world.issuerDevice()
    case "POST" where path == "/issuer/token":
        return await world.issuerToken(request: request)
    case "POST" where path == "/issuer/revoke":
        return await world.issuerRevoke(request: request)
    case "GET" where path == "\(base)/room_keys/version":
        return await world.backupVersionGet()
    case "POST" where path == "\(base)/room_keys/version":
        return await world.backupVersionCreate(request: request)
    case "GET" where path == "\(base)/room_keys/keys":
        guard let version = request.query["version"] else {
            return .matrixError(code: "M_MISSING_PARAM", message: "version?", status: 400)
        }
        return await world.backupKeysGet(version: version)
    case "PUT" where path == "\(base)/room_keys/keys":
        guard let version = request.query["version"] else {
            return .matrixError(code: "M_MISSING_PARAM", message: "version?", status: 400)
        }
        return await world.backupKeysPut(version: version, request: request)
    case "POST" where path == "\(base)/createRoom":
        return await world.createRoom(bearer: bearer, request: request)
    case "POST" where path == "\(base)/publicRooms":
        let filter = try? request.decodeBody(PublicRoomsRequest.self)
        return await world.directoryList(filter: filter?.filter?.genericSearchTerm)
    case "POST" where remainder(after: "\(base)/join/") != nil:
        return await world.joinRoom(bearer: bearer, target: remainder(after: "\(base)/join/")!)
    case "POST" where remainder(after: "\(base)/knock/") != nil:
        return await world.knockRoom(bearer: bearer, target: remainder(after: "\(base)/knock/")!)
    case "POST" where remainder(after: "\(base)/rooms/") != nil:
        let rest = remainder(after: "\(base)/rooms/")!
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let id = roomID(parts[0])
        switch parts[1] {
        case "leave": return await world.leaveRoom(bearer: bearer, roomId: id)
        case "forget": return await world.forgetRoom(bearer: bearer, roomId: id)
        case "invite": return await world.moderate(bearer: bearer, roomId: id, request: request, membership: .invite)
        case "kick": return await world.moderate(bearer: bearer, roomId: id, request: request, membership: .leave)
        case "ban": return await world.moderate(bearer: bearer, roomId: id, request: request, membership: .ban)
        case "unban": return await world.moderate(bearer: bearer, roomId: id, request: request, membership: .leave)
        case "upgrade": return await world.upgradeRoom(bearer: bearer, roomId: id)
        case "report" where parts.count == 3: return await world.reportEvent(roomId: id)
        case "receipt" where parts.count == 4:
            return await world.sendReceipt(
                bearer: bearer, roomId: id,
                receiptType: parts[2].removingPercentEncoding ?? parts[2],
                eventId: parts[3].removingPercentEncoding ?? parts[3])
        case "read_markers" where parts.count == 2:
            return await world.setReadMarkers(bearer: bearer, roomId: id, request: request)
        default: return nil
        }
    case "PUT" where remainder(after: "\(base)/rooms/") != nil:
        let parts = remainder(after: "\(base)/rooms/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let id = roomID(parts[0])
        switch parts[1] {
        case "send" where parts.count == 4:
            return await world.sendRoomEvent(
                bearer: bearer, roomId: id,
                eventType: parts[2].removingPercentEncoding ?? parts[2],
                txnId: parts[3].removingPercentEncoding ?? parts[3],
                request: request)
        case "redact" where parts.count == 4:
            return await world.redactEvent(
                roomId: id, eventId: parts[2].removingPercentEncoding ?? parts[2])
        case "state" where parts.count >= 3:
            let type = parts[2].removingPercentEncoding ?? parts[2]
            let key = parts.count > 3 ? (parts[3].removingPercentEncoding ?? parts[3]) : ""
            if let delayMs = request.query["org.matrix.msc4140.delay"].flatMap(Int.init) {
                return await world.scheduleDelayed(roomId: id, type: type, delayMs: delayMs)
            }
            return await world.sendStateEvent(
                bearer: bearer, roomId: id, type: type, key: key, request: request)
        case "typing" where parts.count == 3:
            return await world.sendTyping(
                roomId: id, userId: parts[2].removingPercentEncoding ?? parts[2],
                request: request)
        default: return nil
        }
    case "GET" where remainder(after: "\(base)/rooms/") != nil:
        let rest = remainder(after: "\(base)/rooms/")!
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 1 else { return nil }
        let id = roomID(parts[0])
        switch parts.count {
        case 1: return nil
        case 2 where parts[1] == "members": return await world.roomMembers(roomId: id)
        case 2 where parts[1] == "joined_members": return await world.roomJoinedMembers(roomId: id)
        case 2 where parts[1] == "aliases": return await world.roomAliases(roomId: id)
        case 2 where parts[1] == "messages": return await world.paginateMessages(roomId: id, query: request.query)
        case 2 where parts[1] == "state": return await world.getRoomState(roomId: id)
        case 3 where parts[1] == "event":
            return await world.fetchEvent(
                roomId: id, eventId: parts[2].removingPercentEncoding ?? parts[2])
        case 3 where parts[1] == "context":
            return await world.eventContext(
                roomId: id, eventId: parts[2].removingPercentEncoding ?? parts[2])
        case 3 where parts[1] == "state":
            return await world.getStateEvent(roomId: id, type: parts[2], key: "")
        case 4 where parts[1] == "state":
            return await world.getStateEvent(
                roomId: id, type: parts[2],
                key: parts[3].removingPercentEncoding ?? parts[3])
        default: return nil
        }
    case "GET" where remainder(after: "/_matrix/client/v1/rooms/") != nil:
        let parts = remainder(after: "/_matrix/client/v1/rooms/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[1] == "hierarchy" else {
            // Fall through to relations handling below.
            if parts.count >= 4, parts[1] == "relations" {
                let id = roomID(parts[0])
                let target = parts[2].removingPercentEncoding ?? parts[2]
                let relType = parts[3].removingPercentEncoding ?? parts[3]
                let eventType = parts.count > 4 ? (parts[4].removingPercentEncoding ?? parts[4]) : nil
                return await world.eventRelations(roomId: id, target: target, relType: relType, eventType: eventType)
            }
            return nil
        }
        return await world.spaceHierarchy(spaceId: roomID(parts[0]))
    case "GET" where path == "\(base)/publicRooms":
        return await world.directoryList(filter: nil)
    case "GET" where remainder(after: "\(base)/directory/list/room/") != nil:
        return await world.roomVisibility(roomId: roomID(remainder(after: "\(base)/directory/list/room/")!))
    case "PUT" where remainder(after: "\(base)/directory/list/room/") != nil:
        return await world.setRoomVisibility(
            roomId: roomID(remainder(after: "\(base)/directory/list/room/")!), request: request)
    case "PUT" where remainder(after: "\(base)/directory/room/") != nil:
        return await world.publishAlias(remainder(after: "\(base)/directory/room/")!, request: request)
    case "DELETE" where remainder(after: "\(base)/directory/room/") != nil:
        return await world.removeAlias(remainder(after: "\(base)/directory/room/")!)
    case "GET" where remainder(after: "\(base)/directory/room/") != nil:
        return await world.resolveAlias(remainder(after: "\(base)/directory/room/")!)
    case "GET" where remainder(after: "\(base)/profile/") != nil:
        let parts = remainder(after: "\(base)/profile/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let user = parts[0].removingPercentEncoding ?? parts[0]
        switch parts.count {
        case 1: return await world.profileGet(user: user)
        case 2 where parts[1] == "displayname": return await world.profileDisplayNameGet(user: user)
        case 2 where parts[1] == "avatar_url": return await world.profileAvatarGet(user: user)
        default: return nil
        }
    case "PUT" where remainder(after: "\(base)/profile/") != nil:
        let parts = remainder(after: "\(base)/profile/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let user = parts[0].removingPercentEncoding ?? parts[0]
        switch parts[1] {
        case "displayname": return await world.profilePutDisplayName(user: user, request: request)
        case "avatar_url": return await world.profilePutAvatar(user: user, request: request)
        default: return nil
        }
    case "GET" where remainder(after: "\(base)/presence/") != nil:
        let parts = remainder(after: "\(base)/presence/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[1] == "status" else { return nil }
        return await world.presenceGet(user: parts[0].removingPercentEncoding ?? parts[0])
    case "PUT" where remainder(after: "\(base)/presence/") != nil:
        let parts = remainder(after: "\(base)/presence/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[1] == "status" else { return nil }
        return await world.presencePut(
            user: parts[0].removingPercentEncoding ?? parts[0], request: request)
    case "GET" where remainder(after: "/_matrix/media/v3/download/") != nil:
        let parts = remainder(after: "/_matrix/media/v3/download/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return await world.mediaDownload(server: parts[0], media: parts[1])
    case "GET" where remainder(after: "/_matrix/media/v3/thumbnail/") != nil:
        let parts = remainder(after: "/_matrix/media/v3/thumbnail/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return await world.mediaDownload(server: parts[0], media: parts[1])
    case "GET" where remainder(after: "/_matrix/client/v1/media/download/") != nil:
        let parts = remainder(after: "/_matrix/client/v1/media/download/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return await world.mediaDownload(server: parts[0], media: parts[1])
    case "GET" where remainder(after: "/_matrix/client/v1/media/thumbnail/") != nil:
        let parts = remainder(after: "/_matrix/client/v1/media/thumbnail/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return await world.mediaDownload(server: parts[0], media: parts[1])
    case "GET" where remainder(after: "\(base)/devices/") != nil:
        return await world.deviceGet(remainder(after: "\(base)/devices/")!)
    case "PUT" where remainder(after: "\(base)/devices/") != nil:
        return await world.deviceRename(
            remainder(after: "\(base)/devices/")!, request: request)
    case "POST" where path.hasPrefix("\(base)/user/") && path.hasSuffix("/openid/request_token"):
        return await world.openIDToken()
    case "POST" where remainder(after: "/_matrix/client/unstable/org.matrix.msc4140/delayed_events/") != nil:
        return await world.cancelDelayed(
            id: remainder(after: "/_matrix/client/unstable/org.matrix.msc4140/delayed_events/")!)
    case "DELETE" where remainder(after: "\(base)/devices/") != nil:
        return await world.deviceDelete(remainder(after: "\(base)/devices/")!)
    case "DELETE" where remainder(after: "\(base)/room_keys/version/") != nil:
        return await world.backupVersionDelete(remainder(after: "\(base)/room_keys/version/")!)
    case "GET" where remainder(after: "\(base)/room_keys/version/") != nil:
        return await world.backupVersionGet()
    case "GET" where remainder(after: "\(base)/room_keys/keys/") != nil:
        let parts = remainder(after: "\(base)/room_keys/keys/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let version = request.query["version"] else { return nil }
        return await world.backupSessionGet(
            version: version,
            room: parts[0].removingPercentEncoding ?? parts[0],
            session: parts[1].removingPercentEncoding ?? parts[1])
    case "PUT" where remainder(after: "\(base)/sendToDevice/") != nil:
        let parts = remainder(after: "\(base)/sendToDevice/")!
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return await world.toDeviceSend(
            type: parts[0].removingPercentEncoding ?? parts[0], txn: parts[1], request: request)
    // NOTE: this bare multi-pattern case matches every GET/PUT/DELETE
    // that reaches it, so it must stay the LAST case before default.
    case "GET", "PUT", "DELETE":
        guard request.path.hasPrefix("\(base)/pushrules/") else { return nil }
        let parts = String(request.path.dropFirst("\(base)/pushrules/".count))
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let kind = parts[1].removingPercentEncoding ?? parts[1]
        let id = parts[2].removingPercentEncoding ?? parts[2]
        if parts.count == 3 {
            if request.method == "GET" { return await world.pushRuleGet(kind: kind, id: id) }
            if request.method == "PUT" {
                return await world.pushRulePut(
                    kind: kind, id: id, request: request,
                    pattern: kind == "content" ? id : nil)
            }
            return await world.pushRuleDelete(kind: kind, id: id)
        }
        guard parts.count == 4 else { return nil }
        if request.method == "GET", parts[3] == "actions" {
            return await world.pushRuleActionsGet(kind: kind, id: id)
        }
        if request.method == "PUT", parts[3] == "actions" {
            return await world.pushRuleActionsPut(kind: kind, id: id, request: request)
        }
        if request.method == "PUT", parts[3] == "enabled" {
            return await world.pushRuleEnabled(kind: kind, id: id, request: request)
        }
        return nil
    default:
        return nil
    }
}
