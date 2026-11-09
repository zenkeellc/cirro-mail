// 撰写页 AI 入口的**可见性回归**（设计稿 §5.4 / §7.3、§10.2-4、审计 D1）。
//
// 这一份补的缺口是「入口层」：AI 能不能用、点了之后发不发请求，别处都钉过了
// （`ai_transport_gate_test.dart` 钉执行层、`ai_source_label_test.dart` 钉署名），
// 但「真订阅用户从没配过自带 Key 时，撰写页那三个 AI 入口到底画不画」一直
// 只有 `channelConfigured` 的纯函数逻辑、没有 widget 级证据 —— 而审计 D1
// 说的正是这条：判据只看 BYOK 的 `isUsable` 时，七个 AI 入口一个都不出现。
//
// 三条判据（`compose_screen` 里合成一个 `aiUsable`）：
//   ① 托管通道**可走**：注册了 `AppExtension.aiTransport`，**且** 用户在
//      「设置 → AI」里选的来源就是通道（`cm_ai_source == 'managed'`）；
//   ② BYOK 配好了（`settings.isUsable`，要 Key + 地址 + 模型）；
//   ③ 实现方要求入口常驻（`AppExtension.aiEntryAlwaysVisible`）。
// 公开版（空注册表 + 没配 Key）必须**藏**：一个点了只回一句「去设置」的图标
// 比没有更糟；商业版敢常驻是因为它点下去有真正的下一步（登录 / 订阅）。
//
// **入口可见性跟着来源走**（2026-11-09，`docs/ai-settings-source-separation.md`
// §2）：注册了通道不等于通道在生效。用户显式选了「自己的 AI」而配置不完整
// 时，三个入口都不出现 —— 以前这里只看「注册了没有」，会造出一个点了只回
// 「还没配置 AI」的入口。`aiEntryAlwaysVisible` 是唯一的例外（它自己就是
// 一条「先让用户点到」的产品决定）。
//
// 三个入口都钉，缺一个就等于允许「工具栏出现了、斜杠菜单里没有」这种半残状态：
//   - 常驻工具栏的 `ct-ai`（AI 改写下拉）；
//   - 主题栏右端的 `compose-subject-ai`（起标题）；
//   - 斜杠菜单里的「AI 起草」（`insert-aiDraft`）。
import 'package:cirro_mail_ext/cirro_mail_ext.dart' as ext;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 最小的托管通道实现：页面只要它「存在」（`channelConfigured` 非空即真），
/// 这三条用例不点任何 AI 按钮，所以 `state()` / `run()` 都不会被真的用到。
class _FakeManagedTransport implements ext.AiTransport {
  @override
  String get channelLabel => '示例通道';

  /// 来源署名。这三条用例只看「入口画不画」，不经署名路径 —— 给 null
  /// 与 BYOK 的常态一致，别处那些「没配 Key 就不署名」的断言不受影响。
  @override
  String? get sourceLabel => null;

  @override
  Future<ext.AiChannelState> state() async =>
      const ext.AiChannelState(usable: true, detail: '余额 100');

  @override
  Stream<String> run(ext.AiCall call) => const Stream<String>.empty();
}

/// 注册一条托管通道（模拟 Pro 已享权）。
class _ExtWithTransport extends ext.AppExtension {
  @override
  String get id => 'test.compose.managed';

  @override
  ext.AiTransport? get aiTransport => _FakeManagedTransport();
}

/// 不提供通道、但要求入口常驻（模拟 Pro 未登录 / 未订阅）。
class _ExtAlwaysVisible extends ext.AppExtension {
  @override
  String get id => 'test.compose.always-visible';

  @override
  bool get aiEntryAlwaysVisible => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 注册表是进程级单例，每个用例都得从空开始。
    ext.AppExtensionRegistry.instance.reset();
    // **没配 Key**：BYOK 的 `isUsable` 因此恒为 false —— 这正是三条用例要的
    // 那个「BYOK 不可用」前提。地址与模型走默认值，更贴近「装好就没动过」。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(ext.AppExtensionRegistry.instance.reset);

