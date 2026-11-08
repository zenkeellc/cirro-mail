// `ThemePack` 接缝的最小契约：默认实现不画背板、注册表按 id 去重、空注册表
// 恒为空。这三条是「公开版零影响」与「选择指向确定的一套」的根，改坏了 UI
// 上看不出来、只有用户的选择会莫名失效。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Pack extends ThemePack {
  const _Pack(this.id);

  @override
  final String id;

  @override
  String name(Locale locale) => id;

  @override
  ThemeData build(Brightness brightness) =>
      ThemeData(brightness: brightness);
}

class _Ext extends AppExtension {
  const _Ext(this.id, this.packs);

  @override
  final String id;

  final List<ThemePack> packs;

  @override
  List<ThemePack> themes() => packs;
}

void main() {
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  test('默认实现：没有分组名、不画背板', () {
    const pack = _Pack('x');
    expect(pack.family(const Locale('zh')), '');
    expect(pack.buildBackdrop(_FakeContext()), isNull);
    expect(pack.toString(), 'ThemePack(x)');
  });

  test('空注册表：主题包列表为空（公开版）', () {
    expect(AppExtensionRegistry.instance.themePacks(), isEmpty);
  });

  test('多个扩展的主题按注册顺序拼平', () {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      const _Ext('a', <ThemePack>[_Pack('one'), _Pack('two')]),
      const _Ext('b', <ThemePack>[_Pack('three')]),
    ]);
    expect(
      AppExtensionRegistry.instance.themePacks().map((p) => p.id).toList(),
      <String>['one', 'two', 'three'],
    );
  });

  test('id 撞车保留第一个（prefs 里那份选择要指向确定的一套）', () {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      const _Ext('a', <ThemePack>[_Pack('same')]),
      const _Ext('b', <ThemePack>[_Pack('same'), _Pack('other')]),
    ]);
    final packs = AppExtensionRegistry.instance.themePacks();
    expect(packs.map((p) => p.id).toList(), <String>['same', 'other']);
    expect(identical(packs.first, packs.last), isFalse);
  });
}

/// `buildBackdrop` 的默认实现不碰 context；给它一个占位实现即可。
class _FakeContext extends Fake implements BuildContext {}
