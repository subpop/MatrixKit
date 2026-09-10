"""Reference vectors for `m.secret_storage.v1.aes-hmac-sha2`.

Transcribed literally from the Matrix client-server spec (Secrets >
Storage > Key storage / Secret storage), independent of the Swift
implementation. Regenerate with: python3 generate_ssss_vectors.py

Spec steps (both sections):
  1. HKDF-SHA-256(ikm=storage key, salt=32 zero bytes, info=name)
     -> 64 bytes; first 32 = AES key, next 32 = MAC key.
     (Key checks use the empty string as the name.)
  2. IV is 16 random bytes with bit 63 cleared; used directly as the
     AES-CTR counter block.
  3. AES-CTR-256 encrypt (32 zero bytes for key checks).
  4. HMAC-SHA-256 over the raw ciphertext.
"""

import base64
import hashlib
import hmac

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac.new(
            prk, block + info + bytes([counter]), hashlib.sha256
        ).digest()
        okm += block
        counter += 1
    return okm[:length]


def derive(storage_key: bytes, name: str) -> tuple[bytes, bytes]:
    okm = hkdf_sha256(storage_key, bytes(32), name.encode("utf-8"), 64)
    return okm[:32], okm[32:]


def ctr(key: bytes, iv: bytes, data: bytes) -> bytes:
    encryptor = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    return encryptor.update(data) + encryptor.finalize()


def b64e(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii").rstrip("=")


def main() -> None:
    storage_key = bytes(range(1, 33))

    check_iv = bytes(range(1, 17))
    check_aes, check_hmac = derive(storage_key, "")
    check_mac = hmac.new(
        check_hmac, ctr(check_aes, check_iv, bytes(32)), hashlib.sha256
    ).digest()

    secret_iv = bytes(range(0x11, 0x21))
    secret_aes, secret_hmac = derive(storage_key, "m.cross_signing.master")
    plaintext = bytes(range(0xA0, 0xC0))
    ciphertext = ctr(secret_aes, secret_iv, plaintext)
    secret_mac = hmac.new(secret_hmac, ciphertext, hashlib.sha256).digest()

    print(f"check_iv    = {b64e(check_iv)}")
    print(f"check_mac   = {b64e(check_mac)}")
    print(f"secret_iv   = {b64e(secret_iv)}")
    print(f"ciphertext  = {b64e(ciphertext)}")
    print(f"secret_mac  = {b64e(secret_mac)}")


if __name__ == "__main__":
    main()
