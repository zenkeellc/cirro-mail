import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'external_resources.dart';

/// 正文顶部的「外联资源已拦截」Banner。
///
/// 只负责展示与转发动作；「启用/屏蔽」后要不要重建 HTML 由 `HtmlBodyView`
/// 决定（它会换 `HtmlWidget` 的 key，让整个正文重新解析一遍）。
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
  });

  final List<ExternalResource> resources;
  final ExternalResourcePolicy policy;

  final void Function(String url) onEnable;
  final void Function(String url) onBlock;
  final VoidCallback onEnableAll;
  final VoidCallback onBlockAll;

  @override
  State<ExternalResourceBanner> createState() => _ExternalResourceBannerState();
}

class _ExternalResourceBannerState extends State<ExternalResourceBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final resources = widget.resources;
    final policy = widget.policy;
    final loaded = resources.where((r) => policy.isLoaded(r.url)).length;
    final blocked = resources.length - loaded;
    final loadableBlocked = resources
        .where((r) => r.canEnable && policy.isBlocked(r.url))
        .length;
    final loadableLoaded = resources
        .where((r) => r.canEnable && policy.isLoaded(r.url))
        .length;

    final title = blocked > 0
        ? l10n.externalResourcesBlockedTitle(blocked)
        : l10n.externalResourcesEnabledTitle(loaded);

    final details = <String>[
      l10n.externalResourcesDomainCount(_domains()),
      if (blocked > 0)
        l10n.externalResourcesSubtitle
      else if (policy.rewriteUrl != null)
        l10n.externalResourcesProxyHint,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    blocked > 0
                        ? Icons.shield_outlined
                        : Icons.verified_user_outlined,
                    size: 18,
                    color: blocked > 0 ? scheme.tertiary : scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          details.join(' · '),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        if (blocked > 0 &&
                            policy.rewriteUrl != null &&
                            loadableBlocked > 0) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            l10n.externalResourcesProxyHint,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.primary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (loadableBlocked > 0)
                    TextButton(
                      onPressed: widget.onEnableAll,
                      child: Text(l10n.externalResourcesEnableAll),
                    )
                  else if (loadableLoaded > 0)
                    TextButton(
                      onPressed: widget.onBlockAll,
                      child: Text(l10n.externalResourcesBlockAll),
                    ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(
                    _expanded
                        ? l10n.externalResourcesHideList
                        : l10n.externalResourcesShowList(resources.length),
                  ),
                ),
              ),
              if (_expanded)
                for (final resource in resources)
                  _ResourceRow(
                    resource: resource,
                    policy: policy,
                    onEnable: widget.onEnable,
                    onBlock: widget.onBlock,
                  ),
            ],
          ),
        ),
      ),
    );
  }

  int _domains() => widget.resources.map((r) => r.host).toSet().length;
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.resource,
    required this.policy,
    required this.onEnable,
    required this.onBlock,
  });

  final ExternalResource resource;
  final ExternalResourcePolicy policy;
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
              Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                l10n.externalResourcesCannotEnable,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    } else if (blocked) {
      action = TextButton(
        onPressed: () => onEnable(resource.url),
        child: Text(l10n.externalResourcesEnable),
      );
    } else {
      action = TextButton(
        onPressed: () => onBlock(resource.url),
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
                        '${_kindLabel(l10n)} · ${resource.host}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurface),
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
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.tertiary),
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
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.primary, fontSize: 10),
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
class BlockedImageTile extends StatelessWidget {
  const BlockedImageTile({
    super.key,
    required this.url,
    required this.host,
  });

  final String url;
  final String host;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Tooltip(
      message: '$host\n$url',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.hasBoundedWidth &&
              constraints.maxWidth < 150;
          final short = constraints.hasBoundedHeight &&
              constraints.maxHeight < 44;
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
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        l10n.externalResourcesTapToLoad,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          return ClipRect(
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
        },
      ),
    );
  }
}

/// 「检测到追踪像素」额外警告条。
///
/// 这是**独立于** [ExternalResourceBanner] 的第二张卡，因为它说的是另一件
/// 事：资源 Banner 讲「有东西要被加载」，这张卡讲「发件人在试图确认你打开了
/// 邮件」。即使像素已被默认拦截，这个意图本身也值得告诉用户 —— 用户据此
/// 才会对「要不要点启用」做出知情决定。
///
/// 只统计 `ExternalResource.trackingPixel` 为 true 的资源：外链 `<img>` 与
/// 1×1 元素上的背景图。尺寸来自 HTML 属性、行内 style 或 `<style>` 里的
/// class/id 规则；只读到一个方向且 ≤ 2 也算（见扫描器里的说明）。
class TrackingPixelWarning extends StatelessWidget {
  const TrackingPixelWarning({
    super.key,
    required this.pixels,
    required this.policy,
  });

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

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.visibility_off_outlined,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.trackingPixelWarningTitle(pixels.length),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.trackingPixelWarningBody,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.trackingPixelWarningDomains('$shown$more'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontSize: 11,
                      ),
                    ),
                    if (loaded > 0) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        l10n.trackingPixelWarningLoadedNote(loaded),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      l10n.trackingPixelWarningNote,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer.withValues(alpha: 0.85),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
