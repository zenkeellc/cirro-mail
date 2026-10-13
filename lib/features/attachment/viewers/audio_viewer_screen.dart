import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../l10n/app_localizations.dart';
import '../audio_playback.dart';

/// 音频附件的播放页。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 播放器是注入的
///
/// [AudioPlayback] 是一个只有几个方法的接口，`audioplayers` 是它的默认实现。
/// 这样做的**唯一**原因是可测：插件在 `flutter_tester` 里只有
/// `MissingPluginException`，不隔一层的话这一页的每一个交互（拖动时暂停、
/// 拖完从哪儿接着放、放完了按钮变回什么样）都没法验。见
/// `audio_playback.dart` 的类注释。
///
/// ## 拖动时不能被位置回调甩回去
///
/// 位置流约每 200ms 推一次。手指按住进度条时如果还让这些回调改
/// `_position`，滑块就会在手指底下自己跳 —— 这是所有自绘进度条都会踩的
/// 一脚。所以拖动期间用一个 [_dragging] 标志把回调挡掉，松手时才 seek。
///
/// ## 失败要说得出来
///
/// Linux 上缺 gstreamer 时，构造播放器或第一次加载就会抛。那不该是一个
/// 静默的「点了没反应」：页面切成一句话 + 提示「用其他应用打开」
/// （后者由附件面板提供，不在这里再放一个按钮）。
class AudioViewerScreen extends StatefulWidget {
  const AudioViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.playerFactory,
  });

  final String path;
  final String? title;

  /// 测试注入用。为空时用 `audioplayers`。
  final AudioPlayback Function()? playerFactory;

  @override
  State<AudioViewerScreen> createState() => _AudioViewerScreenState();
}

class _AudioViewerScreenState extends State<AudioViewerScreen> {
  AudioPlayback? _player;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  PlaybackState _state = PlaybackState.loading;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _rate = 1;

  /// 手指正按在进度条上。见类注释。
  bool _dragging = false;

  /// 拖动过程中的预览位置（松手后才 seek）。
  Duration? _dragTarget;

  /// 读不到文件 / 平台放不了 —— 见 [_error]。
  String? _error;

  /// 倍速档位。
  static const List<double> _rates = <double>[0.5, 1, 1.5, 2];

  @override
  void initState() {
    super.initState();
    // 与其它 viewer 同一套：读盘与加载放 `initState` 里会把首帧卡住。
    // 排的是**宏任务**（timer）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    // dispose 是**异步**的（要等平台层回执），而 `dispose()` 这个回调不能
    // await。丢出去即可 —— 播放器自己会把平台资源收掉。
    unawaited(_player?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _load() async {
    // 音频流式播放不需要把整份读进内存，但「文件在不在、有多大」还是要判：
    // 超限的附件不该走到这个页面（面板那侧已用 `canPreview` 挡过一道）。
    if (LocalFile.length(widget.path) > AppDefaults.attachmentPreviewLimit) {
      setState(() => _error = _AudioError.tooLarge);
      return;
    }
    if (!LocalFile.exists(widget.path)) {
      setState(() => _error = _AudioError.gone);
      return;
    }

    final AudioPlayback player;
    try {
      player = (widget.playerFactory ?? AudioplayersPlayback.new)();
    } catch (_) {
      // 构造就抛（Linux 缺 gstreamer 时就是这样）。
      if (mounted) setState(() => _error = _AudioError.failed);
      return;
    }
    _player = player;

    _subscriptions.addAll(<StreamSubscription<Object?>>[
      player.positionStream.listen((position) {
        if (!mounted) return;
        // 拖动中：别让回调把滑块从手指底下拽走。
        if (_dragging) return;
        setState(() => _position = position);
      }),
      player.durationStream.listen((duration) {
        if (!mounted) return;
        setState(() => _duration = duration);
      }),
      player.stateStream.listen((state) {
        if (!mounted) return;
        setState(() => _state = state);
      }),
      player.completeStream.listen((_) {
        if (!mounted) return;
        // 放完了：位置停在**末尾**而不是跳回 0，再点播放从头开始。
        setState(() {
          _state = PlaybackState.completed;
          _position = _duration;
        });
      }),
    ]);

    try {
      await player.load(widget.path);
      if (!mounted) return;
      setState(() => _state = PlaybackState.paused);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = _AudioError.failed);
    }
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) return;
    try {
      if (_state == PlaybackState.playing) {
        await player.pause();
      } else {
        // 放完之后再点播放：**先回到开头**，否则平台层会认出「已经在末尾」
        // 而立刻再发一次 complete，看起来就是点了没反应。
        if (_state == PlaybackState.completed) {
          await player.seek(Duration.zero);
          if (mounted) setState(() => _position = Duration.zero);
        }
        await player.play();
      }
    } catch (_) {
      if (mounted) setState(() => _error = _AudioError.failed);
    }
  }

