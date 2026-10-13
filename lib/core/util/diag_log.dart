import 'package:flutter/foundation.dart';

/// 排查用的**带时间戳**日志。
///
/// 跟直接 `debugPrint` 的区别只有一点，但就是关键的那一点：每条前面带上
/// 「距进程启动多少毫秒」。排查「转圈转不完」这类问题时，唯一重要的事实是
/// **哪一步之后就没有下文了** —— 而裸的 `debugPrint` 没有时间，几十行日志
/// 里根本看不出停在哪一行、停了多久。
///
/// release 构建里 [enabled] 为 false，所有方法直接短路：不留开销，调用方
/// 也不需要到处写 `if (kDebugMode)`。想临时关掉的话配一个
/// `--dart-define=DIAG_LOG_OFF=true` 即可。
class DiagLog {
  const DiagLog._();

  static const bool enabled = kDebugMode && !bool.fromEnvironment('DIAG_LOG_OFF');

  static final Stopwatch _since = Stopwatch()..start();

  /// 一条带耗时前缀的日志：`[diag +  1234ms] scope: message`
  static void log(String scope, String message) {
    if (!enabled) return;
    final ms = _since.elapsedMilliseconds.toString().padLeft(7);
    // 刻意用 `debugPrintSynchronously` 而不是 `debugPrint`：后者是**限流版**
    // （按带宽排队、慢速吐），而排查「卡住」时最要紧的那几行恰恰会排在队里
    // 出不来 —— 那就等于没打。同步版没有队列，写一行是一行。
    debugPrintSynchronously('[diag +${ms}ms] $scope: $message');
  }

  /// 包住一段异步操作，自动打出「开始 / 结束(耗时) / 抛了什么」。
  ///
  /// **只打出 `→` 而没有对应的 `✓`/`✗`，就是卡在这一步** —— 这正是这类
  /// 问题里最想要的信号，所以进入时先打，而不是等结束再打。
  static Future<T> trace<T>(
    String scope,
    String what,
    Future<T> Function() body,
  ) async {
    if (!enabled) return body();
    final sw = Stopwatch()..start();
    log(scope, '→ $what');
    try {
      final result = await body();
      log(scope, '✓ $what  (${sw.elapsedMilliseconds}ms)');
      return result;
    } catch (error) {
      // 连异常类型一起记：`TimeoutException` 与 `DioException` 要分开看。
      log(scope, '✗ $what  (${sw.elapsedMilliseconds}ms)  '
          '${error.runtimeType}: $error');
      rethrow;
    }
  }

  /// [trace] 的同步版。
  static T traceSync<T>(String scope, String what, T Function() body) {
    if (!enabled) return body();
    final sw = Stopwatch()..start();
    log(scope, '→ $what');
    try {
      final result = body();
      log(scope, '✓ $what  (${sw.elapsedMilliseconds}ms)');
      return result;
    } catch (error) {
      log(scope, '✗ $what  (${sw.elapsedMilliseconds}ms)  '
          '${error.runtimeType}: $error');
      rethrow;
    }
  }

  /// 给对象一个稳定的短标识，日志里用来区分「是不是同一个实例」。
  ///
  /// 用 `identityHashCode` 而不是 `hashCode`：后者可以被覆写（`Dio` 之类
  /// 就不保证稳定），而排查时「两次打印的是不是同一个对象」是刚需。
  static String tag(Object? object) {
    if (object == null) return 'null';
    final hex = identityHashCode(object).toRadixString(16).padLeft(6, '0');
    return '${object.runtimeType}#$hex';
  }
}