  /// 挂一个真的撰写页。
  ///
  /// **注册（或清空）扩展必须在调用它之前完成**：`aiTransportProvider` 是个
  /// 同步 `Provider`，结果被 Riverpod 容器**永久缓存**，容器建好之后再注册就
  /// 不会生效了 —— 「注册了通道但入口还是不出现」会变成一条测不出来的假红。
  Future<void> pumpCompose(WidgetTester tester) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const ComposeScreen(args: ComposeArgs()),
        ),
      ),
    );
    // 等 AI 设置（prefs + 钥匙串）真正落地：在那之前 `settings` 是默认值，
    // 断言会跑在一个「还没读完」的中间态上。
    await tester.pumpAndSettle();
  }

  /// 在正文行首敲一个 `/`，把斜杠菜单叫出来。
  Future<void> openSlashMenu(WidgetTester tester) async {
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.focusNode.requestFocus();
    await tester.pump();
    editor.controller.replaceText(
      0,
      0,
      '/',
      const TextSelection.collapsed(offset: 1),
    );
    await tester.pump();
  }

  /// 三个 AI 入口**都在**。
  Future<void> expectAiEntriesVisible(WidgetTester tester) async {
    expect(find.byKey(const ValueKey('ct-ai')), findsOneWidget,
        reason: '工具栏的「AI 改写」下拉（常驻工具栏）');
    expect(find.byKey(const ValueKey('compose-subject-ai')), findsOneWidget,
        reason: '主题栏右端的「起标题」图标');
    await openSlashMenu(tester);
    expect(find.byKey(const ValueKey('insert-aiDraft')), findsOneWidget,
        reason: '斜杠菜单里的「AI 起草」');
  }

  /// 三个 AI 入口**都不在**（斜杠菜单照样要能开，否则「找不到 AI 条目」
  /// 可能只是因为菜单根本没打开 —— 那种假绿必须避免）。
  Future<void> expectAiEntriesHidden(WidgetTester tester) async {
    expect(find.byKey(const ValueKey('ct-ai')), findsNothing);
    expect(find.byKey(const ValueKey('compose-subject-ai')), findsNothing);
    await openSlashMenu(tester);
    expect(find.byKey(const ValueKey('insert-table')), findsOneWidget,
        reason: '菜单确实开了：非 AI 条目在，AI 条目才谈得上「被藏掉」');
    expect(find.byKey(const ValueKey('insert-aiDraft')), findsNothing);
    expect(find.text('AI 起草'), findsNothing);
  }

  testWidgets('① 空注册表 + BYOK 没配：三个 AI 入口都不出现', (tester) async {
    await pumpCompose(tester);
    await expectAiEntriesHidden(tester);
  });

  testWidgets('② 注册了托管通道、BYOK 仍未配：三个 AI 入口都出现', (tester) async {
    ext.AppExtensionRegistry.instance
        .registerAll(<ext.AppExtension>[_ExtWithTransport()]);
    await pumpCompose(tester);
    // 前提没走样：BYOK 确实还是「没配好」的那一份。
    await expectAiEntriesVisible(tester);
  });

  testWidgets('③ 只要求入口常驻（通道为 null）：三个 AI 入口同样出现',
      (tester) async {
    ext.AppExtensionRegistry.instance
        .registerAll(<ext.AppExtension>[_ExtAlwaysVisible()]);
    await pumpCompose(tester);
    await expectAiEntriesVisible(tester);
  });

  testWidgets('④ 注册了通道，但来源选了「自己的 AI」且没配好：三个入口都不出现',
      (tester) async {
    ext.AppExtensionRegistry.instance
        .registerAll(<ext.AppExtension>[_ExtWithTransport()]);
    // 用户显式选了「自己的 AI」（落盘在 `cm_ai_source`），但没配 Key ——
    // 这正是以前会「因为通道注册了就出现」的那一组。对照组就是上面 ②：
    // 同一份注册、来源缺省（managed）时入口照常出现，所以这里藏掉不是因为
    // 页面没加载完。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cm_ai_source': 'byok',
    });
    await pumpCompose(tester);
    await expectAiEntriesHidden(tester);
  });
}
