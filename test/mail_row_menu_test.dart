import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
// `draftsProvider` 定义在 `compose_controller.dart` 里，`providers/` 那几个
// 文件都没有它 —— `test/mail_list_deactivate_test.dart` 也是为同一件事
// import 这里的。
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/mail_list/mail_list_view.dart';
import 'package:mail_app/features/mail_list/mail_row_tile.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一份「配得上 AI」的设置（形状照 `test/ai_reply_test.dart` 的
/// `_UsableAiSettings`）—— 不覆盖它 AI 就没配，菜单里那一项不会画。
class _UsableAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
      );
}

/// 用户在设置里把「AI 建议」关掉了（spec §10 那个开关）。
class _SuggestOffAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
        mailSuggestEnabled: false,
      );
}

const List<String> _allKeys = <String>[
  'row-menu-read',
  'row-menu-star',
  'row-menu-suggest',
  'row-menu-delete',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );

  MailRow mail({bool send = false, int unread = 0}) => MailRow(
        emailId: 7,
        profileId: 'p1',
        name: '张三',
        sendEmail: 'alice@example.com',
        subject: '上线时间',
        mailboxEmail: 'me@example.com',
        type: send ? MailType.send : MailType.receive,
        // **0 = 未读、1 = 已读**（与字段名直觉相反）。
        unread: unread,
        hasFullBody: true,
      );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 挂一整个真的 `MailListView`（菜单挂在它每一行的手势上，脱不开）。
  ///
  /// override 清单与 `test/mail_list_deactivate_test.dart` 同一套 ——
  /// `MailListController`、`SendQueueBar` 这几条链都要真的 db 与那几条流。
  ///
  /// **[offset] 与那层 `Navigator` 一起模拟外壳的排版**：宽屏下 `app_shell.dart`
  /// 把每一支的分支 Navigator 摆在一条 232px 的一级导航**右边**，于是
  /// `Overlay.of(context)` 找到的**最近**那个 Overlay 原点并不在窗口左上角。
  /// 右键菜单偏移那个 bug 只在有这一层时才复现（窄屏没有侧栏，两个原点重合，
  /// 怎么写都对）—— 这一层 `Navigator` 就是它的替身，`offset` 就是那条侧栏。
  ///
  /// 默认 0 = 原点在窗口左上角，与真实外壳在窄屏下的形状一致。
  Future<void> pump(
    WidgetTester tester,
    MailRow row, {
    bool suggestEnabled = true,
    double offset = 0,
    bool multiSelect = false,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    // 聚合查询（`mailboxes` 为空）：`MailListController._hydrate` 会当场返回，
    // 不跑网络。
    final list = MailListView(
      query: MailListQuery(),
      onOpen: (_) {},
      multiSelect: multiSelect,
    );

    await tester.pumpWidget(ProviderScope(
      // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且没有
      // 对外导出（与 `mail_list_deactivate_test.dart` 同一句注释）。
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
        mailListProvider.overrideWith(
          (ref, query) => Stream.value(<MailRow>[row]),
        ),
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
        aiSettingsProvider.overrideWith(
          () => suggestEnabled ? _UsableAiSettings() : _SuggestOffAiSettings(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              if (offset > 0) SizedBox(width: offset),
              Expanded(
                child: Navigator(
                  // 分支 Navigator 的替身。页面自己撑一层 `Scaffold`：
                  // `InkWell` 那一类控件要一个 `Material` 祖先，而外壳下这一页
                  // 的 Material 的确来自它自己那一屏。
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: list),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 拆树并**把时钟往前推一帧**。drift 的流在取消订阅时会排一个「零延时」
  /// 定时器去关查询（`StreamQueryStore.markAsClosed`），零延时的定时器要时钟
  /// 动了才跑得完（不带时长的 `pump()` 不推时钟），留到用例结束就会报一句与
  /// 本题毫无关系的「A Timer is still pending」。
  ///
  /// 与 `mail_list_deactivate_test.dart:172` 那一对逐字相同。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  testWidgets('长按：底部菜单弹出，四项都在', (tester) async {
    await pump(tester, mail());
    await tester.longPress(find.byType(MailRowTile));
    await tester.pumpAndSettle();

    for (final key in _allKeys) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    await unmount(tester);
  });

  testWidgets('右键：`showMenu` 弹出，四项与长按**一模一样**', (tester) async {
    await pump(tester, mail());
    // `InkWell` 不认次键 —— 这就是为什么外面要包一层 `GestureDetector`。
    await tester.tapAt(
      tester.getCenter(find.byType(MailRowTile)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    for (final key in _allKeys) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    await unmount(tester);
  });

  testWidgets('已发送方向：没有「AI 建议」这一项，其余三项照旧', (tester) async {
    await pump(tester, mail(send: true));
    await tester.longPress(find.byType(MailRowTile));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('row-menu-suggest')), findsNothing,
        reason: '「怎么处理自己发出去的信号」没有意义（spec §8.3 第 1 条）');
    for (final key in _allKeys.where((k) => k != 'row-menu-suggest')) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    await unmount(tester);
  });

  testWidgets('设置里关掉了：同样没有「AI 建议」这一项', (tester) async {
    await pump(tester, mail(), suggestEnabled: false);
    await tester.longPress(find.byType(MailRowTile));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('row-menu-suggest')), findsNothing);
    expect(find.byKey(const ValueKey<String>('row-menu-delete')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('已读的那一行显示「标记未读」，未读的那一行显示「标记已读」',
      (tester) async {
    await pump(tester, mail(unread: 1));
    await tester.longPress(find.byType(MailRowTile));
    await tester.pumpAndSettle();

    expect(find.text('标记未读'), findsOneWidget);
    expect(find.text('标记已读'), findsNothing,
        reason: '两个标签对调过一次（见 mail_detail_screen.dart:505 那段注释）');
    await unmount(tester);
  });

  testWidgets('未读的那一行显示「标记已读」', (tester) async {
    await pump(tester, mail(unread: 0));
    await tester.longPress(find.byType(MailRowTile));
    await tester.pumpAndSettle();

    expect(find.text('标记已读'), findsOneWidget);
    await unmount(tester);
  });

  /// **偏移回归**（用户报的那个 bug）。
  ///
  /// `showMenu` 的 `position` 是**相对菜单要落到的那个 Overlay** 的坐标，
  /// 而 `onSecondaryTapUp` 给的 `globalPosition` 是**全局**的。两者相减才是
  /// 对的 —— 少了这一步，菜单会整体平移一个「Overlay 原点」的距离。
  ///
  /// 这个用例把列表放在一条 232px 的假侧栏右边（见 [pump] 里那层
  /// `Navigator`），分支 Overlay 的原点因此落在 x=232；未修时菜单会整体
  /// 右移 232。
  ///
  /// **画布必须够宽**：`_PopupMenuRouteLayout` 会把菜单夹回屏幕内（约 450
  /// 宽）。默认的 800 宽测试画布下，右边塞不下的那个（错误）位置会被夹到
  /// 屏幕右缘 —— 于是修过与没修过落在同一个地方，用例白写（实测正好都是
  /// 348）。画布放到 1600 宽，两种算法才各落各的。
  testWidgets('右键：菜单落在指针处（列表有 232px 偏移时也不例外）', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pump(tester, mail(), offset: 232);

    // 点在行的左侧而不是正中：靠右的话修正后的位置自己也会被夹。
    final tile = tester.getTopLeft(find.byType(MailRowTile));
    final target = tile + const Offset(68, 33);
    await tester.tapAt(target, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    // 菜单的左上角应当贴着指针（左进右出那点取整差异留着）。
    for (final key in _allKeys) {
      final corner = tester.getTopLeft(find.byKey(ValueKey<String>(key)));
      expect(
        (corner.dx - target.dx).abs(),
        lessThan(40),
        reason: '$key 的左边距应当贴着指针 —— 差 232 说明又用了全局坐标',
      );
    }
    await unmount(tester);
  });
}
