// ignore_for_file: avoid_print
/// 把发布版本写回 pubspec：根包 `version: X.Y.Z+<build>`、内部包
/// `version: X.Y.Z`，以及锁文件里这些 path 依赖的版本条目。
///
/// 发版脚本（`.release/scripts/release-all.sh`）在打 tag 前调它一次，然后把
/// 改动的文件提交 —— 于是仓库里的版本与即将发出去的包一致，直接
/// `flutter run` / `flutter build`（没走 `tool/build.dart`）也不会再显示
/// 手写基线 `0.1.0+1`。
///
/// 常用：
///   dart tool/bump.dart --version=0.1.10 --build=295 --channel=pro
///   dart tool/bump.dart --dry-run --format=paths     # 只算，只打印
///   dart tool/bump.dart --check                      # 校验（发版检查清单用）
///
/// 归属规则见 `src/bump_core.dart` 文件头：同一个文件只让一边改。商业检出用
/// `--package=` 点名它自己的包，共享包不在那个列表里 —— 它随公开 main 合并
/// 过来，不在这边写。
library;

import 'dart:io';

import 'src/bump_core.dart';
import 'src/cli.dart';
import 'src/git_probe.dart';
import 'src/version_core.dart';

void main(List<String> args) {
  final BumpCli cli;
  try {
    cli = parseBumpCli(args);
  } on FormatException catch (error) {
    stderr.writeln('参数错误：${error.message}');
    stderr.writeln();
    stderr.writeln(bumpUsage);
    exitCode = 64;
    return;
  }
  if (cli.help) {
    print(bumpUsage);
    return;
  }

  final repo = (cli.repo ?? defaultRepoRoot()).replaceAll(
    RegExp(r'[/\\]+$'),
    '',
  );
  if (!Directory(repo).existsSync()) {
    stderr.writeln('--repo 指向的目录不存在：$repo');
    exitCode = 66;
    return;
  }

  final channel = _resolveChannel(cli.channel, repo);
  final context = probeVersionContext(repoDir: repo);
  final detected = resolveBuildVersion(context, channelOverride: channel);
  final explicitName = (cli.version ?? '').trim();
  final versionName = explicitName.isEmpty
      ? detected.versionName
      : normalizeVersionName(explicitName);
  if (versionName.isEmpty) {
    stderr.writeln('算不出版本名：检出没有 tag、pubspec 里也没有版本？');
    stderr.writeln('用 --version=<X.Y.Z> 显式指定。');
    exitCode = 65;
    return;
  }
  final buildNumber = cli.buildNumber ?? detected.buildNumber;

  for (final warning in versionWarnings(context, detected)) {
    stderr.writeln('[bump] 警告：$warning');
  }

  // `--package` 给的是包目录。先确认每个目录里真有 pubspec，再交给纯逻辑
  // 过滤 —— 拼错一个字母时宁可报错，也不要悄悄少写一个包。
  final Set<String>? ownedDirs;
  if (cli.packages.isEmpty) {
    ownedDirs = null;
  } else {
    final dirs = <String>{};
    for (final raw in cli.packages) {
      final dir = _normalizeDir(raw);
      if (dir.isEmpty) {
        stderr.writeln('--package 的值是空的');
        exitCode = 64;
        return;
      }
      if (!File('$repo/$dir/pubspec.yaml').existsSync()) {
        stderr.writeln('--package 指向的目录里没有 pubspec.yaml：$dir');
        exitCode = 66;
        return;
      }
      dirs.add(dir);
    }
    ownedDirs = dirs;
  }

  // 检出里真实存在的 pubspec / lock。「存在」是判断的输入，不靠猜。
  final pubspecPaths = _discoverPubspecs(repo);
  final pubspecContents = <String, String>{
    for (final path in pubspecPaths)
      path: File('$repo/$path').readAsStringSync(),
  };
  final lockContents = _readLocks(repo, pubspecPaths);

  final List<PubspecBump> bumps;
  final Map<String, String> edits;
  try {
    bumps = planPubspecBumps(
      present: pubspecPaths,
      ownedDirs: ownedDirs,
      versionName: versionName,
      buildNumber: buildNumber,
      includeRoot: !cli.noRoot,
    );
    edits = computeVersionEdits(
      bumps: bumps,
      pubspecContents: pubspecContents,
      lockContents: lockContents,
    );
  } on FormatException catch (error) {
    stderr.writeln('改写失败：${error.message}');
    stderr.writeln('（这个检出里少了 `version:` 行，或者 --repo 指错了？）');
    exitCode = 65;
    return;
  }
  final changed = edits.keys.toList()..sort();

  // --check 与 --dry-run 都不写盘；--check 只看「是不是已经是目标版本」。
  if (!cli.dryRun && !cli.check) {
    for (final entry in edits.entries) {
      try {
        File('$repo/${entry.key}').writeAsStringSync(entry.value);
      } on FileSystemException catch (error) {
        stderr.writeln('写不了 ${entry.key}：$error');
        exitCode = 74;
        return;
      }
    }
  }

  if (cli.check) {
    if (changed.isNotEmpty) {
      stderr.writeln('版本不一致（期望 ${_display(versionName, buildNumber)}）：');
      for (final path in changed) {
        stderr.writeln('    $path');
      }
      stderr.writeln('用 `dart tool/bump.dart --format=summary` 看它想改成什么。');
      exitCode = 1;
      return;
    }
    print('OK  各 pubspec 已是 ${_display(versionName, buildNumber)}');
    return;
  }

  switch (cli.format) {
    case 'paths':
      print(bumpPathsText(changed));
    case 'json':
      print(
        bumpJsonText(
          repoDir: repo,
          versionName: versionName,
          buildNumber: buildNumber,
          channel: channel,
          changed: changed,
          dryRun: cli.dryRun,
        ),
      );
    default:
      print(
        bumpSummaryText(
          repoDir: repo,
          versionName: versionName,
          buildNumber: buildNumber,
          channel: channel,
          changed: changed,
          dryRun: cli.dryRun,
        ),
      );
  }
}

