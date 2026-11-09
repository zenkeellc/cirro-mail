// 「设置 → AI」页的**来源切换**护栏（AI 来源：托管通道 ⇄ 自己的 AI）。
//
// 这一组盯的是本次改版的核心承诺，而不是像素：
//
// 1. 注册了托管通道之后，**两套设置同时在场上** —— 通道卡、来源单选、以及
//    原来被整段藏起来的 BYOK 表单（地址 / Key / 模型）一个不少；
// 2. 选来源**当场落盘、当场生效**（`AiSettingsStore.preferredSource` 同步
//    读得到），且两个方向都切得回来；
// 3. 两条「就地换来源」的引导各有它的前提：通道不可用且选着它时给「改用
//    自己的 AI」；自己的 AI 没配好、通道可用时给「先用通道」；
// 4. `transport == null`（公开版 / 未订阅）时整组来源与 BYOK 区标题都不
//    出现 —— 版面与从前逐字相同，这条在 `ai_transport_gate_test.dart` 的
//    空注册表那组另有更强的护栏，这里只钉「没有多出来的东西」。
//
// 为什么假实现是自建的：这一页只要一个 `ext.AiTransport`（频道名 + 状态）
// 和一个把它挂进注册表的 `ext.AppExtension`，不碰网络、不碰数据库。
import 'package:cirro_mail_ext/cirro_mail_ext.dart' as ext;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/features/settings/sections/ai_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假托管通道：只回答「叫什么」与「眼下可不可用」。
///
/// `run()` 在设置页里一次都不会被调到（那一页只画设置），所以给一条空流
/// 就够了 —— 真收发由 `ai_transport_gate_test.dart` 那边覆盖。
class _FakeAiTransport implements ext.AiTransport {
  _FakeAiTransport({
    this.channelState = const ext.AiChannelState(
      usable: true,
      detail: '通道可用',
    ),
  });

  /// 通道显示名。核心只原样显示它，所以这里用什么名字都行。
  static const String label = '示例通道';

  final ext.AiChannelState channelState;

  /// `state()` 被问了几次。父级不该为了那两条引导自己再问一遍。
  int stateCalls = 0;

  @override
  String get channelLabel => label;

  @override
  String? get sourceLabel => null;

  @override
  Future<ext.AiChannelState> state() async {
    stateCalls++;
    return channelState;
  }

  @override
  Stream<String> run(ext.AiCall call) => const Stream<String>.empty();
}

/// 只挂一条 AI 通道的假扩展 —— 与真实商业实现的注册方式同一个形状。
class _ExtWithTransport extends ext.AppExtension {
  _ExtWithTransport(this.transport);

  final ext.AiTransport transport;

  @override
  String get id => 'test.ai-source-switch';

  @override
  ext.AiTransport? get aiTransport => transport;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ext.AppExtensionRegistry.instance.reset();
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(ext.AppExtensionRegistry.instance.reset);

  /// 注册必须在 `ProviderScope` 建好**之前**：`aiTransportProvider` 是一个
  /// 同步 `Provider`，页面首帧就会把它读走。
  void register(ext.AiTransport transport) {
    ext.AppExtensionRegistry.instance
        .registerAll(<ext.AppExtension>[_ExtWithTransport(transport)]);
  }

