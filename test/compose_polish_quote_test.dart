import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_prompts.dart' show RewriteTone;
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_quote.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/html/delta_to_email_html.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **点一下右上角那颗润色图标**，端到端验用户报的那个 bug：
/// 「AI 润色把引用进来的旧邮件也改写了一遍」。
///
/// 为什么还要这一层（`compose_quote_test.dart` 已经覆盖了 `userEnd` /
/// `_replaceUserBody` 的算法）：那一组验的是**算法**，这一组验的是**接线** ——
/// `_polishAll` 到底把哪一段发给了模型、回来后 `_replaceUserBody` 又落在谁身上。
/// 两者之间任何一处接错（比如反过来用了 `composePlainText()`）都会让算法那一组
/// 全绿而用户照旧被改写引用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 造一个「配得上 AI」的页面，并把 `rewrite` 的结果换成固定的一句。
  ///
  /// 只 override 三个 provider：设置（绕开钥匙串）、service（绕开网络）、
  /// prefs。其余（database / runtime）**刻意不 override** —— 与
  /// `compose_editor_wiring_test.dart` 同一个理由：它们的失败是
  /// `scheduleMicrotask` 出去的、被吞掉，而这一组只关心正文区与那颗图标。
  Future<({ProviderContainer container, _FakeRewriteService ai})> pumpPolish(
    WidgetTester tester, {
    required String polished,
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final ai = _FakeRewriteService(polished);
    final container = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        // 有 Key、有地址、有模型 —— 三个条件齐了页面才会画出那颗润色图标。
        aiSettingsStoreProvider.overrideWithValue(
          _FakeSettingsStore(
            const AiSettings(model: 'm', baseUrl: 'https://x/v1', hasApiKey: true),
          ),
        ),
        aiServiceProvider.overrideWithValue(ai),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: ComposeScreen(
            args: ComposeArgs(mode: ComposeMode.reply, mail: _row),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, ai: ai);
  }

  testWidgets('润色只发用户写的那段，落地后引用与横线一字不动', (tester) async {
    final (:container, :ai) = await pumpPolish(tester, polished: '您好。');
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));

    // 在引用上方（光标默认就在 offset 0）写两句话。
    editor.controller.replaceText(
      0,
      0,
      '你好\n谢谢',
      const TextSelection.collapsed(offset: 5),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('润色全文'));
    await tester.pumpAndSettle();

    // 图标现在只开面板 —— 用户先设好参数、再点面板里的「生成」才真的花钱
    // （本轮改的正是这个）。点完就发请求，再点「替换全文」才落回正文。
    expect(ai.seenSelection, isNull, reason: '点了图标就发请求 —— 用户没有机会设参数');
    await tester.tap(find.byKey(const ValueKey('polish-generate')));
    await tester.pumpAndSettle();

    // ① **发给模型的那一段**里没有引用 —— 这正是用户报的 bug。
    expect(ai.seenSelection, isNotNull, reason: '润色没有发起调用（面板没找到 / 生成被挡住）');
    expect(ai.seenSelection, contains('你好'));
    expect(ai.seenSelection, isNot(contains('第一段')),
        reason: '整篇被喂给了模型 —— 引用会被一起改写');
    expect(ai.seenSelection, isNot(contains('写道：')),
        reason: '归属行也是引用的一部分，不该出现在模型的输入里');

    await tester.tap(find.byKey(const ValueKey('polish-replace')));
    await tester.pumpAndSettle();

    // ② 落地之后：用户那段被换掉，引用区与横线原样。
    final after = editor.controller.document.toDelta().toJson();
    expect(ComposeQuote.plainText(after), '您好。');

    final html = DeltaToEmailHtml.convert(after);
    expect(html, contains('第一段'), reason: '引用原文被润色吃掉了');
    expect(html, contains('写道：'), reason: '归属行被润色吃掉了');
    expect(html, contains('<hr '),
        reason: '横线没了 = 替换把上一行的行尾 `\\n` 也吃掉了');
    expect(html, contains('<blockquote '),
        reason: '引用块的行属性丢了 —— 收件人看到的就不再是引用');
    expect(
      after.any((op) =>
          (op['attributes'] as Map?)?[MailHtmlToDelta.quoteAttribute] == true),
      isTrue,
      reason: '引用标记没了 → 下一次润色就会把引用也改一遍',
    );

    // ③ 页面还得活着（没有在异步那一头炸掉）。
    expect(find.byType(MailQuillEditor), findsOneWidget);
    expect(container.read(composeControllerProvider(
      ComposeArgs(mode: ComposeMode.reply, mail: _row),
    )).problems, isEmpty);
  });

  testWidgets('引用里的图不拦润色（回复一封带图的邮件照样能用）', (tester) async {
    // 用户区只有字，图在引用里 —— 早先「整篇任何嵌入都拦」会让这条整条用不了。
    final (:container, :ai) = await pumpPolish(tester, polished: '收到。');
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    final doc = editor.controller.document;
    // 在引用区里塞一张图（引用原文本来就带图的那种邮件）。`Document.insert`
    // 只收 `String` 或 `Embeddable` —— 裸 Map 会被它的断言挡下。
    final end = doc.length - 1;
    doc.insert(end, q.BlockEmbed.image('data:image/png;base64,AAA'));
    editor.controller.replaceText(
      0,
      0,
      '谢谢',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('润色全文'));
    await tester.pumpAndSettle();
    // 先设参数、再点生成 —— 这条测的是「引用里的图不该把整条路拦掉」，
    // 于是必须在生成之前就断言拦没拦：面板能开出来本身就已经说明守卫放行了。
    await tester.tap(find.byKey(const ValueKey('polish-generate')));
    await tester.pumpAndSettle();

    expect(ai.seenSelection, isNotNull,
        reason: '引用里的图把整条润色拦掉了 —— 回复带图邮件时用户完全没有润色可用');

    await tester.tap(find.byKey(const ValueKey('polish-replace')));
    await tester.pumpAndSettle();
    expect(ComposeQuote.plainText(doc.toDelta().toJson()), '收到。');
    expect(container.read(composeControllerProvider(
      ComposeArgs(mode: ComposeMode.reply, mail: _row),
    )).problems, isEmpty);
  });
}

