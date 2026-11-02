// 桌面窗口标题：原生标题栏里的「Cirro Mail v0.1.0+131」。
//
// 两个被测面：
//
// 1. `windowTitleFor` 的拼法（纯函数，不起 widget）；
// 2. `WindowTitleHost` / `WindowChannel.setTitle` 真的把 `setWindowTitle`
//    打到那条原生通道上、参数是 `{"title": ...}`。
//
// ## 为什么平台要覆盖成 macOS
//
// `WindowChannel.setTitle` 的第一句是 `if (kIsWeb || !_isDesktop) return;`
// （`window_channel.dart`），而 flutter_tester 的默认平台是 **android** ——
// 不覆盖的话一个调用都不会发出去，「捕获到调用」那条用例根本测不到实现，
// 只能以假绿收场。反过来，钉「非桌面平台不发调用」用的也是同一个开关。
//
// ## 为什么复位不能放 `addTearDown`
//
// `flutter_test` 在**跑完测试体之后、tearDown 之前**就检查
// `debugDefaultTargetPlatformOverride` 有没有被留在非 null 上
// （`debugAssertAllFoundationVarsUnset`）。放进 `addTearDown` 会直接把用例判成
// 「测试改了 foundation debug 变量」。所以复位一律在用例体内 —— 用下面的
// [withTargetPlatform] 包一层，失败时也能复位。
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/window_channel.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/core/version/window_title.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 「改窗口标题」那条原生通道。通道名与三个 runner 注册的逐字一致
  /// （`macos/Runner/AppDelegate.swift`、`windows/runner/flutter_window.cpp`、
  /// `linux/runner/my_application.cc`）—— 换掉这个名字就是三个平台一起哑掉。
  const windowChannel = MethodChannel('com.zenkee.mailapp/window');

  /// 记下原生侧收到的每一条调用。
  List<MethodCall> captureWindowCalls() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });
    return calls;
  }

  /// 在指定平台下跑一段测试体，结束时（含断言失败）复位全局平台覆盖。
  Future<void> withTargetPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('windowTitleFor', () {
    test('版本 + build 号 → 「应用名 vX.Y.Z+N」', () {
      expect(
        windowTitleFor(
          appName: 'Cirro Mail',
          version: '0.1.0',
          buildNumber: 131,
        ),
        'Cirro Mail v0.1.0+131',
      );
    });

    test('build 号未知（0）时不显示 +0', () {
      expect(
        windowTitleFor(appName: 'Cirro Mail', version: '0.1.0', buildNumber: 0),
        'Cirro Mail v0.1.0',
      );
    });

    test('版本未知时只回应用名，不出现孤零零的 v', () {
      expect(
        windowTitleFor(appName: 'Cirro Mail', version: '', buildNumber: 0),
        'Cirro Mail',
      );
      // 纯空白也算未知：上游 `composeAppVersion` 已经 trim 过，这里多兜一层。
      expect(
        windowTitleFor(appName: 'Cirro Mail', version: '   ', buildNumber: 131),
        'Cirro Mail',
      );
    });

    test('预发布标识原样保留（商业版 tag 形如 v0.1.0-pro.1）', () {
      expect(
        windowTitleFor(
          appName: 'Cirro Mail',
          version: '0.1.0-pro.1',
          buildNumber: 7,
        ),
        'Cirro Mail v0.1.0-pro.1+7',
      );
    });
  });

  group('WindowChannel.setTitle', () {
    test('桌面平台：发 setWindowTitle，参数是 {"title": ...}', () async {
      final calls = captureWindowCalls();

      await withTargetPlatform(TargetPlatform.macOS, () async {
        await WindowChannel.setTitle('Cirro Mail v0.1.0+131');

        expect(calls, hasLength(1));
        expect(calls.single.method, 'setWindowTitle');
        expect(
          calls.single.arguments,
          <String, Object?>{'title': 'Cirro Mail v0.1.0+131'},
        );
      });
    });

    test('非桌面平台（android）：一个调用都不发', () async {
      final calls = captureWindowCalls();

      await withTargetPlatform(TargetPlatform.android, () async {
        await WindowChannel.setTitle('Cirro Mail v0.1.0+131');

        expect(calls, isEmpty);
      });
    });

    test('旧构建 / 通道没接上：静默吞掉 MissingPluginException', () async {
      // 刻意不装 mock handler —— 这时 invokeMethod 会抛
      // `MissingPluginException`，setTitle 必须吞掉它（不能把启动路径带崩）。
      await withTargetPlatform(TargetPlatform.macOS, () async {
        await expectLater(
          WindowChannel.setTitle('Cirro Mail v0.1.0+131'),
          completes,
        );
      });
    });
  });

  group('WindowTitleHost', () {
    /// 一棵「版本已注入 + 宿主包一层」的树。child 用带 key 的 `SizedBox`
    /// 而不是 `Text`：没有 `Directionality` 的裸树里 `Text` 会自己报错，
    /// 而这条用例要验的是「child 原样返回」，跟文字布局无关。
    ///
    /// 直接收一个 create 函数而不是 `Override`：`Override` 这个类型没从
    /// `flutter_riverpod` 的公开面导出，写成 `List<Override>` 反而编不过。
    Future<void> pumpHost(
      WidgetTester tester,
      Future<AppVersion> Function(Ref ref) create,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          // 不写显式类型参数：列表会被参数类型推成 `List<Override>`。
          overrides: [appVersionProvider.overrideWith(create)],
          child: const WindowTitleHost(
            child: SizedBox(key: ValueKey<String>('window-title-child')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('版本已知：首帧之后把完整标题推到原生通道，child 原样显示',
        (tester) async {
      final calls = captureWindowCalls();

      await withTargetPlatform(TargetPlatform.macOS, () async {
        await pumpHost(
          tester,
          (ref) async => const AppVersion(name: '0.1.0', buildNumber: 131),
        );

        expect(
          find.byKey(const ValueKey<String>('window-title-child')),
          findsOneWidget,
        );
        expect(calls, hasLength(1));
        expect(calls.single.method, 'setWindowTitle');
        expect(
          calls.single.arguments,
          <String, Object?>{'title': 'Cirro Mail v0.1.0+131'},
        );
      });
    });

    testWidgets('版本未知：不发调用，原生侧标题保持原样', (tester) async {
      final calls = captureWindowCalls();

      await withTargetPlatform(TargetPlatform.macOS, () async {
        await pumpHost(tester, (ref) async => AppVersion.unknown);

        expect(calls, isEmpty);
      });
    });

    testWidgets('非桌面平台：即使版本已知也不发调用', (tester) async {
      final calls = captureWindowCalls();

      await withTargetPlatform(TargetPlatform.android, () async {
        await pumpHost(
          tester,
          (ref) async => const AppVersion(name: '0.1.0', buildNumber: 131),
        );

        expect(calls, isEmpty);
      });
    });

    testWidgets('版本读取失败：不抛、不发调用', (tester) async {
      final calls = captureWindowCalls();

      await withTargetPlatform(TargetPlatform.macOS, () async {
        await pumpHost(
          tester,
          (ref) async => throw StateError('版本读不到'),
        );

        expect(calls, isEmpty);
        expect(tester.takeException(), isNull);
      });
    });
  });
}
