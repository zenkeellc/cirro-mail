package com.zenkee.cirromail

import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import java.util.concurrent.Executors

/**
 * 应用图标上的未读数字角标 —— Android 侧的 best-effort 实现。
 *
 * ## 为什么没有「调一次就全都生效」的 API
 *
 * 原生 Android 至今**没有公开的数字角标 API**（[android.app.Notification.Builder.setNumber]
 * 只是给通知自己标个数字，图标上显不显示、显示成什么样由 launcher 说了算）。
 * 数字角标是各家 launcher 自己加的私货：华为/荣耀用广播，小米/OPPO 用
 * ContentProvider，三星/华硕/LG 用一条通用广播，索尼新老两套协议……没有任何
 * 一份官方文档，只能参考 ShortcutBadger（GitHub 上事实上的协议汇编）里 public
 * 的 action/extra/provider 名，挨个去试。这里**不直接引 ShortcutBadger 依赖**：
 * 我们只需要其中几家，而且那个库多年未更新，引进来反而多一层版本与维护面。
 *
 * 对某台设备来说，下面这些协议里只有它自带 launcher 的那条会生效，其余几条
 * 找不到接收者 / provider 时会抛异常 —— 全部单独 catch，静默跳过。
 *
 * ## 局限（如实写在这里，别指望它像 iOS 那样稳定）
 *
 * - **Google 系 launcher（Pixel Launcher / Launcher3 及大量第三方 launcher）
 *   只显示「有通知」的小圆点，不接受任何第三方传进来的数字。** 而且那个点
 *   通常要求真有通知存在 —— 本实现坚持**不 post 通知**，所以这些设备上连点
 *   都不会有。这是有意的取舍：宁可没有角标，也不往通知栏里塞用户清不掉的
 *   「垃圾通知」。
 * - 华为/荣耀这条用的是**老协议广播**（EMUI 早期 / 部分 Honor 机型认）；
 *   新系统上华为改成了 launcher 私有 settings provider，本实现没有走那条路
 *   （要额外声明华为 launcher 的私有权限，收益只在一个厂商），广播没人收就
 *   静默跳过。荣耀 MagicOS 是否还响应这个 action 同样没有保证。
 * - 三星：老 TouchWiz 走通用广播，新 One UI 走 `content://com.sec.badge/apps`
 *   私有 provider（需要 READ/WRITE 权限）。本实现两条都没做 —— 三星用户在
 *   大多数新机型上**看不到数字角标**，静默跳过。
 * - 魅族等厂商没有稳定公开协议，未覆盖，静默跳过。
 * - 即使协议调用成功，用户也可能在 launcher 设置里关掉了角标 —— 系统行为，
 *   App 侧探测不到，只能接受。
 */
internal object AppIconBadge {
    private const val TAG = "AppIconBadge"

    // 华为 / 荣耀老协议的广播 action 与 extra key（ShortcutBadger 的
    // HuaweiHomeBadger 老版本口径）。
    private const val HUAWEI_ACTION = "com.huawei.android.launcher.action.CHANGE_BADGE"
    private const val HUAWEI_EXTRA_COMPONENT = "com.huawei.android.launcher.extra.COMPONENT"
    private const val HUAWEI_EXTRA_COUNTER = "com.huawei.android.launcher.extra.COUNTER"

    // 小米 MIUI 的广播协议（ShortcutBadger 的 XiaomiHomeBadger）。
    private const val XIAOMI_ACTION = "android.intent.action.APPLICATION_MESSAGE_UPDATE"
    private const val XIAOMI_EXTRA_COMPONENT = "android.intent.extra.update_application_component_name"
    private const val XIAOMI_EXTRA_MESSAGE = "android.intent.extra.update_application_message_text"

    // 通用角标广播。ShortcutBadger 里 ASUS / LG / 部分老 TouchWiz 都吃这一条，
    // 但**不是三星的现行协议**：三星新系统走 `content://com.sec.badge/apps`
    // 的私有 provider（要 READ/WRITE 权限），这条广播在 One UI 上大概率没人
    // 响应。保留它是因为对 ASUS/LG 等机型仍然是有效的，且发一条无人接收的
    // 广播没有副作用。
    private const val BADGE_COUNT_ACTION = "android.intent.action.BADGE_COUNT_UPDATE"

    // 索尼老 Xperia 的广播协议。
    private const val SONY_LEGACY_ACTION = "com.sonyericsson.home.action.UPDATE_BADGE"
    private const val SONY_LEGACY_PACKAGE = "com.sonyericsson.home.intent.extra.badge.PACKAGE_NAME"
    private const val SONY_LEGACY_ACTIVITY = "com.sonyericsson.home.intent.extra.badge.ACTIVITY_NAME"
    private const val SONY_LEGACY_MESSAGE = "com.sonyericsson.home.intent.extra.badge.MESSAGE"
    private const val SONY_LEGACY_SHOW = "com.sonyericsson.home.intent.extra.badge.SHOW_MESSAGE"

