import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/mail_row.dart';
import '../ai/ai_run.dart';
import '../ai/ai_service.dart';
import 'mail_action.dart';
import 'suggest_input.dart';
import 'suggestion.dart';

/// 面板的状态（spec §4.1 的三态 + §8.4 第 1 步那个前置态）。
///
/// [fetching] 与 [analyzing] 在界面上**长得几乎一样**（都是转圈），分开是为了
/// 文案：补正文那一段是 `aiSuggestFetchingBody`（「正在补全正文…」），
/// 分析那一段是 `aiSuggestAnalyzing`。合成一个态的话，补正文那几秒里面板会
/// 说「正在分析…」—— 而那时候请求还没发出去。
enum SuggestStage {
  /// 正在补全正文（`ensureFull`）。
  fetching,

  /// 请求已发出，`AiRun` 在跑。
  analyzing,

  /// 解析出了东西，面板画动作列表。
  done,

  /// 请求失败、被停止、或解析不出任何东西。面板**不画任何可点动作**。
  failed,
}

/// 一次建议的会话：**持有 `AiRun` + 走一遍「补正文 → 分析 → 解析」**。
///
/// 为什么单独一个类（而不是让面板自己干）：面板是 widget，状态机不该活在
/// widget 的 `setState` 里 —— 那样这一整条链（补正文失败不阻断、停止落到失败
/// 态、重新分析要换掉整个 `AiRun`）全都只能用 widget 用例去测。抽出来之后
/// `test/suggest_session_test.dart` 一行 widget 都不用起。
///
/// ## 两条来自 `AiRun` 的硬约束
///
/// 1. **重新分析要换掉整个 `AiRun` 实例**（§0.2 第 21 条）：`AiRun.adopt` 只
///    生效一次，同一个实例上再 adopt 一个新的生成是不生效的（第二次会被
///    `_adopted` 挡下来），表现是「点了重新分析，界面一动不动」。
/// 2. **`dispose()` 之后再来的流回调不许再写 notifier** —— `AiRun` 自己立了
///    `_disposed` 守着，这里额外守一层是因为本类还持有 `stage`。
class SuggestSession {
  // 计划原文的字段名是私有的 `_starEnabled` / `_refresh` / `_launch` /
  // `_maxChars`，而构造参数名必须是公开的（测试与面板按名字传参）—— 两者不能
  // 合并成 `this._starEnabled` 这个 initializing formal，所以四处都要逐处
  // 关掉这条 lint（与 `AiService` / `AiSettingsStore` 同）。
  SuggestSession({
    required MailRow row,
    required bool starEnabled,
    required Future<MailRow?> Function() refresh,
    required Future<AiStart> Function(String input, List<String> actionIds) launch,
    int maxChars = 8000,
  })  : _row = row,
        // ignore: prefer_initializing_formals
        _starEnabled = starEnabled,
        // ignore: prefer_initializing_formals
        _refresh = refresh,
        // ignore: prefer_initializing_formals
        _launch = launch,
        // ignore: prefer_initializing_formals
        _maxChars = maxChars,
        // 正文本来就齐的（详情页那条路几乎总是）时不要先闪一下
        // 「正在补全正文…」——那一帧里我们根本没打算去补。
        stage = ValueNotifier<SuggestStage>(
          row.hasFullBody ? SuggestStage.analyzing : SuggestStage.fetching,
        );

  final bool _starEnabled;
  final Future<MailRow?> Function() _refresh;
  final Future<AiStart> Function(String input, List<String> actionIds) _launch;
  final int _maxChars;

  /// 面板据此决定画哪一块。**面板唯一的监听点。**
  final ValueNotifier<SuggestStage> stage;

  MailRow _row;
  SuggestInput? _input;
  List<MailAction> _pool = const <MailAction>[];
  AiRun? _run;
  SuggestionParseResult? _parsed;
  bool _disposed = false;

  /// 补正文之后**重新读过的那一行**。
  ///
  /// 执行器（`MailActionRunner`）必须拿这一份：`reply` / `forward` 要拼引用块，
  /// 而拼的是 `row.content` —— 拿手里那个摘要行去拼，引用块里只有 300 字。
  MailRow get row => _row;

  /// 喂给模型的那一段（抬头那几行要它）。
  ///
  /// **`start()` 走到组装那一步之后才非空。** 补正文那一态里它还是 null
  /// （`await _refresh()` 那一帧），所以面板**不能**直接读它 —— 见
  /// [inputOrNull]。
  SuggestInput get input => _input!;

