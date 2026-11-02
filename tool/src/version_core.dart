/// 构建期版本的纯逻辑：值对象、回退规则、各种输出格式、`flutter build`
/// 参数的拼装。**不碰文件、不跑 git** —— 那些在 `git_probe.dart` 与两个入口
/// 脚本里；`test/version_tool_test.dart` 只 import 这个文件，所以用例
/// 不需要一个真 git 仓库。
///
/// 这里与运行期的 `lib/core/version/app_version.dart` 字段是对齐的，但
/// **不 import 它**：那一份依赖 Flutter（`foundation`），而 `tool/` 下的脚本
/// 要能用裸 `dart` 跑。两边的约定只有一个 —— `APP_VERSION_NAME` 那几个
/// `--dart-define` 名字（见 `lib/core/config/app_defaults.dart`）。
library;

import 'dart:convert';

/// 没有显式给渠道时的默认值。与运行期 `AppDefaults.updateChannel` 的默认
/// 一致 —— 两处要一起改。
const String defaultUpdateChannel = 'public';

/// 一个值是从哪来的。摘要与 JSON 里带上它，出问题时不用猜「这个 24 是怎么
/// 数出来的」。
enum VersionSource {
  /// 最近一个 tag（`git describe --tags --abbrev=0`）去掉前缀 `v`。
  tag,

  /// `git rev-list --count HEAD`：每次提交 +1，这就是 build 号的定义。
  gitCount,

  /// `--channel` 之外，`APP_*` 环境变量显式给的（容器里没有 `.git` 时靠它）。
  explicit,

  /// `pubspec.yaml` 的 `version:`。最后一条回退 —— 它不会随提交变化，所以
  /// 只保证「算不出来时也有个值」，不代表真实构建次数。
  pubspec,
}

/// 构建期的版本值。
class BuildVersion {
  const BuildVersion({
    required this.versionName,
    required this.buildNumber,
    required this.commit,
    required this.builtAt,
    required this.channel,
    this.dirty = false,
    this.shallow = false,
    this.versionNameSource = VersionSource.tag,
    this.buildNumberSource = VersionSource.gitCount,
  });

  /// 形如 `0.1.0`，带预发布标识也行（商业版是 `0.1.0-pro.1`）。
  final String versionName;

  /// 构建号。定义为 `git rev-list --count HEAD`，所以每提交一次 +1。
  final int buildNumber;

  /// 7 位短 sha；没有 git 时是空串。
  final String commit;

  /// 构建时间（UTC）。
  final DateTime builtAt;

  final String channel;

  /// 工作区有未提交改动。**不注入**给 App（运行期没有这个字段），只进摘要/
  /// JSON —— 发布包带着它，才知道产物不是某个干净的提交。
  final bool dirty;

  /// 检出是浅克隆。浅克隆下 build 号只能数到深度那么多，需要显式提醒。
  final bool shallow;

  final VersionSource versionNameSource;
  final VersionSource buildNumberSource;

  /// 关于页那一行 `0.1.0+24` 的样子。与运行期 `AppVersion.display` 同形。
  String get display => '$versionName+$buildNumber';

  /// 注入给 Dart 侧的 `--dart-define`，名字与 `app_defaults.dart` 一一对应。
  ///
  /// 顺序是固定的（Map 字面量保序）：同一次构建跑两次输出逐字节相同，
  /// 方便 diff 日志。
  Map<String, String> get dartDefines => <String, String>{
        'APP_VERSION_NAME': versionName,
        'APP_BUILD_NUMBER': '$buildNumber',
        'APP_GIT_SHA': commit,
        'APP_BUILD_TIME': formatBuildTime(builtAt),
        'APP_UPDATE_CHANNEL': channel,
      };

  /// 拼在 `flutter build` 后面的参数：
  /// * `--build-name` / `--build-number` 让平台的 Info.plist / versionCode 跟着走；
  /// * `--dart-define=APP_*` 让 Dart 侧的 `String.fromEnvironment` 读得到。
  ///
  /// 两者都得有：只给前者，关于页还是显示 pubspec 里那个 `0.1.0+1`。
  List<String> get flutterArgs => <String>[
        '--build-name=$versionName',
        '--build-number=$buildNumber',
        for (final entry in dartDefines.entries)
          '--dart-define=${entry.key}=${entry.value}',
      ];
}

/// 从仓库里探测到的原始材料。每一项都可空 —— 缺失都有确定的回退，
/// 这里不抛异常：构建脚本不该因为「这个检出没有 tag」就罢工。
class VersionContext {
  const VersionContext({
    required this.now,
    this.tag,
    this.commitCount,
    this.commit,
    this.dirty = false,
    this.shallow = false,
    this.pubspecVersion,
    this.pubspecBuildNumber,
    this.envVersionName,
    this.envBuildNumber,
    this.envCommit,
    this.envBuildTime,
    this.envChannel,
    this.sourceDateEpoch,
  });