    // vivo（OriginOS / Funtouch）的广播协议。
    private const val VIVO_ACTION = "launcher.action.CHANGE_APPLICATION_NOTIFICATION_NUM"

    /**
     * 单线程串行：连续几次未读数变化按顺序落地，避免「先清后设」被乱序打断。
     * 守护线程，进程退出时不需要等它。
     */
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "app-icon-badge").apply { isDaemon = true }
    }

    /**
     * 设置图标角标；[count] <= 0 表示清除。
     *
     * 立即返回：真正的广播/跨进程调用丢到上面的后台线程。任何异常都在内部
     * 吞掉 —— 这个方法是 MethodChannel 的落点，抛出去就是一次用户可见的
     * 崩溃，而角标只是装饰。
     */
    fun setBadge(context: Context, count: Int) {
        // 用 applicationContext：launcher 的协议调用不依赖任何 Activity，
        // 而通道回调可能发生在 Activity 已销毁之后。
        val appContext = context.applicationContext
        val value = count.coerceAtLeast(0)
        try {
            executor.execute {
                try {
                    applyBadge(appContext, value)
                } catch (e: Throwable) {
                    // 兜底：单个协议已在下面各自 catch，这里是「连组件解析都
                    // 失败了」的最后一层，绝不能让异常逃出线程池。
                    Log.w(TAG, "设置图标角标失败（忽略）", e)
                }
            }
        } catch (e: Throwable) {
            // 线程池都塞不进去（理论上不会）也算失败，静默。
            Log.w(TAG, "图标角标任务入队失败（忽略）", e)
        }
    }

    private fun applyBadge(context: Context, value: Int) {
        val component = launcherComponent(context)

        // 各家协议互相独立。一台设备上通常只有其中一家的 launcher 会接住，
        // 其余几条找不到接收者/provider 会抛异常 —— 分别 catch，互不牵连。
        tryOrIgnore("华为/荣耀") { setHuaweiBadge(context, component, value) }
        tryOrIgnore("小米") { setXiaomiBadge(context, component, value) }
        tryOrIgnore("三星/华硕/LG") { setBadgeCountBroadcast(context, component, value) }
        tryOrIgnore("索尼") { setSonyBadge(context, component, value) }
        tryOrIgnore("vivo") { setVivoBadge(context, component, value) }
    }

    /**
     * 取「launcher 图标所指向的 activity」——三星、索尼、小米等协议都要
     * 包名 + activity 类名这一对。
     *
     * 正常情况下就是 Manifest 里带 MAIN/LAUNCHER 的 MainActivity；拿不到
     * launch intent 时（几乎不可能，但 PackageManager 有各种边角状态）退回
     * 硬编码的类名，保证后面几条协议至少能发出一个格式正确的广播。
     */
    private fun launcherComponent(context: Context): ComponentName {
        val packageName = context.packageName
        val className = try {
            context.packageManager.getLaunchIntentForPackage(packageName)?.component?.className
        } catch (e: Throwable) {
            null
        } ?: "$packageName.MainActivity"
        return ComponentName(packageName, className)
    }

    /**
     * 华为 / 荣耀（EMUI / MagicOS）老协议：一条发往 launcher 的广播。
     *
     * action 与 extra key 来自 ShortcutBadger 的 HuaweiHomeBadger 旧实现；
     * 新系统上华为改成私有 provider，这条广播可能没人收 —— 静默跳过。
     */
    private fun setHuaweiBadge(context: Context, component: ComponentName, count: Int) {
        sendVendorBroadcast(
            context,
            Intent(HUAWEI_ACTION).apply {
                putExtra(HUAWEI_EXTRA_COMPONENT, component.flattenToShortString())
                putExtra(HUAWEI_EXTRA_COUNTER, count)
            },
        )
    }

    /**
     * 小米 / Redmi（MIUI / HyperOS）。
     *
     * 主力是 MIUI launcher 的 provider：`app_badge_count` 传 0 即清除。
     * 再补一条 ShortcutBadger 里 XiaomiHomeBadger 用的广播 —— 不同 MIUI
     * 版本认的不一样，两条都发，接住哪条算哪条。
     */
    private fun setXiaomiBadge(context: Context, component: ComponentName, count: Int) {
        // provider 单独 catch：非小米设备上它必然不存在（抛
        // IllegalArgumentException），但不能因此把后面那条广播也跳过。
        runCatching {
            val extra = Bundle().apply { putInt("app_badge_count", count) }
            context.contentResolver.call(
                Uri.parse("content://com.android.badge/badge"),
                "setAppBadgeCount",
                null,
                extra,
            )
        }

        sendVendorBroadcast(
            context,
            Intent(XIAOMI_ACTION).apply {
                // 广播里的 count 是**字符串**，0 传空串（ShortcutBadger 就是这么做的）。
                putExtra(
                    XIAOMI_EXTRA_COMPONENT,
                    "${component.packageName}/${component.className}",
                )
                putExtra(XIAOMI_EXTRA_MESSAGE, if (count == 0) "" else count.toString())
            },
        )
    }

    /**
     * 三星（TouchWiz / One UI）、华硕 ZenUI、LG 等共用的一条通用广播。
     *
     * key 名来自 ShortcutBadger 的 IntentConstants / SamsungHomeBadger。新
     * One UI 对第三方数字角标收紧了很多，部分机型上这条广播已无效 —— 只能
     * 静默接受。
     */
    private fun setBadgeCountBroadcast(context: Context, component: ComponentName, count: Int) {
        sendVendorBroadcast(
            context,
            Intent(BADGE_COUNT_ACTION).apply {
                putExtra("badge_count", count)
                putExtra("badge_count_package_name", context.packageName)
                putExtra("badge_count_class_name", component.className)
            },
        )
    }

    /**
     * 索尼（Xperia Home）。新老两套协议都试：
     *
     * - 老 Xperia：`com.sonyericsson.home.action.UPDATE_BADGE` 广播，需要
     *   Manifest 里的 `BROADCAST_BADGE` 权限；
     * - 新机型：往 `com.sonymobile.home.resourceprovider` 的 badge 表 insert
     *   一行，需要 `PROVIDER_INSERT_BADGE` 权限（见 AndroidManifest.xml）。
     *   没权限就是 SecurityException，被外层 catch 吞掉。
     */
    private fun setSonyBadge(context: Context, component: ComponentName, count: Int) {
        // 先发老广播：万一 provider insert 抛异常，至少广播已经出去了。
        sendVendorBroadcast(
            context,
            Intent(SONY_LEGACY_ACTION).apply {
                putExtra(SONY_LEGACY_PACKAGE, context.packageName)
                putExtra(SONY_LEGACY_ACTIVITY, component.className)
                putExtra(SONY_LEGACY_SHOW, count > 0)
                putExtra(SONY_LEGACY_MESSAGE, count.toString())
            },
        )

        // 新机型：provider 里一行就代表一个图标角标。
        val values = ContentValues().apply {
            put("badge_count", count)
            put("package_name", context.packageName)
            put("activity_name", component.className)
        }
        context.contentResolver.insert(
            Uri.parse("content://com.sonymobile.home.resourceprovider/badge"),
            values,
        )
    }

    /**
     * vivo（Funtouch / OriginOS）的 launcher 广播。
     *
     * action 与 extra 名来自 ShortcutBadger 的 VivoHomeBadger，只对 vivo 自带
     * launcher 有效，其它设备上是一条无人接收的广播。
     */
    private fun setVivoBadge(context: Context, component: ComponentName, count: Int) {
        sendVendorBroadcast(
            context,
            Intent(VIVO_ACTION).apply {
                putExtra("packageName", context.packageName)
                putExtra("className", component.className)
                putExtra("notificationNum", count)
            },
        )
    }

    /**
     * 发一条厂商角标广播。
     *
     * 不能只 `sendBroadcast(intent)`：Android 8.0 起，隐式广播不会被投递到
     * 其它 App 的 manifest receiver，而各家 launcher 的角标接收器正是这么
     * 注册的 —— 隐式发出去在 O+ 上大概率「发出去了但没人收到」。
     * ShortcutBadger 的 `BroadcastHelper.sendIntentExplicitly` 的做法是：
     * 先 `queryBroadcastReceivers` 看这条 action 有谁在收，查到就逐个
     * `setPackage()` 发显式广播，一个都查不到再退回隐式。
     *
     * 查不到时为什么还退回隐式：Android 11+ 的包可见性（没有 `<queries>`
     * 声明时）会让 query 返回空，而广播本身并没有被限制；这时退回隐式是
     * 唯一还能到达的路径，且与改动前行为一致，不会更糟。
     */
    private fun sendVendorBroadcast(context: Context, intent: Intent) {
        val receivers = try {
            context.packageManager.queryBroadcastReceivers(intent, 0)
        } catch (e: Throwable) {
            null
        }
        if (receivers.isNullOrEmpty()) {
            context.sendBroadcast(intent)
            return
        }
        for (receiver in receivers) {
            val packageName = receiver.activityInfo?.packageName ?: continue
            try {
                context.sendBroadcast(Intent(intent).setPackage(packageName))
            } catch (e: Throwable) {
                // 单个接收方失败不影响其它家（反正通常也只有一家会接）。
                Log.d(TAG, "角标广播到 $packageName 失败：${e.javaClass.simpleName}")
            }
        }
    }

    private inline fun tryOrIgnore(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) {
            // 设备上没装对应 launcher 时这里大多是 IllegalArgumentException /
            // SecurityException / ActivityNotFoundException，属正常路径。
            Log.d(TAG, "$name 角标协议不可用：${e.javaClass.simpleName}")
        }
    }
}
