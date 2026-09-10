//! Dev-only vodozemac oracle for MatrixKitCrypto interop (Tier B).
//!
//! JSON-line protocol over stdin/stdout. Each line: `{"cmd": ..., ...}`.
//! Replies: `{"ok": ...}` or `{"error": "..."}`.
//!
//! State (accounts, sessions) crosses the boundary as vodozemac pickle
//! JSON values; message bodies cross as base64 wire bytes.

use std::io::{BufRead, Write};
use vodozemac::megolm::{
    GroupSession, GroupSessionPickle, InboundGroupSession, InboundGroupSessionPickle,
    MegolmMessage, SessionConfig as MegolmConfig, SessionKey,
};
use vodozemac::olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle};
use vodozemac::Curve25519PublicKey;
use x25519_dalek::{PublicKey as XPublic, StaticSecret};

fn raw32(bytes: Vec<u8>, name: &str) -> Result<[u8; 32], String> {
    bytes
        .try_into()
        .map_err(|_| format!("{name} must be 32 bytes"))
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> Vec<u8> {
    use hmac::Mac;
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(key).expect("hmac key");
    mac.update(msg);
    mac.finalize().into_bytes().to_vec()
}

fn main() {
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let line = line.expect("stdin read");
        if line.trim().is_empty() {
            continue;
        }
        let reply = dispatch(&line);
        println!("{}", reply);
        std::io::stdout().flush().expect("stdout flush");
    }
}

fn get<'a>(req: &'a serde_json::Value, key: &str) -> Result<&'a serde_json::Value, String> {
    req.get(key).ok_or_else(|| format!("missing {key}"))
}

fn str_field(req: &serde_json::Value, key: &str) -> Result<String, String> {
    get(req, key)?
        .as_str()
        .map(|s| s.to_owned())
        .ok_or_else(|| format!("{key} not a string"))
}

fn b64(key_bytes: &[u8]) -> String {
    // vodozemac key types already emit base64; raw bytes use std.
    // (Only used for plaintext echoes; kept minimal.)
    base64_encode(key_bytes)
}

fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let mut n: u32 = 0;
        for (i, b) in chunk.iter().enumerate() {
            n |= (*b as u32) << (16 - 8 * i);
        }
        let pad = 3 - chunk.len();
        for i in 0..4 - pad {
            out.push(ALPHABET[((n >> (18 - 6 * i)) & 0x3F) as usize] as char);
        }
        for _ in 0..pad {
            out.push('=');
        }
    }
    out
}

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    let mut vals = Vec::new();
    for c in s.chars() {
        if c == '=' {
            break;
        }
        let v = match c {
            'A'..='Z' => c as u8 - b'A',
            'a'..='z' => c as u8 - b'a' + 26,
            '0'..='9' => c as u8 - b'0' + 52,
            '+' => 62,
            '/' => 63,
            _ => return Err(format!("bad base64 char {c}")),
        };
        vals.push(v);
    }
    let mut out = Vec::new();
    for chunk in vals.chunks(4) {
        let mut n: u32 = 0;
        for (i, v) in chunk.iter().enumerate() {
            n |= (*v as u32) << (18 - 6 * i);
        }
        for i in 0..chunk.len() - 1 {
            out.push(((n >> (16 - 8 * i)) & 0xFF) as u8);
        }
    }
    Ok(out)
}

fn curve_key(s: &str) -> Result<Curve25519PublicKey, String> {
    Curve25519PublicKey::from_base64(s).map_err(|e| format!("bad key: {e}"))
}

fn account_of(req: &serde_json::Value) -> Result<Account, String> {
    let pickle: AccountPickle = serde_json::from_value(get(req, "account_pickle")?.clone())
        .map_err(|e| format!("bad account pickle: {e}"))?;
    Ok(Account::from_pickle(pickle))
}

fn session_of(req: &serde_json::Value) -> Result<Session, String> {
    let pickle: SessionPickle = serde_json::from_value(get(req, "session_pickle")?.clone())
        .map_err(|e| format!("bad session pickle: {e}"))?;
    Ok(Session::from_pickle(pickle))
}

fn session_json(session: &Session) -> serde_json::Value {
    serde_json::to_value(session.pickle()).expect("session pickle")
}

fn group_of(req: &serde_json::Value) -> Result<GroupSession, String> {
    let pickle: GroupSessionPickle = serde_json::from_value(get(req, "group_pickle")?.clone())
        .map_err(|e| format!("bad group pickle: {e}"))?;
    Ok(GroupSession::from_pickle(pickle))
}

fn inbound_of(req: &serde_json::Value) -> Result<InboundGroupSession, String> {
    let pickle: InboundGroupSessionPickle =
        serde_json::from_value(get(req, "inbound_pickle")?.clone())
            .map_err(|e| format!("bad inbound pickle: {e}"))?;
    Ok(InboundGroupSession::from_pickle(pickle))
}

fn dispatch(line: &str) -> String {
    let req: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => return err(&format!("bad json: {e}")),
    };
    let cmd = req.get("cmd").and_then(|c| c.as_str()).unwrap_or("");
    let result = handle(&req);
    match result {
        Ok(v) => ok(&v),
        Err(e) => err(&e),
    }
}

