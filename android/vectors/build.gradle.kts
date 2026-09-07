// Proof of crypto compatibility: compiles the app module's Crypto.kt on a plain JVM and
// prints the same vectors. Crypto.kt deliberately uses no Android API, which is what makes
// this possible. The same trick gives the app's Android-free logic a plain JVM test suite
// (src/test): `./gradlew :vectors:test`.
plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

kotlin { jvmToolchain(25) }

sourceSets["main"].java.srcDirs("src/main/kotlin", "../app/src/main/kotlin")

kotlin {
    sourceSets["main"].kotlin.setSrcDirs(listOf("src/main/kotlin", "../app/src/main/kotlin"))
    sourceSets["main"].kotlin.include(
        "dev/andromac/vectors/**",
        "dev/andromac/core/Crypto.kt",
        // For the handshake test. These three files deliberately use no Android API.
        "dev/andromac/core/Session.kt",
        "dev/andromac/core/Protocol.kt",
        // Receiver-side file name rules (PROTOCOL §5), pure Kotlin.
        "dev/andromac/core/FileNames.kt",
        // Unit-tested here: version ordering and the release lookup, both Android-free.
        "dev/andromac/core/Version.kt",
        "dev/andromac/feature/UpdateCheck.kt",
    )
}

dependencies {
    // Session.kt uses org.json; it ships with the Android platform but not with a plain JVM.
    implementation("org.json:json:20260814")
    testImplementation(kotlin("test"))
}

tasks.test { useJUnitPlatform() }

application { mainClass.set("dev.andromac.vectors.MainKt") }

tasks.named<JavaExec>("run") { standardOutput = System.out }
