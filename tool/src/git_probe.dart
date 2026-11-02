/// 从真实的检出里捞版本原材料：跑 git、读 `pubspec.yaml`、读 `APP_*` 环境
/// 变量。**有副作用**，所以和 `version_core.dart` 的纯逻辑分开 ——
/// `test/version_tool_test.dart` 只测后者，用例不需要真仓库。
library;

import 'dart:io';

import 'version_core.dart';

/// 默认的检出根：本文件在 `<repo>/tool/src/` 下，往上两级。
///
/// 从脚本自己的位置算，而不是 `Directory.current`：在哪个目录下敲
/// `dart /path/to/mail-app/tool/version.dart` 都能算对。
String defaultRepoRoot() {
  final script = Platform.script;
  if (script.scheme == 'file') {
    return File(script.toFilePath()).parent.parent.path;
  }
  return Directory.current.path;
}

/// 探测版本原材料。git 缺失、浅克隆、没有 tag、没有提交都退化成「字段为
/// 空」，由 [resolveBuildVersion] 决定回退 —— 这里不抛异常。
VersionContext probeVersionContext({
  required String repoDir,
  Map<String, String>? environment,
  DateTime? now,
}) {
  final env = environment ?? Platform.environment;
  final root = repoDir.replaceAll(RegExp(r'[/\\]+$'), '');

  final pubspecText = _readTextFile('$root/pubspec.yaml');
  final ({String? name, String? buildNumber}) pubspec = pubspecText == null
      ? (name: null, buildNumber: null)
      : parsePubspecVersion(pubspecText);

  // 不是检出就一条 git 命令都不跑：`git -C` 会**向上**找父目录的仓库，容器里
  // 拷出来的源码目录（`/workspace`、`.release/linux/src`）会被算成父仓库的
  // 提交数 —— 比直接报错还难查。
  final inGitCheckout = isGitCheckout(root);
  return VersionContext(
    now: now ?? DateTime.now(),
    tag: inGitCheckout
        ? _git(root, <String>['describe', '--tags', '--abbrev=0'])
        : null,
    commitCount: inGitCheckout
        ? _git(root, <String>['rev-list', '--count', 'HEAD'])
        : null,
    commit: inGitCheckout
        ? _git(root, <String>['rev-parse', '--short=7', 'HEAD'])
        : null,
    dirty: inGitCheckout &&
        (_git(root, <String>['status', '--porcelain']) ?? '').isNotEmpty,
    shallow: inGitCheckout &&
        _git(root, <String>['rev-parse', '--is-shallow-repository']) == 'true',
    pubspecVersion: pubspec.name,
    pubspecBuildNumber: pubspec.buildNumber,
    envVersionName: env['APP_VERSION_NAME'],
    envBuildNumber: env['APP_BUILD_NUMBER'],
    envCommit: env['APP_GIT_SHA'],
    envBuildTime: env['APP_BUILD_TIME'],
    envChannel: env['APP_UPDATE_CHANNEL'],
    sourceDateEpoch: env['SOURCE_DATE_EPOCH'],
  );
}

/// 这个目录**自己**是不是一个 git 检出。
///
/// 用 `.git` 在不在判断，而不是跑 `git rev-parse`：子模块的 `.git` 是文件
/// （`gitdir: ...`），普通检出是目录，worktree 也是文件 —— 三种都能认。
bool isGitCheckout(String repoDir) {
  final type = FileSystemEntity.typeSync('$repoDir/.git');
  return type == FileSystemEntityType.directory ||
      type == FileSystemEntityType.file;
}

/// 跑一条 git 命令，成功返回 stdout（去掉首尾空白），失败返回 null。
///
/// 失败是**预期内**的（没有 tag、空仓库、没有 git 可执行文件），所以不抛
/// 异常、不打日志 —— 回退由上层统一决定并汇总成警告。
String? _git(String repoDir, List<String> args) {
  try {
    final result = Process.runSync(
      'git',
      <String>['-C', repoDir, ...args],
      runInShell: false,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );
    if (result.exitCode != 0) return null;
    final output = (result.stdout as String).trim();
    return output.isEmpty ? null : output;
  } on ProcessException {
    // 没有 git 可执行文件（容器 / 精简镜像）。
    return null;
  }
}

String? _readTextFile(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}
