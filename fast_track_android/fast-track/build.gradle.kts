plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
    id("maven-publish")
}

group = "com.wenrai"
version = (findProperty("fastTrackVersion") as String?) ?: "1.0.1"

android {
    namespace = "com.fasttrack.sdk"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    // Exposed transitively via POM so hosts resolve Room / OkHttp at runtime
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    api("androidx.room:room-runtime:2.6.1")
    api("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
    api("com.squareup.okhttp3:okhttp:4.12.0")
    api("androidx.lifecycle:lifecycle-process:2.7.0")
    api("androidx.lifecycle:lifecycle-common-java8:2.7.0")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.wenrai"
                artifactId = "fast-track"
                version = project.version.toString()

                pom {
                    name.set("Wenrai Fast Track")
                    description.set(
                        "Android analytics SDK (track / page_view / crash / network) for RCStars Track platform"
                    )
                    licenses {
                        license {
                            name.set("Proprietary")
                        }
                    }
                }
            }
        }

        repositories {
            mavenLocal()

            val publishDir = findProperty("fastTrackPublishDir") as String?
            if (!publishDir.isNullOrBlank()) {
                maven {
                    name = "ProjectRepo"
                    url = uri(rootProject.file(publishDir))
                }
            }

            val remoteUrl = findProperty("fastTrackMavenUrl") as String?
            if (!remoteUrl.isNullOrBlank()) {
                maven {
                    name = "RemoteTrack"
                    url = uri(remoteUrl)
                    isAllowInsecureProtocol = remoteUrl.startsWith("http://")
                    credentials {
                        username = (findProperty("fastTrackMavenUser") as String?) ?: ""
                        password = (findProperty("fastTrackMavenPassword") as String?) ?: ""
                    }
                }
            }
        }
    }
}
