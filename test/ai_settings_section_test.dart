import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/features/settings/sections/ai_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组测试**只换 prefs 与钥匙串，不建数据库**。
///
/// 建库会留下 drift 的流关闭定时器，`flutter test` 会以
/// 「A Timer is still pending」收场 —— `mailbox_filter_overlay_test.dart`
/// 的类注释里记过同一件事。这一页用得上的两条数据源只有 prefs 与钥匙串。
const fakeKey = 'sk-ant-0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> chain;

  setUp(() {
    chain = Map<String, String>.of(const <String, String>{});
    FlutterSecureStorage.setMockInitialValues(chain);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<String>? models,
    String? modelsError,
    int? testChars,
    String? testError,
    String? seedKey,
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    // 想从「钥匙串里已经有 Key」出发的用例，自己往 mock 钥匙串里塞一份。
    if (seedKey != null) {
      chain = Map<String, String>.of({'ai_api_key': seedKey});
    }
    FlutterSecureStorage.setMockInitialValues(chain);
    await tester.pumpWidget(
      ProviderScope(
        // 不写 `<Override>[]`：riverpod 3.4 里 `Override` 是 `sealed`
        // 且没有对外导出（`mailbox_filter_overlay_test.dart` 记过同一坑）。
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          aiServiceProvider.overrideWithValue(
            _FakeAiService(
              models: models,
              modelsError: modelsError,
              testChars: testChars,
              testError: testError,
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: AiSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点「拉取 / 测试连接」前先把路让开 —— 这两颗按钮排在地址 / 格式 / Key
  /// **之后**（「模型」那一段里），两个坑都会让 tap 打空：
  ///
  /// 1. 800×600 的默认视口里它们卡在折线附近（实测：derived an Offset that
  ///    would not hit test）—— 先滚进视口；
  /// 2. 点过「保存」之后那条 SnackBar 悬在屏幕底部，正好盖住按钮 ——
  ///    把 `pumpAndSettle` 卡住的是它 4 秒的展示时长，所以这里手动推时钟
  ///    （`pump` 不跑真定时器，不推的话它永远不会自己走）。
  Future<void> tapAction(WidgetTester tester, Key key) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final target = find.byKey(key);
    await tester.dragUntilVisible(
      target,
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// 「拉取」是模型下拉右沿那颗（`TextButton`），「测试连接」是同行那颗
  /// （`OutlinedButton`）。按钮的灰与亮就直接看 `onPressed` 有没有 ——
  /// 比「点一下看有没有反应」准，也不会被下拉里恰好同名的条目骗到。
  bool fetchEnabled(WidgetTester tester) =>
      tester
          .widget<TextButton>(find.byKey(const ValueKey('ai-models-fetch')))
          .onPressed !=
      null;

  bool testEnabled(WidgetTester tester) =>
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('ai-test-connection')),
          )
          .onPressed !=
      null;

  /// 下拉**开着**的时候里面有没有这个名字。条目只在菜单打开时存在，
  /// 所以这个断言同时说明「菜单弹出来了」。
  Finder modelOption(String name) =>
      find.byKey(ValueKey('ai-model-option-$name'));

  /// 模型栏那个输入框里的字。`ai-model` 这个 key 挂在 `DropdownMenu` 上，
  /// 里面的 `TextField` 是它的后代 —— 所以要往下找一层。
  String? modelText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('ai-model')),
          matching: find.byType(TextField),
        ),
      )
      .controller
      ?.text;

  testWidgets('没配过时：说没填过 Key，并给出隐私声明', (tester) async {
    await pumpScreen(tester);
    expect(find.text('还没填过 Key'), findsOneWidget);
    // spec §4.4 硬要求：这句话必须在设置页上，不能只写在文档里。
    expect(
      find.textContaining('会被发送到你配置的服务商'),
      findsOneWidget,
      reason: '隐私声明不见了 —— spec §4.4 要求它出现在设置页',
    );
  });

  testWidgets('粘贴带空格的 Key → 当场拒掉，且不进钥匙串', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'sk-ant 0123');
    await tester.pumpAndSettle();
    expect(find.text('Key 里有空格或换行 —— 检查一下粘贴'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    expect(chain, isEmpty, reason: '校验没过就不该写进钥匙串');
  });

  testWidgets('填对 Key 保存 → 进钥匙串、界面翻成「已保存 Key」', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    expect(chain.values.single, fakeKey);
    expect(find.text('已保存 Key'), findsOneWidget);
  });

  testWidgets('清除 → 钥匙串清空、界面翻回来', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ai-key-clear')));
    await tester.pumpAndSettle();
    expect(chain, isEmpty);
    expect(find.text('还没填过 Key'), findsOneWidget);
  });

  testWidgets('默认一进来：格式是 OpenAI 兼容、地址是官方地址、模型是空的', (tester) async {
    await pumpScreen(tester);
    // 地址栏的 hint 与默认地址**是同一个串**（`aiBaseUrlHint` 就是
    // `https://api.openai.com/v1`），所以 `find.text(openaiDefaultBase)` 会
    // 同时撞上「框里的值」和「hint」（实测 2 个）。要问的是「框里是不是这个
    // 默认地址」，直接读控制器最准 —— 换成 findsWidgets 的话，框是空的也照样
    // 通过（那时 hint 还挂着），等于把这条断言废掉。
    final baseField = tester.widget<TextField>(
      find.byKey(const ValueKey('ai-base-url')),
    );
    expect(baseField.controller?.text, AiSettings.openaiDefaultBase);
    expect(find.text('OpenAI 兼容'), findsOneWidget);
  });

  testWidgets('切格式：地址为空时自动填该格式的默认地址', (tester) async {
    await pumpScreen(tester);
    // 先把地址清空（模拟「用户还没填」）。
    await tester.enterText(find.byKey(const ValueKey('ai-base-url')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-api-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();
    // 读控制器而不是 `find.text`：地址栏的 hint 与这一档的默认地址**是同一个
    // 串**（`aiBaseUrlHintAnthropic` 就是 `https://api.anthropic.com`），
    // 框里与 hint 会同时命中，`findsOneWidget` 直接被自己的例文撞掉。
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-base-url')))
          .controller
          ?.text,
      AiSettings.anthropicDefaultBase,
    );
  });

  testWidgets('切格式：用户自己填的代理地址不被覆盖', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'https://proxy.example.com/llm',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-api-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();
    expect(
      find.text('https://proxy.example.com/llm'),
      findsOneWidget,
      reason: '用户填的地址不能被格式切换吃掉',
    );
  });

  testWidgets('切到 New API：地址一个字都不动（这一档没有默认地址）', (tester) async {
    await pumpScreen(tester);
    TextField baseField() => tester.widget<TextField>(
      find.byKey(const ValueKey('ai-base-url')),
    );
    // 官方默认地址摆在那儿 —— 切到 New API 时它也**不该**被清掉，
    // 因为这一档没有默认地址可填，清空只是把用户现有的东西抹掉。
    expect(baseField().controller?.text, AiSettings.openaiDefaultBase);
    await tester.tap(find.byKey(const ValueKey('ai-api-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New API').last);
    await tester.pumpAndSettle();
    expect(baseField().controller?.text, AiSettings.openaiDefaultBase);
  });

  testWidgets('地址少协议 → 就地报错，且拉取按钮点不动', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'api.openai.com/v1',
    );
    await tester.pumpAndSettle();
    expect(find.text('地址要以 http:// 或 https:// 开头'), findsOneWidget);
    // 地址是拉取/测试三样门槛里的一样，红了就不该能点（现在填了 Key 也不行）。
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.pumpAndSettle();
    expect(fetchEnabled(tester), isFalse, reason: '地址不合法，按钮该是灰的');
  });

  testWidgets('没配 Key 时拉取按钮点不动，并说明差什么', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'gpt-4o');
    await tester.pumpAndSettle();
    expect(find.text('先填 Key 才能拉取'), findsOneWidget);
    expect(fetchEnabled(tester), isFalse, reason: '按钮该是灰的，点不动');
  });

  testWidgets('地址和 Key 都填了（还没点保存）→ 拉取按钮就能点，且 Key 顺带存好', (tester) async {
    await pumpScreen(tester, models: const ['gpt-4o']);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.pumpAndSettle();
    // **不点「保存」**：三样齐了就该能用，否则用户点下去只会觉得按钮坏了。
    await tapAction(tester, const ValueKey('ai-models-fetch'));

    // 拉回来的名字直接进下拉，并且**自动弹开**让用户挑。
    expect(modelOption('gpt-4o'), findsOneWidget);
    expect(chain.values.single, fakeKey, reason: '点拉取时草稿里的 Key 要先落进钥匙串');
  });

  testWidgets('三样齐但没模型 → 拉取能点、测试连接不能，且说明为什么', (tester) async {
    await pumpScreen(tester, models: const ['gpt-4o']);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();

    expect(find.text('先有模型名才能测试 —— 拉取一个或手填'), findsOneWidget);
    expect(testEnabled(tester), isFalse, reason: '没模型名，按钮该是灰的');
    // 拉取不受模型门槛影响：它本来就是用来拿到模型名的。
    expect(fetchEnabled(tester), isTrue, reason: '地址与 Key 都齐了');
  });

  testWidgets('钥匙串里存过 Key、输入框里这份是错的 → 不按「没填 Key」拦人', (tester) async {
    await pumpScreen(tester, seedKey: fakeKey);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'sk-ant 0123');
    await tester.pumpAndSettle();

    expect(find.text('Key 里有空格或换行 —— 检查一下粘贴'), findsOneWidget);
    // 错的草稿没进钥匙串，但**存过的那份**还在，那才是真正会用的 Key ——
    // 这时再说「先填 Key」是句假话。
    expect(find.text('先填 Key 才能拉取'), findsNothing);
  });

  testWidgets('地址敲到一半（仍是合法 URL）→ 拉取按钮保持可用', (tester) async {
    await pumpScreen(tester, seedKey: fakeKey);

    // 敲到一半的半截地址：还是 http(s) 开头，按钮不该跟着抖。
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'https://proxy.exa',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('ai-models-fetch')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('敲完地址直接点拉取 → 地址先落盘（不必先回车一次）', (tester) async {
    await pumpScreen(tester, models: const ['gpt-4o'], seedKey: fakeKey);
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'https://proxy.example.com/v1',
    );
    await tester.pumpAndSettle();
    await tapAction(tester, const ValueKey('ai-models-fetch'));

    // 按钮认草稿，所以点下去时草稿必须先变成真的 —— 否则 `AiService` 读到的
    // 还是旧地址，用户看到的是「按了没反应 / 报的还是上一个地址」。
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final saved = AiSettingsCodec.decode(prefs.aiSettingsJson);
    expect(saved.baseUrl, 'https://proxy.example.com/v1');
  });

  testWidgets('敲完地址与模型直接点测试连接 → 两个草稿都落盘（不互相抹掉）', (tester) async {
    await pumpScreen(tester, testChars: 4, seedKey: fakeKey);
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'https://proxy.example.com/v1',
    );
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'gpt-4o');
    await tester.pumpAndSettle();
    await tapAction(tester, const ValueKey('ai-test-connection'));

    expect(find.text('连接正常，模型返回了 4 个字'), findsOneWidget);
    // `_save` 是整份覆盖：存地址那一步要是拿**旧对象**去 `copyWith`，刚存下的
    // 模型名会被成片抹回空串（两处 `_save` 的顺序就是为这条盯着的）。
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final saved = AiSettingsCodec.decode(prefs.aiSettingsJson);
    expect(saved.baseUrl, 'https://proxy.example.com/v1');
    expect(saved.model, 'gpt-4o');
  });

  testWidgets('配好 Key 后拉取：下拉自动弹开 → 打字过滤 → 选中写入模型栏', (tester) async {
    // 这一页现在比默认 800×600 的测试视口高，「模型」那一行会落到视口下沿。
    // 而 `DropdownMenu` 挂在一个 `RawMenuAnchor` 上，它的祖先 `Scrollable`
    // 一旦滚动就会把菜单关掉（`_handleScroll`）—— 打字时焦点落进输入框，
    // 滚动位置被 `ensureVisible` 微调一下，菜单就没了。这不是产品缺陷（真机
    // 上用户自己滚好再点开就行），但会让这条断言随机失败。把视口调高，
    // 让整页铺得下、不产生祖先滚动，测的仍是「弹开 → 过滤 → 选中」本身。
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpScreen(tester, models: const ['gpt-4o', 'gpt-4o-mini', 'o3']);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();

    await tapAction(tester, const ValueKey('ai-models-fetch'));
    // 拉回来的三条都在下拉里（这就是「自动弹开」的证据 —— 条目只在开着时存在）。
    expect(modelOption('gpt-4o-mini'), findsOneWidget);
    expect(modelOption('o3'), findsOneWidget);

    // 下拉自己带过滤：敲「mini」把别的都筛掉。
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'mini');
    await tester.pumpAndSettle();
    expect(modelOption('gpt-4o-mini'), findsOneWidget);
    expect(modelOption('o3'), findsNothing);

    await tester.tap(modelOption('gpt-4o-mini'));
    await tester.pumpAndSettle();
    expect(
      modelText(tester),
      'gpt-4o-mini',
      reason: '选中即写入模型栏',
    );
  });

  testWidgets('拉回来的名字不在列表里也能手输（可编辑的那一半）', (tester) async {
    await pumpScreen(tester, models: const ['gpt-4o']);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('ai-model')),
      'my-own-endpoint-model',
    );
    await tester.pumpAndSettle();
    expect(
      modelText(tester),
      'my-own-endpoint-model',
    );
    expect(testEnabled(tester), isTrue, reason: '手输的名字同样算「有模型」');
  });

  testWidgets('拉不到 → 有提示、不弹下拉，手输照样能用', (tester) async {
    await pumpScreen(tester, modelsError: 'no models endpoint');
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    await tapAction(tester, const ValueKey('ai-models-fetch'));

    // 拉不到就一条候选都没有：下拉里空着，但没有第二个选择器弹出来。
    expect(modelOption('gpt-4o'), findsNothing);
    expect(find.textContaining('no models endpoint'), findsOneWidget);
  });

  testWidgets('端点回了 200 但没有列表 → 说「手动填即可」，不说「拉取失败」', (tester) async {
    await pumpScreen(tester, models: const <String>[]);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    await tapAction(tester, const ValueKey('ai-models-fetch'));

    expect(find.text('这个端点没有模型列表，手动填模型名即可'), findsOneWidget);
    expect(find.textContaining('拉取失败'), findsNothing);
  });

  testWidgets('测试连接成功 → 就地一行绿字', (tester) async {
    await pumpScreen(tester, testChars: 4);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-model')),
      'gpt-4o-mini',
    );
    await tester.pumpAndSettle();

    await tapAction(tester, const ValueKey('ai-test-connection'));
    expect(find.text('连接正常，模型返回了 4 个字'), findsOneWidget);
  });

  testWidgets('测试连接通了、但模型这次没吐字（推理模型）→ 不说「返回了 0 个字」', (tester) async {
    // 实测：网关上的推理模型对 `max_tokens: 8` 必然回空 content（思考吃光预算），
    // 而「连接正常，模型返回了 0 个字」读起来像失败。
    await pumpScreen(tester, testChars: 0);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'r1');
    await tester.pumpAndSettle();

    await tapAction(tester, const ValueKey('ai-test-connection'));
    expect(find.text('连接正常，模型返回了 0 个字'), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-test-ok')),
      findsOneWidget,
      reason: '仍是一句绿字的「连接正常」',
    );
  });

  testWidgets('测试连接失败 → 就地一行红字（脱敏后的原文）', (tester) async {
    await pumpScreen(tester, testError: 'The model `nope` does not exist');
    await tester.enterText(find.byKey(const ValueKey('ai-key')), fakeKey);
    await tester.tap(find.byKey(const ValueKey('ai-key-save')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'nope');
    await tester.pumpAndSettle();

    await tapAction(tester, const ValueKey('ai-test-connection'));
    expect(find.textContaining('does not exist'), findsOneWidget);
  });

  testWidgets('地址与 Key 齐、只差模型名 → 拉取按钮亮着能点（模型名本就是它要拿的东西）', (tester) async {
    // 这条盯的是实测报上来的那个缺陷：三样里少模型名时按钮亮着，点下去
    // `AiService` 却按 `isUsable` 拦下、回「还没有配置 AI」—— 用户刚填完
    // 地址和 Key，读到这句只会以为界面在说谎。
    await pumpScreen(tester, models: const ['gpt-4o'], seedKey: fakeKey);
    await tapAction(tester, const ValueKey('ai-models-fetch'));

    expect(modelOption('gpt-4o'), findsOneWidget, reason: '拉取不该被模型名卡住');
    expect(find.textContaining('还没有配置 AI'), findsNothing);
  });

  testWidgets('存过 Key → Key 输入框里显示掩码，且它不是真值', (tester) async {
    await pumpScreen(tester, seedKey: fakeKey);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('ai-key')),
    );
    // 掩码是 hint，不是值：控制器还空着，所以「没打字」与「打了字」不会混淆。
    expect(field.decoration?.hintText, isNotEmpty);
    expect(field.controller?.text, isEmpty);
    expect(chain.values.single, fakeKey, reason: '掩码一个字都不该进钥匙串');

    // 用户一开始打字，掩码就让位（清空输入框 → hint 回来）。
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'sk-ant-abc');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('ai-key')))
          .decoration
          ?.hintText,
      isNotEmpty,
      reason: '有 Key 存着，hint 一直在',
    );
    expect(chain.values.single, fakeKey, reason: '草稿没点保存，不该覆盖钥匙串');
  });

  /// 把目标滚进视口并**等它真的落稳**。
  ///
  /// `dragUntilVisible` 判的是「这个 finder 有没有命中」，而不是「它在不在
  /// 视口内」：列表最后那一项 `cacheExtent`（默认 250）范围内的东西已经
  /// build 出来了，finder 命中，可它的中心还在屏幕外（y=618 > 600）——
  /// 这时候直接 `tap` 会打空，而且 `tap` 只是打一条 warning 就过去，
  /// 失败要等到后面断言「值变了没有」才暴露，看起来像「没落盘」。
  ///
  /// 所以补一步 `ensureVisible`（它才真的保证在视口里）。
  ///
  /// 这一段在 `AiSettingsScreen` 拆成 `AiSettingsSection`、外面多包一层
  /// `Scaffold` / `SafeArea` 之后才暴露出来：视口没变，是内容整体上移了几
  /// 像素，恰好把最后一组开关推过了那条线。
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    final list = find.byType(ListView);
    await tester.dragUntilVisible(target, list, const Offset(0, -200));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  testWidgets('四个开关与每日上限：改了之后离开再回来还是改后的值', (tester) async {
    await pumpScreen(tester);
    // 地址栏从「只对自定义厂商出现」变成常驻主字段之后，这一页整体长高，
    // 默认 800×600 的测试视口下上面的开关组还没被 build 出来（`ListView`
    // 懒构建）—— 与「今日用量」那条同一个坑。先滚到它出现，再断言。
    final inline = find.byKey(const ValueKey('ai-inline'));
    await scrollTo(tester, inline);
    // 行内续写默认关（spec §4.3③：每次停笔都花钱）。
    expect(tester.widget<SwitchListTile>(inline).value, isFalse);
    await tester.tap(inline);
    await tester.pumpAndSettle();

    // 润色是后拆出来的第四个开关，默认开（用户主动点才花钱）。
    final polish = find.byKey(const ValueKey('ai-polish'));
    await scrollTo(tester, polish);
    expect(tester.widget<SwitchListTile>(polish).value, isTrue);
    await tester.tap(polish);
    await tester.pumpAndSettle();

    await pumpScreen(tester);
    await scrollTo(tester, inline);
    expect(
      tester.widget<SwitchListTile>(inline).value,
      isTrue,
      reason: '开关没落盘 —— 它应该走 AiSettingsStore.save',
    );
    await scrollTo(tester, polish);
    expect(
      tester.widget<SwitchListTile>(polish).value,
      isFalse,
      reason: '润色开关同样要落盘（它有自己的 prefs 键 polish）',
    );
  });

  testWidgets('今日用量显示得出来', (tester) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await prefs.setAiUsage('2026-10-10:7');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: AiSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 唯一一处与计划原文的偏差：用量的这两行在页面**最底部**，默认 800×600
    // 的测试视口下 `ListView` 还没把它 build 出来（懒构建），直接 expect 会
    // findsNothing —— 不是文案丢了，是它根本还没被创建。先滚到底再看。
    await tester.dragUntilVisible(
      find.textContaining('今天已用'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    // 日期要对得上「今天」，否则 AiUsageCounter 会按跨天归零算成 0。
    expect(find.textContaining('今天已用'), findsOneWidget);
  });
}

/// 只回答「拉模型」与「测试连接」的假 service —— 那两条要发网络，而这一组
/// 测试不碰网络。四项能力这里用不到，抛出来即可。
class _FakeAiService implements AiService {
  _FakeAiService({
    this.models,
    this.modelsError,
    this.testChars,
    this.testError,
  });

  final List<String>? models;
  final String? modelsError;
  final int? testChars;
  final String? testError;

  @override
  int get usedToday => 0;

  @override
  Future<AiModelsResult> listModels() async {
    if (modelsError != null) return AiModelsFailed(modelsError!);
    return AiModelsOk(models ?? const <String>[]);
  }

  @override
  Future<AiTestResult> testConnection() async {
    if (testError != null) return AiTestFailed(testError!);
    return AiTestOk(testChars ?? 0);
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这一组测试不用 ${invocation.memberName}');
}
