// 「在设置里改签名 → 打开写信页 → 工具栏那颗按钮插的就是那个签名」——
// 这条**端到端往返**在原来的套件里一个护栏都没有。
//
// 各条现有用例各钉一半，谁都不从设置页走到写信页：
// - `writing_snippets_provider_test.dart` 钉 notifier 的**写入路径**
//   （`setSignature` / `setPhrases` 各改各的），但完全不碰设置页 UI、
//   也不碰写信页；
// - `compose_toolbar_menus_test.dart` 把 `ComposeToolbar` 单独挂起来，
//   回调是测试自己给的 spy —— 测不到 `compose_screen.dart` 的接线；
// - `compose_toolbar_wiring_test.dart`（commit b6c80b2）确实从真的
//   `ComposeScreen` 打进去、钉住了「签名按钮插签名、常用语按钮插常用语」，
//   但它**直接往 `PrefsStore` 里塞**种子，绕开了设置页那条写入腿。
//
// 于是「设置页的写」与「写信页的读」中间那段（`compose_section.dart` 的
// `_editSignature` → `writingSnippetsProvider(email).notifier.setSignature`）
// 仍然没有任何用例经过。这条把**两个真的界面**用**同一个容器、同一份 prefs**
// 串起来：先在设置页的对话框里打字保存，再挂起真的 `ComposeScreen`，
// 断言最后落进正文的**就是刚才在对话框里打的那段字**。
//
// **这条用例挡住哪些 mutation**（实测见提交信息）：
// 1. 删掉 `_editSignature` 里那次 `setSignature`（设置页的写不落盘）→
//    「落进正文的是新签名」红；「保存空串才清除」也红；
// 2. `prefs_store.dart` 的 `signatureFor` 读键与 `setSignature` 写键不一致
//    （例如读 `signatures['$email ']`）→ 对话框的预填红（拿到空串）。
//
// 取材说明：sibling 的 `compose_toolbar_wiring_test.dart` 里那套 container
// 搭建（`bootstrapProvider` + `currentProfileIdProvider` + `profilesProvider`
// + `mailboxesProvider`）**这里照抄**，但**不能复用它的文件**（那文件在别处
// 维护，且它 seed 的是 store 而不是走设置页 UI）。
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
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';
import 'package:mail_app/features/settings/sections/compose_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 发件邮箱 —— 也是设置页那一行的 key、`writingSnippetsProvider` 的 family 键、
/// 写信页 `state.sender.email`。**三处必须是同一个值**，往返才成立。
const String _senderEmail = 'me@example.com';

/// 设置页**打开时**预填的那份签名。
const String _initialSignature = '旧签名';

/// 在设置页对话框里**新打**进去的签名。与 [_initialSignature] 不互为子串 ——
/// 「写没写进去」靠两者不同来判。
const String _newSignature = '——\n王五\n示例公司';

const String _phraseName = '约时间';
const String _phraseText = '方便的话，我们约周四下午三点。';

/// 发件人从 **profile** 推出来（不是 `ComposeArgs`）：`ComposeController.build`
/// 走 `resolveProfileId(currentProfileId)` → `profileByIdProvider` →
/// `senderCandidates(mailboxes, profile)`，`state.sender.email` 才是 family 键。
const Profile _profile = Profile(
  id: 'p1',
  baseUrl: 'https://x/api',
  email: _senderEmail,
  userName: '王五',
  userId: 7,
);