  /// 同上，但**组装完成之前是 null**。
  ///
  /// 面板的抬头在「补正文」那一态就要画（spec §4.2 说抬头常驻），而那时
  /// `_input` 还没算出来 —— 读 `input` 会是一个
  /// `Null check operator used on a null value`，且在 `hasFullBody: false`
  /// 的那条用例**第一帧**就炸。
  SuggestInput? get inputOrNull => _input;

  /// 这一次的池子（按当前状态过滤过的那一份）。解析失败时也有值。
  List<MailAction> get pool => _pool;

  /// 当前那一个 `AiRun`。[restart] 会把它整个换掉。
  AiRun get run => _run!;

  /// 解析结果。**`done` 之后必然非 null**；`failed` 时可能是
  /// [SuggestionUnreadable]（解析不出）也可能是 null（请求就失败了）。
  SuggestionParseResult? get parsed => _parsed;

  /// 走一遍（spec §8.4 第 2–4 步）。面板 `initState` 里调一次。
  Future<void> start() async {
    var row = _row;
    if (!row.hasFullBody) {
      stage.value = SuggestStage.fetching;
      final refreshed = await _refresh();
      // **补失败不阻断**：`refreshed` 为 null 就用手里那一条（摘要）继续。
      // 抬头会如实写「正文 N 字」—— 拿不到就明说，比什么都不弹好。
      if (refreshed != null) row = refreshed;
      if (_disposed) return;
    }
    _row = row;
    _input = SuggestInput.build(row, maxChars: _maxChars);
    // 池子只算一次，**prompt 与解析器用同一份**：分两次算的话，
    // 「prompt 里说了、解析器不认」的漂移迟早出现。
    _pool = suggestActionPool(
      isUnread: row.isUnread,
      isStarred: row.isStarred,
      starEnabled: _starEnabled,
      hasBody: _input!.hasBody,
    );
    _parsed = null;
    _launchRun();
  }

  /// 丢掉当前这一次，从头再来（spec §4.5）。
  ///
  /// **整个换掉 `AiRun`**（见类注释第 1 条）。`start()` 会重新判
  /// `hasFullBody` —— 上一轮补正文失败时这一轮会再补一次，正是 spec §4.5
  /// 要的「包括 ensureFull」。
  Future<void> restart() => start();

  void _launchRun() {
    _detach();
    final run = AiRun.pending();
    _run = run;
    stage.value = SuggestStage.analyzing;
    // `running` 从 true 翻到 false 就是「这一次结束了」——正常结束、被停止、
    // 流安静地关掉、报错，四种情况都盖得住（见类注释）。
    run.running.addListener(_onRunningChanged);
    unawaited(
      _launch(_input!.text, _pool.map((a) => a.id).toList(growable: false))
          .then(run.adopt, onError: (Object e) {
        // `AiService` 自己抛的（pref 读崩了之类）也得有个去处 ——
        // 不然就是一个永远不动的转圈（与 `ComposeAi._adopt` 同一句注释）。
        run.adopt(AiNotStarted(AiRun.describeError(e)));
      }),
    );
  }

  void _onRunningChanged() {
    if (_disposed) return;
    final run = _run;
    if (run == null || run.running.value) return;
    run.running.removeListener(_onRunningChanged);
    // 出错时 `AiRun` 会把那一句话写在 `message` 上（`AiStreamView` 负责画）。
    // 这里**不抢着解析** —— 半截内容配上一次失败，解析出来的东西没有意义。
    if (run.message.value.isNotEmpty) {
      stage.value = SuggestStage.failed;
      return;
    }
    _parsed = SuggestionParser.parse(raw: run.text.value, pool: _pool);
    stage.value =
        _parsed is SuggestionParsed ? SuggestStage.done : SuggestStage.failed;
  }

  void _detach() {
    _run?.running.removeListener(_onRunningChanged);
    _run?.dispose();
    _run = null;
  }

  /// 收摊。**先立 `_disposed`**：`stage.dispose()` 之后流上的回调还会来一次
  /// （`AiRun` 的 `cancel()` 只是发信号），那时候写 `stage` 就是
  /// 「used after being disposed」。
  void dispose() {
    _disposed = true;
    _detach();
    stage.dispose();
  }
}
