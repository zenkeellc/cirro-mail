// 「写邮件」设置节（`compose_section.dart`）的三个复现缺陷的护栏。
//
// 这一节没有入口去**建**第一条签名 / 常用语（地址列表原来只取两张已存表的
// 键），对话框又在退场动画期间把 controller 释放掉。这些用例各钉一条：
//
// 1. 可达性：有邮箱、prefs 全空时，签名 / 常用语两行**必须**画出来（Defect 1）；
// 2. 空态：一台实例都没登时才显示 `composeSignatureEmpty`（护栏：并集别把
//    空态也一并吞掉、硬造行）；
// 3. 常用语往返：走**真的**对话框新增一条 —— 这条在修好前是红的
//    （`used after being disposed` + 新行不出现）（Defect 2）；
// 4. 签名往返 + 取消 / 清空的区别（`null` 是取消、`''` 是清除）。
//
// 容器搭建照 `settings_layout_test.dart`（prefsStore + profiles 的 override）；
// `mailboxesProvider` 的 override 照 `compose_toolbar_wiring_test.dart`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/settings/sections/compose_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _email = 'me@example.com';

const Profile _profile = Profile(
  id: 'p1',
  baseUrl: 'https://x/api',
  email: _email,
  userName: '王五',
  userId: 7,
);

const MailboxAccount _box = MailboxAccount(
  accountId: 1,
  email: _email,
  name: 'Me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 每个用例开始前一份干净的 mock prefs。**放在 `setUp` 而不是 `pump` 里**：
  // 有一个用例要重新挂载看副标题，在 `pump` 里重置会把刚写的签名一起抹掉。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  /// 挂起「写邮件」那一节。
  ///
  /// `profiles` / `mailboxes` 都从外面喂：这条用例关心的只是「哪些地址该出现」，
  /// 不需要真实的库。`mailboxes` 默认给一个邮箱；传 `null` 表示不 override
  /// （空态那条用 —— 一台实例都没登时 `mailboxesProvider` 根本不会被问）。
  Future<PrefsStore> pump(
    WidgetTester tester, {
    List<Profile> profiles = const <Profile>[_profile],
    List<MailboxAccount>? mailboxes = const <MailboxAccount>[_box],
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          profilesProvider.overrideWith((ref) => Stream.value(profiles)),
          if (mailboxes != null)
            mailboxesProvider.overrideWith(
              (ref, profileId) => Stream.value(mailboxes),
            ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: ComposeSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  /// 某个签名行的副标题文本（没配签名时 `subtitle == null`）。
  String? signatureSubtitle(WidgetTester tester, String email) {
    final tile =
        tester.widget<ListTile>(find.byKey(ValueKey('signature-$email')));
    final subtitle = tile.subtitle;
    return subtitle == null ? null : (subtitle as Text).data;
  }

  // ── Defect 1：可达性 ────────────────────────────────────────────────

  testWidgets('有邮箱、prefs 全空时：签名与常用语两行都在（新装也能点进去建第一条）',
      (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('signature-$_email')), findsOneWidget,
        reason: '只取两张已存表的键时这里是空的 —— 新装用户没有任何入口建签名');
    expect(find.byKey(const ValueKey('phrases-$_email')), findsOneWidget,
        reason: '同上：常用语那一行也必须由邮箱列表撑出来');
    // 空态那句话不该出现（它现在写的是「还没有邮箱」，而这里明明有）。
    expect(find.text('还没有邮箱 —— 先登录一个实例'), findsNothing,
        reason: '有邮箱时不该显示「还没有邮箱」');
  });

  // ── 空态：一台实例都没登 ────────────────────────────────────────────

  testWidgets('没有实例、没有邮箱时：显示 composeSignatureEmpty 那一块',
      (tester) async {
    await pump(tester, profiles: const <Profile>[], mailboxes: null);

    expect(find.text('还没有邮箱 —— 先登录一个实例'), findsOneWidget,
        reason: '空态该由「真的一台实例都没登」触发，而不是并集硬造行时漏掉');
    expect(find.byType(ListTile), findsOneWidget,
        reason: '空态只有一块提示，不该再冒出任何地址行');
  });

  // ── Defect 2：常用语经真对话框的往返 ────────────────────────────────

  testWidgets('新增一条常用语：走真对话框，新行出现且整组写回 prefs', (tester) async {
    final prefs = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('phrases-$_email')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('phrase-add')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('phrase-name')), '约时间');
    await tester.enterText(
        find.byKey(const ValueKey('phrase-text')), '方便的话，我们约周四下午三点。');
    // OK（`showDialog` 里那颗确认）：`MaterialLocalizations` 在 zh 下是「确定」。
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 新加的这一条必须出现在列表里 —— 修好前 `finally` 在退场动画期间就把
    // controller 释放了，这一帧会抛「used after being disposed」，行也不出现。
    expect(find.text('约时间'), findsOneWidget,
        reason: '保存后新行必须出现在页面上（Defect 2 的核心断言）');

    // 返回：把整组交回 `_editPhrases`，由它写一次盘。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    final saved = prefs.phrasesFor(_email);
    expect(saved, hasLength(1),
        reason: '从常用语页返回时应当把整组写回 prefs');
    expect(saved.single.name, '约时间');
    expect(saved.single.text, '方便的话，我们约周四下午三点。');
  });

  // ── 签名往返 + 取消 / 清空 ─────────────────────────────────────────

  testWidgets('签名：保存后落到 prefs；取消不动、清空才清除', (tester) async {
    final prefs = await pump(tester);

    // ① 保存：写进 prefs。
    await tester.tap(find.byKey(const ValueKey('signature-$_email')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('signature-input')), '——\n王五');
    await tester.tap(find.byKey(const ValueKey('signature-save')));
    await tester.pumpAndSettle();
    expect(prefs.signatureFor(_email), '——\n王五', reason: '保存后 prefs 里应当是刚打的签名');

    // 刷新这一节：`prefsStoreProvider` 是个普通 Provider（值不变就不通知），
    // 所以同一棵树里那次写入不会让副标题自己重画 —— 重新挂载看数据是对的。
    await pump(tester);
    expect(signatureSubtitle(tester, _email), '——\n王五',
        reason: '重新挂载后副标题应显示签名第一行');

    // ② 取消：对话框里什么都不动、直接关掉 -> 已有签名原样。
    await tester.tap(find.byKey(const ValueKey('signature-$_email')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(prefs.signatureFor(_email), '——\n王五',
        reason: '取消（pop 出 null）不该动到已有签名');

    // ③ 清空：把框清掉再保存 -> 签名被清除（空串 = 删掉那一条）。
    await tester.tap(find.byKey(const ValueKey('signature-$_email')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('signature-input')), '');
    await tester.tap(find.byKey(const ValueKey('signature-save')));
    await tester.pumpAndSettle();
    expect(prefs.signatureFor(_email), isEmpty,
        reason: '保存空串是「清除」，不是「取消」—— 两者不能合并');

    await pump(tester);
    expect(signatureSubtitle(tester, _email), isNull,
        reason: '签名被清掉后，这一行不该再显示副标题');
  });
}
