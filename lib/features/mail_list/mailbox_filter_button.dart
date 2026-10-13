import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'mailbox_filter_panel.dart';

/// 列表头左侧那颗「已选 x 个邮箱」按钮，点开贴着它的一张浮层。
///
/// 取代了原来右上角那颗漏斗：筛成子集才带一个数字角标，而「现在到底在看
/// 哪几个邮箱」只能靠标题下那行小字 —— 入口藏在同步按钮旁边，找不着。
/// 现在入口本身就把结论写在脸上（[l10n.mailboxCountSelected]），标题下那行
/// 小字让位给它。
///
/// ## 为什么是 `OverlayPortal` 而不是 `MenuAnchor`
///
/// `MenuAnchor` 看着正合适，但它把面板包在 `IntrinsicWidth` + 自己的
/// `SingleChildScrollView` + `PrimaryScrollController` 里。面板里再放一个可
/// 滚动的邮箱清单时两个滚动容器会抢 —— 本机实测（`flutter test`）会抛
/// `The PrimaryScrollController is attached to more than one ScrollPosition`。
/// 邮箱可能有几十个，浮层必须能滚。另外它把「关闭」绑在 `MenuItemButton`
/// 上，而我们要的是「勾一下写 prefs **且不关**」。
///
/// `OverlayPortal` 属于 `flutter/widgets`，无新依赖、完全可控：
/// - `CompositedTransformTarget`（按钮）+ `CompositedTransformFollower`（面板）
///   → 贴着按钮（`targetAnchor: bottomLeft` / `followerAnchor: topLeft`，偏移 4）；
/// - `TapRegion(groupId: 同一个 id, onTapOutside: hide)` → 点按钮是切换、
///   点别处是关闭；
/// - `CallbackShortcuts(Esc)` + 面板首帧 `Focus(autofocus: true)` → Esc 关
///   （桌面 + 带键盘的设备；触屏退回点外部）。
///
/// 用默认的 `OverlayChildLocation.nearestOverlay`（**不是** rootOverlay）：
/// 最近的那个 `Overlay` 就是这一支 Navigator 自己的那层，于是**切分支
/// （`IndexedStack` 把这一支 offstage）时面板跟着一起不画**，不必去管
/// `TickerMode`。rootOverlay 会让它飘在另一个分支上面。
class MailboxFilterHeaderButton extends ConsumerStatefulWidget {
  const MailboxFilterHeaderButton({super.key, required this.count});

  /// 按钮上的数字。取的是**这一屏已经收窄过**的邮箱数（`query.mailboxes
  /// .length`），所以标签与列表不可能不一致。
  final int count;

  @override
  ConsumerState<MailboxFilterHeaderButton> createState() =>
      _MailboxFilterHeaderButtonState();
}

class _MailboxFilterHeaderButtonState
    extends ConsumerState<MailboxFilterHeaderButton> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _controller = OverlayPortalController();

  /// 按钮与面板必须同组，否则点面板本身会被当成「点外部」把面板关掉。
  static final Object _groupId = Object();

  // 本版 Flutter 的 `Route` **不是 `Listenable`**（`abstract class Route<T>
  // extends _RoutePlaceholder`，没有 `addListener`），所以「这一页被盖住了」
  // 只能靠 `ModalRoute.of(context)` 建立的依赖拿：它读的是 `_ModalScopeStatus`
  // 这个 InheritedWidget，`isCurrent` 一变依赖者就重建（实测：push 一页详情
  // 之后 list 那一层会带着 `isCurrent=false` 再 build 一次）。见 [build]。

  /// 帧后关闭。
  ///
  /// **不能当帧直接 `hide()`**：`_OverlayPortalState.hide` 有一条
  /// `SchedulerBinding.instance.schedulerPhase != SchedulerPhase
  /// .persistentCallbacks` 的断言，而路由变化引起的重建正好发生在构建期间
  /// （实测会抛出来）。放到帧后就没有这个问题。
  ///
  /// `isShowing` 那道判断不是多余的：widget 已经被摘下来时 controller 是
  /// detached 的，那时 `hide()` 会撞上 `controller._attachTarget` 那条断言。
  void _close() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.isShowing) _controller.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 小窗口里 320 的浮层会溢出，再夹一次。
    final maxWidth = (MediaQuery.sizeOf(context).width - 32).clamp(160.0, 320.0);

    // 上面压了新的一页（窄屏点开一封信就是这条）时把面板收掉。
    //
    // **不收会「复活」**：面板挂在 Navigator 那层 `Overlay` 上，push 之后它
    // 只是被那个不透明的路由**盖住**（offstage），并没有被拆掉；退回来时
    // 它又整整齐齐地出现在屏幕上，看起来像一张忘了关的浮层。实测：
    // `push 之后 PANEL=0`、`pop 回来之后 PANEL=1`。
    //
    // 这一行同时也是那句依赖的**唯一**来路（没有它就收不到信号），所以不能
    // 因为「读了不用」删掉它 —— 副作用才是它的用处。
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) _close();

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          // 按钮还没画过时不画面板（默认会把它摆在原点）。
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 4),
          child: Align(
            alignment: Alignment.topLeft,
            child: TapRegion(
              groupId: _groupId,
              onTapOutside: (_) => _controller.hide(),
              child: Focus(
                autofocus: true,
                child: CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.escape):
                        _controller.hide,
                  },
                  child: _PanelSurface(
                    maxWidth: maxWidth,
                    onClose: _controller.hide,
                  ),
                ),
              ),
            ),
          ),
        ),
        child: TapRegion(
          groupId: _groupId,
          child: _HeaderChip(
            label: l10n.mailboxCountSelected(widget.count),
            tooltip: l10n.filterByMailbox,
            onTap: () => _controller.toggle(),
          ),
        ),
      ),
    );
  }
}

/// 浮层那张纸：材质、圆角、阴影、尺寸上限，以及**能滚**的邮箱清单。
class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.maxWidth, required this.onClose});

  final double maxWidth;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          // 邮箱几十个时不能把面板拉到整屏高 —— 它贴着按钮，下面是列表。
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: MailboxFilterPanel(onClose: onClose),
      ),
    );
  }
}

/// 按钮本体：`清单` 图标 + 「已选 x 个邮箱」+ 一个下拉箭头。
///
/// 高 36 是给宽屏那个钉死 52 的 `PaneHeader` 留的余量；
/// `visualDensity: compact` + `shrinkWrap` 让它在窄屏 `AppBar` 里也放得下
/// （那条路的 `toolbarHeight` 已经相应提到 72）。
class _HeaderChip extends StatelessWidget {
  const _HeaderChip({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.filter_alt_outlined, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
