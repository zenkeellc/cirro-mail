pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    // Google 服务插件。**这里必须写 `apply false`**：它由 `app` 模块按需应用，
    // 而应用的前提是仓库里有 `google-services.json`（见 app/build.gradle.kts
    // 开头那段）。声明在根上只是让版本号集中一处。
    //
    // 版本要跟 compileSdk 对得上：4.4.2 要求 AGP 8.x + compileSdk 34 以上，
    // 本工程是 AGP 8.11.1 / SDK 36，满足。
    id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")