  final String? tag;
  final String? commitCount;
  final String? commit;
  final bool dirty;
  final bool shallow;
  final String? pubspecVersion;
  final String? pubspecBuildNumber;

  /// `APP_*` 环境变量。容器/CI 里没有 `.git` 时，由宿主算好后传进来。
  final String? envVersionName;
  final String? envBuildNumber;
  final String? envCommit;
  final String? envBuildTime;
  final String? envChannel;

  /// 可复现构建用的时间戳（Unix 秒）。
  final String? sourceDateEpoch;

  final DateTime now;
}

/// 把探测到的材料合成最终值。
///
/// 优先级（每一列独立回退，不因为一项缺失就整体退）：
/// * 版本名：环境变量 > 最近 tag > pubspec
/// * build 号：环境变量 > 提交数 > pubspec 的 `+N`
/// * 提交 / 时间：环境变量 > git / `SOURCE_DATE_EPOCH` > 当前时间
/// * 渠道：`--channel` > 环境变量 > `public`
BuildVersion resolveBuildVersion(
  VersionContext context, {
  String? channelOverride,
}) {
  final envName = _trimOrNull(context.envVersionName);
  final tagName = normalizeVersionName(stripTagPrefix(context.tag));
  final pubspecName = normalizeVersionName(context.pubspecVersion);

  final String versionName;
  final VersionSource versionNameSource;
  if (envName != null) {
    versionName = normalizeVersionName(envName);
    versionNameSource = VersionSource.explicit;
  } else if (tagName.isNotEmpty) {
    versionName = tagName;
    versionNameSource = VersionSource.tag;
  } else if (pubspecName.isNotEmpty) {
    versionName = pubspecName;
    versionNameSource = VersionSource.pubspec;
  } else {
    versionName = '0.0.0';
    versionNameSource = VersionSource.pubspec;
  }

  final envBuild = int.tryParse(_trimOrNull(context.envBuildNumber) ?? '');
  final gitBuild = int.tryParse(_trimOrNull(context.commitCount) ?? '');
  final pubspecBuild =
      int.tryParse(_trimOrNull(context.pubspecBuildNumber) ?? '');

  final int buildNumber;
  final VersionSource buildNumberSource;
  if (envBuild != null && envBuild > 0) {
    buildNumber = envBuild;
    buildNumberSource = VersionSource.explicit;
  } else if (gitBuild != null && gitBuild > 0) {
    buildNumber = gitBuild;
    buildNumberSource = VersionSource.gitCount;
  } else if (pubspecBuild != null && pubspecBuild > 0) {
    buildNumber = pubspecBuild;
    buildNumberSource = VersionSource.pubspec;
  } else {
    // 0 是刻意允许的：运行期 `composeAppVersion` 把非数字当 0 处理，界面
    // 退化成不显示 `+N`，比崩掉好。
    buildNumber = 0;
    buildNumberSource = VersionSource.pubspec;
  }

  final commit = shortCommit(_trimOrNull(context.envCommit) ?? context.commit);
  final builtAt = resolveBuildTime(
    sourceDateEpoch: context.sourceDateEpoch,
    envBuildTime: context.envBuildTime,
    now: context.now,
  );
  final channel = normalizeChannel(channelOverride ?? context.envChannel);

  return BuildVersion(
    versionName: versionName,
    buildNumber: buildNumber,
    commit: commit,
    builtAt: builtAt,
    channel: channel,
    dirty: context.dirty,
    shallow: context.shallow,
    versionNameSource: versionNameSource,
    buildNumberSource: buildNumberSource,
  );
}

/// 需要人知道的问题。入口脚本把它们打到 stderr，**不改变退出码** ——
/// 回退值是可以发版的，只是要在日志里留痕。
List<String> versionWarnings(VersionContext context, BuildVersion version) {
  final warnings = <String>[];

  final epoch = _trimOrNull(context.sourceDateEpoch);
  if (epoch != null && int.tryParse(epoch) == null) {
    warnings.add('SOURCE_DATE_EPOCH（$epoch）不是整数秒，已忽略');
  }
  final explicitTime = _trimOrNull(context.envBuildTime);
  if (explicitTime != null && DateTime.tryParse(explicitTime) == null) {
    warnings.add('APP_BUILD_TIME（$explicitTime）不是 ISO-8601 时间，已忽略');
  }
  if (version.shallow) {
    warnings.add('这是浅克隆：build 号只数得到 ${version.buildNumber} 个提交。'
        'CI 里 checkout 要设 fetch-depth: 0，否则每次构建都是同一个号');
  }
  if (version.versionNameSource == VersionSource.pubspec) {
    warnings.add('没有可用的 git tag：版本名退回 pubspec 的 ${version.versionName}');
  }
  if (version.buildNumberSource == VersionSource.pubspec) {
    warnings.add('没有可用的提交历史（没有 .git / 空仓库 / 浅克隆）：'
        'build 号退回 pubspec 的 ${version.buildNumber}，不会随提交递增');
  }
  return warnings;
}

