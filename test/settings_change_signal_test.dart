import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/change_signal.dart';

/// [SettingsChangeSignal] 自己的契约。谁在什么时候打枪由各存储的测试管；
/// 这里只钉「信号本身」的三条，免得哪天换成单订阅 / 同步抛异常的实现。
void main() {
  test('广播流：两个订阅者各收到一份', () async {
    final signal = SettingsChangeSignal();
    var first = 0;
    var second = 0;
    final a = signal.changes.listen((_) => first++);
    final b = signal.changes.listen((_) => second++);

    signal.notify();
    await pumpEventQueue();

    expect(first, 1);
    expect(second, 1, reason: '单订阅实现会让第二个订阅方永远收不到');
    await a.cancel();
    await b.cancel();
    await signal.dispose();
  });

  test('没有订阅者时 notify() 不抛', () {
    final signal = SettingsChangeSignal();
    expect(signal.notify, returnsNormally);
    expect(signal.notify, returnsNormally);
  });

  test('dispose() 之后 notify() 静默返回', () async {
    final signal = SettingsChangeSignal();
    await signal.dispose();
    expect(signal.notify, returnsNormally, reason: '晚到的写盘收尾不该炸 App');
  });
}
