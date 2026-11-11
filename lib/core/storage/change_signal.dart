import 'dart:async';

/// 全 App 唯一的「本机配置变了」信号。
///
/// 消费方关心「本机有什么变了」，不是「哪一层改的」：prefs 改签名、drift 多
/// 一台实例、钥匙串写 token 都是同一件事。三条流会逼每个消费方各写一遍
/// merge，漏订阅一条的症状是「某类配置永远不同步」。
///
/// 广播流、无值、没有订阅者时也照常工作。**生产里只允许 `bootstrap()` 建
/// 一份共用实例**（三个存储共用）。不传 signal 的构造会各自拿到私有实例
/// —— 那是测试便利；生产里那样做，写入与订阅永远不在同一条流上。
class SettingsChangeSignal {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  /// 变了。同步、不 await：一次本机配置写入**意图**完成后打一枪（含删除；
  /// 钥匙串写入失败也会打，消费方重读是幂等的）。
  void notify() {
    if (_controller.isClosed) return;
    _controller.add(null);
  }

  Stream<void> get changes => _controller.stream;

  Future<void> dispose() => _controller.close();
}
