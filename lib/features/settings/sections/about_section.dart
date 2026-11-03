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
import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';

/// 设置 → 关于。
///
/// ## 结构（**不要改变**）
///
/// 整页**一个** `ListView`，顺序固定：
///
/// 1. App 名 + 版本号那一行（[AppVersion.display]，形如 `0.1.0+131`）——
///    永远是第一项；
/// 2. 版本明细（构建号 / 提交 / 构建时间 / 渠道，**只显示知道的那几项**）；
/// 3. 检查更新那一块（有更新时可下载）；
/// 4. [AppExtension.aboutExtras] 追加的块 —— **永远在最后**。
///
/// 扩展块直接铺在同一个 `ListView` 的 children 里，**不要**给它们套滚动容器
/// （见 `AppExtension.aboutExtras` 的约定）。公开版没有扩展，所以这一页在
/// 「2、3」之外与从前保持同样的语义：主标识在最前，扩展只在末尾追加。
///
/// ## 为什么这一页不依赖实例状态
///
/// 版本与更新检查都只碰「这个构建」和官网的静态清单，与登录了哪台
/// mail 实例无关 —— 一台实例都没配时，设置页的关于分类照样完整可用。
///
/// ## 版本未知时
///
/// `flutter run` 或某些非官方构建拿不到版本号（[AppVersion.unknown]）：
/// 那一行显示「版本未知」，并隐藏明细；更新检查仍可打开（当前版本未知时
/// 控制器不做新旧判断，见 `UpdateController.check`）。页面不因此打不开 ——
/// 关于页是兜底信息页，不该成为另一处故障点。
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

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
        _VersionTile(version: version),
        if (version.isKnown) ..._versionDetails(l10n, version),
        // 清单地址为空（构建期关掉更新检查）时整块隐藏：一个永远失败 /
        // 永远灰着的「检查更新」比没有更糟。
        if (service.isConfigured) const _UpdateSection(),
        // 扩展块直接铺在同一个 `ListView` 里 —— **不要**给它们套滚动容器
        // （见 `AppExtension.aboutExtras` 的约定）。
        ...AppExtensionRegistry.instance.aboutExtras(context),
      ],
    );
  }

  /// 版本明细：只显示知道的那几项。
  ///
  /// 每一项是独立的一行（`ListTile`）：构建号可以单独看，提交 / 构建时间也
  /// 各自能拿来对 bug 报告 —— 拼成一行反而读不出来。缺的那项直接不出现，
  /// 不留「—」占位（`--dart-define` 只传一部分时很常见）。
  List<Widget> _versionDetails(AppLocalizations l10n, AppVersion version) {
    final details = <Widget>[];
    void add(String key, String label, String value) {
      details.add(
        ListTile(
          key: ValueKey<String>('about-$key'),
          dense: true,
          leading: const SizedBox(width: 24),
          title: Text(label),
          trailing: Text(value),
        ),
      );
    }

    if (version.buildNumber > 0) {
      add('build', l10n.versionBuild, '${version.buildNumber}');
    }
    if (version.commit.isNotEmpty) {
      add('commit', l10n.versionCommit, version.commit);
    }
    if (version.builtAt != null) {
      add(
        'built-at',
        l10n.versionBuiltAt,
        TimeUtils.formatDetailTime(version.builtAt),
      );
    }
    if (version.channel.isNotEmpty) {
      add('channel', l10n.versionChannel, version.channel);
    }
    return details;
  }
}

/// App 名 + 版本号。永远排在关于页第一项。
class _VersionTile extends StatelessWidget {
  const _VersionTile({required this.version});

  final AppVersion version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      key: const ValueKey<String>('about-version'),
      leading: const Icon(Icons.info_outline),
      // 产品名走接缝（商业版 `Cirro Mail Pro`），公开版回落 ARB 默认值。
      title: Text(AppBrand.displayName(context)),
      // 版本号与标题在同一条里（与从前一致）：用户来这一页最先想看的
      // 就是「我装的是哪个版本」。
      subtitle: Text(
        version.isKnown
            ? '${l10n.version} ${version.display}'
            : l10n.versionUnknown,
      ),
    );
  }
}

/// 「检查更新」那一块：状态行 + 自动检查开关。
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
        // disabled 只在「用户关掉了自动检查」时露出（清单地址为空时整块
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
