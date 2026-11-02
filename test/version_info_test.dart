import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/version/version_info.dart';

/// `composeAppVersion` 是「构建期注入 vs PackageInfo」的**唯一**判据 ——
/// 关于页、窗口标题、更新检查都从它拿值，所以优先级在这里钉死。
void main() {
  group('composeAppVersion', () {
    test('注入值优先于 PackageInfo', () {
      final v = composeAppVersion(
        defineVersion: '0.2.0',
        defineBuild: '131',
        defineCommit: 'abc1234',
        defineBuiltAt: '2026-11-02T02:00:00Z',
        defineChannel: 'public',
        packageVersion: '0.1.0',
        packageBuildNumber: '1',
      );
      expect(v.name, '0.2.0');
      expect(v.buildNumber, 131);
      expect(v.commit, 'abc1234');
      expect(v.builtAt, DateTime.utc(2026, 11, 2, 2));
      expect(v.display, '0.2.0+131');
    });

    test('没有注入值时退回 PackageInfo（直接 flutter run 的情况）', () {
      final v = composeAppVersion(
        defineVersion: '',
        defineBuild: '',
        defineCommit: '',
        defineBuiltAt: '',
        defineChannel: 'public',
        packageVersion: '0.1.0',
        packageBuildNumber: '7',
      );
      expect(v.name, '0.1.0');
      expect(v.buildNumber, 7);
      expect(v.commit, '');
      expect(v.builtAt, isNull);
    });

    test('两边都没有时是未知版本，而不是空 build 号的有效版本', () {
      final v = composeAppVersion(
        defineVersion: '',
        defineBuild: '',
        defineCommit: '',
        defineBuiltAt: '',
        defineChannel: 'public',
      );
      expect(v.isKnown, isFalse);
      expect(v.display, '');
    });

    test('build 号不是数字时按 0 处理，不抛', () {
      final v = composeAppVersion(
        defineVersion: '0.1.0',
        defineBuild: '131-dirty',
        defineCommit: '',
        defineBuiltAt: '',
        defineChannel: 'public',
      );
      expect(v.buildNumber, 0);
      expect(v.display, '0.1.0');
    });

    test('渠道默认 public，注入什么就是什么', () {
      final dflt = composeAppVersion(
        defineVersion: '0.1.0',
        defineBuild: '1',
        defineCommit: '',
        defineBuiltAt: '',
        defineChannel: '',
      );
      expect(dflt.channel, 'public');

      final pro = composeAppVersion(
        defineVersion: '0.1.0-pro.1',
        defineBuild: '9',
        defineCommit: '',
        defineBuiltAt: '',
        defineChannel: 'pro',
      );
      expect(pro.channel, 'pro');
      expect(pro.name, '0.1.0-pro.1');
    });

    test('注入的版本名原样保留（tag 去掉 v 之后可能带 -pro.N）', () {
      final v = composeAppVersion(
        defineVersion: ' 0.1.0-pro.1 ',
        defineBuild: ' 9 ',
        defineCommit: '',
        defineBuiltAt: '',
        defineChannel: 'pro',
      );
      expect(v.name, '0.1.0-pro.1');
      expect(v.buildNumber, 9);
    });
  });

  group('loadAppVersion', () {
    test('PackageInfo 读取失败时静默退回注入值', () async {
      final v = await loadAppVersion(
        packageInfoLoader: () async => throw StateError('no plugin'),
        defineVersion: '0.3.0',
        defineBuild: '42',
        defineCommit: 'cafe123',
        defineBuiltAt: '2026-11-02T00:00:00Z',
        defineChannel: 'pro',
      );
      expect(v.name, '0.3.0');
      expect(v.buildNumber, 42);
      expect(v.channel, 'pro');
    });
  });
}
