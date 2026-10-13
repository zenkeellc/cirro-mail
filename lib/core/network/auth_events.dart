import 'dart:async';

/// 401 的单一出口。拦截器只负责广播，谁该跳登录由 router 决定。
///
/// 事件带 `profileId`：多实例下一个实例的 token 失效不应该影响其他实例。
class AuthExpiredEvent {
  const AuthExpiredEvent({required this.profileId, required this.message});

  final String profileId;
  final String message;
}

class AuthEvents {
  AuthEvents();

  final StreamController<AuthExpiredEvent> _controller =
      StreamController<AuthExpiredEvent>.broadcast();

  Stream<AuthExpiredEvent> get stream => _controller.stream;

  void emitAuthExpired({required String profileId, required String message}) {
    if (_controller.isClosed) return;
    _controller.add(AuthExpiredEvent(profileId: profileId, message: message));
  }

  Future<void> dispose() => _controller.close();
}
