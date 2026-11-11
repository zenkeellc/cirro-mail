import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import 'external_resources.dart';

/// 正文顶部的「外联资源已拦截」提示条。
///
/// 只负责展示与转发动作；「启用/屏蔽」后要不要重建 HTML 由 `HtmlBodyView`
/// 决定（它会换 `HtmlWidget` 的 key，让整个正文重新解析一遍）。
///
/// ## 一张卡、两行、按需展开
///
/// 2026-11 改版前这里是**两张**各自占满宽度的卡：琥珀色的「外联资源」+ 红色
/// 的「追踪像素」解释。营销邮件几乎每封都带一个 1×1 追踪图，于是读信页
/// 顶部固定被吃掉近 200dp —— 用户还没读到正文，先读了两段安全说明。
///
/// 现在折叠成一张卡：
///
/// - **折叠态**（默认）约 60dp：图标 + 标题 + 一行副标题 + 主操作 / 展开
///   箭头。这是 Material 3 里 `Card`（filled / outlined）的密度，主操作是
///   `TextButton`，展开是带 tooltip 的 `IconButton`（40dp 紧凑密度，指针
///   设备上与全局 `ListTileTheme` 一致）。
/// - **展开态**：原因说明、追踪像素提示、按域名分组的逐条资源才出现。
///   只有用户点了箭头才占版面；`AnimatedSize` 用 M3 的标准 180ms
///   `easeOutCubic` 过渡，避免高度跳变。
///
/// 整张卡可点（`InkWell`）用来展开/收起 —— 箭头是可见的提示，卡片本身是
/// 更大的点击目标；卡里的按钮自己吃掉点击，不会误触。
///
/// ## 追踪像素不再单独成卡
///
/// 「发件人在确认你打开了这封邮件」这件事仍然要说，但**只在两种时候**：
///
/// 1. 用户关掉了「静默过滤 1×1 追踪像素」（设置 → 安全，默认开）：这时
///    追踪像素照旧计数，展开态里有一段完整解释；
/// 2. 追踪像素**已经加载**（用户逐项显示 / 命中白名单 / Pro 自动经代理加载）：
///    这时发件人可能已经拿到打开记录，折叠态就转成错误色，副标题直接写
///    「含 N 个已加载的追踪像素」，展开态还有一段解释。这条**不受开关影响**
///    —— 静默过滤的是「被拦下的噪音」，不是「已经发生的泄漏」。
///
/// 静默模式下如果一封邮件的全部外联资源都是被拦下的 1×1，本组件直接渲染
/// 成空（`SizedBox.shrink`）：没有要提醒的事，就不该占一行。
///
/// ## 警告色，而不是错误色
///
/// 被拦下（还有东西没加载）用琥珀色（[AppTheme.warningContainer]）——「这封
/// 邮件想联网」是**提醒**，不是错误；真正的错误（投递失败、发送失败）用
/// `errorContainer`（红），两者不该长得一样。但**已加载的追踪像素**是例外：
/// 那是已经发生的隐私损失，用错误色。
///
/// 全部放行之后（`blocked == 0`）退回中性底色（M3 `surfaceContainerLow`）
/// —— 没有要提醒的事了，再亮一张警告卡就是喊狼来了。
///
/// ## 资源按域名分组（展开态）
///
/// 营销邮件一封动辄二三十个外链图，平铺一列读不出「它到底连了哪几家」。
/// 列表按域名分组（域名按首次出现顺序），组头是域名 + 条数，组内才是
/// 逐条资源；组头还能「总是显示」—— 直接把域名加进用户白名单，下一封
/// 邮件起不再拦截。
///
/// ## 动作词统一
///
/// 以前「全部启用 / 启用 / 始终允许」三种说法混用，指的是同一件事（放行），
/// 用户看不出差别。现在统一成「显示」一族：
///
/// - 卡片主操作：**显示图片**（= 原来的「全部启用」）；
/// - 展开后单项：**显示**（原「启用」）；
/// - 域名组头：**总是显示**（原「始终允许」，写的是长期白名单）；
/// - 反方向仍是 **屏蔽 / 全部屏蔽**。
///
/// ## 为什么样式表/脚本不给启用按钮
///
/// 邮件里的 `<script>` 从来不会执行（也没地方执行），`<link rel=stylesheet>`
/// 与 `<style>` 的外链 CSS 现有渲染器也应用不了。给一个点了没反应的「启用」
/// 比不给更糟 —— 用户会以为脚本已经跑起来了。因此这几类只列出 URL 与域名，
/// 标记「无法启用」并写明原因。
class ExternalResourceBanner extends StatefulWidget {
  const ExternalResourceBanner({
    super.key,
    required this.resources,
    required this.policy,
    required this.onEnable,
    required this.onBlock,
    required this.onEnableAll,
    required this.onBlockAll,
    this.onAllowHost,
    this.quietTrackingPixels = true,
  });

