// 写信页的**草稿警示条**（`AppExtension.draftWarning` → 注册表
// `draftWarningFor` → 正文上方那一条）。
//
// 这条接缝存在的理由：Pro 的云草稿同步要让用户知道「这条草稿有附件还没下
// 完整，发送前请先同步」—— 说的是**一封信**的事，落点只能在写信页，而且是
// 一条**可以关掉**的横幅（SnackBar 会自己消失，用户回头就忘了）。
//
// 这里钉住四件事：
// 1. 扩展给非空文本 → 出现；给 null（或空白串）→ 不出现；
// 2. 点关闭 → 这一页不再出现（重进页面会重新问一次）；
// 3. 扩展抛错 → 页面照常可用、无警示、不崩（契约里那句「核心会尽量兜底」）；
// 4. 空注册表 / 还没有草稿行 → 扩展**根本不被问**，这一页与没有这条接缝时
//    逐像素相同（公开版的硬要求）。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _warning = '这条草稿有附件还没下载完整，发送前请先同步';

/// 只会答 `draftWarning` 的扩展。[text] 为 null = 不报；[throws] 模拟坏实现。
class _WarningExt extends AppExtension {
  _WarningExt(this.id, {this.text, this.throws = false, this.calls});

  @override
  final String id;

  final String? Function(String profileId, int draftId)? text;
  final bool throws;

  /// 记下每次被问到的参数（null = 不记账）。
  final List<({String profileId, int draftId})>? calls;

  @override
  Future<String?> draftWarning({
    required String profileId,
    required int draftId,
  }) async {
    calls?.add((profileId: profileId, draftId: draftId));
    if (throws) throw StateError('扩展 $id 读警示失败');
    return text?.call(profileId, draftId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppExtensionRegistry.instance.reset();
  });

  tearDown(AppExtensionRegistry.instance.reset);

  /// 往内存库里塞一条草稿，返回 `(库, 草稿 id)`。
  ///
  /// 走真实的 `saveDraft`：`uid` / `rev` 的语义在它里面，写信页读回来的正是
  /// 这一行（`_restoreDraft` → `state.draftId`）。
  Future<(AppDatabase, int)> seedDraft() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final id = await db.localDao.saveDraft(
      profileId: 'p1',
      accountEmail: 'me@example.com',
      recipientsJson: '["alice@example.com"]',
      subject: '带附件的草稿',
      content: '[{"insert":"正文\\n"}]',
      attachmentPaths: const <String>['/tmp/not-downloaded.pdf'],
    );
    return (db, id);
  }

  /// 直接装写信页。
  Future<void> pumpCompose(
    WidgetTester tester,
    AppDatabase db, {
    int draftId = 0,
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentProfileIdProvider.overrideWithValue('p1'),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: ComposeScreen(args: ComposeArgs(draftId: draftId)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('扩展返回文本：正文上方出现那一条警示', (tester) async {
    final calls = <({String profileId, int draftId})>[];
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _WarningExt('com.example.warn', text: (_, _) => _warning, calls: calls),
    ]);
    final (db, id) = await seedDraft();
    await pumpCompose(tester, db, draftId: id);

    expect(find.text(_warning), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compose-draft-warning-dismiss')),
      findsOneWidget,
      reason: '警示条必须可以关掉（SnackBar 那种自己消失的不算）',
    );
    expect(calls, isNotEmpty, reason: '有草稿行就该问一次扩展');
    expect(calls.first.profileId, 'p1', reason: '问的是这一页实际发信的实例');
    expect(calls.first.draftId, id, reason: '问的是本机草稿行 id');

    // 警示条不能把写信页本身挤坏：主题还在、编辑器还在。
    expect(find.widgetWithText(TextField, '带附件的草稿'), findsOneWidget);
    expect(find.byType(MailQuillEditor), findsOneWidget);
    await db.close();
  });

  testWidgets('扩展返回 null：不出现（公开版 / 没问题的草稿）', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _WarningExt('com.example.nowarn', text: (_, _) => null),
    ]);
    final (db, id) = await seedDraft();
    await pumpCompose(tester, db, draftId: id);

    expect(find.text(_warning), findsNothing);
    expect(
      find.byKey(const ValueKey('compose-draft-warning-dismiss')),
      findsNothing,
    );
    expect(find.byType(MailQuillEditor), findsOneWidget);
    await db.close();
  });

  testWidgets('空白串按「不显示」处理（不能画出一条空格横幅）', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _WarningExt('com.example.blank', text: (_, _) => '   '),
    ]);
    final (db, id) = await seedDraft();
    await pumpCompose(tester, db, draftId: id);

    expect(
      find.byKey(const ValueKey('compose-draft-warning-dismiss')),
      findsNothing,
    );
    await db.close();
  });

  testWidgets('点关闭后文本消失；这一页不再出现（重进页面会重新出现）',
      (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _WarningExt('com.example.warn', text: (_, _) => _warning),
    ]);
    final (db, id) = await seedDraft();
    await pumpCompose(tester, db, draftId: id);
    expect(find.text(_warning), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('compose-draft-warning-dismiss')),
    );
    await tester.pumpAndSettle();
    expect(find.text(_warning), findsNothing, reason: '点关闭就该消失');

    // 重进页面 = 新的一页生命周期：允许重新出现（用户可能又去同步了一次）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpCompose(tester, db, draftId: id);
    expect(find.text(_warning), findsOneWidget);
    await db.close();
  });

  testWidgets('扩展抛错：页面照常可用、无警示、不崩', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _WarningExt('com.example.boom', throws: true),
    ]);
    final (db, id) = await seedDraft();
    await pumpCompose(tester, db, draftId: id);

    // 注册表把异常吞了、只留一行日志 —— 页面这一帧不该有任何红屏/异常。
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('compose-draft-warning-dismiss')),
      findsNothing,
    );
    expect(find.byType(MailQuillEditor), findsOneWidget);
    expect(find.widgetWithText(TextField, '带附件的草稿'), findsOneWidget);
    await db.close();
  });

  testWidgets('空注册表：有草稿行也不画、不问（公开版逐像素不变）', (tester) async {
    final (db, id) = await seedDraft();
    await pumpCompose(tester, db, draftId: id);

    expect(
      find.byKey(const ValueKey('compose-draft-warning-dismiss')),
      findsNothing,
    );
    expect(find.byType(MailQuillEditor), findsOneWidget);
    await db.close();
  });

  testWidgets('还没有草稿行（空信）：扩展根本不被问', (tester) async {
    final calls = <({String profileId, int draftId})>[];
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _WarningExt('com.example.warn', text: (_, _) => _warning, calls: calls),
    ]);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await pumpCompose(tester, db);

    expect(
      calls,
      isEmpty,
      reason: '草稿行都没有，问出来只会让每个实现自己再猜一次',
    );
    expect(find.text(_warning), findsNothing);
    expect(find.byType(MailQuillEditor), findsOneWidget);
    await db.close();
  });
}
