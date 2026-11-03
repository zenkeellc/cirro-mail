import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_detail/external_allowlist.dart';

void main() {
  group('normalizeDomainPattern', () {
    test('小写化、去端口/路径/query', () {
      expect(normalizeDomainPattern('Example.COM'), 'example.com');
      expect(
        normalizeDomainPattern('https://cdn.example.com:8443/a/b.png?x=1#h'),
        'cdn.example.com',
      );
      expect(
        normalizeDomainPattern('//cdn.example.com/x.png'),
        'cdn.example.com',
      );
      expect(normalizeDomainPattern('*.Example.com'), '*.example.com');
      expect(normalizeDomainPattern('example.com.'), 'example.com');
      expect(normalizeDomainPattern('  cdn.example.com  '), 'cdn.example.com');
    });

    test('.example.com 按子域名通配处理', () {
      expect(normalizeDomainPattern('.example.com'), '*.example.com');
    });

    test('非法输入返回 null', () {
      for (final raw in <String>[
        '',
        '   ',
        'http://',
        '*',
        '*.*',
        'bad host',
        '例子.中国',
        'a?b',
        'a..b',
        '://x',
      ]) {
        expect(normalizeDomainPattern(raw), isNull, reason: '输入 "$raw" 应该被拒绝');
      }
    });
  });

  group('通配匹配', () {
    test('精确域名只匹配自己', () {
      expect(hostMatchesDomainPattern('example.com', 'example.com'), isTrue);
      expect(hostMatchesDomainPattern('a.example.com', 'example.com'), isFalse);
      expect(
        hostMatchesDomainPattern('badexample.com', 'example.com'),
        isFalse,
      );
    });

    test('leading * 匹配子域名但不含根域名', () {
      expect(
        hostMatchesDomainPattern('a.example.com', '*.example.com'),
        isTrue,
      );
      expect(
        hostMatchesDomainPattern('a.b.example.com', '*.example.com'),
        isTrue,
      );
      expect(hostMatchesDomainPattern('example.com', '*.example.com'), isFalse);
      expect(
        hostMatchesDomainPattern('evil-example.com', '*.example.com'),
        isFalse,
      );
    });

    test('星号匹配任意字符（包括点），大小写不敏感', () {
      expect(
        hostMatchesDomainPattern('img1.example.com', 'img*.example.com'),
        isTrue,
      );
      expect(
        hostMatchesDomainPattern('img.example.com', 'img*.example.com'),
        isTrue,
      );
      expect(
        hostMatchesDomainPattern('other.example.com', 'img*.example.com'),
        isFalse,
      );
      expect(
        hostMatchesDomainPattern('A.Example.COM', '*.example.com'),
        isTrue,
      );
      expect(
        hostMatchesDomainPattern('a.example.com', '*.EXAMPLE.com'),
        isTrue,
      );
    });

    test('IP 字面量按精确串匹配', () {
      expect(hostMatchesDomainPattern('1.2.3.4', '1.2.3.4'), isTrue);
      expect(hostMatchesDomainPattern('1.2.3.5', '1.2.3.4'), isFalse);
      // 通配符对 IP 同样生效（用户自己写 `1.2.3.*` 是明确的）。
      expect(hostMatchesDomainPattern('1.2.3.5', '1.2.3.*'), isTrue);
    });

    test('非法 pattern 永远不命中', () {
      expect(hostMatchesDomainPattern('a.example.com', 'bad host'), isFalse);
      expect(hostMatchesDomainPattern('a.example.com', ''), isFalse);
      expect(hostMatchesDomainPattern('', 'example.com'), isFalse);
    });

    test('hostMatchesAnyDomainPattern 命中任一即可', () {
      expect(
        hostMatchesAnyDomainPattern('img.example.com', <String>[
          'other.com',
          '*.example.com',
        ]),
        isTrue,
      );
      expect(
        hostMatchesAnyDomainPattern('img.example.com', <String>['other.com']),
        isFalse,
      );
    });
  });

  group('DomainAllowList', () {
    test('规范化、去重，保留加入顺序', () {
      final allowList = DomainAllowList(<String>[
        'https://*.Example.com/x',
        '*.example.com',
        'cdn.example.com:443',
        'bad host',
      ]);
      expect(allowList.patterns, <String>['*.example.com', 'cdn.example.com']);
      expect(allowList.length, 2);
      expect(allowList.isEmpty, isFalse);
    });

    test('allows 命中所属组', () {
      final allowList = DomainAllowList(<String>['*.example.com']);
      expect(allowList.allows('a.example.com'), isTrue);
      expect(allowList.allows('A.EXAMPLE.COM'), isTrue);
      expect(allowList.allows('example.com'), isFalse);
      expect(allowList.allows(''), isFalse);
    });

    test('空名单不允许任何 host', () {
      final allowList = DomainAllowList();
      expect(allowList.isEmpty, isTrue);
      expect(allowList.allows('a.example.com'), isFalse);
    });
  });
}
