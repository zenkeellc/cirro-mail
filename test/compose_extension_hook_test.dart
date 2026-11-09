// 写邮件页退出 → `AppExtension.onComposeClosed` 这条接缝。
//
// 三件事在这里被钉住：
//
// 1. **有内容的信**：退出时最先落盘（保存器 flush），然后才通知扩展；扩展拿到的
//    `draftUid` 必须**就是库里那条草稿**的 `uid`（v6 的跨设备稳定身份），不是
//    随便一个新 UUID —— 否则扩展那一侧的同步层会把「这封信」对应到不存在（或
//    另一封）云端记录上；
// 2. **空信**：什么都没写就退出，库里不该落行，扩展也该被通知一次
//    （`draftUid == null`）—— 不能因为「没草稿」就静默跳过，扩展需要这个事件
//    去取消/清掉临时状态；
// 3. **单个扩展抛错不拖累其它扩展**：钩子是退出路径上的旁支，一个坏实现不能
//    让另一个同步引擎收不到事件，更不能把页面卡住。
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

/// 一个只记账的扩展。[throws] 用来模拟「坏实现」。
class _Recorder extends AppExtension {
  _Recorder(this.id, {this.throws = false});

  @override
  final String id;

  final bool throws;

  final List<({String profileId, String? draftUid})> calls =
      <({String profileId, String? draftUid})>[];

  @override
  Future<void> onComposeClosed({
    required String profileId,
    String? draftUid,
  }) async {
    calls.add((profileId: profileId, draftUid: draftUid));
    if (throws) throw StateError('扩展 $id 自己炸了');
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

  /// 内存库 + 写邮件页。**直接装成 `home:`**：本组用例的出口是 `X` 按钮
  /// （`_leave`），不需要页面被真正弹掉；`pumpAndSettle` 在根路由上没有退场
  /// 动画可等，收尾更干净。
  Future<AppDatabase> pumpCompose(
    WidgetTester tester, {
    ComposeArgs args = const ComposeArgs(),
    AppDatabase? database,
  }) async {
    final db = database ?? AppDatabase.forTesting(NativeDatabase.memory());
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
          home: ComposeScreen(args: args),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  /// 点 `X`（`_leave` 那条出口）。
  ///
  /// `_leave` 里有一次真的落库（drift 内存库），跑在 `unawaited` 的按钮回调
  /// 里 —— 单靠推帧不一定等得到它。这里先 `runAsync` 放真异步跑完，再推一帧
  /// 把 `unawaited` 的 `notifyComposeClosed` 也带出来。
  Future<void> tapCloseAndSettle(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  testWidgets('写过内容的信：扩展收到 profileId 与库里那条草稿的 uid',
      (tester) async {
    final recorder = _Recorder('com.example.recorder');
    AppExtensionRegistry.instance.registerAll(<AppExtension>[recorder]);

    final draftDb = AppDatabase.forTesting(NativeDatabase.memory());
    final draftId = await draftDb.localDao.createComposeDraft(profileId: 'p1');
    final db = await pumpCompose(
      tester,
      database: draftDb,
      args: ComposeArgs(draftId: draftId),
    );

    // 用户写一句正文（走真实的编辑器回写路径）。
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.controller.replaceText(
      0,
      0,
      '这封信要同步到云上',
      const TextSelection.collapsed(offset: 9),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tapCloseAndSettle(tester);

    expect(recorder.calls, hasLength(1), reason: '退出写信页要通知一次');
    final call = recorder.calls.single;
    expect(call.profileId, 'p1');
    expect(call.draftUid, isNotNull, reason: '有内容的信一定落了一条草稿行');

    final row = await db.localDao.findDraft(draftId);
    expect(row, isNotNull);
    expect(
      call.draftUid,
      row!.uid,
      reason: '扩展拿到的必须是库里那条草稿的稳定身份，不能是临时 UUID',
    );
    await db.close();
  });

  testWidgets('空信直接退出：不落草稿，扩展仍收到一次 draftUid == null',
      (tester) async {
    final recorder = _Recorder('com.example.recorder');
    AppExtensionRegistry.instance.registerAll(<AppExtension>[recorder]);

    final db = await pumpCompose(tester);
    await tapCloseAndSettle(tester);

    expect(recorder.calls, hasLength(1));
    expect(recorder.calls.single.profileId, 'p1');
    expect(
      recorder.calls.single.draftUid,
      isNull,
      reason: '空信没有草稿行，扩展要能据此不做事（而不是收不到事件）',
    );
    expect(
      await db.select(db.drafts).get(),
      isEmpty,
      reason: '空信不该在草稿箱里留一条空记录',
    );
    await db.close();
  });

  testWidgets('生产分支的空信：草稿行先建后删，扩展仍收到 draftUid == null',
      (tester) async {
    final recorder = _Recorder('com.example.recorder');
    AppExtensionRegistry.instance.registerAll(<AppExtension>[recorder]);

    // 有草稿行的那条路（`args.draftId > 0`）：页面一进来就挂了保存器，
    // 退出走 `flush` + `closeComposePage`，而不是控制器的 `saveDraftOnExit`。
    final draftDb = AppDatabase.forTesting(NativeDatabase.memory());
    final draftId = await draftDb.localDao.createComposeDraft(profileId: 'p1');
    final db = await pumpCompose(
      tester,
      database: draftDb,
      args: ComposeArgs(draftId: draftId),
    );

    // 一个字都不输入，直接退出：保存器没东西可写，`closeComposePage` 把这条
    // 由 `createComposeDraft` 建出来的空行删掉。
    await tapCloseAndSettle(tester);

    expect(recorder.calls, hasLength(1), reason: '空信也要通知一次');
    expect(recorder.calls.single.profileId, 'p1');
    expect(
      recorder.calls.single.draftUid,
      isNull,
      reason: '行已被删掉，扩展拿到的必须是 null（不能把已删行的 uid 发出去）',
    );
    expect(
      await db.localDao.findDraft(draftId),
      isNull,
      reason: '空信的生产分支同样不留行',
    );
    await db.close();
  });

  testWidgets('一个扩展抛错，不影响另一个扩展收到事件', (tester) async {
    final thrower = _Recorder('com.example.thrower', throws: true);
    final recorder = _Recorder('com.example.recorder');
    // 抛错的排在前面：注册顺序就是调用顺序，这样才真的挡住后一个。
    AppExtensionRegistry.instance
        .registerAll(<AppExtension>[thrower, recorder]);

    final db = await pumpCompose(tester);
    await tapCloseAndSettle(tester);

    expect(thrower.calls, hasLength(1), reason: '坏扩展自己也该被调用到');
    expect(
      recorder.calls,
      hasLength(1),
      reason: '注册表逐个 await + 吞异常：前一个炸了，后一个仍要收到',
    );
    expect(
      recorder.calls.single.draftUid,
      isNull,
      reason: '空信的口径不受扩展是否抛错影响',
    );
    await db.close();
  });
}
