plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "app.asterion.veyra"
    compileSdk = 35
    defaultConfig { applicationId = "app.asterion.veyra"; minSdk = 26; targetSdk = 35; versionCode = 1; versionName = "0.1.0" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    buildTypes { release { isMinifyEnabled = false } }
}
dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
