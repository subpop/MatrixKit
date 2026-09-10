# Olm Interop Harness (dev-only)

A thin CLI wrapper around [vodozemac](https://github.com/matrix-org/vodozemac)
(`0.10.0`, the audited Rust Olm/Megolm implementation) used as an
**independent oracle** for `MatrixKitCrypto`. It proves our Swift Olm and
Megolm sessions are wire-compatible with a second implementation instead
of only round-tripping with themselves.

Never shipped. Nothing outside `Tools/` and `Tests/` depends on it.

## Build

```sh
cd Tools/OlmInteropHarness
cargo build          # binary: target/debug/olm-interop-harness
```

Requires a Rust toolchain (`cargo`). `target/` is gitignored; `Cargo.lock`
is committed so harness builds stay reproducible.

## Protocol

JSON lines over stdin/stdout. One request object per line, one reply per
line:

- Request: `{"cmd": "<name>", ...args}`
- Success: `{"ok": {...}}`
- Failure: `{"error": "<message>"}`

Accounts, sessions, and group sessions cross the boundary as vodozemac
**pickle JSON** (opaque to callers — pass back verbatim). Message bodies,
keys, and plaintexts cross as **standard padded base64**.

### Olm commands

| Command | Args | Returns |
|---|---|---|
| `olm-account` | — | `curve25519`, `ed25519`, `one_time_key` (base64) + `account_pickle` |
| `olm-outbound` | `account_pickle`, `peer_identity`, `peer_one_time` | `session_pickle`, `account_pickle` (OTK consumed) |
| `olm-encrypt` | `session_pickle`, `plaintext` | `type` (`0` pre-key / `1` normal), `body`, `session_pickle` |
| `olm-inbound` | `account_pickle`, `peer_identity`, `body` | `plaintext`, `session_pickle`, `account_pickle` |
| `olm-decrypt` | `session_pickle`, `type`, `body` | `plaintext`, `session_pickle` |

### Megolm commands

| Command | Args | Returns |
|---|---|---|
| `megolm-create` | — | `group_pickle`, `session_key` (229-byte sharing blob), `session_id` |
| `megolm-encrypt` | `group_pickle`, `plaintext` | `body`, `group_pickle` |
| `megolm-import` | `session_key` | `inbound_pickle`, `session_id` |
| `megolm-decrypt` | `inbound_pickle`, `body` | `plaintext`, `message_index`, `inbound_pickle` |

### Debug commands

Added while chasing interop divergences; useful for future protocol work:

- `olm-debug-kdf` — takes four fixed 32-byte private keys
  (`alice_id_priv`, `bob_id_priv`, `bob_otk_priv`, `alice_eph_priv`) and
  re-derives every TripleDH/root/chain/message-key stage
  (`s_bob`, `s_alice`, `r0`, `c0`, `m0`, `aes`, `mac`, `iv`) for
  byte-comparison against Swift's `Primitives`.
- `olm-debug-parse` — parses a pre-key body and round-trips it through
  prost; `roundtrip_ok` proves the bytes are canonically encoded.

## Swift drivers

- `Tests/MatrixKitCryptoTests/InteropLiveTests.swift` — live two-way
  Olm + Megolm exchanges against this binary. Dev-only: silently skips
  when the binary is absent. Override the path with `OLM_INTEROP_BIN`;
  otherwise it uses
  `Tools/OlmInteropHarness/target/debug/olm-interop-harness`.
  (Note: it polls `availableData` instead of blocking `read()` — blocking
  pipe reads hang in some environments.)
- `Tests/MatrixKitCryptoTests/InteropFixturesTests.swift` — hermetic
  tests over committed fixtures in
  `Tests/MatrixKitCryptoTests/InteropFixtures/` (`olm-prekey.json`,
  `megolm-fixed.json`). These run in plain `swift test` with no harness.

## Harvesting deterministic fixtures

vodozemac generates random keys, so deterministic fixtures need pickle
surgery — generate state, then overwrite the key material in the pickle
JSON with fixed bytes before use:

- **AccountPickle**: replace `diffie_hellman_key` (32-int array) with the
  fixed identity bytes, `one_time_keys.private_keys["0"]` **and**
  `one_time_keys.public_keys["0"]` (both — lookup matches on public)
  with the fixed OTK pair. `signing_key` is `{"Normal": [...]}`; leave it
  unless the test needs it.
- **GroupSessionPickle**: replace `ratchet.inner` (128-int array = four
  32-byte parts) and `signing_key.Normal` with fixed bytes; set the
  counter field to the desired start index.

Swift mirrors the same fixed state through its internal deterministic
seams (`OlmSession.createOutbound(..., ephemeral:firstRatchet:)`,
`MegolmSession.createDeterministic(counter:parts:ed25519PrivateKey:)`).
Byte-identical output on both sides is the proof; commit the resulting
JSON so CI stays hermetic.

## History

Building this harness caught three real divergences in `MatrixKitCrypto`
that self-round-trip tests could not (see commit `ecbb77d`): the pre-key
shape (inner carries its own MAC, outer carries none), the setup KDF info
string (`OLM_ROOT`, not `OLM_RATCHET`), and chaining the previous root
key as the DH-ratchet HKDF salt.