  Future<void> _setRate(double rate) async {
    final player = _player;
    if (player == null) return;
    setState(() => _rate = rate);
    try {
      await player.setRate(rate);
    } catch (_) {
      // 个别平台不支持倍速 —— 界面照改（用户按过就是按过），只是不生效。
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: error != null
          ? _AudioErrorView(reason: error)
          : _controls(l10n),
    );
  }

  Widget _controls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final label = widget.title ?? '';
    final total = _duration.inMilliseconds;
    final shown = _dragging ? (_dragTarget ?? _position) : _position;
    // 时长还没解出来时（`durationStream` 还没发第一次）用一个非零的占位，
    // 免得 `Slider` 的 max 为 0 而抛。
    final max = total > 0 ? total.toDouble() : 1.0;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Icon(
                Icons.audiotrack_outlined,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              Slider(
                value: shown.inMilliseconds.clamp(0, max.toInt()).toDouble(),
                max: max,
                // 时长还没解出来时不给拖 —— 拖一个 0..1 的假区间只会跳到开头。
                onChanged: total > 0
                    ? (value) => setState(() {
                          _dragging = true;
                          _dragTarget = Duration(milliseconds: value.round());
                        })
                    : null,
                onChangeEnd: (value) {
                  final target = Duration(milliseconds: value.round());
                  setState(() {
                    _dragging = false;
                    _dragTarget = null;
                    _position = target;
                  });
                  unawaited(_player?.seek(target) ?? Future<void>.value());
                },
              ),
              // 时间在进度条**下面**、左右各一个：拖动时手指正好压着
              // 进度条本身，时间写在它上面会被遮住。
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(_time(shown), style: theme.textTheme.labelSmall),
                  Text(_time(_duration), style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton.filled(
                    iconSize: 36,
                    onPressed: _state == PlaybackState.loading ? null : _toggle,
                    icon: Icon(
                      _state == PlaybackState.playing
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    tooltip: _state == PlaybackState.playing
                        ? l10n.pause
                        : l10n.play,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _RatePicker(
                rates: _rates,
                selected: _rate,
                onSelect: (rate) => unawaited(_setRate(rate)),
                label: l10n.playbackRate,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `12:34` / `1:02:03`。时长未知时给 `--:--`，比 `0:00` 诚实。
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

/// 倍速选择。
class _RatePicker extends StatelessWidget {
  const _RatePicker({
    required this.rates,
    required this.selected,
    required this.onSelect,
    required this.label,
  });

  final List<double> rates;
  final double selected;
  final ValueChanged<double> onSelect;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        for (final rate in rates)
          ChoiceChip(
            label: Text('${rate}x'),
            labelStyle: theme.textTheme.labelSmall,
            selected: rate == selected,
            onSelected: (_) => onSelect(rate),
          ),
      ],
    );
  }
}

abstract final class _AudioError {
  static const String gone = 'gone';
  static const String tooLarge = 'tooLarge';
  static const String failed = 'failed';
}

class _AudioErrorView extends StatelessWidget {
  const _AudioErrorView({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (icon, text) = switch (reason) {
      _AudioError.tooLarge => (
          Icons.file_present_outlined,
          l10n.previewUnsupported,
        ),
      // 「放不了」和「文件不在了」是两回事：前者要用其他应用打开（文件好着呢），
      // 后者要重新下载。
      _AudioError.failed => (Icons.volume_off_outlined, l10n.audioFailed),
      _ => (Icons.error_outline, l10n.viewerFileGone),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
