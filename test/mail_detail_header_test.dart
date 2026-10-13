import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 打开详情时会顺手撤掉这条通知（见 `MailDetailScreen._openOnce`）。测试里
/// 那会真的去建平台插件，失败一次、在日志里留一行「通知：撤销失败」。这里
/// 换成空实现 —— 本文件测的是顶栏与正文宽度，与通知无关。
///
/// 用 `implements` + `noSuchMethod` 而不是 `extends`：继承会把插件对象的构造
/// 跑一遍，而那正是上面那行日志的来源。
///
/// `cancelFor` 那一支**必须给一个真的 `Future`**：调用方是
/// `unawaited(ref.read(...).cancelFor(ref))`，而 `noSuchMethod` 默认返回的
/// `null` 落到 `Future<void>` 的位置会当场抛
/// 「type 'Null' is not a subtype of type 'Future&lt;void&gt;'」—— 被 `_openOnce`
/// 的兜底 catch 吞掉，留一行与本题无关的诊断日志。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

/// 详情顶栏显示**邮件标题**，以及正文占满可用宽度。
///
/// 顶栏原来是实例名（`profile.displayName`）。它改错了两处都不报错：标题栏
/// 依旧有字，只是那行字回答的是「这是哪台实例」—— 而那件事在左栏的头、
/// 聚合列表的实例 chip 上都已经说过了。
///
/// 宽度同理：封顶（原来 `readerMaxWidth = 900`）在分栏右栏上会把正文变成一条
/// 居中的窄带，两边的留白比正文还宽 —— 而右栏的宽度本来就是用户拖出来的。
///
/// **两个形态各写各的调用点，所以两条都要钉住**：只钉一条的话，另一条上会
/// 悄悄留着一道 900 的天花板，而它只有把窗口拖到 900 以上才看得出来。
///
/// 这里**只搭 `MailDetailScreen` 自己**（不给它套 `MailPanes`）：一是需求那句
/// 「正文占满」说的就是右栏这块区域，二是最小依赖 —— 带上分栏宿主就得把
/// 列表栏那几条 drift 流一起喂上。`PaneHeader` 也不在依赖里，改成按可见文案
/// 断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;
  const subject = '一封用来量宽度的邮件';
  const bodyText = '正文';

  /// 测试窗口的宽。比 [paneWidth] 宽是**必须的**：`Scaffold.body` 拿到的
  /// 是「上限 = 窗口宽」的松约束，窗口比那个 `SizedBox` 窄的话它会被静默夹
  /// 到窗口宽 —— 断言读到的就是 800（测试环境默认值），而不是 1100。
  const windowWidth = 1400.0; // 默认 800 装不下。
  const paneWidth = 1100.0; // 比 900（老的天花板）宽。

  /// 一个收件方向、正文齐了的本地行。
  final row = MailRow(
    emailId: emailId,
    profileId: profileId,
    name: '发件人',
    sendEmail: 'from@x.com',
    subject: subject,
    text: bodyText,
    content: '<p>$bodyText</p>',
    hasFullBody: true,
    type: 0,
    createTime: DateTime(2026, 1, 2, 3, 4),
  );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 建一棵「详情页能自己跑起来」的树。
  Future<void> pumpDetail(
    WidgetTester tester, {
    required bool embedded,
  }) async {
    // 窗口要够宽 —— 两个用例量的都是宽度，而测试环境默认只有 800×600。
    // 两条都要显式设：内嵌那条是 `SizedBox` 被夹住，整页那条是根本没地方摆。
    tester.view.physicalSize = const Size(windowWidth, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 内存库：详情那条 drift 流要它（`mailDetailProvider`）。
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[row]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: embedded
            ? Scaffold(
                body: SizedBox(
                  width: paneWidth,
                  child: MailDetailScreen(
                    profileId: profileId,
                    emailId: emailId,
                    embedded: true,
                    onClose: () {},
                  ),
                ),
              )
            : MailDetailScreen(profileId: profileId, emailId: emailId),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 拆掉这一棵树，并把时钟往前推一帧。
  ///
  /// drift 的流在取消订阅时会排一个「零延时」定时器去关查询
  /// （`StreamQueryStore.markAsClosed`），而不带时长的 `pump()` 不推时钟 ——
  /// 留到用例结束就是一句与本题无关的「A Timer is still pending」。
  ///
  /// **调用点在每个用例的末尾，不能塞进 `addTearDown`**：`addTearDown` 排在
  /// 用例体之后，而 flutter_test 检查「还有没有挂着的定时器」是在**用例体
  /// 返回时**做的 —— 放进去就晚了一步，四条例题会一起红在这句上。
  ///
  /// 但断言必须在拆树**之前**：`find.byType(...)` 在空树上一个都找不到。
  Future<void> disposeDetail(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  /// 正文那一块：`_body` 的最外层 `ListView`。
  final bodyView = find.byType(ListView);

  testWidgets('内嵌形态：顶栏是邮件标题，不是实例名', (tester) async {
    await pumpDetail(tester, embedded: true);

    // 顶栏一份、正文里再一份。
    expect(find.text(subject), findsNWidgets(2));

    await disposeDetail(tester);
  });

  testWidgets('整页形态：AppBar 上也是邮件标题', (tester) async {
    await pumpDetail(tester, embedded: false);

    final appBar = find.byType(AppBar);
    expect(appBar, findsOneWidget);
    expect(
      find.descendant(of: appBar, matching: find.text(subject)),
      findsOneWidget,
    );

    await disposeDetail(tester);
  });

  testWidgets('内嵌形态：正文占满阅读区宽度', (tester) async {
    await pumpDetail(tester, embedded: true);

    // `_body` 的 `Padding` 在 ListView **里面**，所以量到的就是可用宽度。
    // 若还留着 `readerMaxWidth = 900` 那道封顶，这里会是 900。
    expect(tester.getSize(bodyView).width, paneWidth);

    await disposeDetail(tester);
  });

  testWidgets('整页形态：正文同样占满窗口宽度', (tester) async {
    await pumpDetail(tester, embedded: false);

    expect(tester.getSize(bodyView).width, windowWidth);

    await disposeDetail(tester);
  });
}
