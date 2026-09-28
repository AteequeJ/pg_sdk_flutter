group = "com.pgsdk.flutter"
version = "0.1.0"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        // The native SDK (com.pgsdk:paymentsdk) is published here by
        // scripts/sync_native.sh until it's on a hosted Maven repo. Apps using
        // this plugin must add the same repository — see README.
        mavenLocal {
            content { includeGroup("com.pgsdk") }
        }
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.pgsdk.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    // `api` so host apps can reference SDK types (e.g. PGDebugInterceptor) natively.
    api("com.pgsdk:paymentsdk:1.0.0")
}
