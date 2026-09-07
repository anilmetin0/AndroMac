package dev.andromac.vectors

import dev.andromac.core.Crypto
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec

/**
 * Must print EXACTLY the same lines as `andromac-selftest` on macOS.
 * `./verify-crypto.sh` diffs the two. A mismatch means a handshake that fails silently on
 * a real device.
 *
 * Run with: ./gradlew -q :vectors:run
 */

/** Deriving a public key from a P-256 scalar is awkward in the JCE, so we hard-code the
 *  values Swift produced and verify that Kotlin DECODES AND RE-ENCODES them identically. */
internal const val PUB1_HEX =
    "040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed" +
        "194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794"
internal const val PUB2_HEX =
    "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf3" +
        "50185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285"

private val params: ECParameterSpec = AlgorithmParameters.getInstance("EC").run {
    init(ECGenParameterSpec("secp256r1"))
    getParameterSpec(ECParameterSpec::class.java)
}

internal fun privateFromScalar(scalar: ByteArray): PrivateKey =
    KeyFactory.getInstance("EC")
        .generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), params))

internal fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
internal fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
private fun line(name: String, b: ByteArray) = println("$name=${hex(b)}")

fun main(args: Array<String>) {
    if (args.getOrNull(0) == "handshake") {
        runHandshakeClient(args.getOrElse(1) { "127.0.0.1" }, args[2].toInt())
        return
    }

    val sk1 = ByteArray(32) { 0x11 }
    val sk2 = ByteArray(32) { 0x22 }
    val k1 = privateFromScalar(sk1)
    val k2 = privateFromScalar(sk2)

    // The decode -> encode round trip proves compatibility with Swift's x963 layout
    val pub1 = Crypto.encodePublic(Crypto.decodePublic(unhex(PUB1_HEX)))
    val pub2 = Crypto.encodePublic(Crypto.decodePublic(unhex(PUB2_HEX)))
    line("pub1", pub1)
    line("pub2", pub2)

    line("ecdh12", Crypto.ecdh(k1, Crypto.decodePublic(pub2)))
    line("ecdh21", Crypto.ecdh(k2, Crypto.decodePublic(pub1)))

    val salt = Crypto.sha256("salt".toByteArray(Charsets.UTF_8))
    val ikm = ByteArray(96) { it.toByte() }
    line("hkdf_a2b", Crypto.hkdf(salt, ikm, "AndroMac a2b", 32))
    line("hkdf_b2a", Crypto.hkdf(salt, ikm, "AndroMac b2a", 32))

    line("nonce0", Crypto.nonce(0))
    line("nonce_big", Crypto.nonce(1_234_567_890))

    val key = ByteArray(32) { it.toByte() }
    val sealed = Crypto.seal(key, 7, "merhaba dünya".toByteArray(Charsets.UTF_8))
    line("gcm_seal", sealed)
    line("gcm_open", Crypto.open(key, 7, sealed))

    val a = ByteArray(65) { (it * 7 + 3).toByte() }
    val b = ByteArray(65) { (it * 11 + 5).toByte() }
    val fixedTranscript = ByteArray(32) { 0x01 }
    val nA = ByteArray(32) { 0x02 }
    val nB = ByteArray(32) { 0x03 }
    line("transcript", Crypto.sha256("AndroMac/v3".toByteArray(Charsets.UTF_8), a, b, b, a, Crypto.commit(nB)))
    line("commit", Crypto.commit(nB))
    println("sas=${Crypto.sas(fixedTranscript, nA, nB)}")
}
