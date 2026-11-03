import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/storage/attachment_launcher.dart';
import '../../l10n/app_localizations.dart';

/// 「另存为」成功后的回执条：一句「存到哪了」+ 两个能让用户马上接着往下走
/// 的动作。
///
/// 为什么不用 `SnackBar.action`：它只挂得下一个动作，而附件存好之后用户想做
/// 的是**并列**的两件事 —— 去文件夹里看一眼（Finder / 资源管理器），或者直接
/// 打开它。少一个就得让用户自己翻「下载」目录去找。
///
/// 两个动作失败都会再弹一条回执（[AppLocalizations.revealFailed] /
/// [AppLocalizations.openFailed]），不静默失败。
///
/// 移动端没有「文件管理器」这个概念（另存为落的是 SAF / 文件 App 的 URI），
/// 所以那边只显示原来那句纯文字回执。
abstract final class AttachmentSavedToast {
  /// [theme] / [l10n] 由调用方在**弹面板之前**取好传进来：
  /// 回执条是在面板 pop 之后弹的，那时候 `context` 已经失效。
  static void show({
    required ScaffoldMessengerState? messenger,
    required AppLocalizations l10n,
    required ThemeData theme,
    required String path,
    required String mimeType,
    TargetPlatform? platform,
  }) {
    if (messenger == null) return;

    if (!_isDesktop) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.savedTo(path))));
      return;
    }

    final target = platform ?? defaultTargetPlatform;
    final actionColor = theme.colorScheme.inversePrimary;

    void fail(String message) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }

    Future<void> reveal() async {
      messenger.hideCurrentSnackBar();
      final ok = await AttachmentLauncher.revealInFileManager(path);
      if (!ok) fail(l10n.revealFailed);
    }

    Future<void> openNow() async {
      messenger.hideCurrentSnackBar();
      final ok = await AttachmentLauncher.open(path, mimeType: mimeType);
      if (!ok) fail(l10n.openFailed);
    }

    messenger.showSnackBar(
      SnackBar(
        // 给用户留够时间：看完那句「存到哪了」再决定点哪个动作。
        duration: const Duration(seconds: 10),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.savedTo(path)),
            const SizedBox(height: 2),
            Wrap(
              spacing: 4,
              children: <Widget>[
                _ToastAction(
                  label: revealLabel(l10n, platform: target),
                  color: actionColor,
                  onPressed: reveal,
                ),
                _ToastAction(
                  label: l10n.openNow,
                  color: actionColor,
                  onPressed: openNow,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「在文件管理器里显示」的文案 —— 桌面三个平台叫法不一样。
  ///
  /// 单独拆出来是为了能纯函数地测（widget 测试里点按钮会真拉起 Finder）。
  static String revealLabel(AppLocalizations l10n, {TargetPlatform? platform}) {
    final target = platform ?? defaultTargetPlatform;
    return switch (target) {
      TargetPlatform.macOS => l10n.revealInFinder,
      TargetPlatform.windows => l10n.revealInExplorer,
      _ => l10n.revealInFileManager,
    };
  }

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
}

class _ToastAction extends StatelessWidget {
  const _ToastAction({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: textTheme.labelLarge,
      ),
      child: Text(label),
    );
  }
}
