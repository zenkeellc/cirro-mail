import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/branding/app_brand.dart';
import '../../../core/update/update_controller.dart';
import '../../../core/update/update_service.dart';
import '../../../core/util/time_utils.dart';
import '../../../core/version/app_version.dart';
import '../../../core/version/version_info.dart';
import '../../../core/widgets/github_star_card.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';

/// 设置 → 关于。
///
/// ## 结构（按**信息字段的逻辑**排，不是按代码先后）
///
/// 整页**一个** `ListView`，顺序固定：
///
/// 1. **产品标识**：产品名 + 版本号那一行（[AppVersion.display]，形如
///    `0.1.0+131`）—— 永远是第一项，用户来这一页最先想知道的就是「我装的
///    是哪个版本」；
/// 2. [AppExtension.aboutExtras] 追加的块 —— 紧跟在主标识之后。它们属于
///    「这个人是谁」这一层（商业版的 logo / 商业版徽章 / 授权归属），
///    所以不塞到技术明细底下；
/// 3. **版本信息**分组：构建号 / 渠道 / 提交 / 构建时间 —— 从「哪个构建」
///    到「从哪来、什么时候打的」，只显示知道的那几项；
/// 4. **更新**分组：检查更新状态 + 自动检查开关（清单地址为空时整组隐藏）；
/// 5. **开源项目**分组：仓库地址 + 「去 GitHub 点个 Star」。卡片与行为跟
///    右栏空白预览页（`NoSelectionPane`）**是同一套**（见
///    `core/widgets/github_star_card.dart`），不是另写一份。
///
/// 扩展块直接铺在同一个 `ListView` 的 children 里，**不要**给它们套滚动容器
/// （见 `AppExtension.aboutExtras` 的约定）。公开版没有扩展，所以这一页在
/// 「2」处什么也不多：主标识在最前，版本明细与更新照旧完整可用。
///
/// ## 为什么这一页不依赖实例状态
///
/// 版本与更新检查都只碰「这个构建」和官网的静态清单，与登录了哪台
/// mail 实例无关 —— 一台实例都没配时，设置页的关于分类照样完整可用。
///
/// ## 版本未知时
///
/// `flutter run` 或某些非官方构建拿不到版本号（[AppVersion.unknown]）：
/// 那一行显示「版本未知」，并隐藏「版本信息」分组；更新检查仍可打开（当前
/// 版本未知时控制器不做新旧判断，见 `UpdateController.check`）。页面不因此
/// 打不开 —— 关于页是兜底信息页，不该成为另一处故障点。
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key, this.openUrl = openInBrowser});

  /// 打开开源仓库那一步。默认系统浏览器（见 [openInBrowser]）；
  /// 测试注入假实现，才能钉住「点下去开的是哪个地址 / 开不成有没有回执」——
  /// `flutter_tester` 里真调一次 `url_launcher` 的 Future **永远不返回**。
  @visibleForTesting
  final UrlOpener openUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final version =
        ref.watch(appVersionProvider).value ?? AppVersion.unknown;
    final service = ref.watch(updateServiceProvider);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        // 主标识那一行**必须在最前**：扩展块再怎么加，也不能把它顶掉。
        _AboutHeader(version: version),
        // 扩展块（商业版标识）紧跟主标识：它们同属「这个产品是谁」这一层。
        // 直接铺在同一个 ListView 里 —— **不要**套滚动容器
        // （见 `AppExtension.aboutExtras` 的约定）。
        ...AppExtensionRegistry.instance.aboutExtras(context),
        if (version.isKnown)
          _AboutGroup(
            key: const ValueKey<String>('about-group-version'),
            title: l10n.aboutGroupVersion,
            children: _versionRows(context, l10n, version),
          ),
        // 清单地址为空（构建期关掉更新检查）时整组隐藏：一个永远失败 /
        // 永远灰着的「检查更新」比没有更糟。
        if (service.isConfigured)
          _AboutGroup(
            key: const ValueKey<String>('about-group-update'),
            title: l10n.aboutGroupUpdate,
            children: const <Widget>[_UpdateSection()],
          ),
        _OpenSourceGroup(openUrl: openUrl),
      ],
    );
  }

  /// 「版本信息」分组的行：构建号 / 渠道 / 提交 / 构建时间。
  ///
  /// 每一项是独立的一行（`ListTile`）：构建号可以单独看，提交 / 构建时间也
  /// 各自能拿来对 bug 报告 —— 拼成一行反而读不出来。缺的那项直接不出现，
  /// 不留「—」占位（`--dart-define` 只传一部分时很常见）。
  ///
  /// 顺序按「我是谁 → 从哪来 → 什么时候打的」：构建号与渠道是**这个构建**
  /// 的身份，提交与构建时间是它的**来源**。
  List<Widget> _versionRows(
    BuildContext context,
    AppLocalizations l10n,
    AppVersion version,
  ) {
    final rows = <Widget>[];
    void add(String key, IconData icon, String label, String value) {
      rows.add(
        ListTile(
          key: ValueKey<String>('about-$key'),
          dense: true,
          leading: Icon(icon, size: 20),
          title: Text(label),
          trailing: Text(value),
        ),
      );
    }

    if (version.buildNumber > 0) {
      add('build', Icons.tag, l10n.versionBuild, '${version.buildNumber}');
    }
    if (version.channel.isNotEmpty) {
      add('channel', Icons.alt_route, l10n.versionChannel, version.channel);
    }
    if (version.commit.isNotEmpty) {
      add('commit', Icons.commit, l10n.versionCommit, version.commit);
    }
    if (version.builtAt != null) {
      add(
        'built-at',
        Icons.schedule,
        l10n.versionBuiltAt,
        TimeUtils.formatDetailTime(version.builtAt),
      );
    }
    return rows;
  }
}