  final List<ExternalResource> resources;
  final ExternalResourcePolicy policy;

  final void Function(String url) onEnable;
  final void Function(String url) onBlock;
  final VoidCallback onEnableAll;
  final VoidCallback onBlockAll;

  /// 「总是显示这个域名」：把 host 加进用户白名单（见 `external_allowlist.dart`）。
  ///
  /// 为空时组头不出现这个动作 —— 例如 `HtmlBodyView` 的 widget 测试直接构造
  /// Banner，没必要为了一个按钮把设置层拖进来。
  final void Function(String host)? onAllowHost;

  /// 是否静默过滤被拦下的 1×1 追踪像素（设置 → 安全，默认开）。
  ///
  /// 只影响提示，不影响拦截；已加载的追踪像素两边都会提示。
  final bool quietTrackingPixels;

  @override
  State<ExternalResourceBanner> createState() => _ExternalResourceBannerState();
}

/// 提示条的三种语义档位。
enum _BannerTone {
  /// 已放行完，没有要提醒的事 —— M3 中性容器。
  neutral,

  /// 有资源被拦 —— 琥珀色提醒。
  warning,

  /// 追踪像素已经加载 —— 错误色（隐私已经受损，不只是「注意」）。
  error,
}

/// 由 [_BannerTone] 派生的一组颜色。
///
/// 抽出来是因为折叠态、展开态、域名组头都要用同一套；散着 switch 一遍遍
/// 容易某个分支漏掉、某张卡又冒出默认蓝。
class _BannerPalette {
  const _BannerPalette({
    required this.container,
    required this.accent,
    required this.header,
    required this.detail,
    required this.divider,
  });

  final Color container;
  final Color accent;
  final Color header;
  final Color detail;
  final Color divider;
}

class _ExternalResourceBannerState extends State<ExternalResourceBanner> {
  /// 展开态。默认收起 —— 用户打开一封邮件第一眼该看到正文。
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;

    final policy = widget.policy;

    // 追踪像素：quiet 模式下被拦下的那些直接过滤掉。注意 `loadedPixels`
    // 永远保留 —— 「已经加载」的那部分不受静默开关影响。
    final allPixels =
        widget.resources.where((r) => r.trackingPixel).toList(growable: false);
    final loadedPixels = allPixels
        .where((r) => policy.isLoaded(r.url))
        .toList(growable: false);
    final pixels = widget.quietTrackingPixels ? loadedPixels : allPixels;
    final resources = widget.quietTrackingPixels
        ? widget.resources
            .where((r) => !r.trackingPixel || policy.isLoaded(r.url))
            .toList(growable: false)
        : widget.resources;

    // 静默模式下「全是看不见的 1×1」= 没有任何要提醒的事。
    if (resources.isEmpty) return const SizedBox.shrink();

    final groups = groupExternalResourcesByDomain(resources);
    final loaded = resources.where((r) => policy.isLoaded(r.url)).length;
    final blocked = resources.length - loaded;
    final loadableBlocked = resources
        .where((r) => r.canEnable && policy.isBlocked(r.url))
        .length;
    final loadableLoaded = resources
        .where((r) => r.canEnable && policy.isLoaded(r.url))
        .length;
    final loadedPixelCount = loadedPixels.length;

