import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';

/// 打开一个外链，返回「到底开没开」。默认实现交给 `url_launcher`。
///
/// 单独抽成一个类型是为了让这块能被测到：`flutter_tester` 里没有
/// `url_launcher` 的平台实现，真调一次那个 method channel，Future **永远
/// 不返回**（不是抛异常 —— 所以 `try/catch` 也接不住）。测试注入一个假的
/// 实现，就能同时钉住「传给按钮的是哪个地址」与「失败时有没有回执」。
typedef UrlOpener = Future<bool> Function(Uri url);

/// 默认实现：一律 `externalApplication` —— Star 要在**用户的浏览器登录态**
/// 里点，App 内嵌 WebView 里没有那个登录态，等于白开。
Future<bool> openInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// 项目公开仓库。App 里每一处「去 GitHub」都取这一份常量：
///
/// - 右栏空白预览页（[NoSelectionPane] 用）；
/// - 「设置 → 关于」页的「开源项目」分组。
///
/// 两处共用同一个字符串，就不会出现「卡片上写一个地址、按钮打开另一个地址」
/// 这种改了半边的错。
class GithubRepo {
  const GithubRepo._();

  /// 仓库地址。带协议，直接交给 [UrlOpener]。
  static const String url = 'https://github.com/zenkeellc/cirro-mail';

  /// 卡片上显示的形式：去掉协议前缀（`github.com/...` 比带协议的短一行，
  /// 阅读区最窄只有 420 宽，省下的每一像素都算数）。
  static String get displayUrl => url.replaceFirst('https://', '');
}

/// 打开仓库页；打不开只弹一条 SnackBar，绝不冒泡。
///
/// 「一键 Star」到底做了什么：GitHub 的 Star 是**登录态下的表单提交**，
/// 客户端拿不到、也不该去要用户的 GitHub 凭据（这个 App 的认证只对自建
/// mail 实例）。所以这里做的是「把用户送到那颗 Star 面前」：系统浏览器打开
/// 仓库页，登录过的账号在页面右上角就能点。
///
/// 打不开外链（桌面端没有默认浏览器、测试环境没有 `url_launcher` 平台实现）
/// 时只弹 SnackBar —— 与「设置 → 关于 → 下载」同一取舍。
Future<void> openGithubRepo(
  BuildContext context, {
  UrlOpener openUrl = openInBrowser,
}) async {
  // 先取好 messenger / 文案：`await` 之后 `context` 可能已经不在树上，
  // 而这两样在 await 前拿到才是安全的。
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = AppLocalizations.of(context);
  var opened = false;
  try {
    opened = await openUrl(Uri.parse(GithubRepo.url));
  } catch (error) {
    // 平台实现缺失 / 系统没浏览器都会走到这里。打不开只是打不开，
    // 不许冒泡把整块界面搞崩。
    debugPrint('打不开仓库页 ${GithubRepo.url}：$error');
  }
  if (opened || !context.mounted) return;
  messenger?.showSnackBar(SnackBar(content: Text(l10n.githubOpenFailed)));
}

/// 仓库卡片：GitHub 标志 + 地址 + 「点个 Star」按钮。
///
/// 整张卡片都可点（地址那一行字太小，只让按钮可点会显得这块东西一半是死的），
/// 按钮是给「看得见的大目标」准备的，两者走同一个回调。调用方负责
/// [onOpen] 里真正做什么（两个落点都走 [openGithubRepo]）。
class GithubStarCard extends StatelessWidget {
  const GithubStarCard({super.key, required this.onOpen});

  /// 点卡片 / 点按钮时执行的动作。
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  GithubMark(size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      GithubRepo.displayUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onOpen,
                icon: const Icon(Icons.star_rounded, size: 18),
                label: Text(AppLocalizations.of(context).starOnGithub),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// GitHub 官方 Mark（octicon `mark-github` 栅格化的 256px 图）。
///
/// 素材本身是**黑色**透明底：浅色主题直接贴没问题，深色主题下就掉进背景里
/// 了。所以统一用 `srcIn` 把整张图染成调用方给的主题色 —— 一张素材，两套
/// 主题都对，不需要另存一份白色版。
class GithubMark extends StatelessWidget {
  const GithubMark({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      child: Image.asset(
        'assets/branding/github-mark.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
    );
  }
}
