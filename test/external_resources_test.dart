import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_detail/external_resources.dart';

const _oss = 'https://mail.example.com/api/oss/';

ExternalResource _only(ExternalResourceScan scan, {String? url}) {
  if (url == null) {
    expect(scan.resources, hasLength(1));
    return scan.resources.single;
  }
  return scan.resources.singleWhere((r) => r.url == url);
}

void main() {
  group('scanExternalResources', () {
    test('收集外联图片，带域名与 alt', () {
      final scan = scanExternalResources(
        '<p>hi</p><img src="https://tracker.example.com/p.gif" alt="像素">',
        ossBase: _oss,
      );
      final r = _only(scan, url: 'https://tracker.example.com/p.gif');
      expect(r.kind, ExternalResourceKind.image);
      expect(r.host, 'tracker.example.com');
      expect(r.label, '像素');
      expect(r.canEnable, isTrue);
      expect(scan.domains, 1);
    });

    test('自家 OSS（绝对与相对）不算外联，其它 host 算', () {
      final scan = scanExternalResources(
        '<img src="https://mail.example.com/api/oss/a.png">'
        '<img src="b.png">'
        '<img src="//cdn.other.example/c.png">',
        ossBase: _oss,
      );
      expect(scan.resources, hasLength(1));
      expect(scan.resources.single.host, 'cdn.other.example');
    });

    test('相对地址按 ossBase 解析，无法解析的不收集', () {
      final scan = scanExternalResources(
        '<img src="/x/y.png"><img src="javascript:alert(1)">'
        '<img src="data:image/png;base64,AAAA"><img src="cid:foo">',
        ossBase: _oss,
      );
      // `/x/y.png` 解析到 mail.example.com，属于自家；其余三种不是 http(s)。
      expect(scan.resources, hasLength(0));
    });

    test('行内 style 的 url() 与 background 属性', () {
      final scan = scanExternalResources(
        '<div style="background-image:url(\'https://cdn.example.com/bg.jpg\')">x</div>'
        '<table background="https://cdn.example.com/t.png"><tr><td>x</td></tr></table>',
        ossBase: _oss,
      );
      expect(scan.resources, hasLength(2));
      expect(
        scan.resources.every((r) => r.kind == ExternalResourceKind.cssImage),
        isTrue,
      );
    });

    test('外链样式表、脚本、@import 与 @font-face', () {
      final scan = scanExternalResources(
        '<link rel="stylesheet" href="https://css.example.com/a.css">'
        '<style>'
        '@import "https://css.example.com/imported.css";'
        '@font-face { font-family: x; src: url(https://font.example.com/f.woff2); }'
        'body{background:url(https://img.example.com/style-bg.png)}'
        '</style>'
        '<script src="https://js.example.com/a.js"></script>',
        ossBase: _oss,
      );
      expect(scan.resources, hasLength(5));
      expect(
        scan.resources
            .firstWhere((r) => r.url.endsWith('a.css'))
            .kind,
        ExternalResourceKind.stylesheet,
      );
      expect(
        scan.resources
            .firstWhere((r) => r.url.endsWith('imported.css'))
            .kind,
        ExternalResourceKind.stylesheet,
      );
      expect(
        scan.resources.firstWhere((r) => r.url.endsWith('f.woff2')).kind,
        ExternalResourceKind.font,
      );
      expect(
        scan.resources.firstWhere((r) => r.url.endsWith('a.js')).kind,
        ExternalResourceKind.script,
      );
      // 样式表 / 脚本 / 框架不可启用，这是 Banner 里不给启用按钮的依据。
      expect(
        scan.resources
            .where((r) => r.kind != ExternalResourceKind.cssImage)
            .where((r) => r.kind != ExternalResourceKind.font)
            .every((r) => r.canEnable),
        isFalse,
      );
    });

    test('媒体与 iframe', () {
      final scan = scanExternalResources(
        '<video src="https://v.example.com/a.mp4" poster="https://v.example.com/p.jpg"></video>'
        '<audio src="https://v.example.com/a.mp3"></audio>'
        '<iframe src="https://frame.example.com/x"></iframe>',
        ossBase: _oss,
      );
      expect(scan.resources, hasLength(4));
      expect(
        scan.resources.where((r) => r.kind == ExternalResourceKind.media),
        hasLength(3),
      );
      expect(
        scan.resources.singleWhere((r) => r.kind == ExternalResourceKind.frame),
        isNotNull,
      );
    });

    test('同一 URL 去重但计数，保持首次出现顺序', () {
      final scan = scanExternalResources(
        '<img src="https://b.example.com/1.png">'
        '<img src="https://a.example.com/2.png">'
        '<img src="https://b.example.com/1.png">',
        ossBase: _oss,
      );
      expect(scan.resources, hasLength(2));
      expect(scan.resources.first.host, 'b.example.com');
      expect(scan.resources.first.count, 2);
    });

    test('超深正文不解析，返回空扫描', () {
      final deep = '${'<div>' * 20000}'
          '<img src="https://tracker.example.com/p.gif">'
          '${'</div>' * 20000}';
      expect(scanExternalResources(deep, ossBase: _oss).isEmpty, isTrue);
    });

    test('空输入返回空扫描', () {
      expect(scanExternalResources('', ossBase: _oss).isEmpty, isTrue);
      expect(scanExternalResources('   ', ossBase: _oss).isEmpty, isTrue);
    });
  });

  group('ExternalResourcePolicy', () {
    test('默认拦截外联、放行自家域', () {
      final p = ExternalResourcePolicy(ossBase: _oss);
      expect(p.isBlocked('https://tracker.example.com/p.gif'), isTrue);
      expect(p.isBlocked('https://mail.example.com/api/oss/a.png'), isFalse);
      expect(p.isBlocked('data:image/png;base64,AA'), isFalse);
    });

    test('显式启用的 URL 放行；规范化时忽略 fragment', () {
      final p = ExternalResourcePolicy(ossBase: _oss);
      p.enabled.add(p.normalize('https://tracker.example.com/p.gif#frag'));
      expect(p.isBlocked('https://tracker.example.com/p.gif'), isFalse);
      expect(p.isLoaded('https://tracker.example.com/p.gif'), isTrue);
    });

    test('autoLoad 放行，blockAll 与单项屏蔽优先', () {
      final auto = ExternalResourcePolicy(ossBase: _oss, autoLoad: true);
      expect(auto.isBlocked('https://tracker.example.com/p.gif'), isFalse);

      final blockedOne = ExternalResourcePolicy(
        ossBase: _oss,
        autoLoad: true,
        blocked: <String>{'https://tracker.example.com/p.gif'},
      );
      expect(blockedOne.isBlocked('https://tracker.example.com/p.gif'), isTrue);

      final blockedAll = ExternalResourcePolicy(
        ossBase: _oss,
        autoLoad: true,
        blockAll: true,
      );
      expect(blockedAll.isBlocked('https://tracker.example.com/p.gif'), isTrue);

      // 「逐项显示」优先于 blockAll —— 用户在 Banner 里点单项启用要生效。
      final shownAgain = ExternalResourcePolicy(
        ossBase: _oss,
        autoLoad: true,
        blockAll: true,
        enabled: <String>{'https://tracker.example.com/p.gif'},
      );
      expect(shownAgain.isBlocked('https://tracker.example.com/p.gif'), isFalse);
    });

    test('rewrite 只作用于外联资源', () {
      final p = ExternalResourcePolicy(
        ossBase: _oss,
        rewriteUrl: (url) => 'https://proxy.example/?$url',
      );
      expect(
        p.loadUrl('https://tracker.example.com/p.gif'),
        'https://proxy.example/?https://tracker.example.com/p.gif',
      );
      expect(
        p.loadUrl('https://mail.example.com/api/oss/a.png'),
        'https://mail.example.com/api/oss/a.png',
      );
    });

    test('hostOf 解析相对地址', () {
      final p = ExternalResourcePolicy(ossBase: _oss);
      expect(p.hostOf('/a.png'), 'mail.example.com');
      expect(p.hostOf('https://CDN.Example.com/x'), 'cdn.example.com');
      expect(p.hostOf(''), '');
    });
  });

  group('追踪像素', () {
    test('width/height 属性都是 1 的外链图 = 追踪像素', () {
      final scan = scanExternalResources(
        '<p>hi</p><img src="https://tracker.example.com/p.gif" '
        'width="1" height="1">',
        ossBase: _oss,
      );
      expect(scan.resources.single.trackingPixel, isTrue);
      expect(scan.hasTrackingPixels, isTrue);
      expect(scan.trackingPixelCount, 1);
      expect(scan.trackingPixels.single.host, 'tracker.example.com');
    });

    test('行内 style 写 1×1 也算（带 px / 空格 / 2×2）', () {
      for (final style in <String>[
        'width:1px;height:1px',
        'width: 1px; height: 1px;',
        'WIDTH:2PX;HEIGHT:2PX',
      ]) {
        final scan = scanExternalResources(
          '<img src="https://tracker.example.com/p.gif" style="$style">',
          ossBase: _oss,
        );
        expect(
          scan.hasTrackingPixels,
          isTrue,
          reason: 'style=$style 应被识别为追踪像素',
        );
      }
    });

    test('正常尺寸 / 只读到一个方向 / 读不到尺寸都不误报', () {
      for (final html in <String>[
        '<img src="https://cdn.example.com/a.png" width="600" height="300">',
        '<img src="https://cdn.example.com/a.png" width="1" height="300">',
        '<img src="https://cdn.example.com/a.png" width="300">',
        '<img src="https://cdn.example.com/a.png">',
        '<img src="https://cdn.example.com/a.png" '
            'style="width:100%;height:auto">',
      ]) {
        final scan = scanExternalResources(html, ossBase: _oss);
        expect(scan.hasTrackingPixels, isFalse, reason: html);
      }
    });

    test('同一 URL 先无尺寸、后 1×1：合并后仍要提醒', () {
      final scan = scanExternalResources(
        '<img src="https://tracker.example.com/p.gif">'
        '<img src="https://tracker.example.com/p.gif" width="1" height="1">',
        ossBase: _oss,
      );
      expect(scan.resources, hasLength(1));
      expect(scan.resources.single.count, 2);
      expect(scan.resources.single.trackingPixel, isTrue);
    });

    test('自家 OSS 的 1×1 不列为外联，也不提醒', () {
      final scan = scanExternalResources(
        '<img src="https://mail.example.com/api/oss/p.gif" '
        'width="1" height="1">',
        ossBase: _oss,
      );
      expect(scan.isEmpty, isTrue);
      expect(scan.hasTrackingPixels, isFalse);
    });
  });
}
