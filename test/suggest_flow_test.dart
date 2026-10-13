import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/suggest/mail_action.dart';
import 'package:mail_app/features/suggest/suggest_flow.dart';
import 'package:mail_app/features/suggest/suggestion.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mocktail/mocktail.dart';

class _FakeAi extends Mock implements AiService {}

/// `EmailRepository` 不是接口，但 mocktail 能按接口实现它 —— 这里**只需要**
/// `ensureFull` 一个方法，别的一律不碰（碰了就会得到 `MissingStubError`，
/// 那正是我们要的信号：`open` 除了 `ensureFull` 不该去动仓库的别的地方）。
class _FakeRepo extends Mock implements EmailRepository {}

/// 摘要行：`hasFullBody == false`，正文只有 `text` 那一小段。
MailRow summaryRow() => const MailRow(
      emailId: 7,
      profileId: 'p1',
      name: '张三',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      mailboxEmail: 'me@example.com',
      text: '会议时间定了吗？',
      hasFullBody: false,
    );

/// 补全之后的那一行（`content` 齐了）—— 它会以这个形态落在**库**里。
MailRow fullRow() => const MailRow(
      emailId: 7,
      profileId: 'p1',
      name: '张三',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      mailboxEmail: 'me@example.com',
      content: '<p>补全之后的完整正文</p>',
      hasFullBody: true,
    );