fn handle(req: &serde_json::Value) -> Result<serde_json::Value, String> {
    let cmd = req.get("cmd").and_then(|c| c.as_str()).unwrap_or("");
    match cmd {
        // Fresh account + one one-time key.
        "olm-account" => {
            let mut account = Account::new();
            account.generate_one_time_keys(1);
            let keys = account.identity_keys();
            let otk = account
                .one_time_keys()
                .values()
                .next()
                .cloned()
                .ok_or("no one-time key")?;
            Ok(serde_json::json!({
                "curve25519": keys.curve25519.to_base64(),
                "ed25519": keys.ed25519.to_base64(),
                "one_time_key": otk.to_base64(),
                "account_pickle":
                    serde_json::to_value(account.pickle()).expect("pickle"),
            }))
        }
        // Debug: re-derive Bob-side TripleDH + root/chain/message keys
        // from fixed 32-byte private keys (base64). Both sides' S must
        // match; isolates exactly which KDF stage diverges from Swift.
        "olm-debug-kdf" => {
            let alice_id = StaticSecret::from(raw32(
                base64_decode(&str_field(&req, "alice_id_priv")?)?,
                "alice_id_priv",
            )?);
            let bob_id = StaticSecret::from(raw32(
                base64_decode(&str_field(&req, "bob_id_priv")?)?,
                "bob_id_priv",
            )?);
            let bob_otk = StaticSecret::from(raw32(
                base64_decode(&str_field(&req, "bob_otk_priv")?)?,
                "bob_otk_priv",
            )?);
            let alice_eph = StaticSecret::from(raw32(
                base64_decode(&str_field(&req, "alice_eph_priv")?)?,
                "alice_eph_priv",
            )?);
            let alice_id_pub = XPublic::from(&alice_id);
            let bob_id_pub = XPublic::from(&bob_id);
            let bob_otk_pub = XPublic::from(&bob_otk);
            let alice_eph_pub = XPublic::from(&alice_eph);
            // Bob: DH(EB,IA) ∥ DH(IB,EA) ∥ DH(EB,EA).
            let mut s_bob = Vec::new();
            s_bob.extend_from_slice(bob_otk.diffie_hellman(&alice_id_pub).to_bytes().as_ref());
            s_bob.extend_from_slice(bob_id.diffie_hellman(&alice_eph_pub).to_bytes().as_ref());
            s_bob.extend_from_slice(bob_otk.diffie_hellman(&alice_eph_pub).to_bytes().as_ref());
            // Alice cross-check: DH(IA,EB) ∥ DH(EA,IB) ∥ DH(EA,EB).
            let mut s_alice = Vec::new();
            s_alice.extend_from_slice(alice_id.diffie_hellman(&bob_otk_pub).to_bytes().as_ref());
            s_alice.extend_from_slice(alice_eph.diffie_hellman(&bob_id_pub).to_bytes().as_ref());
            s_alice.extend_from_slice(alice_eph.diffie_hellman(&bob_otk_pub).to_bytes().as_ref());
            // Root: HKDF(salt=[0], info=OLM_ROOT, 64) → R0 ∥ C0.
            let hk = hkdf::Hkdf::<sha2::Sha256>::new(Some(&[0u8]), &s_bob);
            let mut root = [0u8; 64];
            hk.expand(b"OLM_ROOT", &mut root)
                .map_err(|e| format!("hkdf root: {e}"))?;
            let (r0, c0) = (root[..32].to_vec(), root[32..].to_vec());
            // Message key + AES/HMAC/IV from C0.
            let m0 = hmac_sha256(&c0, &[0x01]);
            let hk2 = hkdf::Hkdf::<sha2::Sha256>::new(Some(&[0u8]), &m0);
            let mut keys = [0u8; 80];
            hk2.expand(b"OLM_KEYS", &mut keys)
                .map_err(|e| format!("hkdf keys: {e}"))?;
            Ok(serde_json::json!({
                "s_bob": base64_encode(&s_bob),
                "s_alice": base64_encode(&s_alice),
                "r0": base64_encode(&r0),
                "c0": base64_encode(&c0),
                "m0": base64_encode(&m0),
                "aes": base64_encode(&keys[..32]),
                "mac": base64_encode(&keys[32..64]),
                "iv": base64_encode(&keys[64..]),
            }))
        }
        // Debug: parse OUR pre-key bytes and re-encode. If the
        // round-trip differs from the input, prost parses different
        // values than Swift encoded (explains InvalidMAC).
        "olm-debug-parse" => {
            let body = base64_decode(&str_field(&req, "body")?)?;
            let msg = OlmMessage::from_parts(0, &body).map_err(|e| format!("parse: {e:?}"))?;
            let (_, bytes) = msg.to_parts();
            match msg {
                OlmMessage::PreKey(pre) => Ok(serde_json::json!({
                    "roundtrip": base64_encode(&bytes),
                    "roundtrip_ok": bytes == body,
                    "inner": base64_encode(&pre.to_bytes()),
                })),
                _ => Err("not a pre-key message".to_string()),
            }
        }
        // Outbound session from pickled account + peer keys.
        "olm-outbound" => {
            let mut account = account_of(&req)?;
            let peer_id = curve_key(&str_field(&req, "peer_identity")?)?;
            let peer_otk = curve_key(&str_field(&req, "peer_one_time")?)?;
            let session = account
                .create_outbound_session(SessionConfig::version_1(), peer_id, peer_otk)
                .map_err(|e| format!("outbound: {e}"))?;
            Ok(serde_json::json!({
                "session_pickle": session_json(&session),
                "account_pickle":
                    serde_json::to_value(account.pickle()).expect("pickle"),
            }))
        }
        // Encrypt with a pickled session. Returns wire type + body.
        "olm-encrypt" => {
            let mut session = session_of(&req)?;
            let plaintext = base64_decode(&str_field(&req, "plaintext")?)?;
            let msg = session
                .encrypt(&plaintext)
                .map_err(|e| format!("encrypt: {e}"))?;
            let (wire_type, raw) = msg.to_parts();
            Ok(serde_json::json!({
                "type": wire_type,
                "body": base64_encode(&raw),
                "session_pickle": session_json(&session),
            }))
        }
        // Inbound session from pickled account + pre-key body.
        "olm-inbound" => {
            let mut account = account_of(&req)?;
            let peer_id = curve_key(&str_field(&req, "peer_identity")?)?;
            let body = base64_decode(&str_field(&req, "body")?)?;
            let pre_key =
                match OlmMessage::from_parts(0, &body).map_err(|e| format!("parse: {e}"))? {
                    OlmMessage::PreKey(m) => m,
                    OlmMessage::Normal(_) => return Err("expected pre-key message".to_owned()),
                };
            let created = account
                .create_inbound_session(SessionConfig::version_1(), peer_id, &pre_key)
                .map_err(|e| format!("inbound: {e:?}"))?;
            Ok(serde_json::json!({
                "plaintext": b64(&created.plaintext),
                "session_pickle": session_json(&created.session),
                "account_pickle":
                    serde_json::to_value(account.pickle()).expect("pickle"),
            }))
        }
        // Decrypt with a pickled session.
        "olm-decrypt" => {
            let mut session = session_of(&req)?;
            let body = base64_decode(&str_field(&req, "body")?)?;
            let wire_type: usize = get(&req, "type")?.as_u64().ok_or("type not an int")? as usize;
            let msg =
                OlmMessage::from_parts(wire_type, &body).map_err(|e| format!("parse: {e}"))?;
            let plaintext = session.decrypt(&msg).map_err(|e| format!("decrypt: {e}"))?;
            Ok(serde_json::json!({
                "plaintext": b64(&plaintext),
                "session_pickle": session_json(&session),
            }))
        }
        // Megolm: fresh outbound group session.
        "megolm-create" => {
            let group = GroupSession::new(MegolmConfig::version_1());
            Ok(serde_json::json!({
                "group_pickle":
                    serde_json::to_value(group.pickle()).expect("pickle"),
                "session_key": base64_encode(&group.session_key().to_bytes()),
                "session_id": group.session_id(),
            }))
        }
        // Megolm: encrypt with a pickled outbound session.
        "megolm-encrypt" => {
            let mut group = group_of(&req)?;
            let plaintext = base64_decode(&str_field(&req, "plaintext")?)?;
            let msg = group.encrypt(&plaintext);
            Ok(serde_json::json!({
                "body": base64_encode(&msg.to_bytes()),
                "group_pickle":
                    serde_json::to_value(group.pickle()).expect("pickle"),
            }))
        }
        // Megolm: import a 229-byte session key (base64) as inbound.
        "megolm-import" => {
            let raw = base64_decode(&str_field(&req, "session_key")?)?;
            let key = SessionKey::from_bytes(&raw).map_err(|e| format!("bad session key: {e}"))?;
            let inbound = InboundGroupSession::new(&key, MegolmConfig::version_1());
            Ok(serde_json::json!({
                "inbound_pickle":
                    serde_json::to_value(inbound.pickle()).expect("pickle"),
                "session_id": inbound.session_id(),
            }))
        }
        // Megolm: decrypt with a pickled inbound session.
        "megolm-decrypt" => {
            let mut inbound = inbound_of(&req)?;
            let body = base64_decode(&str_field(&req, "body")?)?;
            let msg = MegolmMessage::from_bytes(&body).map_err(|e| format!("parse: {e}"))?;
            let decrypted = inbound.decrypt(&msg).map_err(|e| format!("decrypt: {e}"))?;
            Ok(serde_json::json!({
                "plaintext": b64(&decrypted.plaintext),
                "message_index": decrypted.message_index,
                "inbound_pickle":
                    serde_json::to_value(inbound.pickle()).expect("pickle"),
            }))
        }
        _ => Err(format!("unknown cmd: {cmd}")),
    }
}

fn ok(v: &serde_json::Value) -> String {
    serde_json::json!({"ok": v}).to_string()
}

fn err(msg: &str) -> String {
    serde_json::json!({"error": msg}).to_string()
}