    final tone = loadedPixelCount > 0
        ? _BannerTone.error
        : blocked > 0
            ? _BannerTone.warning
            : _BannerTone.neutral;

    final palette = switch (tone) {
      _BannerTone.error => _BannerPalette(
          container: scheme.errorContainer.withValues(alpha: 0.45),
          accent: scheme.error,
          header: scheme.onErrorContainer,
          detail: scheme.onErrorContainer.withValues(alpha: 0.85),
          divider: scheme.error.withValues(alpha: 0.18),
        ),
      _BannerTone.warning => _BannerPalette(
          container: AppTheme.warningContainer(brightness),
          accent: AppTheme.warningAccent(brightness),
          header: AppTheme.onWarningContainer(brightness),
          detail: AppTheme.onWarningContainer(brightness).withValues(alpha: 0.85),
          divider: AppTheme.warningAccent(brightness).withValues(alpha: 0.35),
        ),
      _BannerTone.neutral => _BannerPalette(
          // Material 3 的 filled card：`surfaceContainerHighest` + 0dp 高度，
          // 不描边。提醒色那两档是自定义语义色，才需要一条边把它从正文里
          // 拎出来。
          container: scheme.surfaceContainerHighest,
          accent: scheme.primary,
          header: scheme.onSurface,
          detail: scheme.onSurfaceVariant,
          divider: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
    };

    final title = blocked > 0
        ? l10n.externalResourcesBlockedTitle(blocked)
        : l10n.externalResourcesEnabledTitle(loaded);

    // 折叠态的第二行：一句话说清「拦了什么」。完整解释在展开态里。
    final supporting = loadedPixelCount > 0
        ? l10n.externalResourcesLoadedTrackingNote(loadedPixelCount)
        : pixels.isEmpty
            ? l10n.externalResourcesDomainCount(groups.length)
            : '${l10n.externalResourcesDomainCount(groups.length)}'
                ' · ${l10n.externalResourcesTrackingCount(pixels.length)}';

    final icon = loadedPixelCount > 0
        ? Icons.visibility_off_outlined
        : blocked > 0
            ? Icons.warning_amber_rounded
            : Icons.verified_user_outlined;

    // 主操作：还有能显示的就「显示图片」，全显示了就只剩「全部屏蔽」。
    final String? primaryLabel;
    final VoidCallback? primaryAction;
    if (loadableBlocked > 0) {
      primaryLabel = l10n.externalResourcesEnableAll;
      primaryAction = widget.onEnableAll;
    } else if (loadableLoaded > 0) {
      primaryLabel = l10n.externalResourcesBlockAll;
      primaryAction = widget.onBlockAll;
    } else {
      primaryLabel = null;
      primaryAction = null;
    }

    final header = Row(
      children: <Widget>[
        Icon(icon, size: 20, color: palette.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: palette.header,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                supporting,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.detail,
                ),
              ),
            ],
          ),
        ),
        if (primaryAction != null)
          TextButton(
            onPressed: primaryAction,
            style: TextButton.styleFrom(
              foregroundColor: palette.accent,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(primaryLabel!),
          ),
        // 视觉 20dp、热区 48dp（IconButton 默认值）：Material 3 要求
        // 图标按钮的最小触摸目标 48×48，`visualDensity.compact` 会把它压到
        // 40 —— 这里不压。
        Semantics(
          expanded: _expanded,
          child: IconButton(
            onPressed: _toggle,
            iconSize: 20,
            tooltip: _expanded
                ? l10n.externalResourcesCollapse
                : l10n.externalResourcesExpand,
            color: palette.detail,
            icon: AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOutCubicEmphasized,
              child: const Icon(Icons.expand_more),
            ),
          ),
        ),
      ],
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (blocked > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 2, 8, 0),
            child: Text(
              l10n.externalResourcesSubtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.detail,
                height: 1.4,
              ),
            ),
          ),
        if (pixels.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 8, 8, 2),
            child: _TrackingPixelNote(pixels: pixels, policy: policy),
          ),
        for (var index = 0; index < groups.length; index++)
          _DomainGroupSection(
            group: groups[index],
            policy: policy,
            palette: palette,
            isLast: index == groups.length - 1,
            onEnable: widget.onEnable,
            onBlock: widget.onBlock,
            onAllowHost: widget.onAllowHost,
          ),
        const SizedBox(height: 4),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: palette.container,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: switch (tone) {
            _BannerTone.error => BorderSide(
                color: scheme.error.withValues(alpha: 0.25),
              ),
            _BannerTone.warning => BorderSide(
                color: palette.accent.withValues(alpha: 0.35),
              ),
            _BannerTone.neutral => BorderSide.none,
          },
        ),
        // 卡面本身**不可点**：Material 3 的 Cards 无障碍规范要求
        // 「An action shouldn't be placed on an actionable surface」——
        // 一整张可点的卡再塞两个按钮，读屏与误触都会出问题。展开只走右侧
        // 那个 48dp 的箭头按钮。
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              header,
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOutCubicEmphasized,
                alignment: Alignment.topCenter,
                child: _expanded ? details : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 展开态里的追踪像素说明块。
