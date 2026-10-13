import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「被 TickerMode 暂停的消费者恢复可见」时**不许在 build 阶段碰根上的
/// ProviderScope**。
///
/// 这条路径是真机上炸过的（宽屏侧栏 / 窄屏底部导航切分支）：
///
/// ```
/// setState() or markNeedsBuild() called during build
/// #3  _UncontrolledProviderScopeState.scheduleRefresh
/// #8  ProviderElement.invalidateSelf
/// #21 ProviderSubscriptionImpl.resume
/// #22 ConsumerStatefulElement._updateTickerMode
/// #25 _TickerModeState._updateEffectiveMode
/// ```
///
/// 触发链：`go_router` 的 `StatefulShellRoute.indexedStack` 给每个分支套了
/// `TickerMode(enabled: isActive)`；切分支时 enabled 翻转 → `didUpdateWidget`
/// 里 `resume()` 该元素上所有订阅 → 把暂停期间积压的脏值重放出来 → 依赖链
/// 分叉处某个 provider 的 `ref.watch` 回调 `invalidateSelf` → 它的订阅此刻
/// 还挂在一个暂停中的元素上，于是刷新排到了树根上的
/// `UncontrolledProviderScope`，而那正是一棵正在 build 的树。
///
/// **为什么必须钉「分叉」这种形状**：一条直链上 flush 到叶子就结束了；只有
/// 依赖图有分叉时，第一条分支的重建才会把第二条分支也标脏 —— 也就是说，
/// 这个 bug 只在分叉图上现形，直链图测不出来。生产代码里
/// `mailListProvider` / `mailboxFilterSelectionProvider` / `syncOverviewProvider`
/// 那一片正是分叉的。
///
/// 跑在 `third_party/riverpod` 那份打过补丁的 3.4.3 上：未打补丁的上游 3.4.3
/// 里三条菱形全红，直链与切分支两条过。见 `third_party/PATCHES.md`。
class Seed extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final seed = NotifierProvider<Seed, int>(Seed.new);

/// 直链：seed → a → b（对照组：这种形状**不该**受影响）。
final aPlain = Provider<int>((ref) => ref.watch(seed) + 1);
final bPlain = Provider<int>((ref) => ref.watch(aPlain) * 2);

/// 菱形：seed → shared → {left, rightLeaf → right} → top。
final shared = Provider<int>((ref) => ref.watch(seed));
final left = Provider<int>((ref) => ref.watch(shared) + 1);
final rightLeaf = Provider<int>((ref) => ref.watch(shared) * 2);
final right = Provider<int>((ref) => ref.watch(rightLeaf));
final top = Provider<int>((ref) => ref.watch(left) + ref.watch(right));

/// 反着 watch 的菱形，以及套一层的菱形 —— 上游 #4882 只钉了左优先那一种，
/// 这里把顺序与层数都铺开：补丁少打任何一处，这几种形状里总有一种会露出来。
final topRev = Provider<int>((ref) {
  final r = ref.watch(right);
  final l = ref.watch(left);
  return l + r;
});
final sharedMid = Provider<int>((ref) => ref.watch(shared) + ref.watch(topRev));
final topDeep = Provider<int>((ref) => ref.watch(left) + ref.watch(sharedMid));

void main() {
  for (final probe in <({String name, Provider<int> provider})>[
    (name: '直链', provider: bPlain),
    (name: '菱形（左优先）', provider: top),
    (name: '菱形（右优先）', provider: topRev),
    (name: '两层菱形', provider: topDeep),
  ]) {
    testWidgets('暂停后恢复：${probe.name}', (tester) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      Widget app({required bool enabled}) => UncontrolledProviderScope(
            container: container,
            child: TickerMode(
              enabled: enabled,
              child: Consumer(
                builder: (context, ref, _) => Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text('${ref.watch(probe.provider)}'),
                ),
              ),
            ),
          );

      await tester.pumpWidget(app(enabled: true));
      expect(tester.takeException(), isNull);
      final first = container.read(probe.provider);

      // 暂停 → 在暂停期间把上游弄脏 → 恢复（恢复发生在 build 阶段里）。
      await tester.pumpWidget(app(enabled: false));
      container.read(seed.notifier).bump();
      await tester.pumpWidget(app(enabled: true));
      expect(tester.takeException(), isNull, reason: '恢复时不能抛 setState-during-build');

      // 不抛还不够 —— 卡在暂停那一刻的旧值同样是坏的，只是不会报错。
      final second = container.read(probe.provider);
      expect(second, isNot(first), reason: '恢复后必须拿到新值');
      expect(find.text('$second'), findsOneWidget, reason: '界面要显示新值，不是旧值');

      // 恢复之后订阅要继续活着（暂停/恢复不能把订阅弄丢）。
      container.read(seed.notifier).bump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final third = container.read(probe.provider);
      expect(third, isNot(second));
      expect(find.text('$third'), findsOneWidget);
    });
  }

  testWidgets('来回切分支（IndexedStack + TickerMode）值不丢', (tester) async {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    var index = 0;

    // 复现 `StatefulShellRoute.indexedStack` 的形状：两个分支，非当前分支
    // 被 `TickerMode(enabled: false)` 罩着。
    //
    // 这条**不是**上面那个崩溃的复现（未打补丁的 3.4.3 也过）—— 它钉的是
    // 另一半：暂停/恢复来回切之后订阅还活着、两个分支都显示当前值。
    // 容易坏的形态是「恢复时把值悄悄停在暂停那一刻」，那种错不报异常。
    Widget app() => UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: StatefulBuilder(
              builder: (context, setState) => IndexedStack(
                index: index,
                children: [
                  TickerMode(
                    enabled: index == 0,
                    child: Consumer(
                      builder: (c, ref, _) =>
                          Text('A${ref.watch(topDeep)}', textDirection: TextDirection.ltr),
                    ),
                  ),
                  TickerMode(
                    enabled: index == 1,
                    child: Consumer(
                      builder: (c, ref, _) =>
                          Text('B${ref.watch(top)}', textDirection: TextDirection.ltr),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    await tester.pumpWidget(app());
    for (var i = 0; i < 5; i++) {
      // 切到另一支；切完 index 就是「现在是哪一支可见」。
      index = i.isEven ? 1 : 0;
      await tester.pumpWidget(app());
      container.read(seed.notifier).bump();
      await tester.pump();
      await tester.pumpWidget(app());
      expect(tester.takeException(), isNull, reason: '第 $i 轮切分支');

      // 只断言**当前可见**的那一支：不可见的那一支被 TickerMode 暂停着，
      // 它本该停在旧值、等重新可见时再补上（上面那四条测的就是那个补的过程）。
      final visible = index == 0
          ? 'A${container.read(topDeep)}'
          : 'B${container.read(top)}';
      expect(find.text(visible), findsOneWidget,
          reason: '第 $i 轮：可见的那一支没跟上新值');
    }
  });
}
