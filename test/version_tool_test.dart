import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/src/cli.dart';
import '../tool/src/git_probe.dart';
import '../tool/src/version_core.dart';

/// `tool/version.dart` / `tool/build.dart` 的规则都压在这组纯函数里，所以这里
/// **不需要真 git 仓库**，用例喂字符串就行。真仓库那一条由 CI 的
/// 「计算构建版本」步骤与本地 `dart tool/version.dart --format=summary` 兜。
void main() {
  group('stripTagPrefix / 归一', () {
    test('tag 去掉前缀 v，大小写都认，没有前缀就原样', () {
      expect(stripTagPrefix('v0.1.0'), '0.1.0');
      expect(stripTagPrefix('V1.2.3'), '1.2.3');
      expect(stripTagPrefix('1.2.3'), '1.2.3');
      expect(stripTagPrefix('  v0.2.0  '), '0.2.0');
      expect(stripTagPrefix(null), isNull);
      expect(stripTagPrefix('   '), isNull);
    });

    test('版本名只留 semver 认得的字符（否则 --build-name 会被拆错）', () {
      expect(normalizeVersionName('0.1.0'), '0.1.0');
      expect(normalizeVersionName('release/1.2.3'), 'release-1.2.3');
      expect(normalizeVersionName(' a b '), 'a-b');
      expect(normalizeVersionName(null), '');
    });

    test('渠道：空退 public，大写转小写，怪字符换 -', () {
      expect(normalizeChannel(null), defaultUpdateChannel);
      expect(normalizeChannel('   '), defaultUpdateChannel);
      expect(normalizeChannel('PRO'), 'pro');
      expect(normalizeChannel('Public'), 'public');
      expect(normalizeChannel('beta 通道'), 'beta-');
    });

    test('短 sha：长 sha 砍到 7 位，不是十六进制的按名字归一', () {
      expect(
        shortCommit('852199b1b1173bb4715fc126fa479b71b6b579fd'),
        '852199b',
      );
      expect(shortCommit('852199b'), '852199b');
      expect(shortCommit(' 852199B '), '852199b');
      // 环境变量里塞分支名时不该硬砍 7 个字符 —— 截断只会得到更难认的东西。
      expect(shortCommit('feature/x'), 'feature-x');
      expect(shortCommit(null), '');
    });
  });

  group('渠道标记（tag 上的 -pro.N 不进版本号）', () {
    test('认得出结尾的渠道标记；别的预发布标识也算一段「标记」', () {
      expect(channelMarkerOf('0.1.4-pro.1'), 'pro');
      expect(channelMarkerOf('0.1.4-PRO.12'), 'pro');
      expect(channelMarkerOf('0.1.0-beta.1'), 'beta');
      expect(channelMarkerOf('0.1.4'), isNull);
      expect(channelMarkerOf('dev'), isNull);
      // 不带数字段的 `-pro` 不是这套约定里的标记（tag 约定一定带 .N）。
      expect(channelMarkerOf('0.1.4-pro'), isNull);
    });

    test('与当前渠道对得上才去掉；别的渠道的标记原样留着', () {
      expect(stripChannelMarker('0.1.4-pro.1', 'pro'), '0.1.4');
      expect(stripChannelMarker('0.1.4-PRO.1', 'PRO'), '0.1.4');
      expect(stripChannelMarker('0.1.4-pro.1', 'public'), '0.1.4-pro.1');
      expect(stripChannelMarker('0.1.4-beta.1', 'pro'), '0.1.4-beta.1');
      expect(stripChannelMarker('0.1.4', 'pro'), '0.1.4');
    });
  });

  group('parsePubspecVersion', () {
    test('取 version: 行的版本名与 build 号', () {
      final parsed = parsePubspecVersion('name: mail_app\nversion: 0.1.0+1\n');
      expect(parsed.name, '0.1.0');
      expect(parsed.buildNumber, '1');
    });

    test('没有 +N 时 build 号为空', () {
      final parsed = parsePubspecVersion('version: 0.2.0\n');
      expect(parsed.name, '0.2.0');
      expect(parsed.buildNumber, isNull);
    });

    test('引号包住的 version 也能读', () {
      final parsed = parsePubspecVersion('version: "1.0.0+3"\n');
      expect(parsed.name, '1.0.0');
      expect(parsed.buildNumber, '3');
    });

    test('注释行与缩进的同名 key 不算', () {
      final commented = parsePubspecVersion(
        '# version: 9.9.9\nversion: 0.2.0+7\n',
      );
      expect(commented.name, '0.2.0');
      expect(commented.buildNumber, '7');

      // 子块里缩进的 `version:` 不是顶层版本。
      final indented = parsePubspecVersion('  version: 9.9.9\n');
      expect(indented.name, isNull);
      expect(indented.buildNumber, isNull);
    });

    test('没有 version 行时两个字段都为空', () {
      final parsed = parsePubspecVersion('name: x\ndescription: y\n');
      expect(parsed.name, isNull);
      expect(parsed.buildNumber, isNull);
    });
  });

  group('resolveBuildVersion', () {
    test('官方路径：最近 tag 去 v + 提交数（build 号每次提交 +1）', () {
      final version = resolveBuildVersion(
        _context(
          tag: 'v0.1.0',
          commitCount: '24',
          commit: '852199b1b1173bb4715fc126fa479b71b6b579fd',
          pubspecVersion: '0.1.0',
          pubspecBuildNumber: '1',
        ),
      );
      expect(version.versionName, '0.1.0');
      expect(version.buildNumber, 24);
      expect(version.commit, '852199b');
      expect(version.display, '0.1.0+24');
      expect(version.channel, 'public');
      expect(version.versionNameSource, VersionSource.tag);
      expect(version.buildNumberSource, VersionSource.gitCount);
      expect(version.builtAt, DateTime.utc(2026, 11, 2, 2, 39, 46));
    });

    test('没有 tag、没有提交历史时退回 pubspec，并且给出两条警告', () {
      final context = _context(pubspecVersion: '0.1.0', pubspecBuildNumber: '1');
      final version = resolveBuildVersion(context);
      expect(version.versionName, '0.1.0');
      expect(version.buildNumber, 1);
      expect(version.versionNameSource, VersionSource.pubspec);
      expect(version.buildNumberSource, VersionSource.pubspec);

      final warnings = versionWarnings(context, version).join('\n');
      expect(warnings, contains('没有可用的 git tag'));
      expect(warnings, contains('build 号退回'));
    });

    test('环境变量显式值优先（容器里没有 .git 时靠它）', () {
      final version = resolveBuildVersion(
        _context(
          tag: 'v0.1.0',
          commitCount: '24',
          commit: '852199b',
          envVersionName: '0.2.0',
          envBuildNumber: '130',
          envCommit: 'deadbeefcafe',
          envBuildTime: '2026-11-02T03:00:00Z',
          envChannel: 'PRO',
        ),
      );
      expect(version.versionName, '0.2.0');
      expect(version.buildNumber, 130);
      expect(version.commit, 'deadbee');
      expect(version.builtAt, DateTime.utc(2026, 11, 2, 3));
      expect(version.channel, 'pro');
      expect(version.versionNameSource, VersionSource.explicit);
      expect(version.buildNumberSource, VersionSource.explicit);
    });

    test('提交数不是正整数时不采信，退回 pubspec 的 build 号', () {
      for (final bad in <String>['abc', '0', '-3', '  ']) {
        final version = resolveBuildVersion(
          _context(
            commitCount: bad,
            pubspecVersion: '0.1.0',
            pubspecBuildNumber: '7',
          ),
        );
        expect(version.buildNumber, 7, reason: 'commitCount=$bad');
        expect(
          version.buildNumberSource,
          VersionSource.pubspec,
          reason: 'commitCount=$bad',
        );
      }
    });

    test('--channel 覆盖环境变量里的渠道', () {
      final fromEnv = resolveBuildVersion(_context(envChannel: 'pro'));
      expect(fromEnv.channel, 'pro');

      final overridden = resolveBuildVersion(
        _context(envChannel: 'pro'),
        channelOverride: 'public',
      );
      expect(overridden.channel, 'public');
    });

    test('dirty / shallow 透传；浅克隆要警告（CI 忘了 fetch-depth: 0）', () {
      final context = _context(commitCount: '1', dirty: true, shallow: true);
      final version = resolveBuildVersion(context);
      expect(version.dirty, isTrue);
      expect(version.shallow, isTrue);
      expect(versionWarnings(context, version).join('\n'), contains('浅克隆'));
    });

    test('商业渠道：tag 上的 -pro.N 不进版本号（关于页 / 清单 / 产物名同一个数）',
        () {
      final version = resolveBuildVersion(
        _context(
          tag: 'v0.1.4-pro.1',
          commitCount: '86',
          commit: 'ad6234b',
          pubspecVersion: '0.1.0',
        ),
        channelOverride: 'pro',
      );
      expect(version.channel, 'pro');
      expect(version.versionName, '0.1.4');
      expect(version.display, '0.1.4+86');
      expect(version.dartDefines['APP_VERSION_NAME'], '0.1.4');
      expect(version.dartDefines['APP_UPDATE_CHANNEL'], 'pro');
      expect(version.bundleVersionName, '0.1.4');
      // 没有对不上的标记 → 不该为此报警。
      expect(
        versionWarnings(
          _context(tag: 'v0.1.4-pro.1', commitCount: '86'),
          version,
        ).join('\n'),
        isNot(contains('渠道标记')),
      );
    });

    test('tag 的渠道标记与构建渠道对不上：保留标记并警告（多半漏了 --channel）',
        () {
      // 商业检出没加 --channel 时默认 public —— 版本名会带着 -pro.1，
      // 这类包发出去就是「商业版里显示 0.1.4-pro.1」，所以要在日志里响。
      final context = _context(tag: 'v0.1.4-pro.1', commitCount: '86');
      final version = resolveBuildVersion(context);
      expect(version.channel, 'public');
      expect(version.versionName, '0.1.4-pro.1');
      expect(
        versionWarnings(context, version).join('\n'),
        contains('--channel=pro'),
      );
    });

    test('显式 APP_VERSION_NAME 原样采信（发版补包时钉版），不被标记规则改写',
        () {
      final version = resolveBuildVersion(
        _context(
          tag: 'v0.1.4-pro.1',
          commitCount: '86',
          envVersionName: '0.1.4-pro.1',
        ),
        channelOverride: 'pro',
      );
      expect(version.versionNameSource, VersionSource.explicit);
      expect(version.versionName, '0.1.4-pro.1');
    });
  });

  group('resolveBuildTime / formatBuildTime', () {
    test('SOURCE_DATE_EPOCH 优先于当前时间（可复现构建）', () {
      final epoch =
          DateTime.utc(2026, 11, 2, 2).millisecondsSinceEpoch ~/ 1000;
      final builtAt = resolveBuildTime(
        sourceDateEpoch: '$epoch',
        now: DateTime.utc(2030),
      );
      expect(builtAt, DateTime.utc(2026, 11, 2, 2));
      expect(formatBuildTime(builtAt), '2026-11-02T02:00:00Z');
    });

    test('显式 APP_BUILD_TIME 优先于 SOURCE_DATE_EPOCH', () {
      final builtAt = resolveBuildTime(
        envBuildTime: '2026-11-02T03:00:00Z',
        sourceDateEpoch: '0',
        now: DateTime.utc(2030),
      );
      expect(builtAt, DateTime.utc(2026, 11, 2, 3));
    });

    test('毫秒被截掉：同一个提交 + 同一个时间戳要逐字节可复现', () {
      final builtAt = resolveBuildTime(
        now: DateTime.utc(2026, 11, 2, 2, 39, 46, 789, 123),
      );
      expect(formatBuildTime(builtAt), '2026-11-02T02:39:46Z');
    });

    test('坏掉的 SOURCE_DATE_EPOCH / APP_BUILD_TIME 退回当前时间并警告', () {
      final context = _context(
        sourceDateEpoch: '不是数字',
        envBuildTime: '昨天',
      );
      final version = resolveBuildVersion(context);
      expect(version.builtAt, DateTime.utc(2026, 11, 2, 2, 39, 46));

      final warnings = versionWarnings(context, version).join('\n');
      expect(warnings, contains('SOURCE_DATE_EPOCH'));
      expect(warnings, contains('APP_BUILD_TIME'));
    });
  });

  group('输出格式', () {
    test('summary：一行行念得出来，带来源与注入参数', () {
      final text = summaryText(_sampleVersion());
      expect(text, contains('0.1.0+24'));
      expect(text, contains('git rev-list --count HEAD'));
      expect(text, contains('2026-11-02T02:39:46Z'));
      expect(text, contains('渠道     public'));
      expect(text, contains('干净'));
      expect(text, contains('--build-number=24'));
    });

    test('shell：KEY=value 行，eval 之后就能用', () {
      final lines = shellText(_sampleVersion()).split('\n');
      expect(lines, contains('APP_VERSION_NAME=0.1.0'));
      expect(lines, contains('APP_BUILD_NUMBER=24'));
      expect(lines, contains('APP_GIT_SHA=852199b'));
      expect(lines, contains('APP_BUILD_TIME=2026-11-02T02:39:46Z'));
      expect(lines, contains('APP_UPDATE_CHANNEL=public'));
      expect(lines, contains('VERSION_NAME=0.1.0'));
      expect(lines, contains('BUILD_NUMBER=24'));
      expect(lines, contains('CHANNEL=public'));
    });

    test('json：能解析回同一组值（给脚本用）', () {
      final decoded =
          jsonDecode(jsonText(_sampleVersion())) as Map<String, Object?>;
      expect(decoded['versionName'], '0.1.0');
      expect(decoded['buildNumber'], 24);
      expect(decoded['commit'], '852199b');
      expect(decoded['builtAt'], '2026-11-02T02:39:46Z');
      expect(decoded['channel'], 'public');
      expect(decoded['dirty'], isFalse);
      expect(decoded['shallow'], isFalse);
      expect(decoded['display'], '0.1.0+24');
      expect(
        (decoded['sources'] as Map<String, Object?>)['buildNumber'],
        'gitCount',
      );
    });

    test('build-args：一行、5 个 dart-define、值里不带空格', () {
      final tokens = buildArgsText(_sampleVersion()).split(' ');
      expect(tokens, contains('--build-name=0.1.0'));
      expect(tokens, contains('--build-number=24'));
      expect(
        tokens.where((token) => token.startsWith('--dart-define=')),
        hasLength(5),
      );
      expect(tokens, contains('--dart-define=APP_GIT_SHA=852199b'));
      expect(tokens.every((token) => !token.contains(' ')), isTrue);
    });

    test('shellCommandText：该加引号的加引号，能直接粘进 shell', () {
      expect(
        shellCommandText(<String>[
          'flutter',
          'build',
          'macos',
          '--dart-define=APP_BUILD_TIME=2026-11-02T02:39:46Z',
        ]),
        'flutter build macos '
        '--dart-define=APP_BUILD_TIME=2026-11-02T02:39:46Z',
      );
      expect(
        shellCommandText(<String>['flutter', 'build', '--x=a b']),
        "flutter build '--x=a b'",
      );
    });
  });

  group('平台包版本名（--build-name 只能数字）', () {
    test('正式版：平台包版本名与版本名一致', () {
      expect(_sampleVersion().bundleVersionName, '0.1.0');
    });

    test('预发布标识不进 --build-name，但完整版本名仍走 dart-define', () {
      // CFBundleShortVersionString 只允许数字与点，Windows 的 CMake 也要按 .
      // 拆成整数的 major/minor/patch。
      final beta = _sampleVersion(versionName: '0.1.0-beta.1');
      expect(beta.bundleVersionName, '0.1.0');
      // 关于页 / 窗口标题 / 更新检查读的是完整版本名，不能被这里抹掉
      // （渠道标记是另一回事：它在更早一步就没了，见上面的「渠道标记」组）。
      expect(beta.dartDefines['APP_VERSION_NAME'], '0.1.0-beta.1');
      expect(beta.display, '0.1.0-beta.1+24');
      expect(buildArgsText(beta), contains('--build-name=0.1.0'));
      expect(
        buildArgsText(beta),
        contains('--dart-define=APP_VERSION_NAME=0.1.0-beta.1'),
      );
      expect(
        withVersionArgs(<String>['macos'], beta),
        contains('--build-name=0.1.0'),
      );
    });

    test('一段 / 两段的版本名也认，缺的段不补', () {
      expect(_sampleVersion(versionName: '1.2').bundleVersionName, '1.2');
      expect(_sampleVersion(versionName: '2').bundleVersionName, '2');
      expect(_sampleVersion(versionName: '1.2.3+45').bundleVersionName, '1.2.3');
    });

    test('认不出来的版本名原样用，不凭空造号', () {
      expect(_sampleVersion(versionName: 'dev').bundleVersionName, 'dev');
    });
  });

  group('withVersionArgs（注入时不打架）', () {
    test('用户没传版本参数时全部补上，原有参数顺序不变', () {
      final result = withVersionArgs(
        <String>['macos', '--release'],
        _sampleVersion(),
      );
      expect(result.sublist(0, 2), <String>['macos', '--release']);
      expect(result, contains('--build-name=0.1.0'));
      expect(result, contains('--build-number=24'));
      expect(result, contains('--dart-define=APP_GIT_SHA=852199b'));
      expect(
        result.where((arg) => arg.startsWith('--dart-define=')),
        hasLength(5),
      );
    });

    test('用户自己传了 --build-number 就不再追加（显式值优先）', () {
      final result = withVersionArgs(
        <String>['apk', '--debug', '--build-number=99'],
        _sampleVersion(),
      );
      expect(result, contains('--build-number=99'));
      expect(result.where((arg) => arg.startsWith('--build-number')), hasLength(1));
      // 其它字段照常补。
      expect(result, contains('--build-name=0.1.0'));
    });

    test('--build-number 分两段的写法也认得', () {
      final result = withVersionArgs(
        <String>['macos', '--build-number', '99'],
        _sampleVersion(),
      );
      expect(result.where((arg) => arg == '--build-number'), hasLength(1));
      expect(result, isNot(contains('--build-number=24')));
    });

    test('用户传过的 APP_ dart-define 保留，只补缺的', () {
      final result = withVersionArgs(
        <String>['apk', '--dart-define=APP_GIT_SHA=deadbee'],
        _sampleVersion(),
      );
      expect(result, contains('--dart-define=APP_GIT_SHA=deadbee'));
      expect(result.where((arg) => arg.contains('APP_GIT_SHA')), hasLength(1));
      expect(result, contains('--dart-define=APP_BUILD_NUMBER=24'));
    });

    test('--dart-define NAME=value 分两段的写法也认得', () {
      final result = withVersionArgs(
        <String>['apk', '--dart-define', 'APP_UPDATE_CHANNEL=staging'],
        _sampleVersion(),
      );
      expect(result.where((arg) => arg.contains('APP_UPDATE_CHANNEL')), hasLength(1));
      expect(result, contains('APP_UPDATE_CHANNEL=staging'));
    });
  });

  group('isGitCheckout（容器里的源码拷贝没有 .git）', () {
    test('不是检出时一条 git 命令都不跑：git -C 会向上找到父仓库', () {
      final temp = Directory.systemTemp.createTempSync('version_tool_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      expect(isGitCheckout(temp.path), isFalse);
    });

    test('子模块 / worktree 的 .git 是文件，普通检出是目录，都认', () {
      final temp = Directory.systemTemp.createTempSync('version_tool_test');
      addTearDown(() => temp.deleteSync(recursive: true));

      File('${temp.path}/.git')
          .writeAsStringSync('gitdir: ../.git/modules/mail-app\n');
      expect(isGitCheckout(temp.path), isTrue);

      final plain = Directory('${temp.path}/plain')..createSync();
      Directory('${plain.path}/.git').createSync();
      expect(isGitCheckout(plain.path), isTrue);
    });
  });

  group('参数解析', () {
    test('version：默认 summary；--build-args 与 --format=build-args 等价', () {
      expect(parseVersionCli(const <String>[]).format, 'summary');
      expect(
        parseVersionCli(const <String>['--build-args']).format,
        'build-args',
      );
      expect(
        parseVersionCli(const <String>['--format=build-args']).format,
        'build-args',
      );
      expect(
        parseVersionCli(const <String>['--format', 'json']).format,
        'json',
      );
    });

    test('version：--channel / --repo 两种写法都认', () {
      final cli = parseVersionCli(
        const <String>['--channel=pro', '--repo', '/tmp/checkout'],
      );
      expect(cli.channel, 'pro');
      expect(cli.repo, '/tmp/checkout');
    });

    test('version：不支持的格式 / 拼错的选项直接报错，不静默降级', () {
      expect(
        () => parseVersionCli(const <String>['--format=yaml']),
        throwsFormatException,
      );
      expect(
        () => parseVersionCli(const <String>['--formt=json']),
        throwsFormatException,
      );
    });

    test('build：自己的选项吃掉，其余原样透传', () {
      final cli = parseBuildCli(
        const <String>[
          '--dry-run',
          '--channel=pro',
          'macos',
          '--release',
          '--dart-define=APP_UPDATE_CHANNEL=pro',
        ],
      );
      expect(cli.dryRun, isTrue);
      expect(cli.channel, 'pro');
      expect(cli.flutterArgs, <String>[
        'macos',
        '--release',
        '--dart-define=APP_UPDATE_CHANNEL=pro',
      ]);
    });

    test('build：`--` 之后连长得像我们选项的也透传', () {
      final cli = parseBuildCli(const <String>['macos', '--', '--dry-run']);
      expect(cli.dryRun, isFalse);
      expect(cli.flutterArgs, <String>['macos', '--dry-run']);
    });
  });
}

/// 一个「官方构建」的值：tag 来的 0.1.0 + 24 次提交。
BuildVersion _sampleVersion({
  String versionName = '0.1.0',
  int buildNumber = 24,
  String commit = '852199b',
  DateTime? builtAt,
  String channel = 'public',
  VersionSource versionNameSource = VersionSource.tag,
  VersionSource buildNumberSource = VersionSource.gitCount,
}) =>
    BuildVersion(
      versionName: versionName,
      buildNumber: buildNumber,
      commit: commit,
      builtAt: builtAt ?? DateTime.utc(2026, 11, 2, 2, 39, 46),
      channel: channel,
      versionNameSource: versionNameSource,
      buildNumberSource: buildNumberSource,
    );

VersionContext _context({
  String? tag,
  String? commitCount,
  String? commit,
  bool dirty = false,
  bool shallow = false,
  String? pubspecVersion,
  String? pubspecBuildNumber,
  String? envVersionName,
  String? envBuildNumber,
  String? envCommit,
  String? envBuildTime,
  String? envChannel,
  String? sourceDateEpoch,
  DateTime? now,
}) =>
    VersionContext(
      now: now ?? DateTime.utc(2026, 11, 2, 2, 39, 46),
      tag: tag,
      commitCount: commitCount,
      commit: commit,
      dirty: dirty,
      shallow: shallow,
      pubspecVersion: pubspecVersion,
      pubspecBuildNumber: pubspecBuildNumber,
      envVersionName: envVersionName,
      envBuildNumber: envBuildNumber,
      envCommit: envCommit,
      envBuildTime: envBuildTime,
      envChannel: envChannel,
      sourceDateEpoch: sourceDateEpoch,
    );
