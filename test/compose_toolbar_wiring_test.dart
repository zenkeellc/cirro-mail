// 两条**接线**的回归测试（都是「只钉到回调边界」留下的洞）：
//
// 1. 工具栏 AI 下拉选中的**语气**要真的到面板里（`compose_screen.dart` 的
//    `onAiTone` → `_rewriteSelection` / `_draftWithAi` → `initialTone`）。
//    原来的 `AI 下拉：六个语气一个不少` 只断言 spy 收到了 `RewriteTone.formal`，
//    面板里那个 chip 到底选没选中没人管。
// 2. 签名 / 常用语两颗按钮插入的**是各自那份文本**（`compose_screen.dart`
//    的 `onInsertSignature` / `onInsertPhrase`）。
//
// 两条都从**真的 `ComposeScreen`** 上打进去（这样 `compose_screen.dart` 的调用点
// 在用例内部），而不是对面板/工具栏做单测 —— 单测测不到接线。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/compose/ai/ai_draft_sheet.dart';
import 'package:mail_app/features/compose/ai/ai_rewrite_sheet.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _email = 'me@example.com';

/// 签名与常用语的文本**刻意不同**，而且互不为子串 —— 两个回调对调时
/// 两条断言都会红。
const String _signatureText = '——\n王五\n示例公司';
const String _phraseText = '方便的话，我们约周四下午三点。';

const Profile _profile = Profile(
  id: 'p1',
  baseUrl: 'https://x/api',
  email: _email,
  userId: 7,
);

