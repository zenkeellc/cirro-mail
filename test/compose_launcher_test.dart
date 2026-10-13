// 「打开写邮件页」只有两条路，这一组把它们的产物（**拼出来的地址**）钉住。
//
// 为什么值得单独钉：`Cmd+N` 必须和外壳那颗 FAB 开出**同一个**地址（含
// `composePreselectProvider` 预选的发件箱），`Cmd+R` 必须和详情页那颗回形箭头
// 开出同一个地址。各写一遍的话，「预选发件箱」这个行为迟早只在其中一处生效
// —— 症状是「点 FAB 从对的邮箱发，按 Cmd+N 从默认邮箱发」。
//
// 这里用**真的 `GoRouter`**（不是断言字符串拼接）：`context.push` 是 go_router
// 的扩展方法，在一个普通 `Navigator` 上会直接抛；而且「顶层 push 而不是 go」
// 这件事只有走真路由器才验得出来。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_launcher.dart';
import 'package:mail_app/features/compose/compose_preselect.dart';

void main() {
  /// 装一棵「外壳 + 顶层 push」的最小树，返回被推上去的地址。
  ///
  /// 用 `GoRouter.optionURLReflectsImperativeAPIs` 之外的办法：监听
  /// `routerDelegate` 的 `currentConfiguration.uri` —— push 之后它就是新地址。
  Future<GoRouter> pump(WidgetTester tester, Widget Function(BuildContext) body) async {
    final router = GoRouter(
      initialLocation: '/list',
      routes: <RouteBase>[
        GoRoute(path: '/list', builder: (context, state) => body(context)),
        // 写邮件页用**代替品**：这一组只验地址，不验页面（页面有它自己的
        // 一整套用例）。用一个把地址打出来的壳，顺带能看出 query 参数。
        GoRoute(
          path: '/compose',
          builder: (context, state) => Scaffold(
            body: Text('compose:${state.uri}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('新建：说不清从哪个邮箱发时，地址里什么参数都没有', (tester) async {
    await pump(
      tester,
      (context) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openNewComposeWith(context, null),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('compose:/compose'), findsOneWidget);
  });

  testWidgets('新建：预选了发件箱就带上 profile 与 account', (tester) async {
    await pump(
      tester,
      (context) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openNewComposeWith(
                context,
                const ComposePreselect(profileId: 'p1', accountId: 12),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text('compose:/compose?profile=p1&account=12'),
      findsOneWidget,
    );
  });

  testWidgets('新建：合并项（accountId = 0）不写进地址', (tester) async {
    // `ComposeArgs.hasMailboxHint` 只认 > 0，给 0 与不给是同一件事 ——
    // 但地址里多一个 `account=0` 会让人以为「选中了第 0 个邮箱」。
    await pump(
      tester,
      (context) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openNewComposeWith(
                context,
                const ComposePreselect(profileId: 'p1', accountId: 0),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('compose:/compose?profile=p1'), findsOneWidget);
  });

  testWidgets('新建：读的是 composePreselectProvider 里那一份', (tester) async {
    // FAB 那条路（`openNewCompose`）—— 它与 `With` 版的差别就只有
    // 「谁提供预选值」，所以这里钉住「确实读了 provider」。
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    container
        .read(composePreselectProvider.notifier)
        .publish(Object(), const ComposePreselect(profileId: 'p9', accountId: 3));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _LauncherHarness(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('compose:/compose?profile=p9&account=3'), findsOneWidget);
  });

  testWidgets('回复：带 email 与 mode，不带 account', (tester) async {
    await pump(
      tester,
      (context) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openMailCompose(
                context,
                mode: ComposeMode.reply,
                profileId: 'p2',
                emailId: 42,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text('compose:/compose?profile=p2&email=42&mode=reply'),
      findsOneWidget,
    );
  });

  testWidgets('转发：mode=forward 且实例跟着邮件走', (tester) async {
    await pump(
      tester,
      (context) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openMailCompose(
                context,
                mode: ComposeMode.forward,
                profileId: 'p3',
                emailId: 8,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text('compose:/compose?profile=p3&email=8&mode=forward'),
      findsOneWidget,
    );
  });
}

/// 一棵带真路由的壳，供 provider 那条用例用（`openNewCompose` 要 WidgetRef）。
class _LauncherHarness extends StatelessWidget {
  const _LauncherHarness();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/list',
        routes: <RouteBase>[
          GoRoute(
            path: '/list',
            builder: (context, state) => Scaffold(
              body: Center(
                child: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => openNewCompose(context, ref),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/compose',
            builder: (context, state) =>
                Scaffold(body: Text('compose:${state.uri}')),
          ),
        ],
      ),
    );
  }
}
