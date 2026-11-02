/// 两个入口脚本的参数解析。**纯函数**：脚本本身只做 IO，规则集中在这里，
/// `test/version_tool_test.dart` 才能不跑脚本就把它们钉住。
library;

/// `tool/version.dart` 的命令行。
class VersionCli {
  const VersionCli({
    this.format = 'summary',
    this.channel,
    this.repo,
    this.help = false,
  });

  /// 见 [supportedFormats]。
  final String format;

  /// 覆盖渠道；空表示按 `APP_UPDATE_CHANNEL` / 默认值走。
  final String? channel;

  /// 从哪个检出算版本（默认是本文件所在的检出）。
  final String? repo;

  final bool help;
}

/// 支持的输出格式。拼错直接报错，而不是静默按 summary 输出 ——
/// 「以为拿到 JSON、实际拿到摘要」在 CI 里很难看出来。
const Set<String> supportedFormats = <String>{
  'summary',
  'shell',
  'json',
  'build-args',
};

const String versionUsage = '''
构建期版本（build 号 = `git rev-list --count HEAD`）

用法：dart tool/version.dart [选项]

  --format=<summary|shell|json|build-args>
      输出格式，默认 summary。
        summary     给人看的摘要
        shell       `eval "\$(dart tool/version.dart --format=shell)"` 可取的变量
        json        给脚本解析的 JSON
        build-args  一行 flutter build 参数串
  --build-args        等价于 --format=build-args
  --channel=<名字>    更新渠道，默认 public（商业版传 pro）
  --repo=<目录>       从哪个检出算版本（默认是本文件所在的检出）。商业检出
                      还没合入本工具时可以指过去借用，版本按那个仓库算。
  -h, --help          显示这段说明

git 缺失 / 没有 tag / 浅克隆时都有确定的回退，回退会往 stderr 打警告，
不影响退出码 —— 构建不该因为「这个检出没有 tag」就断。''';

/// 解析 `tool/version.dart` 的参数。格式错抛 [FormatException]。
VersionCli parseVersionCli(List<String> args) {
  final options = <String, String>{};
  var help = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-h' || arg == '--help') {
      help = true;
      continue;
    }
    if (arg == '--build-args') {
      options['format'] = 'build-args';
      continue;
    }
    if (!arg.startsWith('--')) {
      throw FormatException('不认识的参数：$arg');
    }
    final equals = arg.indexOf('=');
    if (equals >= 0) {
      options[arg.substring(2, equals)] = arg.substring(equals + 1);
      continue;
    }
    final name = arg.substring(2);
    if (i + 1 >= args.length) {
      throw FormatException('--$name 需要一个值');
    }
    options[name] = args[++i];
  }

  const known = <String>{'format', 'channel', 'repo'};
  for (final name in options.keys) {
    if (!known.contains(name)) {
      throw FormatException('不认识的选项：--$name');
    }
  }

  final format = options['format'] ?? 'summary';
  if (!supportedFormats.contains(format)) {
    throw FormatException('不支持的 --format：$format');
  }
  return VersionCli(
    format: format,
    channel: options['channel'],
    repo: options['repo'],
    help: help,
  );
}

/// `tool/build.dart` 的命令行。
class BuildCli {
  const BuildCli({
    required this.flutterArgs,
    this.dryRun = false,
    this.channel,
    this.repo,
    this.help = false,
  });

  /// 原样交给 `flutter build` 的参数（顺序保持用户给的顺序）。
  final List<String> flutterArgs;

  final bool dryRun;

  /// 覆盖渠道；空表示按 `APP_UPDATE_CHANNEL` / 默认值走。
  final String? channel;

  /// 版本从哪个检出算（flutter build 本身仍在当前工作目录跑）。
  final String? repo;

  final bool help;
}

const String buildUsage = '''
包一层 `flutter build`，自动注入构建期版本（算法见 tool/version.dart）

用法：dart tool/build.dart [选项] <flutter build 参数...>

  --dry-run           只打印最终命令，不执行
  --channel=<名字>     更新渠道，默认 public（商业版传 pro）
  --repo=<目录>        版本从哪个检出算（默认本工具所在的检出）
  -h, --help          显示这段说明

其余参数原样透传给 `flutter build`，顺序不变。用户自己传过的
--build-name / --build-number / --dart-define=APP_* 不会再重复追加
（显式值优先）。''';

/// 解析 `tool/build.dart` 的参数。格式错抛 [FormatException]。
///
/// 只吃掉自己的那几个选项，**其余一律透传**：`flutter build` 的参数会一直
/// 增加，白名单式的写法每升一次 Flutter 就要补一遍。
BuildCli parseBuildCli(List<String> args) {
  var dryRun = false;
  var help = false;
  var passthroughOnly = false;
  String? channel;
  String? repo;
  final flutterArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (passthroughOnly) {
      flutterArgs.add(arg);
      continue;
    }
    if (arg == '--') {
      // `--` 之后就算长得像我们的选项也原样交给 flutter。
      passthroughOnly = true;
      continue;
    }
    if (arg == '--dry-run') {
      dryRun = true;
      continue;
    }
    if (arg == '-h' || arg == '--help') {
      help = true;
      continue;
    }
    if (arg.startsWith('--channel=')) {
      channel = arg.substring('--channel='.length);
      continue;
    }
    if (arg.startsWith('--repo=')) {
      repo = arg.substring('--repo='.length);
      continue;
    }
    if (arg == '--channel' || arg == '--repo') {
      if (i + 1 >= args.length) {
        throw FormatException('$arg 需要一个值');
      }
      final value = args[++i];
      if (arg == '--channel') {
        channel = value;
      } else {
        repo = value;
      }
      continue;
    }
    flutterArgs.add(arg);
  }

  return BuildCli(
    flutterArgs: flutterArgs,
    dryRun: dryRun,
    channel: channel,
    repo: repo,
    help: help,
  );
}
