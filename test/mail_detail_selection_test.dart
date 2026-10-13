// 详情页正文**可选、可复制**，以及那个「选中之后顺手做点什么」的右键菜单。
//
// 这一条原来是 `TODO.md` §6 里记账的「详情页正文不可选」：`HtmlBodyView` →
// `HtmlWidget`，从 `app.dart` 到 `mail_detail_screen.dart` 整棵树里没有任何
// `SelectionArea` / `SelectableRegion`，所以正文里的字复制不出来。
//
// ## 两个测试环境的坑（都在仓库里踩过，这里照抄现成做法）
//
// ① **绝不读系统剪贴板**。`Clipboard.getData` 在 flutter_tester 里的 future
//    **永不完成**（`mail_shortcuts_clipboard_test.dart:7-12` 记着实测把用例挂到
//    超时）。所以断言「复制成功」一律是**拦 `SystemChannels.platform`** 看
//    `Clipboard.setData` 发了什么 —— 既能看见「谁发的」也能看见「发的是什么」。
//
// ② **鼠标要显式声明**。`SelectableRegion` 给非精确指针（触屏）和鼠标挂的是
//    两套识别器（`selectable_region.dart:684-721`：触屏那套是
//    `TapAndHorizontalDragGestureRecognizer`，只认**水平**拖动，竖直拖动让给
//    `Scrollable`）。`tester.tapAt` / `startGesture` 的 `kind` 默认是
//    `PointerDeviceKind.touch`，不给 `mouse` 就是另一条分支，测出来的东西不一样。
//
// ## 为什么断言里带着**主题**
//
// `Cmd+A` 的作用域是「用户看到的这一封」（主题 / 收发人 / 时间 / 正文 / 附件），
// 不是「只有正文」—— 见 `_body` 上那段注释。这一条**就是那个决定的执行处**：
// 哪天有人把 `SelectionArea` 挪到 `HtmlBodyView` 里面去，这里立刻红。
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/features/shortcuts/shortcut_host.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 打开详情时会顺手撤掉这条通知（见 `MailDetailScreen._openOnce`）。测试里
/// 那会真的去建平台插件，失败一次、在日志里留一行。换成空实现。
///
/// `cancelFor` 那一支**必须给一个真的 `Future`**：调用方是
/// `unawaited(ref.read(...).cancelFor(ref))`，而 `noSuchMethod` 默认返回的
/// `null` 落到 `Future<void>` 的位置会当场抛 —— 被 `_openOnce` 的兜底 catch
/// 吞掉，留一行与本题无关的诊断日志。`dispose()` 同理（`_show` 那一类不走它）。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