/// 去掉 tag 的 `v` / `V` 前缀。`v0.1.0` → `0.1.0`，其它原样。
String? stripTagPrefix(String? tag) {
  final cleaned = _trimOrNull(tag);
  if (cleaned == null) return null;
  if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
    return cleaned.substring(1);
  }
  return cleaned;
}

/// 版本名归一：只留 semver 认得的字符。
///
/// 不是洁癖 —— 这些值会原样进 `--build-name=` 与 `--dart-define=`，被 shell
/// 或 flutter 的参数解析拆开（tag 里出现空格 / 引号完全可能）就会静默错位。
String normalizeVersionName(String? raw) {
  final cleaned = _trimOrNull(raw);
  if (cleaned == null) return '';
  return cleaned.replaceAll(RegExp(r'[^0-9A-Za-z.+_-]+'), '-');
}

/// 渠道归一：小写，只留 `[a-z0-9._-]`；空串退回 [defaultUpdateChannel]。
String normalizeChannel(String? raw) {
  final cleaned = _trimOrNull(raw);
  if (cleaned == null) return defaultUpdateChannel;
  final normalized = cleaned.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
  return normalized.isEmpty ? defaultUpdateChannel : normalized;
}

/// 7 位短 sha。已经是短的（CI 传进来的）就不动。
///
/// 只认十六进制：万一环境变量里塞了别的（`HEAD`、分支名），原样归一而不是
/// 硬砍 7 个字符 —— 截断一个分支名只会得到更难认的东西。
String shortCommit(String? raw) {
  final cleaned = _trimOrNull(raw)?.toLowerCase();
  if (cleaned == null) return '';
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(cleaned)) {
    return normalizeVersionName(cleaned);
  }
  return cleaned.length > 7 ? cleaned.substring(0, 7) : cleaned;
}

/// 解析 `pubspec.yaml` 里的 `version:` 行。
///
/// 只认顶格的 `version:`（pubspec 里这一项就在顶格）；注释行里出现
/// `version:` 不算。返回值里的 `buildNumber` 是 `+` 后面那段。
({String? name, String? buildNumber}) parsePubspecVersion(String content) {
  for (final line in const LineSplitter().convert(content)) {
    final match = RegExp(r'^version\s*:\s*(.+?)\s*$').firstMatch(line);
    if (match == null) continue;
    final value = match
        .group(1)!
        .replaceAll(RegExp(r'''^["']|["']$'''), '')
        .trim();
    final plus = value.indexOf('+');
    final name = (plus < 0 ? value : value.substring(0, plus)).trim();
    final build = plus < 0 ? null : value.substring(plus + 1).trim();
    return (
      name: name.isEmpty ? null : name,
      buildNumber: build == null || build.isEmpty ? null : build,
    );
  }
  return (name: null, buildNumber: null);
}

/// 构建时间：显式值 > `SOURCE_DATE_EPOCH` > 现在（一律 UTC）。
///
/// `SOURCE_DATE_EPOCH` 是「可复现构建」那条行业约定：同一个提交 + 同一个
/// 时间戳，打出来的东西才可能逐字节相同。
DateTime resolveBuildTime({
  String? sourceDateEpoch,
  String? envBuildTime,
  required DateTime now,
}) {
  final explicit = DateTime.tryParse(_trimOrNull(envBuildTime) ?? '');
  if (explicit != null) return _truncateToSecond(explicit.toUtc());
  final epoch = int.tryParse(_trimOrNull(sourceDateEpoch) ?? '');
  if (epoch != null) {
    return _truncateToSecond(
      DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true),
    );
  }
  return _truncateToSecond(now.toUtc());
}

/// ISO-8601，**秒精度**：`2026-11-02T02:39:46Z`。
///
/// 不用 `toIso8601String()`（它会带 `.000`）：这个值会进 `--dart-define` 与
/// 版本清单，越短越不容易被各层转义弄错。
String formatBuildTime(DateTime builtAt) {
  final utc = builtAt.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}Z';
}

/// 人看的摘要（CI 日志里留一份）。
String summaryText(BuildVersion version) {
  final commit = version.commit.isEmpty ? '（未知）' : version.commit;
  final worktree = version.dirty ? '有未提交改动' : '干净';
  return <String>[
    '版本     ${version.display}',
    '版本名   ${version.versionName}（${_verboseSource(version.versionNameSource)}）',
    'build 号 ${version.buildNumber}（${_verboseSource(version.buildNumberSource)}）',
    '提交     $commit',
    '构建时间 ${formatBuildTime(version.builtAt)}',
    '渠道     ${version.channel}',
    '工作区   $worktree',
    '注入参数 ${version.flutterArgs.join(' ')}',
  ].join('\n');
}

