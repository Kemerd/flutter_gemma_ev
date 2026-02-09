// Auto-provision JDK from Adoptium (Eclipse Temurin) if not available locally.
// This allows building on machines that only have a JRE or an older JDK.
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}

rootProject.name = "litertlm-server"
