plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.smartwear.lab"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.smartwear.lab"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    // Mô hình 3D Y25 dùng chung với iOS (apps/shared/watch3d) → assets "watch3d/…".
    sourceSets["main"].assets.srcDirs("src/main/assets", "../shared")
}

dependencies {
    implementation(project(":core"))
    implementation(project(":qring"))
    implementation(project(":gloryfit"))
    implementation(project(":veepoo"))
    implementation(project(":standard"))

    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    // WebViewAssetLoader: phục vụ assets qua https để <script type="module"> của mô hình 3D chạy được.
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    // Chụp ảnh từ xa (RemoteCameraActivity).
    val camerax = "1.4.1"
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
