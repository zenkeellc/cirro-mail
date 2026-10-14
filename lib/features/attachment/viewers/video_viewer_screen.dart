import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../l10n/app_localizations.dart';

/// 视频附件的播放页。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 这个页面在哪些平台上会真的被打开
///
/// `video_player` 只实现了 Android / iOS / macOS。Windows 与 Linux 上
/// `ViewerSupport.video` 直接返回 false，附件面板里**不会出现「预览」这一行**
/// （见 `attachment_kind.dart`）—— 也就是说这个页面在那两个平台上根本走不到，
/// 用户看到的是「用其他应用打开」。不做「点了再告诉你不行」。
///
/// ## 控件自己做，不用 `VideoProgressIndicator`
///
/// 那个控件把「当前时间 / 总时长 / 拖动」全包了，但它**不能**接收
/// 「要不要显示」之外的定制，而这里的控件是要点一下才出现的（见 [_showControls]）。
/// 自己做只要一个 `Slider` 加两个 `Text`，并且能和音频页的时间格式保持一致。
///
/// ## 点一下切换控件是**全屏范围**的
///
/// 视频区域整个铺一层 `GestureDetector`：能点的地方越大越好，因为用户
/// 想隐藏控件时不会去瞄那个小圆按钮。控件本身要吃掉自己的点击
/// （`AbsorbPointer` 反过来用不了，这里靠控件自己 `onTap` 为空时仍会
/// 拦住事件 —— `IconButton` / `Slider` 都是这样），否则点「暂停」会顺带
/// 把控件一起收起来。
class VideoViewerScreen extends StatefulWidget {
  const VideoViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.embedded = false,
  });

  final String path;
  final String? title;

  /// 嵌在分栏右栏里（附件缓存页宽屏的右栏，见 `attachment_cache_screen.dart` 的 `_AttachmentPreview`），而不是 push 上来的整页。
  /// 差别只有一处：不自己撑 `Scaffold` / `AppBar`。玩家与控件照旧。
  final bool embedded;

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  VideoPlayerController? _controller;

  /// 读不到文件 / 初始化失败 —— 见 [_VideoError]。
  String? _error;

  /// 控件要不要显示。视频没在放的时候自动隐藏（见 [_toggleControls] 的
  /// `Timer`），点一下会立刻显示并重新开始计时。
  bool _showControls = true;

  /// 拖动中的预览位置（松手才 seek）。理由同音频页：不这么做，位置回调
  /// 会把滑块从手指底下拽走。
  bool _dragging = false;
  Duration? _dragTarget;

  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // 与其它 viewer 同一套：读盘与初始化放 `initState` 里会把首帧卡住。
    // 排的是**宏任务**（timer）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onValue);
    // `VideoPlayerController.dispose` 是同步的（`ValueNotifier.dispose`），
    // 底层平台资源由它自己丢掉。
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (LocalFile.length(widget.path) >
        AppDefaults.attachmentPreviewLimit) {
      setState(() => _error = _VideoError.tooLarge);
      return;
    }
    if (!LocalFile.exists(widget.path)) {
      setState(() => _error = _VideoError.gone);
      return;
    }

    final controller = VideoPlayerController.file(File(widget.path));
    try {
      await controller.initialize();
    } catch (_) {
      // 编解码器不支持、文件其实是坏的、平台插件没注册 —— 这里分不出来，
      // 对用户也都是同一句「这个视频放不了」。
      controller.dispose();
      if (mounted) setState(() => _error = _VideoError.failed);
      return;
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    controller.addListener(_onValue);
    setState(() {
      _controller = controller;
      _showControls = true;
    });
    _scheduleHide();
  }

  /// 位置 / 播放状态变了就重建 —— 时间与按钮都跟着 `controller.value` 走。
  void _onValue() {
    if (mounted) setState(() {});
  }

  /// 播放中过几秒自动收起控件；暂停时**不收**（那时候用户正要找按钮）。
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      // 暂停时把控件**钉住**：用户刚点过暂停，多半接着要拖进度。
      _hideTimer?.cancel();
      if (mounted) setState(() => _showControls = true);
    } else {
      // 放完了再点播放：先回到开头，否则平台层会认出「已经在末尾」
      // 而立刻再发一次完成，看起来就是点了没反应（同音频页）。
      if (controller.value.position >= controller.value.duration &&
          controller.value.duration > Duration.zero) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
      _scheduleHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;

    // 黑底是视频区的需要（`_VideoErrorView` 的提示也是浅色），整页与内嵌
    // 都一样 —— 内嵌时那层 `Scaffold` 换成一个 `ColoredBox`。
    final body = error != null
        ? _VideoErrorView(reason: error)
        : _player(l10n);
    if (widget.embedded) {
      return ColoredBox(color: Colors.black, child: body);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      backgroundColor: Colors.black,
      body: body,
    );
  }

  Widget _player(AppLocalizations l10n) {
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final value = controller.value;

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          AspectRatio(
            aspectRatio: value.aspectRatio,
            child: VideoPlayer(controller),
          ),
          // 点谁的空白处都能收放控件 —— 铺满整个视频区域。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
            ),
          ),
          if (_showControls)
            Positioned.fill(
              child: _Controls(
                value: value,
                dragging: _dragging,
                dragTarget: _dragTarget,
                onTogglePlay: () => unawaited(_togglePlay()),
                onScrub: (position) => setState(() {
                  _dragging = true;
                  _dragTarget = position;
                }),
                onScrubEnd: (position) {
                  setState(() {
                    _dragging = false;
                    _dragTarget = null;
                  });
                  unawaited(controller.seekTo(position));
                  _scheduleHide();
                },
                l10n: l10n,
              ),
            ),
        ],
      ),
    );
  }
}

