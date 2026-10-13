// 文档注释里那句 `A ValueNotifier<bool> was used after being disposed` 是
// Flutter 报错的**原文**，必须带尖括号照抄；这条 lint 因此是误报，文件级关掉。
// ignore_for_file: unintended_html_in_doc_comment

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_client.dart';
import 'ai_service.dart';

/// 一次生成在界面上的样子：**增量文本 + 运行中 + 出错/没开始**。
///
/// 为什么单独一个类：四个面板（改写 / 起草 / 续写 / 检查）都要做同样的四件事
/// —— 把增量追加到一段文字上、显示一个转圈、给一个停止按钮、把失败变成一句
/// 话。各写一份必然出现「有一个面板忘了在失败时把转圈关掉」这种 bug（用户看到
/// 永远转圈）。这里做一次，四个面板共用，规则也能单测。
///
/// **不用 `ChangeNotifier`**：这个对象的生命周期与「一次生成」绑定，会随每次
/// 重新生成换掉。`ChangeNotifier` 要显式 `dispose`，而重新生成时上一个对象的
/// 监听者还挂在旧的上面 —— 那是典型的「内存没漏但状态串了」。用两个
/// [ValueNotifier] 更笨，但每次重新生成时整个换掉，不会有残留。
class AiRun {
  AiRun(AiStart start) {
    _adopt(start);
  }

  /// 先开一个「正在准备」的 run，随后 [adopt] 一个真正开始的生成。
  ///
  /// 存在的理由：读设置与读 Key 都要走平台通道（钥匙串），是**异步**的 ——
  /// 用户点「改写」之后要有几十毫秒什么都还没发生。直接 `AiRun(await ...)`
  /// 会让面板在这段时间里不知道该画什么（转圈还是不转）。先开一个 pending，
  /// 拿到之后 adopt，转圈就从点下去那一刻开始。
  AiRun.pending();

  /// 已经接管过一次生成（见 [adopt]）。
  var _adopted = false;

  /// 用户主动停了。停不算「没拿到内容」—— 见 [_finish]。
  var _stopped = false;

  /// 已经 dispose。**之后一律不再写三个 notifier** —— 见 [dispose]。
  var _disposed = false;

  /// 接管一个已经开始的生成（或一条「没开始」的说明）。
  ///
  /// **只生效一次**：同一次生成被 adopt 两遍是调用方写错了（比如
  /// `FutureBuilder` 重建时又调了一遍），那时第二遍会把第一遍的增量丢掉。
  void adopt(AiStart start) {
    if (_adopted) return;
    _adopted = true;
    _adopt(start);
  }

  void _adopt(AiStart start) {
    switch (start) {
      case AiNotStarted(:final reason):
        // 「没配 Key」不是错误，是一句要去设置页的提示 —— 但对这一层面言
        // 表现一样：不跑、给一句话。界面据此显示提示条而不是转圈。
        _set(message, reason);
        _set(running, false);
      case AiStarted(:final stream):
        // 用户在 pending 阶段就点了停止：那时 `_stream` 还是 null，`stop()` 只能
        // 立一下 `_stopped` 旗子，没有任何东西可取消。这条流是**已经放弃的那次
        // 生成**，姗姗来迟 —— 挂上监听的话，界面上刚停下的圈会自己又转起来、
        // 增量也照样写进去。这里当场取消，连监听都不挂（`done` 里的失败仍由
        // `AiClient` 内部的 catchError 兜着，不会冒成未处理异常）。
        if (_stopped) {
          stream.cancel();
          return;
        }
        _stream = stream;
        stream.text.listen(
          (part) => _set(text, text.value + part),
          onError: (Object e) => _set(message, describeError(e)),
          onDone: _finish,
        );
        // 截断结论（见 [AiStream.truncated]）。放 here 而不是 `done` 的 then 里：
        // 它比 `done` 早定下来，而 `_finish` 正是那之后跑的 —— 于是
        // 「半截 + 被截断」这一句能赶在界面把这次生成判成「成功」之前写上。
        unawaited(stream.truncated?.then(_applyTruncated));
        // 在响应式代码里用 `unawaited` 忽略这个 future（它只用来把失败
        // 从 zone 里摘掉）—— `done` 的错误已经由上面 text 的 onError 报了。
        unawaited(stream.done.then<void>(
          (_) => _finish(),
          onError: (Object e) {
            _set(message, describeError(e));
            _set(running, false);
          },
        ));
    }
  }

  AiStream? _stream;