const MailboxAccount _box = MailboxAccount(
  accountId: 1,
  email: _email,
  name: 'Me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 把**真的** `ComposeScreen` 挂起来。
  ///
  /// - `bootstrapProvider` 一次性给齐 `db` / `tokens` / `prefs` 三样 ——
  ///   只给 `databaseProvider` 一条的话，设置了发件人之后 `refreshQuota` 会去
  ///   建 runtime（`runtimeRegistryProvider` → `tokenStoreProvider` →
  ///   `bootstrapProvider`）而当场抛「必须被 override」。
  /// - `profilesProvider` + `mailboxesProvider` 给出一个发件邮箱：
  ///   `ComposeController.build` 的发件人候选是 `senderCandidates(mailboxes,
  ///   profile)`，而 `profile` 为空时**候选一律为空** —— 所以两样都要给。
  /// - `aiSettingsProvider` 覆盖成「配得上 AI」（有 key / 地址 / 模型），
  ///   否则 `aiUsable` 为假、`ct-ai` 根本不画。形状照 `test/ai_reply_test.dart`。
  Future<ProviderContainer> pumpCompose(
    WidgetTester tester, {
    bool seedSnippets = false,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    if (seedSnippets) {
      await prefs.setSignature(_email, _signatureText);
      await prefs.setPhrases(_email, const <WritingSnippet>[
        WritingSnippet(id: 'ph1', name: '约时间', text: _phraseText),
      ]);
    }
    final container = ProviderContainer.test(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        // 钉住「当前实例」：`ComposeController.build` 用
        // `args.resolveProfileId(currentProfileId)` 定 profileId，而它在第一帧
        // 同步跑 —— 那时 `profilesProvider` 这条流还没吐值，不 override 的话
        // profileId 会定成空串，`profileByIdProvider` 永远是 null、发件人候选
        // 也就是空的（签名 / 常用语两颗按钮都不画）。照
        // `test/compose_draft_open_test.dart` 的做法直接钉死。
        currentProfileIdProvider.overrideWithValue(_profile.id),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(const <MailboxAccount>[_box]),
        ),
        aiSettingsProvider.overrideWith(() => _UsableAiSettings()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const ComposeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  // ------------------------------------------------------------------ 洞 1

  q.QuillController editorOf(WidgetTester tester) =>
      tester.widget<MailQuillEditor>(find.byType(MailQuillEditor)).controller;

  /// 读某个语气 chip 是不是选中的。**必须读 `ChoiceChip.selected`** ——
  /// 两个面板（改写 / 起草）都用 `tone-<枚举名>` 这个 key，只有选中态能
  /// 分辨「面板没收下那个语气」。
  bool toneSelected(WidgetTester tester, RewriteTone tone) => tester
      .widget<ChoiceChip>(find.byKey(ValueKey('tone-${tone.name}')))
      .selected;

  /// 洞 1（改写腿）：编辑器里有**非折叠**选区 → 点 `ct-ai` → `ct-ai-formal`
  /// → 打开的是改写面板，且「更正式」chip **已经选中**。
  ///
  /// 抓的变异：把 `compose_screen.dart:1293` 的 `initialTone: tone` 改成
  /// `initialTone: RewriteTone.polish`（或干脆删掉、走默认值）—— 面板照样
  /// 打开、spy 照样收到 `formal`，但下面那条 `toneSelected(formal)` 会红。
  testWidgets('AI 语气→改写面板：点「更正式」后面板里「更正式」chip 是选中的',
      (tester) async {
    await pumpCompose(tester);

    // 编辑器里放一段文字、选中它（非折叠）—— 这样走的是改写腿。
    final controller = editorOf(tester);
    controller.replaceText(
      0,
      0,
      '这段话要改',
      const TextSelection.collapsed(offset: 5),
    );
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      q.ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ct-ai')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-ai-formal')));
    await tester.pumpAndSettle();

    expect(find.byType(AiRewriteSheet), findsOneWidget,
        reason: '有选区时应当开改写面板（不是起草面板）');
    expect(toneSelected(tester, RewriteTone.formal), isTrue,
        reason: '「更正式」是用户点的那一个，面板打开就该是它选中');
    expect(toneSelected(tester, RewriteTone.polish), isFalse,
        reason: '默认润色不该还亮着 —— 那说明语气没传进面板');
  });

  /// 洞 1（起草腿）：编辑器选区**折叠** → 点 `ct-ai` → `ct-ai-formal`
  /// → 打开的是起草面板，且「更正式」chip 已选中。
  ///
  /// 这是同一条三元表达式的**另一半**：抓的是两条腿对调
  /// （折叠走改写、非折叠走起草），或起草那条忘了传 `initialTone`
  /// （`compose_screen.dart:1340`）。
  testWidgets('AI 语气→起草面板：折叠选区时点「更正式」，起草面板里它已选中',
      (tester) async {
    await pumpCompose(tester);
    // 默认就是折叠选区（光标在 0），不必额外造。

    await tester.tap(find.byKey(const ValueKey('ct-ai')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-ai-formal')));
    await tester.pumpAndSettle();

    expect(find.byType(AiDraftSheet), findsOneWidget,
        reason: '折叠选区时应当开起草面板（不是改写面板）');
    expect(toneSelected(tester, RewriteTone.formal), isTrue,
        reason: '起草面板也要收下工具栏选的那个语气');
    expect(toneSelected(tester, RewriteTone.polish), isFalse);
  });

  // ------------------------------------------------------------------ 洞 2

  /// 洞 2：签名按钮插的是**签名**的文本，常用语按钮插的是**常用语**的文本。
  ///
  /// 抓的变异：`compose_screen.dart:491-495` 两个回调对调（签名按钮插常用语、
  /// 常用语按钮插签名），或把常用语写成 `phrases.first` 硬塞给签名按钮 ——
  /// 两条都靠「两次插入的文本各不相同」钉住。
  testWidgets('签名 / 常用语按钮：各自插入各自那份文本', (tester) async {
    await pumpCompose(tester, seedSnippets: true);

    // 前置条件：发件人定了、签名按钮画出来了（否则下面的点击是空的）。
    expect(find.byKey(const ValueKey('ct-signature')), findsOneWidget,
        reason: '前置条件：发件人已定、签名已配，按钮应当出现');
    expect(find.byKey(const ValueKey('ct-phrase')), findsOneWidget,
        reason: '前置条件：常用语非空，下拉应当出现');

    await tester.tap(find.byKey(const ValueKey('ct-signature')));
    await tester.pumpAndSettle();
    final afterSignature = editorOf(tester).document.toPlainText();
    expect(afterSignature, contains(_signatureText),
        reason: '签名按钮要插签名的文本');
    expect(afterSignature, isNot(contains(_phraseText)),
        reason: '插入的不能是常用语 —— 两个回调对调时这里会红');

    // 常用语：点下拉 → 点那一条。
    await tester.tap(find.byKey(const ValueKey('ct-phrase')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-phrase-ph1')));
    await tester.pumpAndSettle();
    final afterPhrase = editorOf(tester).document.toPlainText();
    expect(afterPhrase, contains(_phraseText),
        reason: '常用语条目要插那一句常用语的文本');
  });
}

/// 一份「配得上 AI」的设置（有厂商、有模型、存过 Key），把 `aiUsable` 掰成真。
///
/// 继承真实的 `AiSettingsController`（不是另起一个 AsyncNotifier）：
/// `aiSettingsProvider` 的类型参数就是它，`overrideWith` 的工厂必须还它
/// （形状照 `test/ai_reply_test.dart` 的 `_UsableAiSettings`）。
class _UsableAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
      );
}