/// 产品标识：App 名 + 版本号。永远排在关于页第一项。
class _AboutHeader extends StatelessWidget {
  const _AboutHeader({required this.version});

  final AppVersion version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey<String>('about-version'),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 产品名走接缝（商业版 `Cirro Mail Pro`），公开版回落 ARB 默认值。
          Text(
            AppBrand.displayName(context),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          // 版本号与标题紧挨着：用户来这一页最先想看的就是「装的是哪个版本」。
          Text(
            version.isKnown
                ? '${l10n.version} ${version.display}'
                : l10n.versionUnknown,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分组小标题。同一页里所有分组共用，字号/留白不会各写各的。
class _AboutGroupHeader extends StatelessWidget {
  const _AboutGroupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 一页里的一个信息分组：小标题 + 一张卡片，卡片里是一组行（行间细分隔线）。
///
/// 分组而不是一长串平铺的 `ListTile`：这一页回答的是几件不同的事
/// （这个构建是什么 / 要不要更新 / 去哪儿给项目点 Star），平铺会让它们看起来
/// 是同一件事的七条参数。
class _AboutGroup extends StatelessWidget {
  const _AboutGroup({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final child in children) {
      if (rows.isNotEmpty) rows.add(const Divider(height: 1));
      rows.add(child);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AboutGroupHeader(title: title),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          elevation: 0,
          color: scheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Column(children: rows),
        ),
      ],
    );
  }
}

/// 「开源项目」分组：一句请求 + 仓库卡片。
///
/// 卡片与「打开失败只弹 SnackBar」的语义都来自
/// `core/widgets/github_star_card.dart` —— 与右栏空白预览页是同一个组件，
/// 不是又写了一遍 GitHub 引导。
class _OpenSourceGroup extends StatelessWidget {
  const _OpenSourceGroup({required this.openUrl});

  final UrlOpener openUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AboutGroupHeader(title: l10n.aboutGroupOpenSource),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            l10n.aboutOpenSourceHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GithubStarCard(
            onOpen: () => openGithubRepo(context, openUrl: openUrl),
          ),
        ),
      ],
    );
  }
}

