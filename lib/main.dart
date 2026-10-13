import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'core/db/core_mail_store.dart';
import 'core/extensions.dart';
import 'core/theme/app_theme.dart';
import 'features/notifications/background_sync_task.dart';
import 'features/notifications/push_service.dart';
import 'providers/core_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 扩展注册。清单在 `core/extensions.dart` —— **公开版它是空的**，
  // 商业版把那一个常量换成自己的扩展。
  //
  // 为什么不直接写在这行里：后台 isolate 跑的是另一个引擎、**不执行
  // `main()`**，它也要读到同一份清单（见 `background_sync_task.dart` 的入口）。
  // 抽出那个常量之后两个入口共用一份事实来源，副作用是**这个文件两个检出
  // 逐字节相同** —— 以后公开版与商业版合并时它永远不会冲突。
  //
  // 放在最前面（早于下面的后台任务登记、早于 `runApp`）：注册本身是纯内存
  // 写入，而 `bootstrapAll` 会在下面被调用 —— 顺序反了扩展就收不到启动钩子。
  AppExtensionRegistry.instance.registerAll(kAppExtensions);
  // **不 await**：扩展初始化不该拖慢首帧（见 `AppExtension.onBootstrap`）。
  //
  // 这里**还没轮到**挂本地邮件读取口：库要到 `bootstrap()` 里才建（那是一段
  // 异步流程，第一帧才跑），所以扩展在这个时刻 `mailStore` 必然是 null。
  // 要用它的扩展去等 `AppExtensionRegistry.instance.mailStoreReady`，
  // 别在这里想办法提前挂。
  AppExtensionRegistry.instance.bootstrapAll();

  // 后台任务的入口句柄要在进程一开始就登记好（平台侧要用它来唤醒后台
  // isolate），所以放在 `runApp` 之前，而不是等 UI 挂上。
  //
  // **不 await**：`initialize` 是一次平台通道调用，等它会把首帧往后推，
  // 而首帧并不依赖它的结果。真正的注册在 `NotificationHost` 里做，
  // 那里会 `await` 同一个 Future（`_ensureEntrypoint` 缓存了它），
  // 所以不会有竞态。
  unawaited(BackgroundSyncTask.bootstrap());

  // 后台推送的入口也要在这里登记，**不能**等 `NotificationHost`。
  //
  // iOS 上带 `content-available` 的推送可以把*没在运行*的 App 拉到后台
  // 启动：那一刻 `main()` 才刚跑，`bootstrap()` 还没结束，UI 树和
  // `ProviderScope` 都还不存在。等 NotificationHost 挂上再注册就晚了 ——
  // 系统早就把这条消息投完了。
  //
  // **只登记 Apple 那两个平台**：Android 的 `onBackgroundMessage` 走的是
  // 另起一个 FlutterEngine 的路子，而它现在靠 `BackgroundSyncTask`（见
  // 那个文件），这条静态注册对它没有意义，反而会去碰
  // `Messaging#startBackgroundIsolate`。
  if (defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    FirebaseMessaging.onBackgroundMessage(pushServiceBackgroundEntry);
  }

  runApp(const BootstrapGate());
}

/// 启动闸门：**先建好本地库/密钥库/prefs，再让 App 起来**。
///
/// 为什么不把这些塞进 provider 里 `await`：见 `bootstrap.dart` 的注释。
/// 这里只负责三件事：
/// 1. 等待 `bootstrap()`，期间显示一个不讲废话的加载页；
/// 2. 把结果通过 `overrideWithValue` 注入 [bootstrapProvider]；
/// 3. 提供「重试」——重试会**重新跑一遍 bootstrap**（换一个 `key` 重建
///    整个 `ProviderScope`），而不是把同一个坏实例再读一次。
class BootstrapGate extends StatefulWidget {
  const BootstrapGate({super.key});

  @override
  State<BootstrapGate> createState() => _BootstrapGateState();
}

class _BootstrapGateState extends State<BootstrapGate> {
  late Future<BootstrapData> _pending = bootstrap();

  void _retry() {
    setState(() => _pending = bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BootstrapData>(
      future: _pending,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const _SplashScreen();

        // 本地邮件读取口**在这里挂**，不早也不晚。
        //
        // 早不了：`main()` 里那会儿库还不存在（`bootstrap()` 是下面这行才发起
        //   的异步流程）。扩展的启动钩子早于库、晚于它自己拿到 store，正是
        //   为这个顺序才留了 `mailStoreReady`。
        // 晚不得：挂得越早，扩展的索引器越早开始灌 —— 而 `data` 已经拿到手、
        //   下面马上要建 UI 树，再往后拖没有任何好处。
        //
        // 这一句**在 `main.dart` 里，所以两个版本逐字节相同** —— `data.db` 是
        // 核心自己的库，公开版挂上去也没人读（注册表里没有扩展）。
        AppExtensionRegistry.instance.attachMailStore(CoreMailStore(data.db));

        // `key` 用 data 的身份：重试后是一份新的 BootstrapData，
        // 换 key 会让整个 ProviderScope（以及底下所有 provider）从头建，
        // 不会残留上一次那半截坏状态。
        //
        // 重试那条路不会重挂：`bootstrap()` 会新开一个 `AppDatabase`，而
        // `attachMailStore` 第二次是空操作（见其注释）。也就是说重试之后
        // 扩展手上还是**上一个**（可能已经关掉的）库句柄。这是刻意的取舍 ——
        // 两个 store 意味着两个索引器灌同一份数据、互相抢锁，比「搜索不生效」
        // 难查得多。
        return ProviderScope(
          key: ObjectKey(data),
          // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且
          // 没有对外导出，显式写类型名反而编译不过 —— 让推断来做。
          overrides: [
            bootstrapProvider.overrideWithValue(data),
            bootstrapRetryProvider.overrideWithValue(_retry),
          ],
          child: const MailApp(),
        );
      },
    );
  }
}

/// 启动期间的占位页。刻意不做动画之外的任何事 —— 这一步通常在几百毫秒内结束，
/// 做进度条/品牌页反而会闪。
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const Scaffold(
        body: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
      ),
    );
  }
}
