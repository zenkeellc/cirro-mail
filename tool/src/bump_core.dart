/// 发布时把版本写回 `pubspec` 的纯逻辑：算出「哪些文件改成什么」，**不碰
/// 文件**（读盘写盘在 `tool/bump.dart`，用例只 import 这里）。
///
/// ## 为什么需要它
///
/// 构建期版本（`--dart-define=APP_*`）只活在**那一次构建**里，仓库里的
/// `pubspec.yaml` 一直停在手写的基线（`0.1.0+1`）。所以直接
/// `flutter run` / `flutter build`（没走 `tool/build.dart`）时，关于页、
/// 窗口标题、平台包的版本字段全是那个基线 —— 看起来像「版本从来没升过」。
/// 发版脚本在打 tag 前跑一次本工具，把「这次要发的版本」落进仓库，两份
/// 来源就对齐了。
///
/// ## 归属：同一个文件只让一边改
///
/// 两个检出会互相 `git merge`（公开 `main` → 商业分支）。同一行两边都改，
/// 每次合并都要解一次冲突，所以「谁写哪个文件」是硬规矩：
///
/// - **根 `pubspec.yaml`**：默认写（[planPubspecBumps] 的 `includeRoot`）。
///   **商业检出不写** —— 它的根 pubspec 每次合并都会从公开 `main` 拿到同版本
///   名；在这边写它，下一轮合并两边都改了同一行，必然冲突（两个检出合并是
///   `git merge`，不是覆盖）。公开检出发版时写它，直接 `flutter run` 就对得上；
/// - **内部包 `packages/<名字>/pubspec.yaml`**：按 [planPubspecBumps] 的
///   `ownedDirs` 过滤。两个检出**逐字节相同**的共享包只许公开渠道写 ——
///   在商业检出里单方面改它，编译门禁会算成「未登记的差异」直接拒绝出包；
///   商业检出自己的包（公开仓里没有那个目录）只有商业渠道写。
///
/// 规则落在 [planPubspecBumps]，用例在 `test/version_bump_test.dart`。
library;

import 'dart:convert';

/// 根 `pubspec.yaml` 的仓库相对路径。
const String rootPubspecPath = 'pubspec.yaml';

/// 一个要被改写的 `pubspec`。
class PubspecBump {
  const PubspecBump({
    required this.path,
    required this.version,
    required this.isRoot,
  });

  /// 仓库相对路径，POSIX 分隔符：`pubspec.yaml`、`packages/x/pubspec.yaml`。
  final String path;

  /// 写进 `version:` 的值：根包带 `+<build 号>`，内部包只有版本名。
  final String version;

  /// 是不是根 `pubspec.yaml`（只有它带 build 元数据）。
  final bool isRoot;

  /// 这个 pubspec 对应的包名（内部包 = 目录名；根包返回 null）。
  ///
  /// 用来改锁文件里那几条 **path 依赖** 的 `version:` —— 依赖名与目录名
  /// 一致（`packages/cirro_mail_ext/` 里就是 `name: cirro_mail_ext`），
  /// 这些包都是这么摆的。
  String? get packageName {
    if (isRoot) return null;
    final parts = path.split('/');
    if (parts.length < 2) return null;
    return parts[parts.length - 2];
  }
}

/// 本次发布该改哪些 pubspec。见文件头「归属」。
///
/// [present] 是检出里**真实存在**的 pubspec 相对路径（调用方 `File.existsSync`
/// 之后传进来）—— 不替调用方发明文件。
///
/// [ownedDirs] 是「本渠道维护的内部包目录」（相对路径，如 `packages/cirro_mail_ext`）：
///
/// - `null`：检出里**所有** `packages/*/pubspec.yaml` 都写。公开检出走这条
///   （它没有别的渠道的包）；
/// - 非 null：只写这些目录。商业检出发版时由发布脚本传上它自己的商业包，
///   共享包不在里面 —— 共享包随公开 `main` 合并过来，不在这边改。
///
/// [includeRoot] 为 false 时不写根 `pubspec.yaml`（商业检出的发版走这条：
/// 根版本随公开 `main` 合并过来，见文件头）。[buildNumber] <= 0 表示
/// 「不知道 build 号」，根包只写版本名。
List<PubspecBump> planPubspecBumps({
  required Set<String> present,
  required Set<String>? ownedDirs,
  required String versionName,
  required int buildNumber,
  bool includeRoot = true,
}) {
  final name = versionName.trim();
  if (name.isEmpty) {
    throw const FormatException('版本名为空');
  }
  final rootVersion = buildNumber > 0 ? '$name+$buildNumber' : name;

  final bumps = <PubspecBump>[];
  if (includeRoot && present.contains(rootPubspecPath)) {
    bumps.add(
      PubspecBump(path: rootPubspecPath, version: rootVersion, isRoot: true),
    );
  }
  for (final path in present) {
    if (path == rootPubspecPath || !path.endsWith('/pubspec.yaml')) continue;
    if (ownedDirs != null) {
      final dir = path.substring(0, path.length - '/pubspec.yaml'.length);
      if (!ownedDirs.contains(dir)) continue;
    }
    bumps.add(PubspecBump(path: path, version: name, isRoot: false));
  }
  // 输出顺序固定，日志与 `--format=paths` 才逐字节可复现。
  bumps.sort((a, b) => a.path.compareTo(b.path));
  return bumps;
}