const MailboxAccount _box = MailboxAccount(
  accountId: 1,
  email: _senderEmail,
  name: 'Me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 建一个**设置页与写信页共用**的容器：往返靠的就是「同一个容器、同一份
  /// prefs」，两端各自从自己的界面读 / 写。
  ///
  /// override 那几条的理由与 `compose_toolbar_wiring_test.dart` 一致：
  /// - `bootstrapProvider` 一次性给齐 db / tokens / prefs（写信页 `build` 里
  ///   `refreshQuota` / `_restoreDraft` 会去碰它们，失败被吞但会真跑）；
  /// - `currentProfileIdProvider` **必须钉死** —— `ComposeController.build`
  ///   在第一帧同步读它，那时 `profilesProvider` 这条流还没吐值，不钉的话
  ///   profileId 定成空串、发件人恒为 null，签名按钮根本不画；
  /// - `profilesProvider` / `mailboxesProvider` 给出那个发件邮箱。
  ///
  /// **不要自己再 `addTearDown(container.dispose)`** —— `ProviderContainer.test`
  /// 内部已经挂了一个（照 `compose_editor_wiring_test.dart` 记的那条）。
  Future<ProviderContainer> newContainer() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    return ProviderContainer.test(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        currentProfileIdProvider.overrideWithValue(_profile.id),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(const <MailboxAccount>[_box]),
        ),
      ],
    );
  }

  Widget host(ProviderContainer container, Widget home) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: home,
        ),
      );

  /// 挂起**真的设置页那一节**（`ComposeSection` 返回的是 `ListView`，给它一个
  /// `Scaffold` 当壳）。
  Future<void> pumpSection(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      host(container, const Scaffold(body: ComposeSection())),
    );
    await tester.pumpAndSettle();
  }

  /// 挂起**真的写信页**（同一个容器 → 读到设置页刚写进去的东西）。
  Future<void> pumpCompose(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(host(container, const ComposeScreen()));
    await tester.pumpAndSettle();
  }

  q.QuillController editorOf(WidgetTester tester) =>
      tester.widget<MailQuillEditor>(find.byType(MailQuillEditor)).controller;

  // ------------------------------------------------------- 签名：往返

  testWidgets('设置页对话框里改的签名：写信页工具栏按钮插的就是刚打的那段字',
      (tester) async {
    final container = await newContainer();
    // 先给这个邮箱配一份**旧签名**（当「原值」的记号；设置页那一行现在也从
    // 邮箱列表来，但这份旧值仍是后面「写没写进去」的对照）。
    await container.read(prefsStoreProvider).setSignature(_senderEmail, _initialSignature);

    await pumpSection(tester, container);
    await tester.tap(find.byKey(const ValueKey('signature-$_senderEmail')));
    await tester.pumpAndSettle();

    // 对话框**预填的是这条邮箱的旧签名** —— 键若读错（读不到 `_senderEmail`），
    // 这里就是空框。
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('signature-input'))).controller?.text,
      _initialSignature,
      reason: '对话框要预填这个邮箱已有的签名（读键错时这里是空串）',
    );

    await tester.enterText(
      find.byKey(const ValueKey('signature-input')),
      _newSignature,
    );
    await tester.tap(find.byKey(const ValueKey('signature-save')));
    await tester.pumpAndSettle();

    // 写入腿落到了存储上（写键错时这里还是 _initialSignature）。
    expect(container.read(prefsStoreProvider).signatureFor(_senderEmail), _newSignature,
        reason: '保存后存储里应是刚打的那段字');

    // 换到真的写信页，同一个容器、同一份 prefs。
    await pumpCompose(tester, container);
    expect(find.byKey(const ValueKey('ct-signature')), findsOneWidget,
        reason: '发件邮箱配了签名，签名按钮应当出现（family 键 = 发件邮箱）');

    final controller = editorOf(tester);
    const preexisting = '这是一句话';
    controller.replaceText(
      0,
      0,
      preexisting,
      const TextSelection.collapsed(offset: preexisting.length),
    );
    controller.updateSelection(
      const TextSelection.collapsed(offset: preexisting.length),
      q.ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ct-signature')));
    await tester.pumpAndSettle();

    final text = controller.document.toPlainText();
    expect(text, contains(_newSignature),
        reason: '落进正文的必须是**设置页里刚打的那段字** —— '
            '设置页那次写入被删掉时，这里读到的是旧签名，红');
    expect(text, isNot(contains(_initialSignature)),
        reason: '插入的不该是设置前的旧签名');
    expect(text, contains(preexisting),
        reason: '光标在行内时插入不该吞掉已有的字（见 snippet_insert.dart）');
  });

  // ------------------------------------------------ 取消 vs 清空的区别

  testWidgets('取消不改签名；保存空串才清除 —— 两者在设置页这条腿上才分得开',
      (tester) async {
    final container = await newContainer();
    await container.read(prefsStoreProvider).setSignature(_senderEmail, _initialSignature);

    await pumpSection(tester, container);

    // ① 取消：对话框里什么都不动、直接关掉 -> 已有签名原样。
    await tester.tap(find.byKey(const ValueKey('signature-$_senderEmail')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(prefsStoreProvider).signatureFor(_senderEmail), _initialSignature,
        reason: '取消（pop 出 null）不该动到已有签名');

    // ② 保存空串：把框清空、保存 -> 签名被清除（`setSignature('')` 删掉那一条）。
    await tester.tap(find.byKey(const ValueKey('signature-$_senderEmail')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('signature-input')), '');
    await tester.tap(find.byKey(const ValueKey('signature-save')));
    await tester.pumpAndSettle();
    expect(container.read(prefsStoreProvider).signatureFor(_senderEmail), isEmpty,
        reason: '保存空串是「清除」，不是「取消」—— 两者不能合并');

    // 写信页上那两颗按钮的「在不在」跟着变：签名没了，`ct-signature` 不画。
    await pumpCompose(tester, container);
    expect(find.byKey(const ValueKey('ct-signature')), findsNothing,
        reason: '签名被清掉后，写信页不该再画签名按钮');
  });

  // ------------------------------------------------------- 常用语：往返

  /// 常用语这条走**删除**而不是「在对话框里新打一条」。
  ///
  /// 原因是这条路线上有一个**疑似缺陷**（本轮只报告、不修，见文件末尾）：
  /// `_editSnippet` 在 `showDialog` 的 `finally` 里把 `TextEditingController`
  /// `dispose()` 掉了，而出栈动画要等对话框**掉完之后**才收，那一帧仍在用这些
  /// controller —— 测试里当场抛
  /// 「A TextEditingController was used after being disposed」（报在
  /// `compose_section.dart` 的 `phrase-text` / `phrase-name` 上）。也就是说
  /// **任何**经过 `_editSnippet` 的路径（新增 / 编辑一条常用语）在 widget 测试里
  /// 都会抛框架异常，测不出来。
  ///
  /// 删除这条不经过 `_editSnippet`（`_delete` 只是 `setState`），照常驱动
  /// **设置页 UI** → `_editPhrases` → `setPhrases` 那条**写入腿**，再回写信页
  /// 看下拉在不在。抓的是「`_editPhrases` 里那次 `setPhrases` 被删掉」：
  /// 删完回写信页，下拉还在，这里就红。
  testWidgets('设置页里删掉的常用语：写信页那颗下拉跟着消失', (tester) async {
    final container = await newContainer();
    await container.read(prefsStoreProvider).setSignature(_senderEmail, _initialSignature);
    await container.read(prefsStoreProvider).setPhrases(_senderEmail, const <WritingSnippet>[
      WritingSnippet(id: 'p1', name: _phraseName, text: _phraseText),
    ]);

    // 设置页 -> 这个邮箱的常用语页 -> 删掉那一条 -> 返回（整组交回）。
    //
    // **只在这条用例里挂一次写信页**（在删完之后）：同一容器反复挂 / 卸
    // `ComposeScreen` 会让 `profilesProvider` 这条流在重订阅后停在
    // `AsyncLoading`（`sender` 变回 null），那是测试宿主反复 montage 的
    // 产物、不是产品行为，所以不在这里绕。省掉的那次「删之前看一眼」
    // 由最后一条 `ct-signature findsOneWidget` 补上：它本身就证明这次挂载
    // 拿到了非空发件人（否则两颗按钮都不画）—— 于是 `ct-phrase findsNothing`
    // 不是空断言。
    await pumpSection(tester, container);
    await tester.tap(find.byKey(const ValueKey('phrases-$_senderEmail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('phrase-delete-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // 写入腿落到存储（`_editPhrases` 的那次 `setPhrases` 被删掉时这里还有值）。
    expect(container.read(prefsStoreProvider).phrasesFor(_senderEmail), isEmpty,
        reason: '从常用语页返回时应当把整组（这里是空组）写回存储');

    // 删之后：写信页那颗下拉没了 —— 设置页的改动真的走到了写信页。
    await pumpCompose(tester, container);
    // 先钉「这次挂载真的拿到了非空发件人」：签名还在，`ct-signature` 画得出来。
    // 少了这一条，下面的 `ct-phrase findsNothing` 在发件人为 null 时也成立。
    expect(find.byKey(const ValueKey('ct-signature')), findsOneWidget,
        reason: '删常用语不该连签名一起没了 —— 两者是两个 key');
    expect(find.byKey(const ValueKey('ct-phrase')), findsNothing,
        reason: '常用语被删光后，写信页不该再画下拉');
  });
}