/// 这条用例两次重读之间要能区分「谁给的那一份」——留一个哨兵字段。
const String _kFreshMarker = '补全之后的完整正文';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeAi ai;
  late _FakeRepo repo;

  setUpAll(() {
    // `any()` 碰上自定义类型要先登记一个占位值，mocktail 的老规矩。
    registerFallbackValue(const MailRef(profileId: '', emailId: 0));
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ai = _FakeAi();
    repo = _FakeRepo();
  });

  tearDown(() => db.close());

  /// 走一遍 `SuggestFlow.open`。
  ///
  /// [opener] 就是被换掉的面板：它拿到 `open` 组装好的那几个回调，返回
  /// 一个写死的 choice（或 null = 用户关掉）。
  ///
  /// 执行器**也换成一支只记录的笔**：断言「执行器收到的是哪一行」最直接的
  /// 办法就是在它入口处记一下。不换的话这一条要真去拼引用块、开草稿页。
  Future<void> pumpFlow(
    WidgetTester tester, {
    required MailRow row,
    required SuggestionChoice? picked,
    required List<MailRow> executed,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        aiServiceProvider.overrideWithValue(ai),
        emailRepositoryProvider.overrideWithValue(repo),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream<InstanceCapabilities>.value(
            const InstanceCapabilities(),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              key: const ValueKey('go'),
              onPressed: () => SuggestFlow.open(
                context,
                ref,
                row: row,
                opener: (
                  BuildContext _, {
                  required MailRow row,
                  required bool starEnabled,
                  required Future<MailRow?> Function() refresh,
                  required Future<AiStart> Function(String, List<String>) launch,
                }) async =>
                    picked,
                executor: (
                  BuildContext _,
                  WidgetRef _,
                  {
                  required MailRow row,
                  required SuggestionChoice choice,
                  VoidCallback? onDeleted,
                }) async =>
                    executed.add(row),
              ),
              child: const Text('走'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('入口该不该画（spec §8.3）', () {
    // 一份「配得上 AI」的设置。
    const usable = AiSettings(
      model: 'gpt-4o-mini',
      baseUrl: 'https://api.example.com/v1',
      hasApiKey: true,
    );

    MailRow receive() => const MailRow(
          emailId: 1,
          profileId: 'p1',
          type: MailType.receive,
          hasFullBody: true,
        );

    // 单独造一个而不是 `receive().copyWith(type: ...)` —— `MailRow.copyWith`
    // 的**参数表里没有 `type`**（它只改状态类字段），传了编译不过。
    MailRow send() => const MailRow(
          emailId: 1,
          profileId: 'p1',
          type: MailType.send,
          hasFullBody: true,
        );

    test('三条都满足才画', () {
      expect(SuggestFlow.visible(receive(), usable), isTrue);
    });

    test('① 已发送方向：不画', () {
      expect(
        SuggestFlow.visible(send(), usable),
        isFalse,
        reason: '「怎么处理自己发出去的信号」没有意义',
      );
    });

    test('② 没配好（还没读到 / 缺 Key / 缺模型）：不画', () {
      expect(SuggestFlow.visible(receive(), null), isFalse);
      expect(
        SuggestFlow.visible(receive(), const AiSettings()),
        isFalse,
        reason: '地址与模型都是空的',
      );
      expect(
        SuggestFlow.visible(
          receive(),
          const AiSettings(
            model: 'gpt-4o-mini',
            baseUrl: 'https://api.example.com/v1',
            // hasApiKey 默认 false
          ),
        ),
        isFalse,
        reason: '没存过 Key',
      );
    });

    test('③ 用户在设置里关掉了：不画', () {
      expect(
        SuggestFlow.visible(
          receive(),
          const AiSettings(
            model: 'gpt-4o-mini',
            baseUrl: 'https://api.example.com/v1',
            hasApiKey: true,
            mailSuggestEnabled: false,
          ),
        ),
        isFalse,
      );
    });
  });

  testWidgets('执行器拿到的是**重读过的那一行**，不是传进来那个对象',
      (tester) async {
    // 库里已经是全文（这就是 `ensureFull` 干完活之后的样子），
    // 而调用方手里那个 `row` 还是列表页给的摘要行。
    await db.mailDao.upsertPage(<MailRow>[fullRow()]);
    final executed = <MailRow>[];

    await pumpFlow(
      tester,
      row: summaryRow(),
      picked: const SuggestionChoice(
        action: MailAction.reply,
        reason: '在等你回',
      ),
      executed: executed,
    );
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pump();

    expect(executed, hasLength(1));
    expect(
      executed.single.hasFullBody,
      isTrue,
      reason: '拿摘要行去拼引用块，用户点「答复」只会看到那 300 字',
    );
    expect(executed.single.content, contains(_kFreshMarker));
  });

  testWidgets('用户关掉面板（pop null）：一次都不执行', (tester) async {
    await db.mailDao.upsertPage(<MailRow>[fullRow()]);
    final executed = <MailRow>[];

    await pumpFlow(
      tester,
      row: fullRow(),
      picked: null,
      executed: executed,
    );
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pump();

    expect(executed, isEmpty);
  });

  testWidgets('补正文失败（实例不支持 full / 网络挂）**不阻断**', (tester) async {
    // 库里只有摘要那一行 —— 补不上就是补不上。
    await db.mailDao.upsertPage(<MailRow>[summaryRow()]);
    when(() => repo.ensureFull(any())).thenThrow(Exception('实例不支持 full'));
    final executed = <MailRow>[];
    MailRow? fromRefresh;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        aiServiceProvider.overrideWithValue(ai),
        emailRepositoryProvider.overrideWithValue(repo),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream<InstanceCapabilities>.value(
            const InstanceCapabilities(),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              key: const ValueKey('go'),
              onPressed: () => SuggestFlow.open(
                context,
                ref,
                row: summaryRow(),
                opener: (
                  BuildContext _, {
                  required MailRow row,
                  required bool starEnabled,
                  required Future<MailRow?> Function() refresh,
                  required Future<AiStart> Function(String, List<String>) launch,
                }) async {
                  // 面板会调它，这里手动调一次 —— 断的是「抛了也不往外冒」。
                  fromRefresh = await refresh();
                  return const SuggestionChoice(
                    action: MailAction.none,
                    reason: '不用管',
                  );
                },
                executor: (
                  BuildContext _,
                  WidgetRef _,
                  {
                  required MailRow row,
                  required SuggestionChoice choice,
                  VoidCallback? onDeleted,
                }) async =>
                    executed.add(row),
              ),
              child: const Text('走'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pump();

    expect(
      fromRefresh,
      isNotNull,
      reason: '补不到就明说：仍然把库里那一行给面板（抬头如实写「正文 N 字」）',
    );
    expect(fromRefresh!.hasFullBody, isFalse);
    expect(executed, hasLength(1), reason: '拿摘要继续，不阻断');
  });

  testWidgets('面板拿到的 row / starEnabled / launch 都对', (tester) async {
    await db.mailDao.upsertPage(<MailRow>[fullRow()]);
    when(() => ai.suggest(
          input: any(named: 'input'),
          actionIds: any(named: 'actionIds'),
        )).thenAnswer(
      (_) async => AiStarted(AiStream(
        text: const Stream<String>.empty(),
        done: Future<String>.value(''),
        cancel: () {},
      )),
    );

    MailRow? seen;
    var seenStarEnabled = false;
    Future<AiStart>? seenLaunch;
    // 传进去的必须是**同一个对象**才能用 `same()` 断 —— `summaryRow()`
    // 每次调用都新造一个。
    final row = summaryRow();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        aiServiceProvider.overrideWithValue(ai),
        emailRepositoryProvider.overrideWithValue(repo),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream<InstanceCapabilities>.value(
            const InstanceCapabilities(),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              key: const ValueKey('go'),
              onPressed: () => SuggestFlow.open(
                context,
                ref,
                row: row,
                opener: (
                  BuildContext _, {
                  required MailRow row,
                  required bool starEnabled,
                  required Future<MailRow?> Function() refresh,
                  required Future<AiStart> Function(String, List<String>) launch,
                }) async {
                  seen = row;
                  seenStarEnabled = starEnabled;
                  seenLaunch = launch(String.fromCharCode(0), const <String>[]);
                  return null;
                },
              ),
              child: const Text('走'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pump();

    expect(seen, same(row), reason: '面板要先能显示「拿的是哪封信」');
    expect(seenStarEnabled, isTrue,
        reason: '能力探测没结论（unknown）时按可用算 —— 与星标那颗同一个口径');
    await seenLaunch;
    verify(() => ai.suggest(
          input: any(named: 'input'),
          actionIds: any(named: 'actionIds'),
        )).called(1);
  });

  /// `starEnabled` 真的是**读能力探测**得来的，不是一个写死的 `true`。
  ///
  /// 上面那条用 `unknown` 钉的是「没结论时按可用算」，而 `unknown` 与
  /// 「直接 `true`」的结果一样 —— 单靠它，把 `capabilitiesProvider` 那一行
  /// 换成常量也能全绿。这里用 `absent`（实例没有 `/star/list`）把两条路分开。
  testWidgets('实例明确没有星标能力时，面板拿到的是 false', (tester) async {
    MailRow? seenRow;
    var seenStarEnabled = true;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        aiServiceProvider.overrideWithValue(ai),
        emailRepositoryProvider.overrideWithValue(repo),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream<InstanceCapabilities>.value(
            const InstanceCapabilities(hasStar: ProbeState.absent),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              // **先订阅**，否则 `capabilitiesProvider` 没人监听、从没被创建
              // 过，`open` 里那次 `ref.read(...).value` 只会拿到一个刚起步的
              // `AsyncLoading`（null），于是退到 `?? true` —— 这条用例就变成
              // 在断那个兜底了。真实界面里详情页那颗星一直在 `watch` 它，
              // 所以这里如实模拟：进页面时它已经在读了。
              ref.watch(capabilitiesProvider('p1'));
              return ElevatedButton(
                key: const ValueKey('go'),
                onPressed: () => SuggestFlow.open(
                  context,
                  ref,
                  row: summaryRow(),
                  opener: (
                    BuildContext _, {
                    required MailRow row,
                    required bool starEnabled,
                    required Future<MailRow?> Function() refresh,
                    required Future<AiStart> Function(String, List<String>)
                        launch,
                  }) async {
                    seenRow = row;
                    seenStarEnabled = starEnabled;
                    return null;
                  },
                ),
                child: const Text('走'),
              );
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 前提自查：能力真的读到了 —— 断的就是「读的是能力探测」，不是兜底。
    expect(
      ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('go'))),
      ).read(capabilitiesProvider('p1')).value?.hasStar,
      ProbeState.absent,
    );

    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pump();

    expect(seenRow, isNotNull, reason: '前提：面板确实被调起来了');
    expect(seenStarEnabled, isFalse,
        reason: '`absent` 是「端点不存在」—— 与详情页那颗星同一个判据，'
            '不能退化成写死的 true');
  });
}
