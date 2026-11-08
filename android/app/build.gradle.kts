import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")

    // Google 服务（FCM 的 Android 侧）。**`apply false`** —— 真正应用它
    // 的是下面那段判断。`plugins {}` 块里的接收者是 `PluginDependenciesSpec`
    // 而不是 `Project`，所以 `file()` / `logger` 在那里都不存在，条件
    // 只能写在外面。
    id("com.google.gms.google-services") apply false
}

// 只在仓库里真的有 `google-services.json` 时才应用 Google 服务插件。
//
// 那个插件在缺配置文件时会**硬构建失败**（"File google-services.json is
// missing"），而「还没去 Firebase 建项目」是绝大多数人第一次 clone 下来
// 的状态 —— 让他们连调试包都编不出来，就等于把一个可选功能变成了整个
// 工程的前置条件。
//
// 检测写在脚本里（不是 `plugins {}` 块里），所以它对任何一次构建都生效：
// `flutter run`、`flutter build`、IDE 里点运行，走的都是同一条配置阶段。
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.lifecycle(
        "android/app/google-services.json 不存在 —— 本次构建跳过 Google 服务插件，" +
            "没有 FCM 推送。要启用：去 Firebase 建项目、把该文件下载到 " +
            "android/app/ 下，然后重新构建。"
    )
}

// Android release 签名：密钥路径与口令只在 `android/key.properties` 里，
// 该文件与 `*.jks` 都已被 `android/.gitignore` 忽略 —— 仓库里不出现任何秘密。
//
// 没有这个文件时（CI、新 clone 的机器、没有备份密钥的贡献者）回退到 debug
// 签名：本地 `flutter run --release` 照样能跑，但**对外分发的包必须**由正式
// 密钥签出，否则以后换正式签名时用户只能卸载重装。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.zenkee.cirromail"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // `flutter_local_notifications` 用到了 java.time（Android 8 之前没有），
        // 必须在**应用模块**打开脱糖 —— 这个开关不会从插件那边继承过来，
        // 少了它整包直接构建失败（报的是一句很不好懂的错误）。
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // 包名一旦发布就不能再改（改包名 = 另一个应用，升级装不上），
        // 同时它必须与 Firebase 控制台里「添加 Android 应用」填的那个**一字不差**。
        applicationId = "com.zenkee.cirromail"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 有正式密钥就用它；缺 `key.properties` 时回退 debug（只适合本地调试）。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // Firebase BoM 只有在 Google 服务插件生效时才需要 —— 但 `firebase_core`
    // 的 Flutter 插件自己就会带上传传递依赖，所以这里**不加**任何东西。
    // （加了反而会出现两套 Firebase 版本被 BoM 覆盖的怪问题。）
}
