// ignore_for_file: avoid_print
/// `flutter build` 的薄包装：把 `tool/version.dart` 算出的版本自动接上。
///
/// 为什么值得包一层：漏一个 `--dart-define=APP_BUILD_NUMBER` 不会报错，只会在
/// 关于页上静默显示 pubspec 里那个 `0.1.0+1` —— 这种错没人会发现。CI 与本地
/// 发布脚本都走它，版本从算出到注入只有一条路。
///
///   dart tool/build.dart macos --release
///   dart tool/build.dart apk --debug
///   dart tool/build.dart --dry-run macos --release   # 只打印命令
///
/// 除 `--dry-run` / `--channel` / `--repo` / `--help` 外的参数原样交给
/// `flutter build`；用户自己传过的同名字段不会再重复追加。
library;

import 'dart:io';

import 'src/cli.dart';
import 'src/git_probe.dart';
import 'src/version_core.dart';

Future<void> main(List<String> args) async {
  final BuildCli cli;
  try {
    cli = parseBuildCli(args);
  } on FormatException catch (error) {
    stderr.writeln('参数错误：${error.message}');
    stderr.writeln();
    stderr.writeln(buildUsage);
    exitCode = 64;
    return;
  }
  if (cli.help) {
    print(buildUsage);
    return;
  }
  if (cli.flutterArgs.isEmpty) {
    stderr.writeln('缺少 flutter build 的参数，例如：'
        'dart tool/build.dart macos --release');
    stderr.writeln();
    stderr.writeln(buildUsage);
    exitCode = 64;
    return;
  }

  final repo = cli.repo ?? defaultRepoRoot();
  final context = probeVersionContext(repoDir: repo);
  final version = resolveBuildVersion(context, channelOverride: cli.channel);
  for (final warning in versionWarnings(context, version)) {
    stderr.writeln('[version] 警告：$warning');
  }

  final command = <String>[
    'flutter',
    'build',
    ...withVersionArgs(cli.flutterArgs, version),
  ];
  final commit = version.commit.isEmpty ? '未知' : version.commit;
  print('== 构建版本 ${version.display}'
      '（渠道 ${version.channel}，提交 $commit）==');
  // 完整命令打出来：CI 日志里对得上「这个包是哪次提交、哪个构建号」。
  print('== ${shellCommandText(command)}');
  if (cli.dryRun) return;

  final Process process;
  try {
    process = await Process.start(
      command.first,
      command.skip(1).toList(),
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (error) {
    stderr.writeln('启动 flutter 失败：${error.message}'
        '（flutter 在 PATH 里吗？）');
    exitCode = 127;
    return;
  }
  final code = await process.exitCode;
  if (code != 0) {
    stderr.writeln('flutter build 失败（退出码 $code）');
  }
  exit(code);
}