/// 「更新」分组的内容：状态行 + 自动检查开关。
///
/// 状态完全由 [updateCheckProvider] 驱动；这一块自己不打网络，也不弹提示
/// （启动提示在 `features/update/update_host.dart`）。
class _UpdateSection extends ConsumerWidget {
  const _UpdateSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(updateCheckProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _statusTile(context, ref, l10n, state),
        const Divider(height: 1),
        SwitchListTile(
          key: const ValueKey<String>('about-auto-check'),
          secondary: const Icon(Icons.update_outlined),
          title: Text(l10n.updateAutoCheck),
          // 关掉后仍有手动「检查」—— 版本展示永远在，与本开关无关。
          value: ref.watch(updateCheckEnabledProvider),
          onChanged: (value) =>
              ref.read(updateCheckEnabledProvider.notifier).set(value),
        ),
      ],
    );
  }

  Widget _statusTile(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    UpdateCheckState state,
  ) {
    void check() {
      // 不 await：状态机自己会把 checking → 结果推给界面。
      ref.read(updateCheckProvider.notifier).check();
    }

    switch (state.status) {
      case UpdateCheckStatus.checking:
        return ListTile(
          key: const ValueKey<String>('about-update-status'),
          leading: const Icon(Icons.hourglass_top_outlined),
          title: Text(l10n.checkingForUpdates),
          trailing: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );

      case UpdateCheckStatus.available:
        final release = state.release!;
        // 优先平台直链；该平台没有产物时回退清单的 releaseUrl；
        // 两者都没有就不出现「下载」按钮（只展示更新说明）。
        final url = release.downloadUrlFor(defaultTargetPlatform);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ListTile(
              key: const ValueKey<String>('about-update-status'),
              leading: const Icon(Icons.new_releases_outlined),
              title: Text(l10n.updateAvailable(release.display)),
              // 更新说明是官网负责人写的原文，不翻：翻过的说明与发布页
              // 对不上反而容易误导。
              subtitle: release.notes.isEmpty ? null : Text(release.notes),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () =>
                        ref.read(updateCheckProvider.notifier).dismiss(),
                    child: Text(l10n.updateLater),
                  ),
                  if (url != null) ...<Widget>[
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => _openDownload(context, url),
                      child: Text(l10n.updateDownload),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );

      case UpdateCheckStatus.failed:
        return ListTile(
          key: const ValueKey<String>('about-update-status'),
          leading: const Icon(Icons.error_outline),
          title: Text(l10n.updateCheckFailed),
          // 用户可见的只有「检查失败 + 一句怎么办」；`state.failure` 里的
          // 原始原因（可能是英文的 Dio 错误）只留给诊断/测试，不直接上屏。
          subtitle: Text(
            l10n.updateCheckFailedHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: TextButton(
            onPressed: check,
            child: Text(l10n.updateRetry),
          ),
        );

      case UpdateCheckStatus.upToDate:
        return ListTile(
          key: const ValueKey<String>('about-update-status'),
          leading: const Icon(Icons.check_circle_outline),
          title: Text(l10n.updateUpToDate),
          trailing: TextButton(
            onPressed: check,
            child: Text(l10n.updateCheckNow),
          ),
        );

      case UpdateCheckStatus.idle:
      case UpdateCheckStatus.disabled:
        // disabled 只在「用户关掉了自动检查」时露出（清单地址为空时整组
        // 隐藏），手动检查不受开关影响，所以这一态仍然给按钮。
        return ListTile(
          key: const ValueKey<String>('about-update-status'),
          leading: const Icon(Icons.system_update_alt),
          title: Text(l10n.checkForUpdates),
          trailing: TextButton(
            onPressed: check,
            child: Text(l10n.updateCheckNow),
          ),
        );
    }
  }

  /// 打开下载页 / 安装包。
  ///
  /// 一律 `externalApplication`：安装包要么在系统浏览器里下载，要么直接交给
  /// 浏览器打开发布页，**不在 App 内嵌 WebView**（下载与安装都得走系统）。
  Future<void> _openDownload(BuildContext context, String url) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      // 清单里的地址是不可信输入：拼坏了也只是「打不开」，不许冒泡崩 UI。
      debugPrint('打不开更新下载地址 $url：$error');
    }
    if (opened || !context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.updateOpenFailed)),
    );
  }
}
