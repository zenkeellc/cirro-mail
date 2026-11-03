import 'package:flutter/material.dart';

import '../../core/widgets/github_star_card.dart';
import '../../l10n/app_localizations.dart';

/// 分栏形态下右栏**还没有选中任何邮件**时的那一整块。
///
/// 调用方是 `MailPanes`：它**不默认选中第一封**（那样冷启动一进页面就等于
/// 替用户把最上面那封标成已读），宁可留一块空的，于是这里接手那块空白。
///
/// ## 为什么不再是「选择一封邮件」那一行
///
/// 空白本身说明不了什么。这里放一块「给项目点个 Star」的引导：
/// 一个大号 👍 + 一句夸赞 + 仓库卡片（[GithubStarCard]）。
///
/// 卡片、仓库地址与「打开失败只弹 SnackBar」的语义都在
/// `core/widgets/github_star_card.dart` —— 「设置 → 关于」页的「开源项目」
/// 分组用的是**同一套**：两处不会各写一份地址、各写一份失败回执。
class NoSelectionPane extends StatelessWidget {
  const NoSelectionPane({super.key, this.openUrl = openInBrowser});

  /// 真正打开外链的那一步。默认是系统浏览器（见 [openInBrowser]）；
  /// 测试注入一个假实现，两条分支（开成 / 没开成）才都能钉住 ——
  /// `flutter_tester` 里真调一次 `url_launcher` 会**一直挂着**，
  /// 既不会返回也不会抛（见 [UrlOpener]）。
  @visibleForTesting
  final UrlOpener openUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      // 窗口很矮时（笔记本竖屏分屏）整块要能滚，而不是 `RenderFlex overflow`。
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 大号 👍。用 emoji 而不是 `Icons.thumb_up`：需求要的就是这个
              // 字符本身的表情包质感，图标字体里那颗拇指太「系统控件」了。
              // `height: 1` 是为了不让字体自带的行高把整块往下顶一截。
              const Text('👍', style: TextStyle(fontSize: 64, height: 1)),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context).noSelectionPraise,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              GithubStarCard(
                onOpen: () => openGithubRepo(context, openUrl: openUrl),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