String _display(String versionName, int buildNumber) =>
    buildNumber > 0 ? '$versionName+$buildNumber' : versionName;

/// `--package` 的值归一成仓库相对目录（去首尾斜杠 / `./`）。
String _normalizeDir(String raw) {
  var dir = raw.trim().replaceAll('\\', '/');
  while (dir.startsWith('./')) {
    dir = dir.substring(2);
  }
  return dir.replaceAll(RegExp(r'^/+|/+$'), '');
}

/// 渠道：显式 `--channel` > 环境变量 `APP_UPDATE_CHANNEL` > 目录名以 `-pro`
/// 结尾（商业检出的约定命名）> `public`。
///
/// 判据只看**检出目录名**，不看文件内容：公开仓库里不允许出现商业包的名字
/// （CI 的 `no-commercial-refs` 会扫整棵树），所以这个工具里不写死它。
/// 发布脚本调它时总是显式传 `--channel`。
String _resolveChannel(String? explicit, String repo) {
  final given = (explicit ?? '').trim();
  if (given.isNotEmpty) return normalizeChannel(given);
  final fromEnv = (Platform.environment['APP_UPDATE_CHANNEL'] ?? '').trim();
  if (fromEnv.isNotEmpty) return normalizeChannel(fromEnv);
  final base = repo.split(RegExp(r'[/\\]+')).last;
  return base.endsWith('-pro') ? 'pro' : 'public';
}

/// 检出里存在的 pubspec：根 + `packages/<名字>/pubspec.yaml` 各一层。
Set<String> _discoverPubspecs(String repo) {
  final found = <String>{};
  if (File('$repo/$rootPubspecPath').existsSync()) {
    found.add(rootPubspecPath);
  }
  final packages = Directory('$repo/packages');
  if (packages.existsSync()) {
    for (final entity in packages.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(RegExp(r'[/\\]+')).last;
      if (name.isEmpty) continue;
      final relative = 'packages/$name/pubspec.yaml';
      if (File('$repo/$relative').existsSync()) found.add(relative);
    }
  }
  return found;
}

/// 锁文件：根 `pubspec.lock` + 每个内部包自己的 `pubspec.lock`（有的话）。
///
/// 这些文件里记着 path 依赖解析出来的版本，pubspec 一改它们就过期了。
Map<String, String> _readLocks(String repo, Set<String> pubspecPaths) {
  final locks = <String, String>{};
  void add(String relative) {
    final file = File('$repo/$relative');
    if (file.existsSync()) locks[relative] = file.readAsStringSync();
  }

  add('pubspec.lock');
  for (final path in pubspecPaths) {
    if (path == rootPubspecPath) continue;
    final dir = path.substring(0, path.length - '/pubspec.yaml'.length);
    add('$dir/pubspec.lock');
  }
  return locks;
}
