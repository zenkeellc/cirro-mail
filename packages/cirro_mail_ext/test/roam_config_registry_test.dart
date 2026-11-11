import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';

class _Ext extends AppExtension {
  _Ext(this.id, {this.calls, this.fail = false});

  @override
  final String id;
  final List<String>? calls;
  final bool fail;

  @override
  Future<void> onConfigChanged() async {
    calls?.add(id);
    if (fail) throw StateError('boom');
  }
}

class _Host implements RoamConfigHost {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<RoamConfigItem>> exportItems({bool includeSecrets = false}) async =>
      const <RoamConfigItem>[];

  @override
  Future<void> applyItems(List<RoamConfigItem> items) async {}

  @override
  Future<void> deleteItems(List<String> keys) async {}

  @override
  Future<String?> readSecret(String key) async => null;

  @override
  Future<void> writeSecret(String key, String value) async {}
}

void main() {
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  test('host：挂上之前 null；只认第一次', () async {
    final registry = AppExtensionRegistry.instance;
    expect(registry.roamConfigHost, isNull);
    final first = _Host();
    registry.registerRoamConfigHost(first);
    registry.registerRoamConfigHost(_Host());
    expect(registry.roamConfigHost, same(first));
    expect(await registry.roamConfigHostReady, same(first));
  });

  test('notifyConfigChanged 逐个调用，一个抛错不拖累后面的', () async {
    final calls = <String>[];
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _Ext('ext-bad', fail: true),
      _Ext('ext-good', calls: calls),
    ]);
    await AppExtensionRegistry.instance.notifyConfigChanged();
    expect(calls, <String>['ext-good']);
  });

  test('reset 之后 host 也清掉', () {
    final registry = AppExtensionRegistry.instance;
    registry.registerRoamConfigHost(_Host());
    registry.reset();
    expect(registry.roamConfigHost, isNull);
  });

  test('没注册时 roamConfigHostReady 不完成也不抛', () {
    // 公开版没有 host：启动期 await 它只会一直等着，不会抛出来把启动流程打断。
    // 这条盯的是契约本身 —— 别哪天给它加个 `completeError`，也别在 reset 后
    // 顺手 complete(null)。
    expect(AppExtensionRegistry.instance.roamConfigHostReady, doesNotComplete);
  });

  test('reset 换新 Completer：旧 host 不会被新注册的等到', () async {
    final registry = AppExtensionRegistry.instance;
    final old = _Host();
    registry.registerRoamConfigHost(old);
    expect(await registry.roamConfigHostReady, same(old));

    registry.reset();
    final next = _Host();
    registry.registerRoamConfigHost(next);
    // 若 reset 只把 host 置 null、没换 Completer，这里拿到的会是 old。
    expect(await registry.roamConfigHostReady, same(next));
  });
}
