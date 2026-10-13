import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// 一次播放的**状态**。
///
/// 不直接把 `audioplayers` 的 `PlayerState` 摊给界面：那个枚举里的
/// `stopped` / `disposed` 对「这个播放条该显示成什么样」没有区别，
/// 而我们还要多一个「放完了」—— 那个在 `audioplayers` 里是**另一个**
/// 事件流（`onPlayerComplete`），不在状态机里。
enum PlaybackState { idle, loading, playing, paused, completed, failed }

/// 播放器这一层往界面暴露的全部东西。
///
/// ## 为什么要抽这一层
///
/// `audioplayers` 是个**插件**：在 `flutter_tester` 里它只有
/// `MissingPluginException`，一个用例都跑不起来。抽出一个只有几个方法的
/// 接口之后，控件层（按钮、进度条、时间、倍速）可以用一个假实现测 ——
/// 而那几个控件恰恰是最容易写错的地方（拖进度条时要不要暂停、放完了
/// 按钮回到什么状态、拖动中位置会不会被流的回调甩回去）。
///
/// 接口刻意做**薄**：只有播放器确实能保证的能力。像「缓冲进度」「音量」
/// 这些不同平台支持程度不一样的东西不进接口 —— 一旦进了，假实现就得
/// 假装它们也这样，测试就变成了在测假装。
abstract interface class AudioPlayback {
  /// 把一个本地文件装进播放器并准备好。失败时抛异常（由调用方转成
  /// [PlaybackState.failed]）。
  Future<void> load(String path);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 倍速。1.0 是原速。
  Future<void> setRate(double rate);

  /// 当前位置的流。约每 200ms 一次。
  Stream<Duration> get positionStream;

  /// 总时长的流。文件头解析出来之后才会发一次。
  Stream<Duration> get durationStream;

  Stream<PlaybackState> get stateStream;

  /// 放完了（自然结束）。
  Stream<void> get completeStream;

  Future<void> dispose();
}

/// [AudioPlayback] 的默认实现：`audioplayers`。
///
/// 不做任何缓存与重试 —— 输入是本机已经落盘的附件，读不到就是读不到。
class AudioplayersPlayback implements AudioPlayback {
  AudioplayersPlayback() : _player = AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> load(String path) async {
    // `DeviceFileSource` 而不是 `UrlSource`：路径是本机缓存里的文件，
    // 走 `setSourceDeviceFile` 那条**不会**经过平台层的 URI 解析，
    // 文件名里的空格与中文也就不会成为一次静默的加载失败。
    //
    // `setReleaseMode(ReleaseMode.stop)`：默认是 `release`，放完一次就把
    // 底层资源放掉，用户再点播放就没声音了。附件预览里「再听一遍」是
    // 常态，所以显式改成保留。
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setSourceDeviceFile(path);
  }

  @override
  Future<void> play() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setPlaybackRate(rate);

  @override
  Stream<Duration> get positionStream => _player.onPositionChanged;

  @override
  Stream<Duration> get durationStream => _player.onDurationChanged;

  @override
  Stream<PlaybackState> get stateStream =>
      _player.onPlayerStateChanged.map(_translate);

  @override
  Stream<void> get completeStream => _player.onPlayerComplete;

  @override
  Future<void> dispose() => _player.dispose();

  /// `audioplayers` 的状态机 → 我们的。
  ///
  /// 只映射**界面看得出来**的那几档：`stopped` 在我们这里与 `idle` 同义
  /// （「没在放、也没有暂停在那儿」），而 `disposed` 永远不会在播放页
  /// 还活着的时候出现（我们 dispose 之后就没人听了）。
  static PlaybackState _translate(PlayerState state) => switch (state) {
        PlayerState.playing => PlaybackState.playing,
        PlayerState.paused => PlaybackState.paused,
        PlayerState.stopped || PlayerState.disposed => PlaybackState.idle,
        // 旧版本里的 `completed`。新版把它挪成了单独的事件流
        // （见 [completeStream]），但枚举值还留着，所以这里两种都要接。
        PlayerState.completed => PlaybackState.completed,
      };
}
