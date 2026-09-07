package dev.andromac.core

import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * P-256 ECDH + HKDF-SHA256 + AES-256-GCM. The counterpart of docs/PROTOCOL.md §2 and §4.
 * No third-party dependencies; everything here comes from the platform JCE.
 */
object Crypto {

    const val PUB_LEN = 65          // X9.62 uncompressed: 0x04 || X(32) || Y(32)
    private const val CURVE = "secp256r1"

    private val params: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").run {
            init(ECGenParameterSpec(CURVE))
            getParameterSpec(ECParameterSpec::class.java)
        }
    }

    fun generateKeyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec(CURVE), SecureRandom()) }
            .generateKeyPair()

    /** Public key -> 65-byte X9.62 uncompressed form. */
    fun encodePublic(key: PublicKey): ByteArray {
        val w = (key as ECPublicKey).w
        val out = ByteArray(PUB_LEN)
        out[0] = 0x04
        fixedWidth(w.affineX.toByteArray()).copyInto(out, 1)
        fixedWidth(w.affineY.toByteArray()).copyInto(out, 33)
        return out
    }

    /** 65-byte X9.62 -> PublicKey. Points that are not on the curve are rejected here. */
    fun decodePublic(bytes: ByteArray): PublicKey {
        require(bytes.size == PUB_LEN && bytes[0] == 0x04.toByte()) { "invalid P-256 public key" }
        val x = java.math.BigInteger(1, bytes.copyOfRange(1, 33))
        val y = java.math.BigInteger(1, bytes.copyOfRange(33, 65))
        // KeyFactory verifies that the point lies on the curve; an off-curve point throws InvalidKeySpecException.
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
    }

    fun encodePrivate(key: PrivateKey): ByteArray = key.encoded            // PKCS#8
    fun decodePrivate(bytes: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(bytes))

    fun ecdh(own: PrivateKey, peer: PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run { init(own); doPhase(peer, true); generateSecret() }

    fun sha256(vararg parts: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").apply { parts.forEach(::update) }.digest()

    fun hkdf(salt: ByteArray, ikm: ByteArray, info: String, len: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)                                          // Extract

        mac.init(SecretKeySpec(prk, "HmacSHA256"))                          // Expand
        val infoBytes = info.toByteArray(Charsets.UTF_8)
        val out = ByteArray(len)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < len) {
            mac.update(t); mac.update(infoBytes); mac.update(counter.toByte())
            t = mac.doFinal()
            val n = minOf(t.size, len - pos)
            t.copyInto(out, pos, 0, n)
            pos += n; counter++
        }
        return out
    }

    fun nonce(counter: Long): ByteArray {
        val n = ByteArray(12)
        for (i in 0 until 8) n[11 - i] = (counter ushr (8 * i)).toByte()    // 4 zero bytes + BE64 counter
        return n
    }

    fun seal(key: ByteArray, counter: Long, plaintext: ByteArray): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(counter)))
            doFinal(plaintext)
        }

    fun open(key: ByteArray, counter: Long, ciphertext: ByteArray): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(counter)))
            doFinal(ciphertext)
        }

    const val NONCE_LEN = 32        // n_A / n_B and the commitment c_B, PROTOCOL §2
    const val TAG_LEN = 16          // AES-GCM tag, appended to every ciphertext

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also(SecureRandom()::nextBytes)

    /** docs/PROTOCOL.md §2 — c_B = SHA256("AndroMac/commit" || n_B). */
    fun commit(nonce: ByteArray): ByteArray = sha256("AndroMac/commit".toByteArray(Charsets.UTF_8), nonce)

    /**
     * docs/PROTOCOL.md §3 — the 6 digits compared across the two screens. Bound to the
     * session transcript and both fresh nonces, so a MITM cannot grind the code offline.
     */
    fun sas(transcript: ByteArray, nA: ByteArray, nB: ByteArray): String {
        val h = sha256("AndroMac/SAS/v3".toByteArray(Charsets.UTF_8), transcript, nA, nB)
        var v = 0L
        for (i in 0 until 4) v = (v shl 8) or (h[i].toLong() and 0xff)
        return (v % 1_000_000L).toString().padStart(6, '0')
    }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    /** BigInteger.toByteArray() may prepend a sign byte or come back short; pin it to 32 bytes. */
    private fun fixedWidth(raw: ByteArray): ByteArray = when {
        raw.size == 32 -> raw
        raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
        else -> ByteArray(32).also { raw.copyInto(it, 32 - raw.size) }
    }
}
