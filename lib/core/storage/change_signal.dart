import 'dart:async';

/// 全 App 唯一的「本机配置变了」信号。
///
/// 消费方关心「本机有什么变了」，不是「哪一层改的」：prefs 改签名、drift 多
/// 一台实例、钥匙串写 token 都是同一件事。三条流会逼每个消费方各写一遍
/// merge，漏订阅一条的症状是「某类配置永远不同步」。
///
/// 广播流、无值、没有订阅者时也照常工作。生产代码只有一个实例（`bootstrap()`
/// 里建、三个存储共用）。
class SettingsChangeSignal {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  /// 变了。同步、不 await：调用方都是「写盘成功后顺手打一枪」。
  void notify() {
    if (_controller.isClosed) return;
    _controller.add(null);
  }

  Stream<void> get changes => _controller.stream;

  Future<void> dispose() => _controller.close();
}
