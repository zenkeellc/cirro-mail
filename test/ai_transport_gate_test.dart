// 商业 AI 通道接缝的**公开面护栏**（设计稿 §6.1 / §6.2）。
//
// 这个文件同时管三件事，按「公开版」与「注册了实现方」两组分开：
//
// 1. **空注册表 = 公开版既有行为逐字不变**：AI 设置页不出现「通道」行、BYOK
//    的地址 / Key / 模型 / 拉取 / 测试连接一个不少；`AiService` 仍然走 BYOK，
//    没配好时那句提示与今天一字不差。
// 2. **注册之后**：设置页多一行「通道」（名字与状态都来自实现方）、BYOK 区
//    整体隐藏；`AiService` 改走 `transport.run()`，`state()` 说不通就不发，
//    调用计数照记。
// 3. **失败映射与脱敏**：实现方给的 `message` 原样显示，**不进公开 ARB**；
//    公开 ARB 里也没有实现方那边的商业词。
//
// 「没注册 = 原样」这一组存在的理由与 `about_section_extension_test.dart`
// 完全相同：商业功能必须是可选的，公开版关掉商业包之后行为要回到从前。
import 'dart:async';
import 'dart:io' show File;

import 'package:cirro_mail_ext/cirro_mail_ext.dart' as ext;
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart' show AiApiFormat;
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/features/settings/sections/ai_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假钥匙串里那把「用户自己的 Key」。
const String fakeKey = 'sk-test-0123456789';

/// BYOK 那条路的假传输：记下最后一次请求，回一段固定的 OpenAI 形状流。
class _ByokTransport implements AiTransport {
  String? lastUrl;
  Map<String, dynamic>? lastBody;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    lastUrl = url;
    lastBody = body;
    onChunk('data: {"choices":[{"delta":{"content":"你好"}}]}\n\n');
  }

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async =>
      '{}';
}

/// 假的托管通道：记录收到的 `AiCall`，吐固定增量，可配置各种失败。
class _FakeAiTransport implements ext.AiTransport {
  _FakeAiTransport({
    this.channelState = const ext.AiChannelState(usable: true, detail: '余额 100'),
    this.stateError,
    this.chunks = const <String>['你', '好'],
    this.streamError,
    this.throwOnRun,
    this.staysOpen = false,
  });

  /// 通道显示名（设置页那一行取的就是它）。
  static const String label = '示例通道';

  final ext.AiChannelState channelState;
  final Object? stateError;
  final List<String> chunks;
  final Object? streamError;

  /// `run()` **同步**抛出的错误（流还没建立）。
  final Object? throwOnRun;

  /// 吐完 chunks 之后不关闭（用来测取消）。
  final bool staysOpen;

  final List<ext.AiCall> calls = <ext.AiCall>[];
  int stateCalls = 0;
  bool cancelled = false;

  @override
  String get channelLabel => label;

  @override
  Future<ext.AiChannelState> state() async {
    stateCalls++;
    if (stateError != null) throw stateError!;
    return channelState;
  }

  @override
  Stream<String> run(ext.AiCall call) {
    calls.add(call);
    if (throwOnRun != null) throw throwOnRun!;
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        for (final chunk in chunks) {
          controller.add(chunk);
        }
        if (streamError != null) {
          controller.addError(streamError!);
          unawaited(controller.close());
        } else if (!staysOpen) {
          unawaited(controller.close());
        }
      },
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }
}

/// 只挂一条 AI 通道的假扩展（公开仓库里当然没有这样的实现）。
class _ExtWithTransport extends ext.AppExtension {
  _ExtWithTransport(this.transport);

  final ext.AiTransport transport;

  @override
  String get id => 'test.ai-channel';

  @override
  ext.AiTransport? get aiTransport => transport;
}

