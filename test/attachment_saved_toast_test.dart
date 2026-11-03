import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/attachment_saved_toast.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 「另存为」回执条。
///
/// 用户原文：
/// > 下载附件后，在弹出的 toast 需要添加一个在 finder 或在资源管理器打开
/// > （根据平台设置），以及一个直接打开或预览的按钮（mac 使用 os 预览）
///
/// 所以这一组钉住三件事：
/// 1. 那条回执上**真的有两个动作**（不是只有一句话，也不是只挂一个
///    `SnackBarAction`）；
/// 2. 「在文件管理器里显示」的文案**按平台换**（Finder / 资源管理器 /
///    文件管理器）—— 用户在 macOS 上看到「在资源管理器中显示」会一头雾水；
/// 3. 拉不起来（通道返回 false / 沙盒拒绝）时**有回执**，不静默失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const desktopChannel = MethodChannel('com.zenkee.cirromail/desktop');
  final zh = lookupAppLocalizations(const Locale('zh'));
  final en = lookupAppLocalizations(const Locale('en'));

  /// 把 `show()` 挂在一个真 `ScaffoldMessenger` 上（回执条要有宿主才弹得出来）。
  Future<void> pumpToast(
    WidgetTester tester, {
    required AppLocalizations l10n,
    String path = '/Users/me/Downloads/original.eml',
    TargetPlatform platform = TargetPlatform.macOS,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => AttachmentSavedToast.show(
                  messenger: ScaffoldMessenger.of(context),
                  l10n: l10n,
                  theme: Theme.of(context),
                  path: path,
                  mimeType: 'message/rfc822',
                  platform: platform,
                ),
                child: const Text('save'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('save'));
    // SnackBar 入场：微任务 → 首帧 → 动画。不用 `pumpAndSettle`，
    // 那会一路等到 10 秒的自动消失。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('回执上有两个动作：在 Finder 中显示 + 打开', (tester) async {
    await pumpToast(tester, l10n: zh);

    expect(find.text(zh.savedTo('/Users/me/Downloads/original.eml')), findsOneWidget);
    expect(find.text('在 Finder 中显示'), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('点「在 Finder 中显示」→ 走原生通道，参数是另存为的路径', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      desktopChannel,
      (call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(desktopChannel, null),
    );

    await pumpToast(tester, l10n: zh);
    await tester.tap(find.text('在 Finder 中显示'));
    await tester.pump();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'revealInFileManager');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['path'],
      '/Users/me/Downloads/original.eml',
    );
  });

  testWidgets('Finder 拉不起来（通道说 false）→ 有回执，不静默', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      desktopChannel,
      (call) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(desktopChannel, null),
    );

    await pumpToast(tester, l10n: zh);
    await tester.tap(find.text('在 Finder 中显示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(zh.revealFailed), findsOneWidget);
  });

  test('「显示位置」的文案按平台换：Finder / 资源管理器 / 文件管理器', () {
    expect(
      AttachmentSavedToast.revealLabel(zh, platform: TargetPlatform.macOS),
      '在 Finder 中显示',
    );
    expect(
      AttachmentSavedToast.revealLabel(zh, platform: TargetPlatform.windows),
      '在资源管理器中显示',
    );
    expect(
      AttachmentSavedToast.revealLabel(zh, platform: TargetPlatform.linux),
      '在文件管理器中显示',
    );

    expect(
      AttachmentSavedToast.revealLabel(en, platform: TargetPlatform.macOS),
      'Show in Finder',
    );
    expect(
      AttachmentSavedToast.revealLabel(en, platform: TargetPlatform.windows),
      'Show in Explorer',
    );
  });
}
