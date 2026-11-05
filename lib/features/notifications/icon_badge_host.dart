import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notify/icon_badge.dart';
import '../../providers/sync_providers.dart';

/// 把「全部实例的收件未读总数」写进系统图标角标的那一层。
///
/// 它**不画任何东西**，只是挂一个副作用：`totalUnreadProvider` 变了就推一次
/// 给原生侧（[IconBadge]）。与 `WindowTitleHost` 同一路数，放在
/// `MaterialApp.router` 的 `builder` 链里（见 `lib/app.dart`），因为它只要
/// `ref`，既不需要 `BuildContext` 的本地化，也不参与布局。
///
/// ## 三个刻意的取舍
///
/// 1. **首帧之后补推一次**。用户可能原地就看到一个非零角标（比如冷启动时
///    本地库里已经有未读），而 provider 在挂载时不会「变化」一次 —— 只靠
///    `ref.listen` 的话要等到下一封新信才会出现。所以 `initState` 里挂一个
///    post-frame 的初值推送。
/// 2. **相同数字不重复推**。`totalUnreadProvider` 由一条 drift watch 派生，
///    窗口重建、主题切换之类的无关刷新不会改变它，但 `build` 会被调用很多次；
///    去重让原生侧只在「数字真的变了」时重绘图标（Windows/Linux 那两处重绘
///    是要新建 HICON / 重写 PNG 的，不该白做）。
/// 3. **不加「窗口在前台时清空」之类的花活**。用户在设置里选的是「一直显示」：
///    数字只跟未读数走，未读归零就清空。桌面端窗口藏进菜单栏/托盘之后
///    App 还活着，角标仍然有意义，这正是它最有用的场景。
class IconBadgeHost extends ConsumerStatefulWidget {
  const IconBadgeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IconBadgeHost> createState() => _IconBadgeHostState();
}

class _IconBadgeHostState extends ConsumerState<IconBadgeHost> {
  /// 上一次推给原生侧的数字。用 [int] 而不是 `int?` + 另一个 bool：这里
  /// 不需要区分「没推过」和「推过 0」—— 补推走的是同一个入口，重复推一次
  /// 0 也无害（原生侧清角标是幂等的）。
  int? _lastPushed;

  @override
  void initState() {
    super.initState();
    // 首帧之后：原生窗口/托盘都已经建好，通道一定挂上了。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _push(ref.read(totalUnreadProvider));
    });
  }

  void _push(int count) {
    final value = count < 0 ? 0 : count;
    if (value == _lastPushed) return;
    _lastPushed = value;
    unawaited(IconBadge.set(value));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(totalUnreadProvider, (_, next) => _push(next));
    return widget.child;
  }
}
