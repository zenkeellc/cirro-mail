import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组只钉 prompt 的两件事：**要求的是「开头」而不是整封信**，
/// 以及**夹了条数**。生成与落地由别的用例管。
void main() {
  group('回复建议的 prompt', () {
    test('要求只写开头、不要整封信', () {
      final p = AiPrompts.replySuggestions(incoming: '请问下周的会议时间定了吗？');
      expect(p, contains('请问下周的会议时间定了吗？'));
      // 「只写开头」是这个能力与「起草」唯一的区别（spec §6.1）——
      // 少了这句，模型会写出一整封信，而用户自己还要写正文，
      // 拿到手的东西没法用。
      expect(p, contains('开头'));
      expect(p, contains('2'), reason: '条数要写进 prompt');
    });

    test('要几条就写几条', () {
      expect(AiPrompts.replySuggestions(incoming: 'x', count: 3), contains('3'));
    });

    test('来信为空时不崩', () {
      expect(() => AiPrompts.replySuggestions(incoming: ''), returnsNormally);
    });
  });

  group('候选抠取', () {
    test('一行一条，序号剥掉、引号不剥', () {
      final raw = '1. 好的，我确认一下时间。\n'
          '2. 「会议时间我这边没问题。」\n'
          '- 收到，我看下日历再回你。\n';
      final lines = AiPrompts.replyCandidates(raw);
      // ⚠️ **实测订正过**：`parseLines`（`ai_prompts.dart:151`）只剥**序号**
      // 与 `- ` / `* `，**不剥引号**（实测：`「会议时间我这边没问题。」` 原样
      // 出来）。`replyCandidates` 是**复用** `parseLines` 的，不另写一套
      // 拆分 —— 所以这里期望的是**带引号**的那一句。它同时钉住「确实复用了
      // parseLines」：另写一套拆分会把引号剥掉，这条就会红。
      expect(lines, <String>[
        '好的，我确认一下时间。',
        '「会议时间我这边没问题。」',
        '收到，我看下日历再回你。',
      ]);
    });

    test('空行与说明性的一行不算候选', () {
      final raw = '\n好的。\n\n以上是三个开头。\n';
      // `以上是…` 这种收尾话要能被滤掉，否则它会变成一个用户点下去
      // 插进正文的候选。宁可少一条，不要插一句废话。
      expect(AiPrompts.replyCandidates(raw), <String>['好的。']);
    });

    test('最多给三条', () {
      final raw = 'a\nb\nc\nd\ne\n';
      expect(AiPrompts.replyCandidates(raw).length, 3);
    });
  });

  // ---------------------------------------------------------------- 入口条件

  TestWidgetsFlutterBinding.ensureInitialized();

  group('入口条件（spec §6.3）', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    /// 建一个**能被测试读到 state** 的容器（与 `compose_editor_wiring_test`
    /// 的 `pumpCompose` 同形）：回写/组装都靠 `ProviderContainer.test`。
    ///
    /// **覆盖 `aiSettingsProvider` 成一份「可用」的设置**：不覆盖的话 AI 没配，
    /// `aiUsable` 为假 —— 那样「按钮没画」两个条件谁为假都能成立，这条用例就
    /// 退化成非判别性的了。覆盖之后 `aiUsable` 恒真，唯一能让 `ct-ai-reply`
    /// 缺席的就是**第二个**条件（`_incomingBody == null`）。
    ///
    /// **不要自己再 `addTearDown(container.dispose)`** —— `ProviderContainer.test`
    /// 内部已经挂了一个，dispose 两次会报「already disposed」。
    Future<ProviderContainer> pumpCompose(
      WidgetTester tester, {
      ComposeArgs args = const ComposeArgs(),
    }) async {
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      final container = ProviderContainer.test(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          aiSettingsProvider.overrideWith(
            () => _UsableAiSettings(),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: ComposeScreen(args: args),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    /// **空写信页（`ComposeArgs()` 的 `mail == null`）不画 `ct-ai-reply`。**
    ///
    /// 这条钉的是**第二个**入口条件（`_incomingBody != null`），而且它**真的是
    /// 判别性的**：`aiSettingsProvider` 已被覆盖成一份「可用」的设置，所以
    /// `aiUsable` 恒真 —— 唯一能让 `ct-ai-reply` 缺席的就是 `mail == null`。
    ///
    /// 前置条件由下面那句 `ct-ai` 断言兜着：AI 下拉在那儿，说明「配得上 AI」
    /// 这一条成立；此时回复建议那颗仍然不画，就只能是「没有来信正文」那一条把
    /// 它拦下了。少了这个对照，这条用例会退化成非判别性的（见覆盖处的注释）。
    ///
    /// 正方向（有来信正文 → 按钮出现）需要一份 `MailRow` 夹具，这里**不声称**
    /// 测到了那一半 —— 它由 `_incomingBody` 自己的逻辑覆盖。
    testWidgets('空写信页：AI 已配好，但没来信正文，回复建议按钮仍不画', (tester) async {
      await pumpCompose(tester);
      // 前置条件：AI 那条下拉在 → `aiUsable` 为真（否则下面那条断言是空的）。
      expect(find.byKey(const ValueKey('ct-ai')), findsOneWidget,
          reason: '前置条件：AI 配好了，ct-ai 应当出现');
      // 结论：第二个条件不成立 → 回复建议那颗不画。
      expect(find.byKey(const ValueKey('ct-ai-reply')), findsNothing);
    });

    /// **转发：有来信正文，但仍然不画 `ct-ai-reply`。**
    ///
    /// 这条钉的是**模式**那半条闸门。转发时 `args.mail` 也是非 null
    /// （`compose_entry.dart` 转发也传 `mail: _row`），而 `_incomingBody`
    /// 只看 `mail` 不看模式 —— 光靠「有来信正文」放行的话，转发页就会冒出
    /// 回复建议，点下去是拿一封你正要转出去的信去生成回信开头（spec §6.3
    /// 把转发与普通写邮件、`_row == null` 并列为三种不画的情形）。
    ///
    /// 判别性由下面那句 `ct-ai` 断言兜着：AI 下拉在 → `aiUsable` 为真；
    /// `mail != null` 且正文非空 → 「有来信正文」那半条也为真。此时唯一还能
    /// 让 `ct-ai-reply` 缺席的就是「模式不是 reply」—— 去掉模式判断这条会红。
    testWidgets('转发页：有来信正文，但模式不是回复，回复建议按钮不画',
        (tester) async {
      await pumpCompose(
        tester,
        args: ComposeArgs(mode: ComposeMode.forward, mail: _incomingRow),
      );
      // 前置条件：AI 配好了（`ct-ai` 在），且这封信确实有正文。
      expect(find.byKey(const ValueKey('ct-ai')), findsOneWidget,
          reason: '前置条件：AI 配好了，ct-ai 应当出现');
      expect(_incomingRow.content, isNotEmpty,
          reason: '前置条件：夹具这封信得有正文，否则测不到模式那半条');
      // 结论：模式不是 reply → 那颗按钮不画。
      expect(find.byKey(const ValueKey('ct-ai-reply')), findsNothing);
    });

    /// **回复：有来信正文且模式是 reply → 按钮在。**（正方向）
    ///
    /// 与上面转发那条合起来才把 `_canSuggestReply` 的**两个与项都钉住**：
    /// 转发这条红说明「模式」在起作用，回复这条红说明没把闸门关死。
    testWidgets('回复页：有来信正文 → 回复建议按钮出现', (tester) async {
      await pumpCompose(
        tester,
        args: ComposeArgs(mode: ComposeMode.reply, mail: _incomingRow),
      );
      expect(find.byKey(const ValueKey('ct-ai')), findsOneWidget,
          reason: '前置条件：AI 配好了，ct-ai 应当出现');
      expect(find.byKey(const ValueKey('ct-ai-reply')), findsOneWidget);
    });

    /// **回复建议真正吃到的**，是 `_incomingBody` 那一步转出来的纯文本 ——
    /// 不只是「按钮在」。
    ///
    /// 这条专治 `_incomingBody` 的**无声失败**：它走 `ComposeHtml.originalBody`
    /// → `MailHtmlToDelta.convert` → `toPlainText()`，任何一步坏掉都只是返回
    /// `null`，于是那颗按钮**静默消失**（没有异常、没有别的断言会红）。上面三条
    /// 入口条件用例只断言按钮在不在，分不出「本来就该没有」与「取文本坏了」；
    /// 只有「有来信正文」这条正向用例间接触到它。这里把**内容**钉住：来信是一段
    /// 可辨认的病句/口令式文本，断言它**逐字**送到 `AiService.replySuggestions`
    /// 的 `incoming`，并且面板顶部显示的也是它。
    ///
    /// **能红它的改动**（两处都实测过）：
    /// - 把 `ComposeHtml.originalBody` 里的 `original.content` 换成别的字段
    ///   （比如 `original.text`，夹具没给 → 空 → 按钮又不画）：红在
    ///   `find.byKey('ct-ai-reply')` found 0。
    /// - 让 `_incomingBody` 跳过 HTML→纯文本那一步、直接把净化 HTML 当正文：
    ///   按钮照样在，但 `service.seenIncoming` 是 `'<p>…</p>'` 而不是那串字 →
    ///   红在下面那条逐字断言（这才是「只有本用例抓得住、别的用例全绿」的那种
    ///   无声降级）。
    testWidgets('回复页：来信纯文本逐字喂给回复建议（不是只看按钮在不在）',
        (tester) async {
      final service = _FakeReplyService();
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      final container = ProviderContainer.test(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          aiSettingsProvider.overrideWith(() => _UsableAiSettings()),
          aiServiceProvider.overrideWithValue(service),
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
              args: ComposeArgs(mode: ComposeMode.reply, mail: _incomingRow),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 前置：按钮确实画了（否则这封来信压根没被当作「有正文」）。
      expect(find.byKey(const ValueKey('ct-ai-reply')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ct-ai-reply')));
      await tester.pumpAndSettle();

      // 结论：`_suggestReply(settings, _incomingBody!)` 里那串字，**就是**来信
      // 净化后的纯文本 —— 逐字相等，不是「非空」。
      expect(
        service.seenIncoming,
        '请问下周的会议时间定了吗？',
        reason: '`_incomingBody` 出来的字与来信正文对不上：'
            '净化 / HTML→Delta / 取纯文本 / 读错字段，任何一处坏了都是这个症状，'
            '而按钮消失那条路是无声的 —— 这条是它的哨兵',
      );
      // 面板顶部显示的就是喂进去的那段字（用户据此确认「它在看这封信」）。
      final shown = tester.widget<Text>(
        find.byKey(const ValueKey('ai-reply-incoming')),
      );
      expect(shown.data, service.seenIncoming);
    });

    /// **面板与它的候选二次弹出都自包一层 `TextFieldTapRegion`**（spec §1.3
    /// 硬约束：每个新弹出层的根 widget 都要声明自己是输入框的点击区域）。
    ///
    /// ## 为什么这一条只能写成**结构断言**
    ///
    /// 本机实测（`flutter test`，探针放 `/tmp`）：去掉这两层 region 之后
    /// **没有任何可观测差异** —— 点 `ct-ai-reply` 打开面板、再点候选把一句话
    /// 选回来，`hasFocus` 前后都是 `true→false→true`，`controller.selection`
    /// 也逐字不变，插进去的字符落点一样。原因是 `showModalBottomSheet` 走的
    /// 是**路由**：它是顶层 `PopupRoute`，自己的 `_ModalScopeState` 在动画起
    /// 步就抢走 primary focus，正文那一圈 `TextFieldTapRegion` 拦不住这一层
    /// （android/iOS/macOS/linux/windows/fuchsia 六种 target 都试过，一样）。
    /// 所以**这条要求的护栏只能是结构性的**：region 留着是照 §1.3 的一致做法
    /// （同 `ToolbarMenu` / `_ImageActionsSheet`），不是因为本机能量到行为收益。
    ///
    /// 写成一个「点一下、断言 `hasFocus` 仍为 true」的行为测试是**不能失败**
    /// 的空测试 —— 去掉 region 它照样绿，那种绿是假的。这里诚实地钉结构。
    ///
    /// **能红它的改动**（已实测）：把 `AiReplySheet.build` 根上那层
    /// `TextFieldTapRegion` 删掉（退回裸 `SafeArea`）→ 下面第一条
    /// `find.ancestor` 立刻 `findsNothing` 而红；把 `_pick` 里二次弹窗
    /// builder 的根那层删掉 → 第二条同样红。两条各钉一个 site，缺一不可
    /// （spec 指出这正是「最容易回归的一点」）。
    testWidgets('面板与候选二次弹出各自包一层 TextFieldTapRegion（spec §1.3）',
        (tester) async {
      final service = _FakeReplyService();
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      final container = ProviderContainer.test(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          aiSettingsProvider.overrideWith(() => _UsableAiSettings()),
          // 假 service：面板一构造就发请求，真 HTTP 会在测试里失败；
          // 这里回一条能抠出候选的文本，好触发 `_pick` 那条二次弹出。
          aiServiceProvider.overrideWithValue(service),
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
              args: ComposeArgs(mode: ComposeMode.reply, mail: _incomingRow),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // site 1：面板自己（`AiReplySheet.build` 的根）。
      await tester.tap(find.byKey(const ValueKey('ct-ai-reply')));
      await tester.pumpAndSettle();
      // region 就在面板自己的 `build` 返回的树里，所以断言「面板内容（来信
      // 那段）的上方恰好有一层 region」—— 这比「AiReplySheet 子树里有几层
      // region」稳：那一层 region 底下还可能有别的自包 region 的控件（实测
      // 子树里是 2 层），但**来信那段**上方只应有一层，就是 `build` 的根。
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('ai-reply-incoming')),
          matching: find.byType(TextFieldTapRegion),
        ),
        findsOneWidget,
        reason: 'AiReplySheet 的根必须自包一层 TextFieldTapRegion（spec §1.3）。'
            '它产出的文字由 `_suggestReply` 插在**光标处** —— 少了这层声明，'
            '点面板会被 quill 当成「点到编辑器外面」。'
            '能红它：删掉 `build` 根上那层 region（实测会 findsNothing）。',
      );

      // site 2：候选列表那个**嵌套** `showModalBottomSheet<String>`。
      await tester.tap(find.byKey(const ValueKey('ai-reply-insert')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-reply-candidate-0')),
        findsOneWidget,
        reason: '前置：假 service 回了一条候选，二次弹窗应当已打开',
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('ai-reply-candidate-0')),
          matching: find.byType(TextFieldTapRegion),
        ),
        findsOneWidget,
        reason: '候选二次弹出（`_pick`）的 builder 根同样要包 region（spec §1.3）。'
            '这一层 `pop` 的是**要插到光标处**的那一句话。'
            '能红它：删掉 `_pick` builder 根上那层 region。',
      );
    });
  });
}

/// 只回答 `replySuggestions` 的假 service —— 用来**抓住**喂进去的来信正文。
///
/// `AiStream` 用 `Stream.value` + `Future.value`（与 `compose_polish_quote_test`
/// 的假 service 同形）：这一组不关心分帧，只关心「发出去的 `incoming` 是什么」。
class _FakeReplyService implements AiService {
  /// 最近一次 `replySuggestions` 收到的来信正文。断言 `_incomingBody` 全靠它。
  String? seenIncoming;

  @override
  int get usedToday => 0;

  @override
  bool overDailyLimit(AiSettings settings) => false;

  @override
  Future<AiStart> replySuggestions({
    required String incoming,
    int count = 3,
  }) async {
    seenIncoming = incoming;
    // 回一条能抠出来的候选，面板就不必画「没返回内容」。
    const reply = '1. 我确认一下时间。';
    return AiStarted(
      AiStream(
        text: Stream<String>.value(reply),
        done: Future<String>.value(reply),
        cancel: () {},
      ),
    );
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这一组测试不用 ${invocation.memberName}');
}

/// 一封有正文的信 —— 两处入口条件用例都用它。
///
/// **必须带 `content`**：`_incomingBody` 走 `ComposeHtml.originalBody`，
/// 没有 HTML 也没有 `text` 时它返回空串，于是「有来信正文」那半条不成立，
/// 转发那条就测不到「模式」了（形状照抄 `compose_editor_wiring_test.dart`
/// 的 `_row`）。
final _incomingRow = MailRow(
  emailId: 7,
  profileId: 'p1',
  accountId: 1,
  subject: '主题',
  sendEmail: 'alice@example.com',
  name: 'Alice',
  createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
  content: '<p>请问下周的会议时间定了吗？</p>',
);

/// 一份「配得上 AI」的设置（有厂商、有模型、存过 Key）—— 只给上面那条
/// 入口条件用例用，把 `aiUsable` 从假掰成真，让用例真的在测 `_incomingBody`。
///
/// 继承真实的 `AiSettingsController`（不是自己另起一个 AsyncNotifier）：
/// `aiSettingsProvider` 的类型参数就是它，`overrideWith` 的工厂必须还它。
class _UsableAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
      );
}
