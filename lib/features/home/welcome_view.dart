import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/branding/app_brand.dart';
import '../../l10n/app_localizations.dart';
import '../../router.dart';

/// 零实例（全新安装 / 刚把最后一个实例删掉）时**主屏**的样子。
///
/// ## 为什么主屏要有这样一页
///
/// 主屏（`/home`）本来是那张 icon 网格，但**一个实例都没有**时网格上七个
/// 入口全都通向「空列表」—— `HomeMenuScreen` 给它们 `onTap: null`，点下去
/// 什么都不发生。上一版的做法是把零实例的落点钉在设置页、再把底部导航整条
/// 收起：设置页于是成了唯一可达的一页，用户看到的是「停在设置页、回不到
/// 主页面」（2026-11-11 iOS 真机反馈）。死键是没了，**主页面也没了**。
///
/// 现在零实例的主屏就是这一页：说清楚「还没有接入服务器」，给一条最直接的
/// 路（「添加第一个实例」→ 设置页的「实例」那一栏），再把接上之后能做的事
/// 铺成几张卡 —— 用户不配置、不登录也能先看到这个 App 能做什么。底部导航
/// 照常在（见 `AppShell`），所以随时能回这一页。
///
/// ## 为什么「功能亮点」是静态卡
///
/// 它们是**说明**，不是入口：点一张卡并不能在零实例时打开真收件箱（没有
/// 服务器可读）。做成可点的卡片只会再造一批「点了没反应」的按钮。等用户
/// 接上实例之后，这些能力本来就在主屏网格上 —— 那时这一页已经不显示了。
///
/// ## 扩展入口
///
/// 主按钮下面那一行是 [AppExtension.welcomeActions]：账号 / 订阅这类**不依赖
/// 邮件实例**的东西由扩展自己挂（商业版的「登录 Pro 账号」）。公开版（空
/// 注册表）时那一行不存在。
class WelcomeView extends StatelessWidget {
  const WelcomeView({super.key});

  /// 正文最大宽度。与设置页（`SettingsPage.maxWidth`）同一档：一行字横跨
  /// 1400px 会很难读，窄屏本来就没有这个烦恼。
  static const double _maxWidth = 560;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actions = AppExtensionRegistry.instance.welcomeActions(context);

    return Scaffold(
      appBar: AppBar(title: Text(AppBrand.displayName(context))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: <Widget>[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SizedBox(height: 12),
                    // 品牌块：一颗图标 + 标题 + 一句说明。没有插画资源，
                    // 也不该为零实例专门引入一张图 —— 图标 + 文案已经说清
                    // 「这是个邮件 App，只是还没接服务器」。
                    Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.mark_email_unread_outlined,
                          size: 34,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n.welcomeHeadline,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.welcomeBody,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 22),
                    // 主按钮：**唯一**的一级动作 —— 去设置添加第一个实例。
                    //
                    // 走 `go` 而不是 `push`：设置是**另一个分支**（底部导航
                    // 第 1 格），push 到别的分支会叠出第二个状态壳，返回键也
                    // 对不上。用户从设置回来就走底部导航「邮件」那一格。
                    FilledButton.icon(
                      onPressed: () => context.go(Routes.settings),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.addFirstInstance),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                    // 扩展入口（商业版：登录 / 注册 Pro 账号）。排在主按钮
                    // 之后、亮点卡之前 —— 「先把邮件接上」永远是第一眼。
                    for (final action in actions)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: action,
                      ),
                    const SizedBox(height: 10),
                    Text(
                      l10n.welcomeAddInstanceHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      l10n.welcomeFeaturesHeadline,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    _FeatureCard(
                      icon: Icons.all_inbox_outlined,
                      title: l10n.welcomeFeatureInboxTitle,
                      body: l10n.welcomeFeatureInboxBody,
                    ),
                    _FeatureCard(
                      icon: Icons.edit_note_outlined,
                      title: l10n.welcomeFeatureComposeTitle,
                      body: l10n.welcomeFeatureComposeBody,
                    ),
                    _FeatureCard(
                      icon: Icons.notifications_active_outlined,
                      title: l10n.welcomeFeatureNotifyTitle,
                      body: l10n.welcomeFeatureNotifyBody,
                    ),
                    _FeatureCard(
                      icon: Icons.shield_outlined,
                      title: l10n.welcomeFeaturePrivacyTitle,
                      body: l10n.welcomeFeaturePrivacyBody,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一张功能亮点卡：图标 + 标题 + 一句说明，**不可点**（见 [WelcomeView] 的
/// 类文档：它们是说明，不是入口）。
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
