import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 未捕获异常的**落盘日志**，以及「这块界面没画出来」时的可读替代品。
///
/// ## 为什么需要它
///
/// release 构建里，某个 widget 在 `build()` 里抛异常时，Flutter 会把那一块
/// 换成默认的 [ErrorWidget] —— 在 release 下**就是一块灰白**，没有任何文字。
/// 用户的观感是「这一页打不开 / 空白」，开发者也拿不到任何线索：控制台的栈
/// 在 release 里没人看得到，App 也没有留痕。
///
/// 这条链路已经真的咬过一次人（「设置 → 实例 点不开/右栏空白」，偶发，
/// 复现不了）。所以做两件事：
///
/// 1. **留痕**：`FlutterError.onError` 与 `PlatformDispatcher.onError` 收到的
///    异常都写进 `<应用支持目录>/crash.log`（环形，封顶 [maxBytes]），进程退出
///    之后还在 —— 下一次偶发之后可以直接把它捞出来看栈；
/// 2. **可读**：release / profile 下把 [ErrorWidget.builder] 换成
///    [buildCard]，那块灰白变成「这一块没加载出来 + 异常摘要」。
///
/// debug 下**不动** [ErrorWidget.builder]：那片红底错误屏信息最全（含栈、
/// 布局溢出、provider 名），盖掉它只会让人更难查。留痕那一路在 debug 里照样
/// 生效。
///
/// ## 边界
///
/// 这里的所有动作都是 **best-effort、绝不抛**：异常兜底本身再炸一次，会变成
/// 「错误处理里的错误」，比原来的错误难查一个数量级。目录拿不到（`path_provider`
/// 在某些 Linux 环境会抛）就只留在内存里，App 照常跑。
class CrashLog {
  CrashLog._();

  /// 内存里保留的最近条数（给测试与将来的「诊断」页用）。
  static const int maxEntries = 50;

  /// 日志文件封顶大小；超过就清空重来（不做复杂轮转 —— 这是排障用的一次性
  /// 流水，不是审计日志）。
  static const int maxBytes = 64 * 1024;

  /// 每条栈最多写这么多行：release 的栈动辄上百帧，全写会把文件瞬间灌满。
  static const int maxStackLines = 20;

  static const String fileName = 'crash.log';

  static final List<String> _recent = <String>[];
  static final List<String> _pending = <String>[];
  static File? _file;
  static int _bytes = 0;
  static bool _installed = false;
  static FlutterExceptionHandler? _previousOnError;
  static ErrorWidgetBuilder? _previousErrorBuilder;

  /// 内存里的最近若干条（时间倒序不需要；按发生顺序）。
  @visibleForTesting
  static List<String> get recent => List<String>.unmodifiable(_recent);

  /// 装好全局异常钩子。**尽早调用**（`main()` 的第一句），越早越不漏。
  ///
  /// 幂等：重复调用不会把自己套娃。
  static void install() {
    if (_installed) return;
    _installed = true;

    _previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      record(
        'FlutterError',
        details.exception,
        details.stack,
        where: details.context?.toDescription() ?? details.library,
      );
      // 控制台照旧：debug 下那串栈是排障主力，不能被我们吞掉。
      final previous = _previousOnError;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record('uncaught', error, stack);
      // false = 交回默认处理（debug 下会打到控制台）。我们不静默吃掉。
      return false;
    };