///
/// 不再是独立的一张红卡：它只是展开内容的第一块，颜色/圆角跟着内嵌块的
/// 规格走（`errorContainer` 半透明 + 8dp 圆角），外层卡片已经提供了边框。
class _TrackingPixelNote extends StatelessWidget {
  const _TrackingPixelNote({required this.pixels, required this.policy});

  final List<ExternalResource> pixels;
  final ExternalResourcePolicy policy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final domains = pixels.map((p) => p.host).toSet().toList()..sort();
    final separator = Localizations.localeOf(context).languageCode == 'zh'
        ? '、'
        : ', ';
    final shown = domains.take(3).join(separator);
    final more = domains.length > 3 ? ' +${domains.length - 3}' : '';
    final loaded = pixels.where((p) => policy.isLoaded(p.url)).length;

    // 只有**已经加载**的追踪像素才是错误（泄漏已经发生）；仅仅「检测到但
    // 已拦下」属于提醒 —— Material 3 的 error 语义只该给真正的错误状态。
    final brightness = theme.brightness;
    final leaked = loaded > 0;
    final accent = leaked
        ? scheme.error
        : AppTheme.warningAccent(brightness);
    final container = leaked
        ? scheme.errorContainer.withValues(alpha: 0.5)
        : AppTheme.warningContainer(brightness);
    final onContainer = leaked
        ? scheme.onErrorContainer
        : AppTheme.onWarningContainer(brightness);

    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: onContainer,
      height: 1.4,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.visibility_off_outlined,
              size: 16,
              color: accent,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.trackingPixelWarningTitle(pixels.length),
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: onContainer,
                  ),
                ),
                const SizedBox(height: 3),
                Text(l10n.trackingPixelWarningBody, style: bodyStyle),
                const SizedBox(height: 3),
                Text(
                  l10n.trackingPixelWarningDomains('$shown$more'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: bodyStyle?.copyWith(fontSize: 11),
                ),
                if (loaded > 0) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    l10n.trackingPixelWarningLoadedNote(loaded),
                    style: bodyStyle?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  l10n.trackingPixelWarningNote,
                  style: bodyStyle?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 展开列表里的一个域名分组：组头（域名 · 条数 · 总是显示）+ 组内资源行。
class _DomainGroupSection extends StatelessWidget {
  const _DomainGroupSection({
    required this.group,
    required this.policy,
    required this.palette,
    required this.isLast,
    required this.onEnable,
    required this.onBlock,
    required this.onAllowHost,
  });

  final ExternalResourceDomainGroup group;
  final ExternalResourcePolicy policy;
  final _BannerPalette palette;
  final bool isLast;
  final void Function(String url) onEnable;
  final void Function(String url) onBlock;
  final void Function(String host)? onAllowHost;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final allowed = policy.isHostAllowed(group.host);

    final List<Widget> headerActions = <Widget>[
      const SizedBox(width: 6),
      Text(
        l10n.externalResourcesGroupItems(group.count),
        style: theme.textTheme.labelSmall?.copyWith(
          color: palette.header.withValues(alpha: 0.65),
        ),
      ),
      if (allowed)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: _Tag(
            text: l10n.externalResourcesAllowListedTag,
            color: palette.accent,
          ),
        )
      else if (onAllowHost != null)
        Tooltip(
          message: l10n.externalResourcesAllowDomainHint(group.host),
          child: TextButton(
            onPressed: () => onAllowHost!(group.host),
            style: TextButton.styleFrom(
              foregroundColor: palette.accent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(l10n.externalResourcesAllowDomain),
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.language, size: 15, color: palette.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  group.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette.header,
                  ),
                ),
              ),
              ...headerActions,
            ],
          ),
          for (final resource in group.resources)
            Padding(
              padding: const EdgeInsets.only(left: 21),
              child: _ResourceRow(
                resource: resource,
                policy: policy,
                palette: palette,
                onEnable: onEnable,
                onBlock: onBlock,
              ),
            ),
          if (!isLast)
            Divider(
              height: 12,
              thickness: 1,
              color: palette.header.withValues(alpha: 0.12),
            ),
        ],
      ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.resource,
    required this.policy,
    required this.palette,
    required this.onEnable,
    required this.onBlock,
  });

  final ExternalResource resource;
  final ExternalResourcePolicy policy;
  final _BannerPalette palette;
  final void Function(String url) onEnable;
  final void Function(String url) onBlock;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocked = policy.isBlocked(resource.url);
    final proxied = resource.canEnable &&
        policy.isLoaded(resource.url) &&
        policy.loadUrl(resource.url) != resource.url;

    final Widget action;
    if (!resource.canEnable) {
      action = Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Tooltip(
          message: _whyCannotEnable(l10n),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.lock_outline,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                l10n.externalResourcesCannotEnable,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (blocked) {
      action = TextButton(
        onPressed: () => onEnable(resource.url),
        style: TextButton.styleFrom(foregroundColor: palette.accent),
        child: Text(l10n.externalResourcesEnable),
      );
    } else {
      action = TextButton(
        onPressed: () => onBlock(resource.url),
        style: TextButton.styleFrom(foregroundColor: palette.accent),
        child: Text(l10n.externalResourcesBlock),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_icon, size: 16, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        _kindLabel(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (proxied) ...<Widget>[
                      const SizedBox(width: 6),
                      _Tag(text: l10n.externalResourcesViaProxy),
                    ],
                    if (resource.count > 1) ...<Widget>[
                      const SizedBox(width: 6),
                      _Tag(text: '×${resource.count}'),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                // 完整 URL：用户要能判断这是哪家、哪个路径。可选中复制
                // （外层详情页的 SelectionArea 会接管），所以这里用 Text。
                Text(
                  resource.url,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
                if (!resource.canEnable)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _whyCannotEnable(l10n),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.tertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }

  IconData get _icon => switch (resource.kind) {
    ExternalResourceKind.image => Icons.image_outlined,
    ExternalResourceKind.cssImage => Icons.wallpaper_outlined,
    ExternalResourceKind.stylesheet => Icons.style_outlined,
    ExternalResourceKind.script => Icons.code_outlined,
    ExternalResourceKind.media => Icons.videocam_outlined,
    ExternalResourceKind.frame => Icons.web_asset_outlined,
    ExternalResourceKind.font => Icons.font_download_outlined,
  };

  String _kindLabel(AppLocalizations l10n) => switch (resource.kind) {
    ExternalResourceKind.image => l10n.externalResourcesKindImage,
    ExternalResourceKind.cssImage => l10n.externalResourcesKindCssImage,
    ExternalResourceKind.stylesheet => l10n.externalResourcesKindStylesheet,
    ExternalResourceKind.script => l10n.externalResourcesKindScript,
    ExternalResourceKind.media => l10n.externalResourcesKindMedia,
    ExternalResourceKind.frame => l10n.externalResourcesKindFrame,
    ExternalResourceKind.font => l10n.externalResourcesKindFont,
  };

  String _whyCannotEnable(AppLocalizations l10n) => switch (resource.kind) {
    ExternalResourceKind.stylesheet => l10n.externalResourcesStylesheetNote,
    ExternalResourceKind.script => l10n.externalResourcesScriptNote,
    ExternalResourceKind.frame => l10n.externalResourcesFrameNote,
    _ => '',
  };
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.color});

  final String text;

  /// 默认用主色；警告色背景上用 [AppTheme.warningAccent]。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: tint, fontSize: 10),
      ),
    );
  }
}

