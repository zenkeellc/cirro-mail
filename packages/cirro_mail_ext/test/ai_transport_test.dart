// AI 托管通道接缝（`AppExtension.aiTransport` + `AiTransport`）的公开面护栏。
//
// 这一条与 `app_extension_registry_test.dart` 是同一个套路：**接缝对公开版必须
// 是零影响**。所以这里钉住四件事：
//
// 1. 空注册表时 `aiTransport` 是 null —— 公开版没有实现方，核心照旧走 BYOK；
// 2. 注册之后取得到，且多实现之间按**注册顺序取第一个**（一个进程只该有一条
//    托管通道，两条同时生效 = 同一次点击发两份请求、计两份费）；
// 3. 基类默认返回 null（实现方不写这个 getter 时也不能凭空多出一条通道）；
// 4. `AiTransportException.toString` **不带 message** —— message 可能含服务端
//    原文，任何日志/字符串化都不该把它带出去。
import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个只够回答「通道是不是我」的假实现。
class _FakeAiTransport implements AiTransport {
  _FakeAiTransport(this.label, {this.chunks = const <String>['增量']});

  final String label;

  /// `run` 会依次吐出来的文本增量。
  final List<String> chunks;

  int runCalls = 0;

  @override
  String get channelLabel => label;

  @override
  Future<AiChannelState> state() async =>
      const AiChannelState(usable: true, detail: '示例通道可用');

  @override
  Stream<String> run(AiCall call) => Stream<String>.fromIterable(chunks);
}

/// 一个只声明（或不声明）AI 通道的假扩展。
class _FakeExt extends AppExtension {
  _FakeExt(this.id, {this.transport});

  @override
  final String id;

  final AiTransport? transport;

  @override
  AiTransport? get aiTransport => transport;
}

void main() {
  // 单例跨用例存活，每个用例前后都清一次，免得互相串味。
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  group('空注册表 = 公开版既有行为', () {
    test('没有扩展时 aiTransport 是 null', () {
      expect(AppExtensionRegistry.instance.aiTransport, isNull);
    });

    test('扩展不实现这个钩子时也是 null（基类默认）', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[_FakeExt('plain')]);
      expect(AppExtensionRegistry.instance.aiTransport, isNull);
    });
  });

  group('注册之后', () {
    test('取得到实现方给的实例', () {
      final transport = _FakeAiTransport('示例通道');
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_FakeExt('ai', transport: transport)]);
      expect(AppExtensionRegistry.instance.aiTransport, same(transport));
    });

    test('多个扩展都提供时按注册顺序取第一个，后者不覆盖', () {
      final first = _FakeAiTransport('第一条');
      final second = _FakeAiTransport('第二条');
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', transport: first),
        _FakeExt('b', transport: second),
      ]);
      expect(AppExtensionRegistry.instance.aiTransport, same(first));
    });

    test('前面的扩展没提供时继续往后找', () {
      final transport = _FakeAiTransport('示例通道');
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('plain'),
        _FakeExt('ai', transport: transport),
      ]);
      expect(AppExtensionRegistry.instance.aiTransport, same(transport));
    });

    test('reset 之后回到 null', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('ai', transport: _FakeAiTransport('示例通道')),
      ]);
      AppExtensionRegistry.instance.reset();
      expect(AppExtensionRegistry.instance.aiTransport, isNull);
    });
  });

  group('数据形状', () {
    test('AiCall 原样带着任务 id 与入参', () {
      const call = AiCall(
        task: 'rewrite',
        input: <String, Object?>{'selection': '原文', 'tone': 'polish'},
      );
      expect(call.task, 'rewrite');
      expect(call.input, <String, Object?>{
        'selection': '原文',
        'tone': 'polish',
      });
    });

    test('AiChannelState 带着可用性与一句人话', () {
      const state = AiChannelState(usable: false, detail: '设备授权失效，请重新激活');
      expect(state.usable, isFalse);
      expect(state.detail, '设备授权失效，请重新激活');
    });

    test('run 只吐文本增量（实现方的流原样交给核心）', () async {
      final transport = _FakeAiTransport('示例通道', chunks: <String>['你', '好']);
      final parts = await transport.run(
        const AiCall(task: 'rewrite', input: <String, Object?>{}),
      ).toList();
      expect(parts, <String>['你', '好']);
    });
  });

  group('AiTransportException', () {
    test('code 与 message 都保真', () {
      const error = AiTransportException('unauthorized', '设备授权失效，请重新激活');
      expect(error.code, 'unauthorized');
      expect(error.message, '设备授权失效，请重新激活');
    });

    /// **toString 不带 message**：日志、crash reporter、`debugPrint('$e')`
    /// 都会走它，而 message 可能含服务端原文。要文案的地方显式取 `message`。
    test('toString 只留 code，不泄漏 message', () {
      const error = AiTransportException('unauthorized', '含敏感原文的那句话');
      expect(error.toString(), 'AiTransportException(unauthorized)');
      expect(error.toString(), isNot(contains('含敏感原文的那句话')));
    });
  });
}