  /// 建 prefs，并可选地预置「上次选的来源」。
  Future<PrefsStore> makePrefs({AiSource? source}) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    if (source != null) await prefs.setAiSourceCode(source.name);
    return prefs;
  }

  /// 挂起这一页。视口调得足够高，让整页（`ListView` 是懒构建的）都真的
  /// 建出来 —— 这一组关注「有哪些行」，不关注滚动。
  Future<void> pumpSection(WidgetTester tester, PrefsStore prefs) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(body: AiSettingsSection(key: UniqueKey())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(AiSettingsSection)));

  /// 来源单选组眼下的选中值。`RadioGroup` 是唯一的真源 —— 两个
  /// `RadioListTile` 只是它的两个选项（旧的 `groupValue/onChanged` 已废弃）。
  AiSource? selectedSource(WidgetTester tester) => tester
      .widget<RadioGroup<AiSource>>(find.byType(RadioGroup<AiSource>))
      .groupValue;

  /// 点一颗按钮：先保证它在视口里（`tap` 打在屏幕外只会留一条 warning，
  /// 失败要等到后面的断言才暴露，看起来像「没生效」）。
  Future<void> tapKey(WidgetTester tester, Key key) async {
    final target = find.byKey(key);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  group('有通道：两套设置同时在场', () {
    testWidgets('来源单选 + 通道卡 + BYOK 字段一个不少，默认选通道',
        (tester) async {
      final transport = _FakeAiTransport();
      register(transport);
      final prefs = await makePrefs();
      await pumpSection(tester, prefs);
      final l10n = l10nOf(tester);

      // 来源那组：两个选项同时摆着（「有订阅也能用自己的 AI」在版面上的落点）。
      expect(find.text(l10n.aiSourceSection), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-source-managed')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-source-byok')), findsOneWidget);
      expect(selectedSource(tester), AiSource.managed);

      // 通道那组与它的既有锚点照旧。
      expect(find.text(l10n.aiChannelSection), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-channel')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-channel-label')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-channel-detail')), findsOneWidget);

      // 默认选通道：通道分组标题行挂「使用中」。
      expect(
        find.byKey(const ValueKey('ai-source-in-use-channel')),
        findsOneWidget,
      );

      // **BYOK 不再被藏起来**：地址 / Key / 模型都在，可以直接配。
      expect(find.byKey(const ValueKey('ai-base-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-key')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-model')), findsOneWidget);

      // 选着通道、自己的 AI 没配好 → 状态行说明「要选上才生效」，副标题说
      // 「还没配置完整」。
      expect(find.text(l10n.aiByokInactiveHint), findsOneWidget);
      expect(find.text(l10n.aiSourceByokIncomplete), findsOneWidget);
      // 通道可用 + 选着它：没有「换来源」的引导。
      expect(find.byKey(const ValueKey('ai-switch-to-byok')), findsNothing);
    });

    testWidgets('点「自己的 AI」→ 落盘 + 当场生效 + 有提示', (tester) async {
      final transport = _FakeAiTransport();
      register(transport);
      final prefs = await makePrefs();
      await pumpSection(tester, prefs);
      final l10n = l10nOf(tester);

      await tapKey(tester, const ValueKey('ai-source-byok'));

      // 落盘：prefs 里的来源码与 `AiSettingsStore.preferredSource` 都变了
      // （后者是 `AiService` 每次调用前同步读的那个值，所以这就是「立即生效」）。
      expect(prefs.aiSourceCode, AiSource.byok.name);
      expect(
        AiSettingsStore(prefs: prefs).preferredSource,
        AiSource.byok,
        reason: '切换必须当场生效，不能等重启',
      );
      expect(selectedSource(tester), AiSource.byok);

      // UI 跟着翻：通道不再标「使用中」，BYOK 区的状态行换成「没配好」。
      expect(
        find.byKey(const ValueKey('ai-source-in-use-channel')),
        findsNothing,
      );
      expect(find.text(l10n.aiByokInactiveHint), findsNothing);
      expect(find.text(l10n.aiByokNotReadyHint), findsOneWidget);

      // 弹一句确认（不是静默落盘）。
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(l10n.aiSourceSwitchedToByok), findsOneWidget);
    });

    testWidgets('再点回通道 → 落盘 + UI 翻回来', (tester) async {
      final transport = _FakeAiTransport();
      register(transport);
      final prefs = await makePrefs(source: AiSource.byok);
      await pumpSection(tester, prefs);
      final l10n = l10nOf(tester);
      expect(selectedSource(tester), AiSource.byok);

      await tapKey(tester, const ValueKey('ai-source-managed'));

      expect(prefs.aiSourceCode, AiSource.managed.name);
      expect(
        AiSettingsStore(prefs: prefs).preferredSource,
        AiSource.managed,
      );
      expect(selectedSource(tester), AiSource.managed);
      expect(
        find.byKey(const ValueKey('ai-source-in-use-channel')),
        findsOneWidget,
      );
      expect(find.text(l10n.aiByokInactiveHint), findsOneWidget);
      expect(find.text(l10n.aiSourceSwitchedToChannel), findsOneWidget);
    });
  });

  group('就地换来源的两条引导', () {
    testWidgets('通道不可用 + 选着通道 → 「改用我自己的 AI」点一下落到 byok',
        (tester) async {
      final transport = _FakeAiTransport(
        channelState: const ext.AiChannelState(
          usable: false,
          detail: '这张通道现在用不了',
        ),
      );
      register(transport);
      final prefs = await makePrefs();
      await pumpSection(tester, prefs);

      final switchToByok = find.byKey(const ValueKey('ai-switch-to-byok'));
      expect(switchToByok, findsOneWidget);

      await tapKey(tester, const ValueKey('ai-switch-to-byok'));

      expect(prefs.aiSourceCode, AiSource.byok.name);
      expect(selectedSource(tester), AiSource.byok);
      // 已经换走了，这条引导不该还挂着。
      expect(find.byKey(const ValueKey('ai-switch-to-byok')), findsNothing);
    });

    testWidgets('选了 byok 但没配好 + 通道可用 → 「先用通道」点一下切回 managed',
        (tester) async {
      final transport = _FakeAiTransport();
      register(transport);
      final prefs = await makePrefs(source: AiSource.byok);
      await pumpSection(tester, prefs);
      final l10n = l10nOf(tester);

      // 没有 Key、没有模型 → `isUsable` 假：既要说「没配好」，又要给回头路。
      expect(find.text(l10n.aiByokNotReadyHint), findsOneWidget);
      final switchToChannel =
          find.byKey(const ValueKey('ai-switch-to-channel'));
      expect(switchToChannel, findsOneWidget);

      await tapKey(tester, const ValueKey('ai-switch-to-channel'));

      expect(prefs.aiSourceCode, AiSource.managed.name);
      expect(selectedSource(tester), AiSource.managed);
      expect(find.byKey(const ValueKey('ai-switch-to-channel')), findsNothing);
      expect(find.text(l10n.aiByokInactiveHint), findsOneWidget);
    });
  });

  group('没有通道（公开版 / 未订阅）', () {
    testWidgets('来源组与 BYOK 区标题都不出现，BYOK 版面照旧', (tester) async {
      final prefs = await makePrefs();
      await pumpSection(tester, prefs);
      final l10n = l10nOf(tester);

      // 没有第二条路可选时，「来源」这个问题不存在。
      expect(find.byKey(const ValueKey('ai-source-managed')), findsNothing);
      expect(find.byKey(const ValueKey('ai-source-byok')), findsNothing);
      expect(find.byKey(const ValueKey('ai-source-in-use-channel')), findsNothing);
      expect(find.text(l10n.aiByokSection), findsNothing);
      expect(find.byKey(const ValueKey('ai-channel')), findsNothing);

      // BYOK 那一套仍在（并且没有多出「自己的 AI」这个区标题）。
      expect(find.byKey(const ValueKey('ai-base-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-key')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-model')), findsOneWidget);
      expect(find.text(l10n.aiSourceByokIncomplete), findsNothing);
    });
  });
}
