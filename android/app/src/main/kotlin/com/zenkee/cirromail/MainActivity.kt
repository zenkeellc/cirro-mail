package com.zenkee.cirromail

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * 注册应用图标角标通道。
     *
     * 为什么是 `configureFlutterEngine`：这里能拿到**当前这个引擎**的
     * binaryMessenger，通道跟着引擎生命周期走；写在 `onCreate` 里会拿到
     * 空引擎或重复注册，写在 Dart 侧轮询更没必要。
     *
     * 通道协议与 Dart 侧 `lib/core/notify/icon_badge.dart` 逐字一致：
     * 名字 `com.zenkee.cirromail/badge`，方法 `setBadge`，参数
     * `map {"count": int}`，`count <= 0` 表示清除。另外三端（macOS /
     * Windows / Linux）注册的是同一个名字，改通道名要五处一起改。
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BADGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBadge" -> {
                    // 参数缺失/类型不对时按 0（清除）处理：角标是装饰，
                    // 不值得为一次参数异常让 Dart 侧拿到 error。
                    val count = call.argument<Number>("count")?.toInt() ?: 0
                    // 真正的 launcher 协议调用在 AppIconBadge 内部的后台线程
                    // 上跑（详见该文件），这里立刻回，不占 UI 线程。
                    AppIconBadge.setBadge(applicationContext, count)
                    result.success(null)
                }
                // 旧构建 / 其他平台多出来的方法：明确告诉 Dart 侧不支持，
                // Dart 侧 catch 后静默跳过（见 IconBadge.set 的注释）。
                else -> result.notImplemented()
            }
        }
    }

    private companion object {
        /** 与 Dart 侧 `IconBadge.channelName` 逐字一致。 */
        const val BADGE_CHANNEL = "com.zenkee.cirromail/badge"
    }
}
