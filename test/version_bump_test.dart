import 'package:flutter_test/flutter_test.dart';

import '../tool/src/bump_core.dart';
import '../tool/src/cli.dart';

/// `tool/bump.dart` 的规则都压在这组纯函数里，所以这里**不需要真检出**：
/// 用例喂字符串就行。真检出那一条由发布脚本的 `--dry-run` 与实际发版兜。
void main() {
  group('planPubspecBumps：一个文件只有一个作者', () {
    test('不给 --package：根 + 检出里的全部内部包', () {
      final bumps = planPubspecBumps(
        present: {
          'pubspec.yaml',
          'packages/cirro_mail_ext/pubspec.yaml',
          'packages/acme_extra/pubspec.yaml',
        },
        ownedDirs: null,
        versionName: '0.1.10',
        buildNumber: 295,
      );
      expect(bumps.map((bump) => bump.path), [
        'packages/acme_extra/pubspec.yaml',
        'packages/cirro_mail_ext/pubspec.yaml',
        'pubspec.yaml',
      ]);
      final root = bumps.firstWhere((bump) => bump.isRoot);
      expect(root.version, '0.1.10+295');
      for (final bump in bumps.where((bump) => !bump.isRoot)) {
        expect(bump.version, '0.1.10');
      }
    });

    test('--package 只点名商业检出自己的包：共享包留给公开 main 合并', () {
      final bumps = planPubspecBumps(
        present: {
          'pubspec.yaml',
          'packages/cirro_mail_ext/pubspec.yaml',
          'packages/acme_extra/pubspec.yaml',
        },
        ownedDirs: {'packages/acme_extra'},
        versionName: '0.1.10',
        buildNumber: 295,
      );
      expect(bumps.map((bump) => bump.path), [
        'packages/acme_extra/pubspec.yaml',
        'pubspec.yaml',
      ]);
      final extra = bumps.firstWhere((bump) => !bump.isRoot);
      expect(extra.packageName, 'acme_extra');
    });

    test('--package 点名共享包时只写它（公开检出的默认形态）', () {
      final bumps = planPubspecBumps(
        present: {
          'pubspec.yaml',
          'packages/cirro_mail_ext/pubspec.yaml',
          'packages/acme_extra/pubspec.yaml',
        },
        ownedDirs: {'packages/cirro_mail_ext'},
        versionName: '0.2.0',
        buildNumber: 7,
      );
      expect(bumps.map((bump) => bump.path), [
        'packages/cirro_mail_ext/pubspec.yaml',
        'pubspec.yaml',
      ]);
    });

    test('includeRoot=false 时只写内部包（商业检出的发版形态）', () {
      final bumps = planPubspecBumps(
        present: {
          'pubspec.yaml',
          'packages/cirro_mail_ext/pubspec.yaml',
          'packages/acme_extra/pubspec.yaml',
        },
        ownedDirs: {'packages/acme_extra'},
        versionName: '0.1.10',
        buildNumber: 295,
        includeRoot: false,
      );
      // 根 pubspec 不写：它的版本随公开 main 合并过来，在这边改会让每次合并
      // 都在 version 那一行撞车。
      expect(bumps.map((bump) => bump.path), [
        'packages/acme_extra/pubspec.yaml',
      ]);
    });

    test('不存在的文件不凭空发明', () {
      final bumps = planPubspecBumps(
        present: {'pubspec.yaml'},
        ownedDirs: {'packages/acme_extra'},
        versionName: '0.2.0',
        buildNumber: 1,
      );
      expect(bumps.map((bump) => bump.path), ['pubspec.yaml']);
    });

    test('build 号未知时根包只写版本名（不写 +0）', () {
      final bumps = planPubspecBumps(
        present: {'pubspec.yaml'},
        ownedDirs: null,
        versionName: '0.1.10',
        buildNumber: 0,
      );
      expect(bumps.single.version, '0.1.10');
    });

    test('版本名为空直接报错', () {
      expect(
        () => planPubspecBumps(
          present: {'pubspec.yaml'},
          ownedDirs: null,
          versionName: '  ',
          buildNumber: 1,
        ),
        throwsFormatException,
      );
    });
  });

  group('applyPubspecVersion', () {
    test('只换顶层 version 行，其余逐字不动', () {
      const before = '''
name: mail_app
version: 0.1.0+1
description: "x"

environment:
  sdk: '>=3.12.0 <4.0.0'
''';
      final after = applyPubspecVersion(before, '0.1.10+295');
      expect(after, contains('version: 0.1.10+295'));
      expect(after, contains('name: mail_app'));
      expect(after, contains("sdk: '>=3.12.0 <4.0.0'"));
      // 行数不变（只替换一行）。
      expect(after.split('\n').length, before.split('\n').length);
    });

    test('行尾注释保留；引号包住的旧值也能换掉', () {
      final after = applyPubspecVersion('version: "0.1.0+1"  # 基线\n', '0.2.0');
      expect(after, 'version: 0.2.0  # 基线\n');
    });

    test('缩进的同名键与注释行不碰', () {
      final after = applyPubspecVersion(
        '# version: 9.9.9\nversion: 0.1.0+1\n',
        '0.2.0+3',
      );
      expect(after, '# version: 9.9.9\nversion: 0.2.0+3\n');
    });

    test('幂等：已经是目标值时逐字节不变', () {
      const content = 'name: x\nversion: 0.2.0+3\n';
      expect(applyPubspecVersion(content, '0.2.0+3'), content);
    });

    test('没有 version 行时报错（路径传错不该静默跳过）', () {
      expect(
        () => applyPubspecVersion('name: x\ndescription: y\n', '0.2.0'),
        throwsFormatException,
      );
    });

    test('空版本名报错', () {
      expect(
        () => applyPubspecVersion('version: 0.1.0\n', '   '),
        throwsFormatException,
      );
    });
  });

  group('applyLockVersions', () {
    const lock = '''
packages:
  cirro_mail_ext:
    dependency: "direct main"
    description:
      path: "packages/cirro_mail_ext"
      relative: true
    source: path
    version: "0.1.0"
  acme_extra:
    dependency: "direct main"
    description:
      path: "packages/acme_extra"
      relative: true
    source: path
    version: "0.1.0"
  collection:
    dependency: transitive
    description:
      name: collection
      sha256: abc
      url: "https://pub.flutter-io.cn"
    source: hosted
    version: "1.19.1"
sdks:
  dart: ">=3.13.0 <4.0.0"
''';

    test('只改 path 依赖的版本条目，hosted 包原样', () {
      final after = applyLockVersions(lock, {'cirro_mail_ext': '0.1.10'});
      expect(
        after,
        contains('''      path: "packages/cirro_mail_ext"
      relative: true
    source: path
    version: "0.1.10"'''),
      );
      // 没点名的那条 path 依赖不动。
      expect(
        after,
        contains('''      path: "packages/acme_extra"
      relative: true
    source: path
    version: "0.1.0"'''),
      );
      // hosted 包逐字不动。
      expect(after, contains('    version: "1.19.1"'));
      expect(after, contains('sdks:'));
    });

    test('同名但 hosted 的包不碰（版本来源不是我们的 pubspec）', () {
      const hosted = '''
packages:
  cirro_mail_ext:
    dependency: transitive
    description:
      name: cirro_mail_ext
      url: "https://pub.flutter-io.cn"
    source: hosted
    version: "9.9.9"
''';
      final after = applyLockVersions(hosted, {'cirro_mail_ext': '0.1.10'});
      expect(after, hosted);
    });

    test('带 build 元数据的版本照样写成带引号的字符串', () {
      final after = applyLockVersions(lock, {'acme_extra': '0.1.10+295'});
      expect(after, contains('    version: "0.1.10+295"'));
    });

    test('空映射原样返回；没点的包原样返回', () {
      expect(applyLockVersions(lock, const {}), lock);
      expect(applyLockVersions(lock, {'unknown': '1.0.0'}), lock);
    });
  });

  group('computeVersionEdits', () {
    const rootPubspec = 'name: mail_app\nversion: 0.1.0+1\n';
    const extPubspec = 'name: cirro_mail_ext\nversion: 0.1.0\n';
    const lock = '''
packages:
  cirro_mail_ext:
    dependency: "direct main"
    description:
      path: "packages/cirro_mail_ext"
      relative: true
    source: path
    version: "0.1.0"
''';

    List<PubspecBump> bumps({Set<String>? ownedDirs}) => planPubspecBumps(
      present: {'pubspec.yaml', 'packages/cirro_mail_ext/pubspec.yaml'},
      ownedDirs: ownedDirs,
      versionName: '0.1.10',
      buildNumber: 295,
    );

    test('pubspec 与锁文件一起改，只返回真的变了的文件', () {
      final edits = computeVersionEdits(
        bumps: bumps(),
        pubspecContents: {
          'pubspec.yaml': rootPubspec,
          'packages/cirro_mail_ext/pubspec.yaml': extPubspec,
        },
        lockContents: {'pubspec.lock': lock},
      );
      expect(edits.keys.toSet(), {
        'pubspec.yaml',
        'packages/cirro_mail_ext/pubspec.yaml',
        'pubspec.lock',
      });
      expect(edits['pubspec.yaml'], contains('version: 0.1.10+295'));
      expect(
        edits['packages/cirro_mail_ext/pubspec.yaml'],
        contains('version: 0.1.10'),
      );
      expect(edits['pubspec.lock'], contains('    version: "0.1.10"'));
    });

    test('pubspec 已是目标值时只补锁文件那一半', () {
      final edits = computeVersionEdits(
        bumps: bumps(),
        pubspecContents: {
          'pubspec.yaml': 'name: mail_app\nversion: 0.1.10+295\n',
          'packages/cirro_mail_ext/pubspec.yaml':
              'name: cirro_mail_ext\nversion: 0.1.10\n',
        },
        lockContents: {'pubspec.lock': lock},
      );
      expect(edits.keys, ['pubspec.lock']);
    });

    test('全都已经是目标版本时返回空（发布脚本靠它跳过提交）', () {
      const updatedLock = '''
packages:
  cirro_mail_ext:
    dependency: "direct main"
    description:
      path: "packages/cirro_mail_ext"
      relative: true
    source: path
    version: "0.1.10"
''';
      final edits = computeVersionEdits(
        bumps: bumps(),
        pubspecContents: {
          'pubspec.yaml': 'name: mail_app\nversion: 0.1.10+295\n',
          'packages/cirro_mail_ext/pubspec.yaml':
              'name: cirro_mail_ext\nversion: 0.1.10\n',
        },
        lockContents: {'pubspec.lock': updatedLock},
      );
      expect(edits, isEmpty);
    });

    test('文件不在输入里时跳过（而不是抛错）', () {
      final edits = computeVersionEdits(
        bumps: bumps(),
        pubspecContents: {'pubspec.yaml': rootPubspec},
        lockContents: const {},
      );
      expect(edits.keys, ['pubspec.yaml']);
    });

    test('没被 --package 点名的包不进编辑集', () {
      final edits = computeVersionEdits(
        bumps: bumps(ownedDirs: const {'packages/acme_extra'}),
        pubspecContents: {
          'pubspec.yaml': rootPubspec,
          'packages/cirro_mail_ext/pubspec.yaml': extPubspec,
        },
        lockContents: {'pubspec.lock': lock},
      );
      expect(edits.keys, ['pubspec.yaml']);
    });
  });

  group('parseBumpCli', () {
    test('默认值：什么都不给就是「算版本、写当前检出、summary」', () {
      final cli = parseBumpCli(const []);
      expect(cli.version, isNull);
      expect(cli.buildNumber, isNull);
      expect(cli.channel, isNull);
      expect(cli.repo, isNull);
      expect(cli.packages, isEmpty);
      expect(cli.format, 'summary');
      expect(cli.dryRun, isFalse);
      expect(cli.check, isFalse);
      expect(cli.noRoot, isFalse);
      expect(cli.help, isFalse);
    });

    test('= 与空格两种写法都认；build 转成整数；--package 可重复', () {
      final cli = parseBumpCli(const [
        '--version=0.1.10',
        '--build',
        '295',
        '--channel',
        'pro',
        '--repo=/tmp/mail-app-pro',
        '--package=packages/acme_extra',
        '--package',
        'packages/another',
        '--format=paths',
        '--dry-run',
        '--check',
        '--no-root',
      ]);
      expect(cli.version, '0.1.10');
      expect(cli.buildNumber, 295);
      expect(cli.channel, 'pro');
      expect(cli.repo, '/tmp/mail-app-pro');
      expect(cli.packages, ['packages/acme_extra', 'packages/another']);
      expect(cli.format, 'paths');
      expect(cli.dryRun, isTrue);
      expect(cli.check, isTrue);
      expect(cli.noRoot, isTrue);
    });

    test('--help 与拼错的选项', () {
      expect(parseBumpCli(const ['-h']).help, isTrue);
      expect(parseBumpCli(const ['--help']).help, isTrue);
      expect(() => parseBumpCli(const ['--formt=json']), throwsFormatException);
      expect(() => parseBumpCli(const ['--version']), throwsFormatException);
      expect(() => parseBumpCli(const ['--package']), throwsFormatException);
      expect(() => parseBumpCli(const ['bogus']), throwsFormatException);
    });

    test('--build 必须是整数，--format 必须是认得的那个', () {
      expect(() => parseBumpCli(const ['--build=abc']), throwsFormatException);
      expect(() => parseBumpCli(const ['--build=-1']), throwsFormatException);
      expect(
        () => parseBumpCli(const ['--format=yaml']),
        throwsFormatException,
      );
    });
  });
}