    if (!kDebugMode) {
      _previousErrorBuilder = ErrorWidget.builder;
      ErrorWidget.builder = buildCard;
    }
  }

  /// 把日志接到应用支持目录（`main()` 里 `ensureInitialized()` 之后调）。
  ///
  /// 拿到目录之前发生的异常不会丢：先攒在内存里，接上之后补写。
  static void attachStorage() {
    unawaited(_resolveFile());
  }

  static Future<void> _resolveFile() async {
    try {
      final base = await getApplicationSupportDirectory();
      final file = File(
        '${base.path}${Platform.pathSeparator}$fileName',
      );
      await base.create(recursive: true);
      _file = file;
      _bytes = await file.exists() ? await file.length() : 0;
      if (_pending.isNotEmpty) {
        final buffered = List<String>.of(_pending);
        _pending.clear();
        for (final line in buffered) {
          _append(line);
        }
      }
    } catch (_) {
      // 落不了盘就算了：App 照常跑，内存里那份还在。
    }
  }

  /// 记一条。同一时刻可能被任意 isolate/回调调进来，所以只做同步、纯追加。
  static void record(
    String kind,
    Object error,
    StackTrace? stack, {
    String? where,
  }) {
    final line = _format(kind, error, stack, where);
    _recent.add(line);
    if (_recent.length > maxEntries) {
      _recent.removeRange(0, _recent.length - maxEntries);
    }
    if (_file == null) {
      _pending.add(line);
      if (_pending.length > maxEntries) {
        _pending.removeRange(0, _pending.length - maxEntries);
      }
      return;
    }
    _append(line);
  }

  static String _format(
    String kind,
    Object error,
    StackTrace? stack,
    String? where,
  ) {
    final now = DateTime.now();
    final stamp = now.toIso8601String();
    final head = StringBuffer('[$stamp] $kind');
    if (where != null && where.isNotEmpty) head.write(' @ $where');
    head.write(': $error');
    final buffer = StringBuffer(head.toString());
    if (stack != null) {
      final lines = stack
          .toString()
          .trimRight()
          .split('\n')
          .take(maxStackLines)
          .toList(growable: false);
      for (final line in lines) {
        buffer.write('\n    $line');
      }
    }
    return buffer.toString();
  }

  static void _append(String line) {
    final file = _file;
    if (file == null) return;
    try {
      final payload = '$line\n';
      if (_bytes + payload.length > maxBytes) {
        // 封顶：重开一份。会丢掉历史，但这本来就是「最近一次怎么回事」的流水。
        file.writeAsStringSync(payload, flush: false);
        _bytes = payload.length;
        return;
      }
      file.writeAsStringSync(payload, mode: FileMode.append, flush: false);
      _bytes += payload.length;
    } catch (_) {
      // 磁盘满 / 没权限 / 沙盒 → 静默，下一行还会再试一次。
    }
  }

  /// release / profile 下替代那块灰白的卡片。
  ///
  /// 约束比普通 widget 多得多：它可能出现在**任何**位置（包括还没有
  /// `MaterialApp` / `Localizations` / `MediaQuery` 的树里 —— 启动阶段的根
  /// widget 抛异常就是那种情形）。所以这里刻意只依赖 `Directionality` 与
  /// 一个写死的 `TextStyle`，不用 Theme、不用图标、不用 Column/Expanded
  /// 这类需要布局约束友好的东西：一个 `Container` + 一段可换行的文字，
  /// 在紧约束、松约束、无界高度下都不会再抛。
  static Widget buildCard(FlutterErrorDetails details) {
    final summary = _summary(details.exception);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        width: double.infinity,
        color: const Color(0x1AFF3B30),
        padding: const EdgeInsets.all(12),
        child: Text(
          '⚠ 这一块界面没加载出来 / This section failed to render\n$summary',
          softWrap: true,
          style: const TextStyle(
            fontSize: 12,
            height: 1.5,
            color: Color(0xFF8A1F1A),
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  static String _summary(Object error) {
    final text = error.toString();
    // 一行摘要就够指路了；完整栈在 crash.log 里。
    final firstLine = text.split('\n').first.trim();
    return firstLine.length <= 400
        ? firstLine
        : '${firstLine.substring(0, 400)}…';
  }

  /// 仅测试用：清空状态、把全局钩子还原（避免污染同一进程里的其它用例）。
  @visibleForTesting
  static Future<void> resetForTest() async {
    _recent.clear();
    _pending.clear();
    _bytes = 0;
    _file = null;
    if (_installed) {
      if (_previousOnError != null) {
        FlutterError.onError = _previousOnError;
      }
      if (_previousErrorBuilder != null) {
        ErrorWidget.builder = _previousErrorBuilder!;
      }
    }
    _installed = false;
    _previousOnError = null;
    _previousErrorBuilder = null;
  }

  /// 仅测试用：把写入目标换成给定目录（跳过 `path_provider`）。
  @visibleForTesting
  static Future<void> attachDirectoryForTest(Directory dir) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    _file = file;
    _bytes = await file.exists() ? await file.length() : 0;
    final buffered = List<String>.of(_pending);
    _pending.clear();
    for (final line in buffered) {
      _append(line);
    }
  }
}