/// 被拦截图片的占位块 —— 替换掉真正的 `CachedNetworkImage`。
///
/// 尺寸由 fwfh 按 `<img width/height>` 与 CSS 施加，所以这里**不能**假定自己
/// 拿到的是 600px 宽的大图：邮件里大量 16px 图标、1px 追踪像素都会走这里。
/// 空间不够时退化成一个小图标；1×1 由工厂直接返回 `SizedBox.shrink()`，
/// 不会画到版面上。
///
/// ## alt / title 走悬浮层，不进版面
///
/// 被拦下的图看不见内容，`alt`（或 `title`）往往就是唯一能说明「这里原本
/// 是什么」的线索 —— 营销邮件的 CTA 图常把整句文案写在 alt 里。但它**不能**
/// 画进占位块：占位块被 fwfh 压在原图尺寸里，塞一段长文案要么被裁掉，
/// 要么把版式撑开。所以它进 `Tooltip`（桌面悬停、触屏长按）—— 一个**悬浮
/// div**，完全不参与布局。
class BlockedImageTile extends StatelessWidget {
  const BlockedImageTile({
    super.key,
    required this.url,
    required this.host,
    this.label,
  });

  final String url;
  final String host;

  /// 原图的 `alt`，没有则退回 `title`。可空。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final hint = (label ?? '').trim();
    final message = hint.isEmpty ? '$host\n$url' : '$hint\n$host\n$url';

    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 150),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.hasBoundedWidth && constraints.maxWidth < 150;
          final short =
              constraints.hasBoundedHeight && constraints.maxHeight < 44;
          final compact = narrow || short;
          final maxHeight = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : 160.0;

          final Widget child;
          if (compact) {
            final size = maxHeight.clamp(10.0, 18.0);
            child = ClipRect(
              child: OverflowBox(
                maxWidth: size,
                maxHeight: size,
                child: Icon(
                  Icons.image_not_supported_outlined,
                  size: size,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            );
          } else {
            child = Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.image_not_supported_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        l10n.externalResourcesImageBlocked,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        l10n.externalResourcesTapToLoad,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          final tile = ClipRect(
            child: Container(
              constraints: const BoxConstraints(minHeight: 24),
              padding: compact
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: child,
            ),
          );

          // 高度可能是无界的：fwfh 把 `<img>` 放进 `WidgetSpan`（正文 inline
          // 混排）或做表格最小宽度探测时，子 widget 拿到的是「宽度受限、
          // 高度无界」的约束。而 `Container.alignment` 生成的 `Align` 与紧凑
          // 分支里的 `OverflowBox` 都会撑到 `constraints.biggest` —— 无界高度
          // 就变成 Infinity，整帧布局断言（`RenderConstrainedOverflowBox` /
          // `RenderClipRect` … object was given an infinite size during layout）。
          //
          // 占位块本身是**有确定尺寸**的东西（一张图的替身），所以无界时按内容
          // 高度收紧：`IntrinsicHeight` 取子树固有高度（紧凑分支即 `minHeight:
          // 24`，完整分支即三行 labelSmall + 内边距），作为紧约束后 Align /
          // OverflowBox 都不再往外撑。宽度受限、高度有界时（正常渲染路径）行为
          // 完全不变。
          if (constraints.hasBoundedHeight) return tile;
          return IntrinsicHeight(child: tile);
        },
      ),
    );
  }
}