/// 文本里第 `offset` 个字符在屏幕上的坐标（字符左下角再往下挪一点）。
///
/// **不是 `flutter_test` 的公开 helper** —— 它是框架自己测试里的一个顶层函数
/// （`flutter/test/widgets/selectable_region_test.dart:23-29`），这里抄一份。
/// 用 `getOffsetForCaret` 而不是「控件中心」：控件中心落在一行的**右端留白**
/// 上，会被 `getPositionForOffset` 夹到最近的一个字符，量不出「第 0 个字」。
Offset _textOffsetToPosition(RenderParagraph paragraph, int offset) {
  const caret = Rect.fromLTWH(0.0, 0.0, 2.0, 20.0);
  final local =
      paragraph.getOffsetForCaret(TextPosition(offset: offset), caret) +
          Offset(0.0, paragraph.preferredLineHeight);
  return paragraph.localToGlobal(local) + const Offset(0.0, -2.0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;
  const subject = '一封用来选正文的邮件';
  // **正文用英文**，不是审美：`_selectWordAt` 走的是 `getWordBoundary`
  // （ICU 分词）。中文那一段（原来是 `'正文'`）在无空格时**逐字成词** ——
  // 右击第 1 个字符选出来的是 `'文'` 一个字的选区，于是 ⑥ 里那句
  // 「复制出来的应当是选中的词」证不出东西来。换成 ASCII 句子，
  // 「一个词」就是 `'selectable'`，语义干净。
  const bodyText = 'selectable body text';
  const bodyWord = 'selectable';
  const code = '483920';
  const windowWidth = 1400.0;
  const windowHeight = 900.0;

  final row = MailRow(
    emailId: emailId,
    profileId: profileId,
    name: '发件人',
    sendEmail: 'from@x.com',
    subject: subject,
    text: bodyText,
    content: '<p>$bodyText</p>',
    code: code,
    hasFullBody: true,
    type: 0,
    createTime: DateTime(2026, 1, 2, 3, 4),
  );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 记下每一条发往平台 channel 的 `Clipboard.setData`。
  ///
  /// 用 `setMockMethodCallHandler`（不是 `setMockMessageHandler`）：`Clipboard`
  /// 走的是 `MethodChannel.invokeMethod`。回来的 `null` 让 `invokeMethod`
  /// 正常完成。
  List<String> captureClipboard(WidgetTester tester) {
    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        // 别的平台调用（`SystemChrome` / `HapticFeedback` …）照旧放过。
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return writes;
  }

  /// 按 `Ctrl + <key>`。
  ///
  /// flutter_tester 的默认平台是 android，框架 `_clipboardShortcuts` 认的就是
  /// control（`default_text_editing_shortcuts.dart:301`）。macOS 那一支是同一张
  /// 表的另一个分支（认 meta，`:718-731`），`mail_shortcuts_keymap_test.dart`
  /// 已经逐字段钉过我们的五个动作；剪贴板这几组不归我们管，所以这里只跑
  /// 默认平台那一遍。
  Future<void> pressWithCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 建一棵「详情页能自己跑起来」的树，外面套上**宿主层**。
  ///
  /// 套 `MailShortcutHost` 不是装饰：它是整棵树上最外面的一层 `Shortcuts`
  /// （`app.dart:57`），比框架的 `DefaultTextEditingShortcuts` **近**。不套
  /// 它的话，「`Ctrl+C` 能把正文复制出来」这条可能是白拿的 —— 真机上那一层
  /// 就在那儿。`Ctrl+N` 那条守卫是同一件事的执行处。
  ///
  /// 写邮件页用**代替品**：这一组只关心「按键有没有落到该去的地方」。
  Future<AppDatabase> pumpDetail(
    WidgetTester tester, {
    required bool embedded,
    void Function()? onClose,
  }) async {
    tester.view.physicalSize = const Size(windowWidth, windowHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[row]);

    final router = GoRouter(
      initialLocation: Routes.settings,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.settings,
          builder: (context, state) => embedded
              ? Scaffold(
                  body: MailDetailScreen(
                    profileId: profileId,
                    emailId: emailId,
                    embedded: true,
                    onClose: onClose ?? () {},
                  ),
                )
              : MailDetailScreen(profileId: profileId, emailId: emailId),
        ),
        GoRoute(
          path: Routes.compose,
          builder: (context, state) =>
              Scaffold(body: Text('compose:${state.uri}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        routerProvider.overrideWithValue(router),
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        // 位置照抄 `lib/app.dart`：在 `builder` 里。宿主层是新的那一层。
        builder: (context, child) =>
            MailShortcutHost(child: child ?? const SizedBox.shrink()),
      ),
    ));
    await tester.pumpAndSettle();
    return db;
  }

  /// 拆树并把时钟往前推一帧。
  ///
  /// drift 的流在取消订阅时会排一个「零延时」定时器去关查询，而不带时长的
  /// `pump()` 不推时钟 —— 留到用例结束就是一句与本题无关的
  /// 「A Timer is still pending」。**调用点在每个用例的末尾，不能塞进
  /// `addTearDown`**：flutter_test 检查挂起定时器是在**用例体返回时**做的，
  /// 放进去就晚了一步。
  ///
  /// 断言必须在拆树**之前**：`find.byType(...)` 在空树上一个都找不到。
  Future<void> disposeDetail(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  /// 正文那一段 `RenderParagraph`（fwfh 的 `buildText` 直接产 `RichText`，
  /// 外面那两层 `Text` 是主题 / 收发人，不在这里）。
  RenderParagraph bodyParagraph(WidgetTester tester) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(HtmlBodyView),
          matching: find.text(bodyText, findRichText: true),
        ),
      );

  testWidgets('① 正文可以拖选（鼠标）', (tester) async {
    await pumpDetail(tester, embedded: true);

    final paragraph = bodyParagraph(tester);
    // `kind: mouse` **必须给**：触屏那一套识别器只认水平拖动，竖直拖动会被
    // 让给 `Scrollable`，测出来的行为与桌面完全不是一回事。
    final gesture = await tester.startGesture(
      _textOffsetToPosition(paragraph, 0),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(_textOffsetToPosition(paragraph, bodyText.length));
    await tester.pump();

    expect(
      paragraph.selections,
      isNotEmpty,
      reason: '正文没有 `SelectionArea` —— 拖选之后一个字都选不中',
    );

    await gesture.up();
    await tester.pump();
    await disposeDetail(tester);
  });

  testWidgets('② Ctrl+A 再 Ctrl+C：主题与正文一起进剪贴板', (tester) async {
    final writes = captureClipboard(tester);
    await pumpDetail(tester, embedded: true);

    // 先点一下正文把焦点移进区域。`Cmd+A` 的前提是「焦点在区域内」——
    // `SelectableRegion` 只在 mouse down 时 `_focusNode.requestFocus()`
    // （`selectable_region.dart:741`），所以这一步不是装饰。
    final paragraph = bodyParagraph(tester);
    await tester.tapAt(
      _textOffsetToPosition(paragraph, 1),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    await pressWithCtrl(tester, LogicalKeyboardKey.keyA);
    await pressWithCtrl(tester, LogicalKeyboardKey.keyC);

    expect(writes, isNotEmpty, reason: '`Ctrl+C` 没有发出任何 Clipboard.setData');
    expect(
      writes.last,
      contains(bodyText),
      reason: '正文没被选进来',
    );
    expect(
      writes.last,
      contains(subject),
      reason: '`Cmd+A` 的范围应当是「用户看到的这一封」，含主题行 —— '
          '这里红说明 `SelectionArea` 被挪到了 `HtmlBodyView` 里面',
    );

    await disposeDetail(tester);
  });

  testWidgets('③ 守卫：验证码那张卡片上的复制按钮仍然发出验证码', (tester) async {
    // 选区的手势与卡片上那颗 `IconButton` 会同时进 arena。后端（按钮）先进，
    // 无位移时 sweep 给先进的那个（`gestures/arena.dart:169`），所以按钮该赢。
    // 这条钉的就是「套了 `SelectionArea` 之后按钮没被抢走」。
    final writes = captureClipboard(tester);
    await pumpDetail(tester, embedded: true);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pumpAndSettle();

    expect(writes, contains(code));

    await disposeDetail(tester);
  });

  testWidgets('④ 证伪条件：同一棵树里 Ctrl+N 仍然开出写邮件页', (tester) async {
    // ①②③ 全绿也可能是因为「宿主层压根没接上」—— 那就什么都没测到。
    await pumpDetail(tester, embedded: true);

    await pressWithCtrl(tester, LogicalKeyboardKey.keyN);

    expect(find.text('compose:/compose'), findsOneWidget);

    await disposeDetail(tester);
  });

  testWidgets('⑤ 右键正文弹出菜单：复制 / 回复 / 转发 / 删除', (tester) async {
    // **必须是 macOS**。右键那条路各平台不同（`selectable_region.dart:1046-1099`）：
    // macOS / iOS 是 `_selectWordAt`（选出一个词，于是有 `复制`），
    // android / fuchsia / windows 是把选区**塌陷到光标**（没有可复制的选区，
    // 框架算出来的条目里就只有 `全选`）；linux 又是第三种。
    // 框架自己那条「right-click mouse can select word at position on Apple
    // platforms」也是 `variant: TargetPlatformVariant.only(TargetPlatform.macOS)`
    // （`flutter/test/widgets/selectable_region_test.dart:3377`）。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await pumpDetail(tester, embedded: true);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(HtmlBodyView)),
    );
    final paragraph = bodyParagraph(tester);

    final gesture = await tester.startGesture(
      _textOffsetToPosition(paragraph, 1),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(l10n.copy), findsOneWidget);
    expect(find.text(l10n.reply), findsOneWidget);
    expect(find.text(l10n.forward), findsOneWidget);
    expect(find.text(l10n.delete), findsOneWidget);

    await disposeDetail(tester);
    // 复位必须在**用例体内**（`mail_row_menu_test.dart` 的约定）。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('⑥ 右键菜单里的「复制」把选中的词写进剪贴板', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final writes = captureClipboard(tester);
    await pumpDetail(tester, embedded: true);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(HtmlBodyView)),
    );
    final paragraph = bodyParagraph(tester);

    final gesture = await tester.startGesture(
      _textOffsetToPosition(paragraph, 1),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.copy));
    await tester.pumpAndSettle();

    // 右击第 1 个字符落在 `selectable` 这个词里，复制出来的就是这个词
    // —— 不是整段（`_selectWordAt` 是词粒度），也不是某一个字。
    expect(
      writes,
      contains(bodyWord),
      reason: '菜单里那颗「复制」没把选中的词写进剪贴板 —— '
          '多半是 onPressed 里先 `Navigator.pop()` 把页面 pop 掉了，'
          '`_copy()` 没来得及跑',
    );

    await disposeDetail(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('⑦ 右键菜单里的「删除」：删完之后内嵌形态会关掉右栏', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var closed = 0;
    final db = await pumpDetail(tester, embedded: true, onClose: () => closed++);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(HtmlBodyView)),
    );
    final paragraph = bodyParagraph(tester);

    final gesture = await tester.startGesture(
      _textOffsetToPosition(paragraph, 1),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.delete));
    await tester.pumpAndSettle();
    // 确认框（`MailActionRunner._delete` 走的是「删除「XX」？」那一句）。
    await tester.tap(find.text(l10n.confirm));
    // **不能 `pumpAndSettle`**：删完之后这一页在**测试的**树里不会消失 ——
    // 真机上 `onClose` 会让宿主清掉选中、详情页整个被换掉，而这里 `onClose`
    // 只把计数 +1，页面留在原地显示「转不完的圈」
    // （正是 `_afterDelete` 那条注释里记着的现象）。那个圈是无限动画，
    // `pumpAndSettle` 会一直等到 10 秒超时。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(
      closed,
      1,
      reason: '漏了 `onDeleted` —— 内嵌形态删完会停在「转不完的圈」上',
    );
    // 库也要真的干净：`onDeleted` 被调用只说明收尾跑了，不说明删成功了
    // （`_delete` 里那个 `context.mounted` 守卫曾经在确认框之后直接 return，
    // 表现就是「点了确定、什么都没发生」）。
    expect(
      await db.mailDao.find(profileId, emailId),
      isNull,
      reason: '库里那一行还在 —— 删除动作根本没执行',
    );

    await disposeDetail(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
