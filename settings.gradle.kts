pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "smart-wear-sdk"

// BLE dùng chung cho mọi thiết bị.
include(":core")
project(":core").projectDir = file("sdks/core/android")

// Mỗi loại thiết bị là một SDK riêng: sdks/<device>/android
include(":qring")
project(":qring").projectDir = file("sdks/qring/android")

include(":gloryfit")
project(":gloryfit").projectDir = file("sdks/gloryfit/android")

include(":veepoo")
project(":veepoo").projectDir = file("sdks/veepoo/android")

include(":standard")
project(":standard").projectDir = file("sdks/standard/android")

// App SmartWear Lab
include(":app")
project(":app").projectDir = file("apps/android")