/// 读公开 ARB 原文 —— 用来断言「实现方的文案不该出现在这里」。
String arb(String locale) => File('lib/l10n/app_$locale.arb').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ext.AppExtensionRegistry.instance.reset();
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(ext.AppExtensionRegistry.instance.reset);

  Future<PrefsStore> prefs() async =>
      PrefsStore(await SharedPreferences.getInstance());

  /// 建一个 `AiService`。[transport] 非 null = 托管通道；
  /// 否则走 BYOK（[byok] 是那条路上的假传输）。
  Future<AiService> service({
    ext.AiTransport? transport,
    _ByokTransport? byok,
    bool configured = true,
    AiSettings settings = const AiSettings(
      apiFormat: AiApiFormat.openai,
      model: 'gpt-4o-mini',
    ),
  }) async {
    FlutterSecureStorage.setMockInitialValues(
      configured
          ? <String, String>{AiApiKeyStore.storageKey: fakeKey}
          : <String, String>{},
    );
    final p = await prefs();
    final store = AiSettingsStore(prefs: p);
    await store.save(settings);
    return AiService(
      store: store,
      usage: AiUsageCounter(prefs: p),
      client: AiClient(transport: byok ?? _ByokTransport()),
      transport: transport,
    );
  }

  /// 挂 `AiSettingsSection`。视口调高，让整页（含 skipOffstage 的懒构建项）
  /// 都真的建出来 —— 这一页的护栏关注「有哪些行」，不关注滚动。
  Future<void> pumpAiSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = await prefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsStoreProvider.overrideWithValue(p)],
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

  group('空注册表 = 公开版行为逐字不变', () {
    test('注册表里没有 AI 通道', () {
      expect(ext.AppExtensionRegistry.instance.aiTransport, isNull);
    });

    testWidgets('AI 设置页没有「通道」行，BYOK 的字段一个不少', (tester) async {
      await pumpAiSection(tester);
      final l10n = l10nOf(tester);

      expect(find.byKey(const ValueKey('ai-channel')), findsNothing);
      expect(find.text(l10n.aiChannelSection), findsNothing);

      // BYOK 那一段原样还在：地址 / 格式 / Key / 模型 / 拉取 / 测试连接。
      expect(find.byKey(const ValueKey('ai-base-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-api-format')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-key')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-model')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-models-fetch')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-test-connection')), findsOneWidget);

      // 「还没配置 AI」这句也照旧出现（没有 Key 也没有通道）。
      expect(find.text(l10n.aiUnavailable), findsOneWidget);
      // 隐私声明照旧。
      expect(find.byKey(const ValueKey('ai-privacy')), findsOneWidget);
    });

    test('AI 调用仍走 BYOK：请求真的发到用户自己的端点', () async {
      final byok = _ByokTransport();
      final ai = await service(byok: byok);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      expect(start, isA<AiStarted>());
      final stream = (start as AiStarted).stream;
      expect(await stream.text.join(), '你好');
      expect(await stream.done, '你好');
      expect(byok.lastBody, isNotNull, reason: 'BYOK 路径必须真的发请求');
      expect(ai.usedToday, 1, reason: '两条路共用调用计数');
    });

    test('没配好时那句提示与今天一字不差，且一次网络都不发', () async {
      final byok = _ByokTransport();
      final ai = await service(byok: byok, configured: false);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      expect(start, isA<AiNotStarted>());
      expect((start as AiNotStarted).reason, AiService.notConfiguredMessage);
      expect(byok.lastBody, isNull);
      expect(ai.usedToday, 0);
    });
  });

  group('注册之后：走托管通道', () {
    testWidgets('设置页多一行「通道」，名字取实现方，BYOK 区隐藏', (tester) async {
      final transport = _FakeAiTransport();
      ext.AppExtensionRegistry.instance
          .registerAll(<ext.AppExtension>[_ExtWithTransport(transport)]);
      await pumpAiSection(tester);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.aiChannelSection), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-channel')), findsOneWidget);
      expect(find.text('示例通道'), findsOneWidget);
      expect(find.text('余额 100'), findsOneWidget);
      expect(transport.stateCalls, 1);

      // 托管通道的可用性由 `state()` 表达：BYOK 那套探测全都不该出现。
      expect(find.byKey(const ValueKey('ai-base-url')), findsNothing);
      expect(find.byKey(const ValueKey('ai-api-format')), findsNothing);
      expect(find.byKey(const ValueKey('ai-key')), findsNothing);
      expect(find.byKey(const ValueKey('ai-model')), findsNothing);
      expect(find.byKey(const ValueKey('ai-models-fetch')), findsNothing);
      expect(find.byKey(const ValueKey('ai-test-connection')), findsNothing);
      // 与 BYOK 配置有关的那句「还没配置 AI」也不该出现。
      expect(find.text(l10n.aiUnavailable), findsNothing);
    });

    testWidgets('不可用时照原样显示实现方给的那句话', (tester) async {
      final transport = _FakeAiTransport(
        channelState: const ext.AiChannelState(
          usable: false,
          detail: '设备授权失效，请重新激活',
        ),
      );
      ext.AppExtensionRegistry.instance
          .registerAll(<ext.AppExtension>[_ExtWithTransport(transport)]);
      await pumpAiSection(tester);
      expect(find.text('设备授权失效，请重新激活'), findsOneWidget);
    });

    test('可用时 AiService 走 transport.run，call 的 task/input 正确', () async {
      final transport = _FakeAiTransport();
      final byok = _ByokTransport();
      final ai = await service(transport: transport, byok: byok);

      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.formal,
        extraInstruction: '短一点',
      );
      expect(start, isA<AiStarted>());
      final stream = (start as AiStarted).stream;
      expect(await stream.text.join(), '你好');
      expect(await stream.done, '你好');

      final call = transport.calls.single;
      expect(call.task, 'rewrite');
      expect(call.input['selection'], '原文');
      expect(call.input['tone'], 'formal');
      expect(call.input['extraInstruction'], '短一点');

      expect(byok.lastBody, isNull, reason: '托管模式下不该碰 BYOK 的端点');
      expect(ai.usedToday, 1, reason: '两条路共用调用计数');
    });

    test('state() 说不可用：不发调用、不计数，提示就是实现方那句话', () async {
      final transport = _FakeAiTransport(
        channelState: const ext.AiChannelState(
          usable: false,
          detail: '设备授权失效，请重新激活',
        ),
      );
      final ai = await service(transport: transport);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      expect(start, isA<AiNotStarted>());
      expect((start as AiNotStarted).reason, '设备授权失效，请重新激活');
      expect(transport.calls, isEmpty);
      expect(ai.usedToday, 0);
    });

    test('state() 抛异常：兜底一句中性提示，不把异常漏给界面', () async {
      final transport = _FakeAiTransport(stateError: StateError('boom'));
      final ai = await service(transport: transport);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      expect(start, isA<AiNotStarted>());
      expect(
        (start as AiNotStarted).reason,
        AiService.channelUnavailableMessage,
      );
    });

    test('state() 不可用但没给 detail：兜底一句中性提示', () async {
      final transport = _FakeAiTransport(
        channelState: const ext.AiChannelState(usable: false, detail: '   '),
      );
      final ai = await service(transport: transport);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      expect(
        (start as AiNotStarted).reason,
        AiService.channelUnavailableMessage,
      );
    });

    test('run() 同步抛错：转成「没开始」，message 原样', () async {
      final transport = _FakeAiTransport(
        throwOnRun: const ext.AiTransportException(
          'bad_input',
          '请求有误，请调整内容后再试',
        ),
      );
      final ai = await service(transport: transport);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      expect(start, isA<AiNotStarted>());
      expect((start as AiNotStarted).reason, '请求有误，请调整内容后再试');
      expect(ai.usedToday, 0, reason: '没真的开始就不该计数');
    });

    test('流开始后失败：错误带实现方的 message，界面原样显示', () async {
      final transport = _FakeAiTransport(
        chunks: const <String>['半句'],
        streamError: const ext.AiTransportException(
          'upstream_error',
          '上游暂时没有返回内容，请稍后重试',
        ),
      );
      final ai = await service(transport: transport);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      final stream = (start as AiStarted).stream;
      Object? error;
      await stream.text.drain<void>().catchError((Object e) {
        error = e;
      });
      await stream.done.then<void>(
        (_) {},
        onError: (Object e) {
          error = e;
        },
      );
      expect(error, isA<ext.AiTransportException>());
      expect(
        AiRun.describeError(error!),
        '上游暂时没有返回内容，请稍后重试',
        reason: 'message 由实现方给，核心原样显示、不拼任何前缀',
      );
    });

    test('取消：done 以已拿到的部分收尾，实现方收到取消', () async {
      final transport = _FakeAiTransport(
        chunks: const <String>['你'],
        staysOpen: true,
      );
      final ai = await service(transport: transport);
      final start = await ai.rewrite(
        selection: '原文',
        tone: RewriteTone.polish,
      );
      final stream = (start as AiStarted).stream;
      final parts = <String>[];
      stream.text.listen(parts.add);
      await Future<void>.delayed(Duration.zero);
      stream.cancel();
      expect(await stream.done, '你');
      expect(transport.cancelled, isTrue);
      expect(parts, <String>['你']);
    });
  });

  group('公开面不留商业痕迹（§6.1 / 验收标准 1）', () {
    test('实现方的文案不写进公开 ARB', () {
      for (final locale in <String>['zh', 'en']) {
        final content = arb(locale);
        expect(
          content.contains('设备授权失效，请重新激活'),
          isFalse,
          reason: 'ARB 里不许出现实现方给的错误文案（locale=$locale）',
        );
        expect(
          content.contains('示例通道'),
          isFalse,
          reason: 'ARB 里不许出现通道显示名（locale=$locale）',
        );
      }
    });

    test('公开 ARB 里没有商业词（Pro / 订阅 / 积分）', () {
      final commercial = RegExp(r'\bPro\b|订阅|积分');
      for (final locale in <String>['zh', 'en']) {
        final hits = commercial.allMatches(arb(locale))
            .map((m) => m.group(0))
            .toList();
        expect(hits, isEmpty, reason: 'app_$locale.arb 出现了商业词：$hits');
      }
    });

    test('通道行自己的通用词都在 ARB 里（不是硬编码）', () {
      for (final locale in <String>['zh', 'en']) {
        final content = arb(locale);
        for (final key in <String>[
          'aiChannelSection',
          'aiChannelChecking',
          'aiChannelReady',
          'aiChannelUnavailable',
        ]) {
          expect(content, contains('"$key"'), reason: '$key @ $locale');
        }
      }
    });
  });
}
