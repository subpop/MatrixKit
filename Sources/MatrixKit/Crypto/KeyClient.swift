/// E2EE key endpoints: device keys, cross-signing keys, signatures, query.
public actor KeyClient {
    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Upload

    /// Publish our device keys and one-time keys (`POST /keys/upload`).
    @discardableResult
    public func uploadDeviceKeys(
        _ request: UploadDeviceKeysRequest
    ) async throws(MatrixError) -> UploadDeviceKeysResponse {
        try await transport.send(
            .post, path: "/_matrix/client/v3/keys/upload",
            body: request, accessToken: try await token()
        )
    }

    /// Publish our cross-signing keys (`POST /keys/device_signing/upload`).
    public func uploadSigningKeys(
        _ request: UploadSigningKeysRequest
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/keys/device_signing/upload",
            body: request, accessToken: try await token()
        )
    }

    /// Publish signatures over keys (`POST /keys/signatures/upload`).
    /// Throws when the server rejects any signature — note the
    /// endpoint answers 200 with a `failures` map in that case, so a
    /// bare status check would silently accept a failed upload.
    public func uploadSignatures(
        _ request: UploadSignaturesRequest
    ) async throws(MatrixError) {
        let response: UploadSignaturesResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/keys/signatures/upload",
            body: request, accessToken: try await token()
        )
        if let failures = response.failures, !failures.isEmpty {
            let (userId, keyFailures) = failures.first!
            let (keyId, failure) = keyFailures.first!
            throw .serverError(
                code: failure.errcode,
                message: "\(userId)/\(keyId): \(failure.error)",
                retryAfter: nil)
        }
    }

    // MARK: - Query

    /// Fetch device and cross-signing keys (`POST /keys/query`).
    public func queryKeys(
        _ request: KeyQueryRequest
    ) async throws(MatrixError) -> KeyQueryResponse {
        try await transport.send(
            .post, path: "/_matrix/client/v3/keys/query",
            body: request, accessToken: try await token()
        )
    }

    /// Fetch all device + cross-signing keys for the given users.
    public func queryKeys(
        users: [UserId]
    ) async throws(MatrixError) -> KeyQueryResponse {
        var deviceKeys: [String: [String]] = [:]
        for user in users {
            deviceKeys[user.value] = []
        }
        return try await queryKeys(KeyQueryRequest(deviceKeys: deviceKeys))
    }

    // MARK: - Claim

    /// Claim one-time keys to start Olm sessions (`POST /keys/claim`).
    public func claimKeys(
        _ request: ClaimKeysRequest
    ) async throws(MatrixError) -> ClaimKeysResponse {
        try await transport.send(
            .post, path: "/_matrix/client/v3/keys/claim",
            body: request, accessToken: try await token()
        )
    }

    /// Claim a signed one-time key for one device (`"device"` or `"*"`).
    public func claimKeys(
        user: UserId, device: String = "*"
    ) async throws(MatrixError) -> ClaimKeysResponse {
        try await claimKeys(
            ClaimKeysRequest(
                oneTimeKeys: [user.value: [device: "signed_curve25519"]]))
    }
}
