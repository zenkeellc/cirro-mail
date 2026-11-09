import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_ref.dart';
import 'suggest_input.dart';
import 'suggestion.dart';

/// 停靠面板上一次分析出来的**成品**（结果 + 抬头要用的那份输入）。
///
/// 只带「画出来要的东西」，不带会话（`AiRun`、流、补正文的 future）——
/// 那些跟着面板那个 widget 一起活、一起死（见 `SuggestView`）。
@immutable
class SuggestSnapshot {
  const SuggestSnapshot({required this.parsed, required this.input});

  final SuggestionParseResult parsed;
  final SuggestInput input;
}

/// 「AI 建议停靠面板此刻开着哪一封」以及它上一次的结果。
///
/// ## 为什么这份状态不能留在 `MailDetailScreen` 的 `State` 里
///
/// 面板是正文下方**停靠**的一块，而「正文」这个宿主在两种布局里是**两棵不同
/// 的 widget 树**：
///
/// - 分栏（>= 1024）：右栏里的内嵌 `MailDetailScreen`（`embedded: true`）；
/// - 单栏（< 1024）：整页的 `MailDetailScreen`。
///
/// 用户拖窗口跨过那条线时（见 `router.dart` 的 `foldSelectionAcrossBreakpoints`
/// 与 `app_shell.dart` 的 `_BreakpointRouteSync`），地址在 `?sel=` 与详情路径
/// 之间折一次，宿主 widget 整棵被拆掉重建 —— 面板的开关如果还是 `State` 里的
/// 一个 bool，就会**随着旧 widget 一起消失**（用户的原话：「邮件 AI 提示框出现
/// 之后，如果我此时修改了窗口的大小……这个面板就会消失」）。
///
/// 所以开关与结果放到这里：
///
/// - [openFor] 记着「哪一封的面板是开着的」—— 换了宿主还在，只要还是同一封；
/// - [snapshot] 记着上一次的成品 —— 新宿主挂载时直接画结果，**不再发一次
///   请求**（否则用户看到的是「结果明明出来了又转圈」，还白烧一次 token）。
///
/// 生命周期跟着「面板」而不是「页面」：收起（× / 选了一项 / 换了一封）就整个
/// 清掉，不落盘、不跨会话。同号邮件在别处被重开时不会突然冒出一个旧面板 ——
/// `MailDetailScreen` 在**换了一封**时会把不是自己这一封的开关收掉。
@immutable
class SuggestDockState {
  const SuggestDockState({this.openFor, this.snapshot});

  /// 什么都没开。
  static const SuggestDockState closed = SuggestDockState();

  /// 面板开着的那封；null = 关着。
  final MailRef? openFor;

  /// 那一次分析出来的成品（还在分析时为 null）。
  final SuggestSnapshot? snapshot;

  /// 这一封的面板是不是开着。
  bool isOpenFor(MailRef mail) => openFor == mail;

  @override
  bool operator ==(Object other) =>
      other is SuggestDockState &&
      other.openFor == openFor &&
      identical(other.snapshot, snapshot);

  @override
  int get hashCode => Object.hash(openFor, identityHashCode(snapshot));

  @override
  String toString() =>
      'SuggestDockState(openFor: $openFor, snapshot: ${snapshot != null})';
}

/// 停靠面板的开关与结果缓存（见 [SuggestDockState]）。
class SuggestDockController extends Notifier<SuggestDockState> {
  @override
  SuggestDockState build() => SuggestDockState.closed;

  /// 打开这一封的面板。已经开着同一封时是空操作 —— 结果不能被一次「再点一下
  /// 入口」清掉。
  void open(MailRef mail) {
    if (state.openFor == mail) return;
    state = SuggestDockState(openFor: mail);
  }

  /// 收起面板（× / 用户选了一项 / 换了一封）。
  void close() {
    if (state.openFor == null && state.snapshot == null) return;
    state = SuggestDockState.closed;
  }

  /// 记下这一次的成品。只认**当前开着的那一封**：面板已经收起、或者已经换到
  /// 另一封时，一个晚到的结果不许把面板重新弹出来。
  void publish(MailRef mail, SuggestSnapshot snapshot) {
    if (state.openFor != mail) return;
    state = SuggestDockState(openFor: mail, snapshot: snapshot);
  }
}

final NotifierProvider<SuggestDockController, SuggestDockState>
    suggestDockStateProvider =
    NotifierProvider<SuggestDockController, SuggestDockState>(
  SuggestDockController.new,
);
