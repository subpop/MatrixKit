/// Cross-signing identity lifecycle: generate, upload, fetch, sign devices.
///
/// Trust chain: the master key signs the self-signing and user-signing
/// keys; the self-signing key signs our verified devices; the
/// user-signing key signs other users' master keys. Keypairs live in
/// memory — persist `exportPrivateKeys()` output (e.g. 4S/account data)
/// to survive restarts.
import MatrixKitCrypto

public actor CrossSigning {
    private let keys: KeyClient
    private let session: Session

    private var master: SigningKey?
    private var selfSigning: SigningKey?
    private var userSigning: SigningKey?

    public init(transport: MatrixTransport, session: Session) {
        self.keys = KeyClient(transport: transport, session: session)
        self.session = session
    }

    // MARK: - Local state

    /// Whether all three cross-signing keypairs are held in memory.
    public var hasKeys: Bool {
        master != nil && selfSigning != nil && userSigning != nil
    }

    /// Unpadded-base64 public keys (master, self-signing, user-signing).
    /// Nil unless `generate()` or `importPrivateKeys(_:)` ran.
    public var publicKeys: (master: String, selfSigning: String, userSigning: String)? {        guard let master, let selfSigning, let userSigning else { return nil }
        return (
            master.publicKeyBase64, selfSigning.publicKeyBase64,
            userSigning.publicKeyBase64
        )
    }

    /// Generate fresh master/self-signing/user-signing keypairs in memory.
    @discardableResult
    public func generate() -> (master: String, selfSigning: String, userSigning: String) {
        master = .generate()
        selfSigning = .generate()
        userSigning = .generate()
        return publicKeys!
    }

    /// Export private halves (unpadded base64) for backup. Handle as secrets.
    public func exportPrivateKeys() -> (master: String, selfSigning: String, userSigning: String)? {
        guard let master, let selfSigning, let userSigning else { return nil }
        return (
            master.privateKeyBase64, selfSigning.privateKeyBase64,
            userSigning.privateKeyBase64
        )
    }

    /// Restore keypairs from previously exported private halves.
    public func importPrivateKeys(
        master: String, selfSigning: String, userSigning: String
    ) throws(MatrixError) {
        guard
            let masterBytes = Primitives.base64UnpaddedDecode(master),
            let selfBytes = Primitives.base64UnpaddedDecode(selfSigning),
            let userBytes = Primitives.base64UnpaddedDecode(userSigning)
        else {
            throw .encodingError("Malformed cross-signing private key backup")
        }
        do {
            self.master = try SigningKey.restore(privateKeyBytes: masterBytes)
            self.selfSigning = try SigningKey.restore(
                privateKeyBytes: selfBytes)
            self.userSigning = try SigningKey.restore(
                privateKeyBytes: userBytes)
        } catch {
            throw .encodingError(
                "Invalid cross-signing private key in backup")
        }
    }

    // MARK: - Upload

    /// Sign self-signing + user-signing keys with the master key and upload
    /// all three (`POST /keys/device_signing/upload`).
    ///
    /// - Parameter auth: UIAA continuation for the retry after a 401
    ///   challenge. Nil on the first attempt; when the server demands
    ///   interactive auth it throws `MatrixError.uiaa` — complete a stage
    ///   (see `uploadWithReset()`) and retry with its `UIAAuth`.
    public func upload(auth: UIAAuth? = nil) async throws(MatrixError) {
        guard let master, let selfSigning, let userSigning else {
            throw .notAuthenticated
        }
        let userId = await session.userId.value
        let masterId = "ed25519:\(master.publicKeyBase64)"

        var selfKey = CrossSigningKey(
            userId: userId, usage: ["self_signing"],
            keys: ["ed25519:\(selfSigning.publicKeyBase64)": selfSigning.publicKeyBase64]
        )
        var userKey = CrossSigningKey(
            userId: userId, usage: ["user_signing"],
            keys: ["ed25519:\(userSigning.publicKeyBase64)": userSigning.publicKeyBase64]
        )
        let masterKey = CrossSigningKey(
            userId: userId, usage: ["master"],
            keys: ["ed25519:\(master.publicKeyBase64)": master.publicKeyBase64]
        )
        selfKey.signatures = [userId: [masterId: try signCrossSigningKey(selfKey, with: master)]]
        userKey.signatures = [userId: [masterId: try signCrossSigningKey(userKey, with: master)]]

        try await keys.uploadSigningKeys(
            UploadSigningKeysRequest(
                masterKey: masterKey, selfSigningKey: selfKey,
                userSigningKey: userKey, auth: auth)
        )
    }

    /// Upload, completing the `org.matrix.cross_signing_reset` UIAA stage
    /// if the server already holds an identity for this account.
    ///
    /// Destructive: the reset wipes the existing cross-signing identity,
    /// unverifying every device. Callers must confirm with the user first
    /// (the CLI prompts). Throws the original `MatrixError.uiaa` when the
    /// server offers no reset stage.
    public func uploadWithReset() async throws(MatrixError) {
        do {
            try await upload()
        } catch .uiaa(let challenge) {
            guard
                challenge.offersStage(UIAAChallenge.resetStage),
                challenge.session != nil
            else { throw .uiaa(challenge) }
            try await upload(
                auth: UIAAuth(
                    type: UIAAChallenge.resetStage,
                    session: challenge.session))
        }
    }

    /// Sign the JSON of a cross-signing key (minus signatures) with a keypair.
    private func signCrossSigningKey(
        _ key: CrossSigningKey, with signer: SigningKey
    ) throws(MatrixError) -> String {
        let payload: [String: Any] = [
            "user_id": key.userId,
            "usage": key.usage,
            "keys": key.keys,
        ]
        let canonical = try CryptoPrimitives.canonicalJSON(payload)
        do {
            return Primitives.base64UnpaddedEncode(
                try signer.sign(canonical))
        } catch {
            throw .encodingError(
                "Failed to sign cross-signing key: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch

    /// Fetch cross-signing keys for users via `POST /keys/query`.
    public func fetchKeys(
        users: [UserId]
    ) async throws(MatrixError) -> KeyQueryResponse {
        try await keys.queryKeys(users: users)
    }

    // MARK: - Sign devices

    /// Sign one of our devices with the self-signing key and upload the
    /// signature. Returns the signature's key ID.
    ///
    /// Uploads the FULL device object with the new signature merged
    /// into `.signatures`, per the `/keys/signatures/upload` shape —
    /// a bare signature map is rejected (`M_INVALID_PARAM`).
    @discardableResult
    public func signDevice(
        userId: UserId, deviceId: DeviceId
    ) async throws(MatrixError) -> String {
        guard let selfSigning else { throw .notAuthenticated }
        let response = try await keys.queryKeys(users: [userId])
        guard
            var device = response.deviceKeys[userId.value]?[deviceId.value]
        else {
            throw .invalidIdentifier(
                "No device keys for \(userId):\(deviceId)")
        }
        let payload: [String: Any] = [
            "user_id": device.userId,
            "device_id": device.deviceId,
            "algorithms": device.algorithms,
            "keys": device.keys,
        ]
        let canonical = try CryptoPrimitives.canonicalJSON(payload)
        let signature: String
        let keyId = "ed25519:\(selfSigning.publicKeyBase64)"
        do {
            signature = Primitives.base64UnpaddedEncode(
                try selfSigning.sign(canonical))
        } catch {
            throw .encodingError(
                "Failed to sign device: \(error.localizedDescription)")
        }
        var userSignatures = device.signatures[userId.value] ?? [:]
        userSignatures[keyId] = signature
        device.signatures[userId.value] = userSignatures
        try await keys.uploadSignatures(
            UploadSignaturesRequest(signed: [
                userId.value: [deviceId.value: device]
            ]))
        return keyId
    }

    // MARK: - Verify devices

    /// Whether this device's keys are validly signed by our self-signing
    /// key (i.e. the session is cross-signing verified). Verifies the
    /// signature cryptographically, not just its presence.
    public func isDeviceVerified(_ device: DeviceKeys) -> Bool {
        guard let selfSigning = publicKeys?.selfSigning else { return false }
        return Self.deviceSignatureValid(device, selfSigningKey: selfSigning)
    }

    /// Check a self-signing signature over device keys (pure).
    nonisolated static func deviceSignatureValid(
        _ device: DeviceKeys, selfSigningKey: String
    ) -> Bool {
        guard
            let sigB64 = device.signatures[device.userId]?["ed25519:\(selfSigningKey)"],
            let signature = Primitives.base64UnpaddedDecode(sigB64),
            let keyData = Primitives.base64UnpaddedDecode(selfSigningKey)
        else { return false }
        let payload: [String: Any] = [
            "user_id": device.userId,
            "device_id": device.deviceId,
            "algorithms": device.algorithms,
            "keys": device.keys,
        ]
        guard let canonical = try? CryptoPrimitives.canonicalJSON(payload) else {
            return false
        }
        return SigningKey.verify(
            signature: signature, for: canonical, publicKey: keyData)
    }
}
