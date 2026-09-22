# Encryption

How end-to-end encryption fits together: Olm sessions, Megolm room keys,
verification, cross-signing, and key backup.

## Overview

Encryption is opt-in per client. Call `configureEncryption()` once after
login or restore; it wires the crypto actors (`OlmConnector`,
`RoomCrypto`, `KeyClient`, verification, cross-signing) into the sync
engines via shared `SyncCryptoHooks`, so both the v3 loop and sliding
sync decrypt timelines and process device updates identically.

```swift
try await client.configureEncryption()

// Encrypted send (falls back to plaintext in unencrypted rooms):
try await room.send(text: "Secret hello")

// Or explicitly:
try await client.sendEncryptedContent(
    roomId, MessageContent.markdown("Secret hello"))
```

`ObservableRoom.isEncrypted` reports whether a room encrypts; undecryptable
timeline events surface with their session details so the UI can offer
`retryTimelineDecryption()` after keys arrive.

### Olm device messaging

`OlmConnector` owns the device identity, the signed pre-key bundle, and a
50-key one-time-key pool: upload on configure, claim-on-first-send
sessions, encrypted to-device delivery through `EncryptedToDeviceSender`
(`PUT /sendToDevice`). `ToDeviceClient` is the raw transport underneath.

### Megolm room encryption

`RoomCrypto` owns per-room Megolm sessions: automatic room-key sharing
with the room's device list, session rotation, and decryption of
`m.megolm.v1.aes-sha2` timeline events. `shareRoomKey(_:)` forces a
fresh share (e.g. after new devices join); `retryTimelineDecryption()`
reprocesses previously undecryptable events once keys land.

### Verification and cross-signing

SAS emoji verification runs through `VerificationSession`
(requester + responder flows), observed via `VerificationMonitor`;
`refreshVerificationState()` and `hasDevicesToVerifyAgainst()` expose
the pending state to settings UI. `CrossSigning` manages the
generate/upload/fetch lifecycle (`CrossSigningStore` persists the keys),
and `KeyClient` carries the wire calls (`/keys/upload`,
`/keys/device_signing/upload`, `/keys/signatures/upload`, `/keys/query`,
`/keys/claim`).

### Secrets and key backup

`SecretStorage` + `SecretShare` implement 4S secret sharing
(request/receive); account secrets persist through any
`SecretItemStore` (ships with `KeychainSecretStore`). Server-side Megolm
backup (`m.megolm_backup.v1`) lives in `KeyBackup` — version lifecycle
plus bulk/per-session upload/download — surfaced via
`recover(withRecoveryKey:)` / `recover(withPassphrase:)` (which also
unlock 4S) followed by `restoreKeyBackup(privateKey:)`; the CLI exposes
the same flow as `recover` + `backup-restore`. `encryptionStatus()`
reports backup/recovery state for settings UI. `deleteLocalCryptoMaterial()`
wipes device-local crypto state (e.g. on logout).

Wire-compatibility with an independent implementation is proven by the
`Tools/OlmInteropHarness` oracle (vodozemac) plus hermetic fixtures; see
its README for the protocol and fixture-harvesting workflow.

## Topics

### Facade entry points

- ``MatrixClient/configureEncryption()``
- ``MatrixClient/sendEncryptedContent(_:_:transactionId:)``
- ``MatrixClient/shareRoomKey(_:)``
- ``MatrixClient/retryTimelineDecryption()``
- ``MatrixClient/recover(withRecoveryKey:)``
- ``MatrixClient/recover(withPassphrase:)``
- ``MatrixClient/restoreKeyBackup(privateKey:)``
- ``MatrixClient/requestBackupKey(from:deviceId:)``
- ``MatrixClient/encryptionStatus()``
- ``MatrixClient/hasDevicesToVerifyAgainst()``
- ``MatrixClient/refreshVerificationState()``
- ``MatrixClient/deleteLocalCryptoMaterial()``

### Crypto actors

- ``OlmConnector``
- ``RoomCrypto``
- ``KeyClient``
- ``KeyBackup``
- ``CrossSigning``
- ``CrossSigningStore``
- ``VerificationSession``
- ``VerificationMonitor``
- ``SecretStorage``
- ``SecretShare``
- ``SecretItemStore``
- ``DeviceIdentity``
- ``EncryptedToDeviceSender``
- ``ToDeviceClient``