/// 播放控件：底部一层渐变 + 播放键 + 进度条 + 时间。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.value,
    required this.dragging,
    required this.dragTarget,
    required this.onTogglePlay,
    required this.onScrub,
    required this.onScrubEnd,
    required this.l10n,
  });

  final VideoPlayerValue value;
  final bool dragging;
  final Duration? dragTarget;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onScrub;
  final ValueChanged<Duration> onScrubEnd;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final total = value.duration.inMilliseconds;
    final max = total > 0 ? total.toDouble() : 1.0;
    final shown = dragging ? (dragTarget ?? value.position) : value.position;

    // 铺满整层并吞掉点击：底下的 `GestureDetector` 就收不到这一片的事件，
    // 点控件不会顺带把控件收起来。空白处（渐变之外的区域）仍然穿透给下面。
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: <Color>[Color(0xCC000000), Color(0x00000000)],
          stops: <double>[0.0, 0.4],
        ),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onTogglePlay,
                icon: Icon(
                  value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                tooltip: value.isPlaying ? l10n.pause : l10n.play,
              ),
              Text(
                _time(shown),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: shown.inMilliseconds.clamp(0, max.toInt()).toDouble(),
                  max: max,
                  // 时长还没解出来时不给拖（拖一个 0..1 的假区间只会跳到开头）。
                  onChanged: total > 0
                      ? (raw) =>
                          onScrub(Duration(milliseconds: raw.round()))
                      : null,
                  onChangeEnd: (raw) =>
                      onScrubEnd(Duration(milliseconds: raw.round())),
                ),
              ),
              Text(
                _time(value.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `12:34` / `1:02:03`（与音频页同一个写法）。
  static String _time(Duration duration) {
    if (duration <= Duration.zero) return '--:--';
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }
}

abstract final class _VideoError {
  static const String gone = 'gone';
  static const String tooLarge = 'tooLarge';
  static const String failed = 'failed';
}

class _VideoErrorView extends StatelessWidget {
  const _VideoErrorView({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 这一页底色是黑的（视频区域），提示也得是浅色，否则黑底黑字。
    final (icon, text) = switch (reason) {
      _VideoError.tooLarge => (
          Icons.file_present_outlined,
          l10n.previewUnsupported,
        ),
      _VideoError.failed => (Icons.videocam_off_outlined, l10n.videoFailed),
      _ => (Icons.error_outline, l10n.viewerFileGone),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