/// 只回答 `rewrite` 的假 service。四项能力里润色走的就是它，别的抛出来。
///
/// `AiStream` 用 `Stream.value` + `Future.value` 而不是 `StreamController`：
/// 这一组不关心「分帧」，只关心**发出去的是什么、落回来的又是什么**；
/// 少一个 controller 就少一处要收的资源。
class _FakeRewriteService implements AiService {
  _FakeRewriteService(this.result);

  final String result;

  /// 最近一次发给模型的「选区」。断言「引用没被喂进去」全靠它。
  String? seenSelection;

  @override
  int get usedToday => 0;

  @override
  bool overDailyLimit(AiSettings settings) => false;

  @override
  Future<AiStart> rewrite({
    required String selection,
    required RewriteTone tone,
    String? extraInstruction,
  }) async {
    seenSelection = selection;
    return AiStarted(
      AiStream(
        text: Stream<String>.value(result),
        done: Future<String>.value(result),
        cancel: () {},
      ),
    );
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这一组测试不用 ${invocation.memberName}');
}

/// 绕开钥匙串的设置来源：读出来就是给定的一份。
class _FakeSettingsStore implements AiSettingsStore {
  _FakeSettingsStore(this._settings);

  final AiSettings _settings;

  @override
  Future<AiSettings> load() async => _settings;

  @override
  bool get isKeychainDegraded => false;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这一组测试不用 ${invocation.memberName}');
}

/// `MailRow.createTime` 是 `DateTime?` —— 这里必须给一个 `DateTime`。
final _row = MailRow(
  emailId: 7,
  profileId: 'p1',
  accountId: 1,
  subject: '主题',
  sendEmail: 'alice@example.com',
  name: 'Alice',
  createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
  content: '<p>第一段</p>',
);
