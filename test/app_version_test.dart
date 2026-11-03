import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/version/app_version.dart';

void main() {
  group('AppVersion.compareTo / isNewerThan', () {
    test('主体版本按数值比较，不是字符串比较', () {
      expect(
        const AppVersion(name: '0.10.0').isNewerThan(const AppVersion(name: '0.9.9')),
        isTrue,
      );
      expect(
        const AppVersion(name: '1.0.0').isNewerThan(const AppVersion(name: '1.0.0')),
        isFalse,
      );
    });

    test('主体版本相同时，正式版 > 预发布版', () {
      // 渠道标记（tag 上的 `-pro.N`）不会出现在版本名里；这里测的是通用的
      // semver 预发布标识。
      expect(
        const AppVersion(name: '0.1.0').isNewerThan(const AppVersion(name: '0.1.0-beta.1')),
        isTrue,
      );
      expect(
        const AppVersion(name: '0.1.0-beta.1').isNewerThan(const AppVersion(name: '0.1.0')),
        isFalse,
      );
    });

    test('预发布标识按 semver §11 比较：数字标识 < 字母标识，前缀短的更低', () {
      expect(
        const AppVersion(name: '1.0.0-alpha.2')
            .isNewerThan(const AppVersion(name: '1.0.0-alpha.1')),
        isTrue,
      );
      expect(
        const AppVersion(name: '1.0.0-alpha.1')
            .isNewerThan(const AppVersion(name: '1.0.0-alpha')),
        isTrue,
      );
      expect(
        const AppVersion(name: '1.0.0-alpha.beta')
            .isNewerThan(const AppVersion(name: '1.0.0-alpha.9')),
        isTrue,
      );
    });

    test('版本名相同、build 号不同时比 build 号', () {
      expect(
        const AppVersion(name: '0.1.0', buildNumber: 131)
            .isNewerThan(const AppVersion(name: '0.1.0', buildNumber: 130)),
        isTrue,
      );
      // 跨主体版本时 build 号不参与 —— 0.2.0+build1 仍然比 0.1.0+build999 新。
      expect(
        const AppVersion(name: '0.2.0', buildNumber: 1)
            .isNewerThan(const AppVersion(name: '0.1.0', buildNumber: 999)),
        isTrue,
      );
    });

    test('不认识版本名时退回字符串比较，不抛', () {
      final a = const AppVersion(name: 'nightly-a');
      final b = const AppVersion(name: 'nightly-b');
      expect(() => a.compareTo(b), returnsNormally);
      expect(a.isNewerThan(b), isFalse);
      expect(b.isNewerThan(a), isTrue);
    });

    test('未知版本（name 为空）不会把自己判成「有更新」', () {
      expect(AppVersion.unknown.isKnown, isFalse);
      expect(
        AppVersion.unknown.isNewerThan(const AppVersion(name: '0.1.0')),
        isFalse,
      );
    });
  });

  group('AppVersion 显示', () {
    test('display 带 build 号；没有 build 号时只有版本名', () {
      expect(const AppVersion(name: '0.1.0', buildNumber: 131).display, '0.1.0+131');
      expect(const AppVersion(name: '0.1.0').display, '0.1.0');
      expect(AppVersion.unknown.display, '');
    });

    test('coreName 去掉预发布与 build 元数据', () {
      expect(const AppVersion(name: '0.1.0-beta.1').coreName, '0.1.0');
      expect(const AppVersion(name: '1.2.3+45').coreName, '1.2.3');
      // 解析不出来的原样返回，不是空串。
      expect(const AppVersion(name: 'dev').coreName, 'dev');
    });

    test('相等性包含构建元信息', () {
      const a = AppVersion(name: '0.1.0', buildNumber: 5, commit: 'abc');
      const b = AppVersion(name: '0.1.0', buildNumber: 5, commit: 'abc');
      const c = AppVersion(name: '0.1.0', buildNumber: 5, commit: 'def');
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('AppVersion 解析 tag 形状', () {
    test('带 v 前缀的版本名可以比较', () {
      expect(
        const AppVersion(name: 'v0.2.0').isNewerThan(const AppVersion(name: 'v0.1.9')),
        isTrue,
      );
    });

    test('两段版本（0.2 / 0.1.9）补 0 后比较', () {
      expect(
        const AppVersion(name: '0.2').isNewerThan(const AppVersion(name: '0.1.9')),
        isTrue,
      );
    });
  });
}
