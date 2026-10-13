import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/mail_list/mail_list_view.dart';
import 'package:mail_app/features/mail_list/mail_row_tile.dart';
import 'package:mail_app/features/mail_list/mail_selection_pane.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多选在**真的 `MailListView` 里**的样子：手势进得去、复选框出得来、
/// 底部操作栏与右键菜单读的是同一份判据。
///
/// 纯逻辑（下标怎么折、scope 怎么比）在 `test/mail_selection_test.dart` 里测；
/// 这里只关心「接上界面之后，用户看得见、点得着的那几样」。
class _UsableAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );

  /// 第 [emailId] 封的摘要行（`unread: 0` 是未读，与字段名直觉相反）。
  MailRow mail(int emailId, {int unread = 1}) => MailRow(
        emailId: emailId,
        profileId: 'p1',
        name: '发件人$emailId',
        sendEmail: 'sender$emailId@example.com',
        subject: '主题$emailId',
        mailboxEmail: 'me@example.com',
        type: MailType.receive,
        unread: unread,
        hasFullBody: true,
      );

  final rows = <MailRow>[for (var i = 1; i <= 6; i++) mail(i)];

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 挂一整个真的 `MailListView`（手势都挂在它每一行上）。
  ///
  /// 默认窗口 800×600 —— `Breakpoints.panesOf` 为 false，于是底部操作栏那条
  /// 分支会走（宽屏有右栏，不挂它）。
  Future<void> pump(
    WidgetTester tester, {
    bool multiSelect = true,
    void Function(MailRow row)? onOpen,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(const <MailboxAccount>[]),
        ),
        mailListProvider.overrideWith((ref, query) => Stream.value(rows)),
        unsyncedPlaceholderProvider.overrideWith(
          (ref, query) => Stream<int?>.value(null),
        ),
        draftsProvider.overrideWith(
          (ref, profileId) => Stream.value(const <DbDraft>[]),
        ),
        syncOverviewProvider.overrideWith(
          (ref) => Stream.value(const <SyncOverview>[]),
        ),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        aiSettingsProvider.overrideWith(() => _UsableAiSettings()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: MailListView(
            query: MailListQuery(),
            onOpen: onOpen ?? (_) {},
            multiSelect: multiSelect,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 拆树并把时钟往前推一帧（见 `mail_row_menu_test.dart` 里同名的那个）。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  Finder tileAt(int index) => find.byType(MailRowTile).at(index);

  Finder checkboxAt(int index) =>
      find.descendant(of: tileAt(index), matching: find.byKey(const ValueKey<String>('selectionCheckbox')));

  /// 第 [index] 行**被选中**（整行底色那条 key 在它里面）。
  bool isPicked(WidgetTester tester, int index) =>
      find
          .descendant(
            of: tileAt(index),
            matching: find.byKey(const ValueKey<String>('selectedBand')),
          )
          .evaluate()
          .isNotEmpty;

  /// 顶部那条「已选 N 封」。
  String countText(WidgetTester tester) =>
      tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey<String>('selectionBar')),
        matching: find.textContaining('已选'),
      )).data!;

  /// 按住一个修饰键点某一行。
  Future<void> tapWithKey(
    WidgetTester tester,
    int index,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(key);
    await tester.tap(tileAt(index));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(key);
  }

  testWidgets('没进多选时的平点：还是「打开这一封」，不是进入多选', (tester) async {
    final opened = <int>[];
    await pump(tester, onOpen: (row) => opened.add(row.emailId));

    await tester.tap(tileAt(2));
    await tester.pumpAndSettle();

    expect(opened, <int>[3], reason: '平点的语义是「打开」，与多选上线前一致');
    expect(find.byKey(const ValueKey<String>('selectionBar')), findsNothing);
    expect(find.byKey(const ValueKey<String>('selectionCheckbox')), findsNothing);
    await unmount(tester);
  });

  testWidgets('没接多选的列表：长按还是弹行菜单，且没有复选框', (tester) async {
    await pump(tester, multiSelect: false);
    await tester.longPress(tileAt(0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('row-menu-read')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('selectionCheckbox')), findsNothing);
    expect(find.byKey(const ValueKey<String>('selectionBar')), findsNothing);
    await unmount(tester);
  });

  testWidgets('长按进入多选：该行出现复选框、底部栏报「已选 1 封」', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey<String>('selectionCheckbox')), findsNothing,
        reason: '没进多选时连一个空槽都不留');

    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('selectionBar')), findsOneWidget);
    expect(checkboxAt(0), findsOneWidget, reason: '多选时每一行都换成复选框');
    expect(checkboxAt(1), findsOneWidget);
    expect(isPicked(tester, 1), isTrue);
    expect(isPicked(tester, 0), isFalse);
    expect(countText(tester), '已选 1 封');
    // 长按不再弹行菜单 —— 它被多选占用了（右键里四个动作原样都在）。
    expect(find.byKey(const ValueKey<String>('row-menu-read')), findsNothing);
    await unmount(tester);
  });

  testWidgets('Shift 点击：从按下那一行连到这一行；底栏计数跟着变', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();

    await tapWithKey(tester, 4, LogicalKeyboardKey.shiftLeft);

    expect(countText(tester), '已选 4 封');
    for (final index in <int>[1, 2, 3, 4]) {
      expect(isPicked(tester, index), isTrue, reason: '第 $index 行应当在区间里');
    }
    expect(isPicked(tester, 0), isFalse);
    await unmount(tester);
  });

  testWidgets('Ctrl 点击：切换一行（点第二次取消）', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();

    await tapWithKey(tester, 4, LogicalKeyboardKey.controlLeft);
    expect(countText(tester), '已选 2 封');
    expect(isPicked(tester, 4), isTrue);

    await tapWithKey(tester, 4, LogicalKeyboardKey.controlLeft);
    expect(countText(tester), '已选 1 封');
    expect(isPicked(tester, 4), isFalse);
    await unmount(tester);
  });

  testWidgets('平点（已进多选）：把选择换成这一行', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();
    await tapWithKey(tester, 4, LogicalKeyboardKey.shiftLeft);
    expect(countText(tester), '已选 4 封');

    await tester.tap(tileAt(5));
    await tester.pumpAndSettle();

    expect(countText(tester), '已选 1 封');
    expect(isPicked(tester, 5), isTrue);
    expect(isPicked(tester, 4), isFalse);
    await unmount(tester);
  });

  testWidgets('点复选框：勾掉这一行（不影响别的行）', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();
    await tapWithKey(tester, 3, LogicalKeyboardKey.shiftLeft);
    expect(countText(tester), '已选 3 封');

    await tester.tap(checkboxAt(2));
    await tester.pumpAndSettle();

    expect(countText(tester), '已选 2 封');
    expect(isPicked(tester, 2), isFalse);
    await unmount(tester);
  });

  testWidgets('取消到一封不剩 → 退出多选（复选框与底栏一起消失）', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();

    await tester.tap(checkboxAt(1));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('selectionBar')), findsNothing);
    expect(find.byKey(const ValueKey<String>('selectionCheckbox')), findsNothing);
    await unmount(tester);
  });

  /// 长按后往下拖：带子按行扩展，松手折成集合。
  ///
  /// **拖的是「大约两行」而不是「恰好两行」**：`_onPointerMove` 用的是
  /// `(位移 / 行高).round()`，所以只要指针落在第 3 行的范围里就够了 —— 写成
  /// 精确的 `rowHeight * 2` 会在测量值有半个像素误差时落到第 2 行上去，用例
  /// 变成在赌整除。
  testWidgets('长按后往下拖：带子按行扩展，松手折成集合', (tester) async {
    await pump(tester);

    final start = tester.getCenter(tileAt(1));
    final rowHeight = tester.getSize(tileAt(1)).height;
    final gesture = await tester.startGesture(start);
    // 等 `InkWell` 认下长按（它自己那个 `LongPressGestureRecognizer`）。
    await tester.pump(const Duration(milliseconds: 600));
    // 往下拖两行的高度：带子该覆盖 1、2、3 三行。
    await gesture.moveBy(Offset(0, rowHeight * 2.2));
    await tester.pump();
    expect(countText(tester), '已选 3 封');

    await gesture.up();
    await tester.pumpAndSettle();

    // 松手之后带子折成了具体下标（再拖已经不算数了）。
    expect(countText(tester), '已选 3 封');
    expect(isPicked(tester, 1), isTrue);
    expect(isPicked(tester, 3), isTrue);
    expect(isPicked(tester, 4), isFalse);
    expect(find.byKey(const ValueKey<String>('selectionBar')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('底栏「取消选择」：退出多选，但列表不动', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(1));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('selectionBarClear')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('selectionBar')), findsNothing);
    expect(find.byType(MailRowTile), findsNWidgets(rows.length),
        reason: '退出多选只清选择，不动列表');
    await unmount(tester);
  });

  testWidgets('底栏「全选」：把当前加载进来的这些行全选上', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('selectionBarSelectAll')));
    await tester.pumpAndSettle();

    expect(countText(tester), '已选 ${rows.length} 封');
    expect(isPicked(tester, rows.length - 1), isTrue);
    await unmount(tester);
  });

  testWidgets('右键落在没选中的行上：**先选中它**，菜单不带批量后缀', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(0));
    await tester.pumpAndSettle();
    await tapWithKey(tester, 2, LogicalKeyboardKey.shiftLeft);
    expect(countText(tester), '已选 3 封');

    await tester.tapAt(
      tester.getCenter(tileAt(5)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(isPicked(tester, 5), isTrue, reason: '右键 = 选中该邮件（用户需求 2）');
    expect(isPicked(tester, 0), isFalse);
    expect(countText(tester), '已选 1 封');
    expect(find.textContaining('已选 1 封)'), findsNothing,
        reason: '只有一封时菜单不该有批量后缀');
    expect(find.text('删除'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('右键落在**已选中**的行上：保持整批，菜单项带「已选 N 封」', (tester) async {
    await pump(tester);
    await tester.longPress(tileAt(0));
    await tester.pumpAndSettle();
    await tapWithKey(tester, 2, LogicalKeyboardKey.shiftLeft);
    expect(countText(tester), '已选 3 封');

    await tester.tapAt(
      tester.getCenter(tileAt(1)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(countText(tester), '已选 3 封', reason: '右键一封已选中的信，处理的是这一批');
    expect(find.text('删除（已选 3 封）'), findsOneWidget);
    // 三封都已读 → 这一批的目标状态是「标记未读」（只要还有一封没读，目标才
    // 反过来是「标记已读」；口径与 `_runBatch` 是同一套）。
    expect(find.text('标记未读（已选 3 封）'), findsOneWidget);
    await unmount(tester);
  });

  /// 宽屏右栏那个面板：**统计要说得出这一批是什么样**（用户需求 1），
  /// 而不是把「已选 N 封」再说一遍。
  ///
  /// 直接挂 `MailSelectionPane`（不搭整套 `MailListScreen` + 路由）：它读的
  /// 只有 `SelectedMails` 与 scope，列表怎么来的与它无关。按钮点下去那一端
  /// （`executeBatch`）要真的动网络，不在这一层测。
  group('宽屏右栏：统计与按钮', () {
    Future<void> pumpPane(
      WidgetTester tester,
      List<MailRow> rows, {
      int total = 6,
      bool starred = false,
    }) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bootstrapProvider.overrideWithValue(
            BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
          ),
          profilesProvider.overrideWith(
            (ref) => Stream.value(const <Profile>[profile]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: MailSelectionPane(
              stats: SelectedMails(
                rows: rows,
                refs: <MailRef>[
                  for (final row in rows)
                    MailRef(profileId: row.profileId, emailId: row.emailId),
                ],
                indices: <int>[for (var i = 0; i < rows.length; i++) i],
                total: total,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('标题与统计四项：未读 / 带附件 / 实例 / 时间', (tester) async {
      final withAttachment = MailRow(
        emailId: 1,
        profileId: 'p1',
        subject: '带附件的那封',
        type: MailType.receive,
        unread: 0,
        hasFullBody: true,
        attachmentCount: 2,
        createTime: DateTime(2026, 3, 2, 9),
      );
      final other = MailRow(
        emailId: 2,
        profileId: 'p2',
        subject: '另一台实例的',
        type: MailType.receive,
        unread: 1,
        hasFullBody: true,
        createTime: DateTime(2026, 3, 1, 9),
      );
      await pumpPane(tester, <MailRow>[withAttachment, other]);

      expect(find.text('已选 2 封'), findsOneWidget);
      expect(find.text('未读 1 封'), findsOneWidget);
      expect(find.text('带附件 1 封'), findsOneWidget);
      expect(find.text('2 个实例'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('selectionStatTime')),
        findsOneWidget,
      );
      // 「全选」写的是**这一块列表有多少行**，不是选了多少 —— 点一下不该把
      // 选择缩到刚才那两封。
      expect(find.text('全选（本页 6 封）'), findsOneWidget);
    });

    testWidgets('同一实例、没有附件时那两条不画（没有信息量的统计不占地方）',
        (tester) async {
      await pumpPane(tester, <MailRow>[
        MailRow(
          emailId: 1,
          profileId: 'p1',
          subject: 'a',
          type: MailType.receive,
          unread: 0,
          hasFullBody: true,
        ),
      ]);

      expect(find.byKey(const ValueKey<String>('selectionStatUnread')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('selectionStatInstances')),
          findsNothing, reason: '只有一台实例 —— 那条没有信息量');
      expect(find.byKey(const ValueKey<String>('selectionStatTime')),
          findsNothing, reason: '这封没有时间 → 那条不该出现');
    });

    /// 造一封邮件（`unread: 0` 未读 / `1` 已读，与字段名直觉相反）。
    MailRow rowWith({required int unread}) => MailRow(
          emailId: 1,
          profileId: 'p1',
          subject: 'a',
          type: MailType.receive,
          unread: unread,
          hasFullBody: true,
        );

    testWidgets('整批都已读 → 按钮是「标记未读」', (tester) async {
      await pumpPane(tester, <MailRow>[rowWith(unread: 1)]);

      expect(find.text('标记未读'), findsOneWidget,
          reason: '全已读 → 用户点它的意思只可能是「都标未读」');
    });

    testWidgets('只要有一封没读 → 按钮是「标记已读」', (tester) async {
      await pumpPane(tester, <MailRow>[rowWith(unread: 0)]);

      expect(find.text('标记已读'), findsOneWidget);
    });
  });
}