  /// 已经生成出来的文本。**只增不改** —— 界面用它在末尾追加，不用整段重绘。
  final ValueNotifier<String> text = ValueNotifier<String>('');

  /// 还在生成中。停止按钮与转圈的可见性都看它。
  final ValueNotifier<bool> running = ValueNotifier<bool>(true);

  /// 出错或者「没开始」的那一句话。空串表示一切正常。
  final ValueNotifier<String> message = ValueNotifier<String>('');

  bool get started => _stream != null;

  /// 生成走到头了（正常结束、被取消、或出错之后关闭流）。
  ///
  /// 这里补的是**「一个字都没拿到」这种失败**：流安静地关掉，界面上就只剩一个
  /// 永远转不完的圈 —— 用户完全不知道发生了什么。厂商侧真的返回空内容是可能的
  /// （触发了内容过滤、或 max_tokens 太小）。主动停止（[stop]）不算。
  ///
  /// 「预算被吃光」那一支已经由 `AiClient` 抛成 [AiTruncatedException]，走的是
  /// `onError`（那里的话术更具体），所以不会落到这里这句笼统的提示上。
  void _finish() {
    _set(running, false);
    if (_stopped) return;
    if (message.value.isEmpty && text.value.trim().isEmpty) {
      _set(message, 'AI 没有返回内容，请重试');
    }
  }

  /// 「这次撞上了长度上限」。见 [AiStream.truncated]。
  ///
  /// 空内容那一支根本走不到这里（`AiClient` 已经把它抛成
  /// [AiTruncatedException]、由 `onError` 报掉），所以这里要管的是**半截内容**
  /// —— 界面上有一句没写完的话，却什么都不说。**只加一句提示、不动 `text`**：
  /// 半截结果留着，用户想用还是能用。
  ///
  /// 文案**不指路去设置页**：输出上限是代码里定死的（`AiService._maxOutputTokens`），
  /// 设置里没有这一项 —— 让用户去找一个不存在的东西，比不给建议更糟。
  void _applyTruncated(bool truncated) {
    if (!truncated || _stopped) return;
    if (text.value.trim().isEmpty) return;
    if (message.value.isNotEmpty) return;
    _set(message, '回答被长度限制截断了，可能没写完');
  }

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (_disposed) return;
    notifier.value = value;
  }

  /// 停止。用户在生成到一半时点了停止 —— **不算错误**，已经拿到的半截留在
  /// `text` 里（「拿到什么算什么」）。
  ///
  /// **pending 阶段也点得动**：那时还没有流可取消，这里只是立下 `_stopped`；
  /// 迟到的 [adopt] 会据此把那条流当场取消掉（见 [_adopt]）。
  void stop() {
    _stopped = true;
    _stream?.cancel();
    _set(running, false);
  }

  /// 收摊。**先立 `_disposed` 再 dispose 三个 notifier**：`cancel()` 只是发出
  /// 取消信号，流上的监听者还会各自回调一次（`onDone` 至少要来一次），而那时候
  /// notifier 已经被回收 —— 表现是
  /// `A ValueNotifier<bool> was used after being
  /// disposed`，在真实的重新生成/关面板路径上每次都能复现。
  void dispose() {
    _disposed = true;
    _stream?.cancel();
    text.dispose();
    running.dispose();
    message.dispose();
  }

  /// 把异常变成一句给人看的话。
  ///
  /// **绝不把异常 toString 直接倒出来**：`DioException` 的 `toString` 里可能
  /// 带着请求 URL 与响应体，而 `AiTransportException` 的 message 是厂商写的
  /// 原因（例如「invalid api key」）。两样都保留一层，但都不含 Key 本身。
  static String describeError(Object error) {
    if (error is AiTransportException) {
      final status = error.statusCode;
      return status == null ? error.message : 'AI 返回 $status：${error.message}';
    }
    // **撞上长度上限**与「厂商什么都没回」是两件事：前者是「这次预算不够」，
    // 说得出原因；后者用户只能反复重试。分开报是这一层存在的意义之一
    // （见 [AiTruncatedException]）。文案不提「设置里调大」——上限是代码里
    // 定死的，设置页没有这一项，指路指向一个不存在的地方更糟。
    if (error is AiTruncatedException) {
      return 'AI 这次没答完（输出被长度限制截断），请重试或把正文分短一些';
    }
    if (error is TimeoutException) return 'AI 响应超时，请稍后再试';
    return 'AI 调用失败，请稍后再试';
  }
}
