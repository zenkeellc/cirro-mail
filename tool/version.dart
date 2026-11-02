// ignore_for_file: avoid_print
/// 构建期版本：build 号 = 提交数。CI（`.github/workflows/ci.yml`）与本地
/// 发布脚本（`.release/scripts/build-macos.sh`、
/// `.release/linux/build-in-container.sh`）共用这一份 —— 以前版本号在几处
/// 手填，发版前要人对一遍，还总对不上。
///
/// 常用：
///   dart tool/version.dart --format=summary     # 人看的摘要
///   dart tool/version.dart --format=shell       # eval 之后得到 APP_* 变量
///   dart tool/version.dart --format=json        # 给脚本解析
///   dart tool/version.dart --format=build-args  # 拼在 flutter build 后面
///
/// `dart tool/build.dart` 会直接复用这里的算法，正常构建不用手敲本脚本。
library;

import 'dart:io';

import 'src/cli.dart';
import 'src/git_probe.dart';
import 'src/version_core.dart';

void main(List<String> args) {
  final VersionCli cli;
  try {
    cli = parseVersionCli(args);
  } on FormatException catch (error) {
    stderr.writeln('参数错误：${error.message}');
    stderr.writeln();
    stderr.writeln(versionUsage);
    exitCode = 64;
    return;
  }
  if (cli.help) {
    print(versionUsage);
    return;
  }

  final repo = cli.repo ?? defaultRepoRoot();
  if (!Directory(repo).existsSync()) {
    stderr.writeln('--repo 指向的目录不存在：$repo');
    exitCode = 66;
    return;
  }

  final context = probeVersionContext(repoDir: repo);
  final version = resolveBuildVersion(context, channelOverride: cli.channel);
  for (final warning in versionWarnings(context, version)) {
    stderr.writeln('[version] 警告：$warning');
  }

  print(switch (cli.format) {
    'shell' => shellText(version),
    'json' => jsonText(version),
    'build-args' => buildArgsText(version),
    _ => summaryText(version),
  });
}
