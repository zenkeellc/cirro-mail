import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/attachment_cache.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/attachment/viewers/text_viewer_screen.dart';
import 'package:mail_app/features/settings/attachment_cache_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 附件缓存页宽屏右栏的预览。
///
/// 用户报的是「点附件，右侧的预览功能好像没有实现」：原先 `_AttachmentPreview`
/// 只对**图片**铺出真图，其余类型一律给一张图标卡 —— 而这一页存在的理由是
/// 「腾地方」，判断「还值不值得留」恰恰要看得见内容。
///
/// 这一组钉住四件事：
/// 1. 能应用内预览的类型，右栏**真的渲染出那个 viewer**，而且内容是**读出来的**
///    （不是放一个空壳）；
/// 2. 那个 viewer 是**内嵌形态** —— 它自己不带 `Scaffold` / `AppBar`（带了就是
///    宿主头上面又多一条头）；
/// 3. 换一条**同类型**的附件要重新挂载（viewer 的 `_load()` 只在 `initState`
///    跑一次，漏了这个 key 就会继续显示上一条）；
/// 4. 没有 viewer 的类型（压缩包）仍然给图标卡 + 落盘路径 —— 那是这一页的
///    另一半用途，不能被「都能预览了」顺手删掉。
///
/// ## 这一组为什么长得和其它 widget 用例不一样
///
/// 因为 `AttachmentCacheScreen` 不是纯 widget：它的 `_reload()` 查库，
/// 右栏里的 viewer 在 `initState` 之后**真的去读磁盘**（`LocalFile.readBytes`）。
/// 而 `testWidgets` 默认把整个用例跑在 **fake-async 区**里 ——
/// 在那个区里 `Future.delayed` 不推进真实时钟、真实文件 I/O 的完成回调也
/// 排不进来，于是任何「等它读完盘」的写法都会**永久挂住**（实测：不加
/// `runAsync` 时用例在本文件的第一条真 I/O 上停死，`pumpAndSettle` 会一直转到
/// 十分钟超时）。
///
/// 所以这里只用两种推进手段：
/// - [`runAsync`]：fork 出一个**真**的异步区，I/O 在那儿才会完成；
/// - 在真区里 `Future.delayed` + `tester.pump` 交替若干轮 —— 延时让真 I/O 的
///   完成回调有机会跑，`pump` 把 `setState` 渲染出来。
///
/// **不用 `pumpAndSettle`**：这一页在拿到数据之前挂着一个永不停止的
/// `CircularProgressIndicator`，`pumpAndSettle` 会转到它自己的超时为止。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );

  late AppDatabase db;
  late Directory tempDir;
  late AttachmentCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('attach_cache_screen');
    cache = AttachmentCache(root: tempDir);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 往库里塞一条「已下载」的附件，并把真实文件写到磁盘上。
  ///
  /// 两条都要：库决定它出现在左栏，磁盘决定 viewer 读得到内容 ——
  /// 只有库里那行的话，`_AttachmentPreview` 会走「文件已经不在了」那条路，
  /// 用例会在一个与本题无关的地方红。
  ///
  /// **必须在 `tester.runAsync` 里调**（见本文件顶部的说明）。
  Future<MailAttachment> seed({
    required int attId,
    required String filename,
    String? content,
    int size = 128,
  }) async {
    final att = MailAttachment(
      attId: attId,
      profileId: profile.id,
      emailId: 100,
      key: 'attachments/$attId',
      filename: filename,
      mimeType: 'application/octet-stream',
      size: size,
    );
    await db.mailDao.upsertAttachments(profile.id, 100, <MailAttachment>[att]);
    if (content != null) {
      final file = await cache.targetFor(
        profileId: profile.id,
        emailId: 100,
        filename: filename,
      );
      await file.writeAsString(content);
      await db.mailDao.markAttachmentDownloaded(
        profile.id,
        attId,
        localPath: file.path,
      );
    }
    final rows = await db.mailDao.downloadedAttachments();
    return rows.firstWhere((a) => a.attId == attId);
  }

  /// 推若干轮「真延时 + 一帧」，把这一页挂在真区里的 I/O 跑完。
  ///
  /// 一轮 4ms：文本预览读的是几十字节，一两轮就够；给 30 轮是为了容下
  /// `_reload()` 那两条库查询 + 磁盘占用统计的慢路径。跑完就退出，
  /// 不会白等（每轮开头都会先看一眼目标是不是已经到了）。
  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    await tester.runAsync(() async {
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        await tester.pump();
      }
    });
  }

  /// 起这一页。**必须在真区里 `pumpWidget`**，否则 `initState` 里
  /// `_reload()` 那两条查库落在 fake 区，永远不回来（页面就一直转圈）。
  Future<void> pump(
    WidgetTester tester, {
    required bool wide,
  }) async {
    if (wide) {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.runAsync(() async {
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bootstrapProvider.overrideWithValue(
            BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
          ),
          prefsStoreProvider.overrideWithValue(prefs),
          attachmentCacheProvider.overrideWithValue(cache),
          profilesProvider.overrideWith(
            (ref) => Stream.value(const <Profile>[profile]),
          ),
          syncOverviewProvider.overrideWith(
            (ref) => Stream.value(const <SyncOverview>[]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const AttachmentCacheScreen(),
        ),
      ));
    });
    await settle(tester);
  }

  /// 点一行（按文件名找，`ListTile` 的 title）。点完等右栏那个 viewer 读完盘。
  Future<void> tapRow(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(ListTile, name));
    await settle(tester, rounds: 20);
  }

  group('宽屏右栏', () {
    testWidgets('点一个文本附件 → 右栏真的把内容渲染出来', (tester) async {
      await tester.runAsync(
        () => seed(attId: 1, filename: 'notes.txt', content: '合同已签，周四交付\n'),
      );
      await pump(tester, wide: true);

      // 还没选：右栏是空态。
      expect(find.byType(TextViewerScreen), findsNothing);

      await tapRow(tester, 'notes.txt');

      expect(find.byType(TextViewerScreen), findsOneWidget);
      expect(find.text('合同已签，周四交付'), findsOneWidget,
          reason: '渲染出来的是那个 viewer，不是一张图标卡');
      // **内嵌**：宿主已经有一个头了（左栏是 `PaneHeader`），viewer 不许
      // 再自撑一个 `Scaffold` / `AppBar` —— 那会在右栏顶上多出一条头。
      expect(
        find.descendant(
          of: find.byType(TextViewerScreen),
          matching: find.byType(AppBar),
        ),
        findsNothing,
      );
    });

    testWidgets('换一条同类型的附件 → 右栏跟着换内容（viewer 要重挂）', (tester) async {
      await tester.runAsync(() async {
        await seed(attId: 1, filename: 'first.txt', content: '第一封的内容\n');
        await seed(attId: 2, filename: 'second.txt', content: '第二封的内容\n');
      });
      await pump(tester, wide: true);

      // 两条的 `downloadedAt` 可能是同一毫秒，顺序不定 —— 按名字点，不假设。
      await tapRow(tester, 'first.txt');
      expect(find.text('第一封的内容'), findsOneWidget);
      expect(find.text('第二封的内容'), findsNothing);

      await tapRow(tester, 'second.txt');
      expect(find.text('第二封的内容'), findsOneWidget);
      expect(find.text('第一封的内容'), findsNothing,
          reason: '同类型的两条挂的是同一个 widget 类型 —— 没有 key 的话 '
              'State 会被复用，`_load()` 只在 initState 跑一次，右栏会继续'
              '显示上一条的内容');
    });

    testWidgets('没有 viewer 的类型仍然给图标卡 + 落盘路径', (tester) async {
      final zip = (await tester.runAsync(
        () => seed(attId: 3, filename: 'bundle.zip', content: 'PK\u0003\u0004'),
      ))!;
      await pump(tester, wide: true);
      await tapRow(tester, 'bundle.zip');

      // 压缩包没有应用内 viewer（`AttachmentViewers.implemented` 就没它）。
      expect(find.byType(TextViewerScreen), findsNothing);
      // 同一个图标这一页会出现两次：左栏行首那个 16 的小图标，与右栏
      // 图标卡上那个 64 的大图标 —— 这里要的是后者。
      final bigIcon = tester
          .widgetList<Icon>(find.byIcon(Icons.folder_zip_outlined))
          .where((icon) => icon.size == 64);
      expect(bigIcon, hasLength(1), reason: '右栏给的是一张图标卡，不是空态');
      // 落盘路径要显示出来：这一页的另一半用途是「这些文件到底占在哪儿」。
      expect(find.text(zip.localPath!), findsOneWidget);
    });
  });

  group('窄屏', () {
    testWidgets('点一行仍然是那块动作面板（行为不变）', (tester) async {
      await tester.runAsync(
        () => seed(attId: 4, filename: 'notes.txt', content: 'hi\n'),
      );
      await pump(tester, wide: false);

      await tester.tap(find.widgetWithText(ListTile, 'notes.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // 面板里第一行是「预览」（`canPreview` 通过时才出现），后面是打开 /
      // 分享 / 另存为 —— 与从前逐字相同。
      expect(find.text('预览'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
      expect(find.text('另存为'), findsOneWidget);
    });
  });
}