/// shell 格式：`eval "$(dart tool/version.dart --format=shell)"` 之后可用。
///
/// 两组名字都发：`APP_*` 是 `--dart-define` 与 `docker run -e` 认的；
/// `VERSION_NAME` / `BUILD_NUMBER` 是发布脚本拼产物文件名用的。
String shellText(BuildVersion version) {
  final lines = <String>[
    r'# 用法：eval "$(dart tool/version.dart --format=shell)"',
    "APP_VERSION_NAME=${shellQuote(version.versionName)}",
    "APP_BUILD_NUMBER=${shellQuote('${version.buildNumber}')}",
    "APP_GIT_SHA=${shellQuote(version.commit)}",
    "APP_BUILD_TIME=${shellQuote(formatBuildTime(version.builtAt))}",
    "APP_UPDATE_CHANNEL=${shellQuote(version.channel)}",
    "VERSION_NAME=${shellQuote(version.versionName)}",
    "BUILD_NUMBER=${shellQuote('${version.buildNumber}')}",
    "CHANNEL=${shellQuote(version.channel)}",
  ];
  return lines.join('\n');
}

/// 给脚本解析用的 JSON。
String jsonText(BuildVersion version) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(<String, Object?>{
    'versionName': version.versionName,
    'buildNumber': version.buildNumber,
    'commit': version.commit,
    'builtAt': formatBuildTime(version.builtAt),
    'channel': version.channel,
    'dirty': version.dirty,
    'shallow': version.shallow,
    'display': version.display,
    'sources': <String, String>{
      'versionName': version.versionNameSource.name,
      'buildNumber': version.buildNumberSource.name,
    },
  });
}

/// 一行 `flutter build` 参数串（给 shell 里 `$VERSION_ARGS` 那种用法）。
String buildArgsText(BuildVersion version) => version.flutterArgs.join(' ');

/// 把版本参数接到用户自己的 `flutter build` 参数后面。
///
/// 用户显式传了的那一项**不重复追加**：`--build-name=x`、`--build-number=x`、
/// 或 `--dart-define=APP_XXX=x`（两种写法都认）。显式值优先，是构建工具该有的
/// 行为 —— 临时钉一个版本不该被包装层悄悄盖掉。
List<String> withVersionArgs(List<String> flutterArgs, BuildVersion version) {
  final result = <String>[...flutterArgs];
  final presentDefines = dartDefineNames(flutterArgs);
  if (!hasFlutterOption(flutterArgs, '--build-name')) {
    result.add('--build-name=${version.versionName}');
  }
  if (!hasFlutterOption(flutterArgs, '--build-number')) {
    result.add('--build-number=${version.buildNumber}');
  }
  for (final entry in version.dartDefines.entries) {
    if (presentDefines.contains(entry.key)) continue;
    result.add('--dart-define=${entry.key}=${entry.value}');
  }
  return result;
}

/// 参数里有没有 `--flag` / `--flag=值` 这一项。
bool hasFlutterOption(List<String> args, String option) {
  for (final arg in args) {
    if (arg == option || arg.startsWith('$option=')) return true;
  }
  return false;
}

/// `--dart-define` 里出现过的变量名（`--dart-define=A=B` 与
/// `--dart-define A=B` 两种写法都认）。
Set<String> dartDefineNames(List<String> args) {
  final names = <String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? body;
    if (arg.startsWith('--dart-define=')) {
      body = arg.substring('--dart-define='.length);
    } else if (arg == '--dart-define' && i + 1 < args.length) {
      body = args[++i];
    }
    if (body == null) continue;
    final equals = body.indexOf('=');
    names.add(equals < 0 ? body : body.substring(0, equals));
  }
  return names;
}

/// 单引号包一个 shell 值（内部单引号转义成 `'\''`）。
String shellQuote(String value) {
  if (value.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_./=:+-]+$').hasMatch(value)) return value;
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// 把整条命令拼成可直接粘进 shell 的一行（dry-run 输出用）。
String shellCommandText(List<String> command) =>
    command.map(shellQuote).join(' ');

String _verboseSource(VersionSource source) {
  switch (source) {
    case VersionSource.tag:
      return '最近 tag 去掉 v';
    case VersionSource.gitCount:
      return 'git rev-list --count HEAD';
    case VersionSource.explicit:
      return '显式指定';
    case VersionSource.pubspec:
      return 'pubspec 回退';
  }
}

DateTime _truncateToSecond(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
      (value.millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true,
    );

String? _trimOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