/// 改写 pubspec 文本里的顶层 `version:` 行。
///
/// 只认顶格的那一行（pubspec 里版本就在这里）；注释行、缩进的同名键不碰。
/// 行尾注释原样保留。找不到 `version:` 行时抛 [FormatException]：一个没有
/// 版本的 pubspec 只可能是路径传错了，静默跳过会让发版漏掉一个包。
String applyPubspecVersion(String content, String version) {
  final target = version.trim();
  if (target.isEmpty) {
    throw const FormatException('版本名为空');
  }
  final pattern = RegExp(r'^(version[ \t]*:[ \t]*)([^#\r\n]*?)([ \t]*#.*)?$');
  var replaced = false;
  final lines = content.split('\n').map((line) {
    if (replaced) return line;
    final match = pattern.firstMatch(line);
    if (match == null) return line;
    replaced = true;
    final comment = match.group(3) ?? '';
    return '${match.group(1)}$target$comment';
  }).toList();
  if (!replaced) {
    throw const FormatException('找不到顶层 `version:` 行');
  }
  return lines.join('\n');
}

/// 改写 `pubspec.lock` 里 **path 依赖** 的版本条目。
///
/// [versions] 是「包名 → 新版本」。只改 `source: path` 的块：同名的 hosted
/// 包（万一以后引了同名的公开包）不动，那版本的来源不是我们的 pubspec。
/// 不改锁文件的话，发版提交刚落下，下一次 `flutter pub get` 就会把它改脏。
String applyLockVersions(String content, Map<String, String> versions) {
  if (versions.isEmpty) return content;
  final lines = content.split('\n');

  // 先找出所有块的起点：锁文件里包名是两格缩进、以冒号结尾。
  final blockStart = RegExp(r'^  ([A-Za-z0-9_]+):$');
  final starts = <int>[];
  final names = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final match = blockStart.firstMatch(lines[i]);
    if (match == null) continue;
    starts.add(i);
    names.add(match.group(1)!);
  }

  final versionLine = RegExp(r'^(    version: )(.+)$');
  for (var block = 0; block < starts.length; block++) {
    final target = versions[names[block]];
    if (target == null) continue;
    final start = starts[block];
    final end = block + 1 < starts.length ? starts[block + 1] : lines.length;

    var isPathDependency = false;
    for (var i = start; i < end; i++) {
      if (lines[i] == '    source: path') {
        isPathDependency = true;
        break;
      }
    }
    if (!isPathDependency) continue;

    for (var i = start; i < end; i++) {
      final match = versionLine.firstMatch(lines[i]);
      if (match == null) continue;
      lines[i] = '${match.group(1)}"$target"';
      break;
    }
  }
  return lines.join('\n');
}

/// 算出所有该改的文件：仓库相对路径 → 新内容。**只含真的变了的文件**，
/// 所以这个函数是幂等的（已经是目标版本时返回空）。
///
/// [pubspecContents] / [lockContents] 是调用方读到的原文。锁文件里的
/// path 依赖版本即使对应 pubspec 已经是对的也会被校正 —— 那说明上次只改
/// 了一半，留在盘上迟早把工作区弄脏。
Map<String, String> computeVersionEdits({
  required List<PubspecBump> bumps,
  required Map<String, String> pubspecContents,
  required Map<String, String> lockContents,
}) {
  final edits = <String, String>{};
  final packageVersions = <String, String>{};

  for (final bump in bumps) {
    final before = pubspecContents[bump.path];
    if (before == null) continue;
    final after = applyPubspecVersion(before, bump.version);
    if (after != before) edits[bump.path] = after;
    final packageName = bump.packageName;
    if (packageName != null) packageVersions[packageName] = bump.version;
  }

  for (final entry in lockContents.entries) {
    final after = applyLockVersions(entry.value, packageVersions);
    if (after != entry.value) edits[entry.key] = after;
  }
  return edits;
}

/// 一行一个改动路径（发布脚本 `git add` 用）。
String bumpPathsText(Iterable<String> paths) => paths.join('\n');

/// 人看的摘要。
String bumpSummaryText({
  required String repoDir,
  required String versionName,
  required int buildNumber,
  required String channel,
  required List<String> changed,
  required bool dryRun,
}) {
  final display = buildNumber > 0 ? '$versionName+$buildNumber' : versionName;
  return <String>[
    '版本     $display（渠道 $channel）',
    '检出     $repoDir',
    if (changed.isEmpty)
      '改动     无（各 pubspec 已经是这个版本）'
    else
      '改动     ${changed.length} 个文件${dryRun ? '（只算不写）' : ''}',
    for (final path in changed) '  $path',
  ].join('\n');
}

/// 给发布脚本 / CI 解析的 JSON。
String bumpJsonText({
  required String repoDir,
  required String versionName,
  required int buildNumber,
  required String channel,
  required List<String> changed,
  required bool dryRun,
}) {
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'versionName': versionName,
    'buildNumber': buildNumber,
    'channel': channel,
    'repo': repoDir,
    'dryRun': dryRun,
    'changed': changed,
  });
}
