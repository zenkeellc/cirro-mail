import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/breakpoints.dart';
import '../../l10n/app_localizations.dart';
import '../mail_list/mail_panes.dart' show PaneHeader;
import '../shell/nav_sidebar.dart' show NavSidebarItem;
import 'sections/about_section.dart';
import 'sections/ai_section.dart';
import 'sections/appearance_section.dart';
import 'sections/compose_section.dart';
import 'sections/diagnostics_section.dart';
import 'sections/instances_section.dart';
import 'sections/mailboxes_section.dart';
import 'sections/polling_section.dart';
import 'sections/push_section.dart';

/// 设置的九个分类。
///
/// 顺序即分类栏里的顺序，也是窄屏列表里的顺序。分工按「用户要解决什么事」
/// 排，不按代码怎么放：**实例**（我在连哪几台）/ **轮询**（多久收一次、
/// 发信能后悔多久、要不要提醒）/ **外观** / **写邮件**（写信时要用的签名与
/// 常用语）/ **AI** / **推送**（App 不在时怎么收到提醒）/ **诊断**（出问题了）/
/// **关于**。
///
/// **邮箱**排在实例之后：实例是「一台服务器」，邮箱是「那台服务器下面的
/// 一个地址」，两者是同一件事的两个层级，挨着最顺（网页端也把它做成独立
/// 一栏）。写邮件 / 外观 / AI 那些与「我有哪几个地址」无关。
///
/// 推送从「轮询」那一组里**独立出来**：它们回答的是两件事 —— 轮询管
/// 「App 在的时候」，推送管「App 不在的时候」，以前挤在一组里，用户得
/// 点开才知道自己要看的是哪一个。
///
/// 「写邮件」排在「外观」之后：签名与常用语是**写信这件事本身**的一部分，
/// 与调色板那种纯表现层的东西并列；而 AI 是「帮忙写」，是外加的助力，
/// 所以排在它后面。
enum SettingsCategory {
  instances,
  mailboxes,
  polling,
  appearance,
  compose,
  ai,
  push,
  diagnostics,
  about;

  /// 分类栏与窄屏列表里显示的名字。
  ///
  /// 推送用 `pushShort`（「推送」）而不是 `pushTitle`（「后台推送（FCM）」）：
  /// 分类栏只有 [Breakpoints.settingsRailWidth] 宽，后者会挤爆。分类**页内**
  /// 的标题仍然用长的那个。
  String label(AppLocalizations l10n) => switch (this) {
        SettingsCategory.instances => l10n.instances,
        // 分类栏只有 `Breakpoints.settingsRailWidth` 宽，用短名字 `mailbox`
        // （「邮箱」）；分类**页内**的标题用长的 `mailboxTitle`，
        // 与「推送」那条完全同一个理由。
        SettingsCategory.mailboxes => l10n.mailbox,
        SettingsCategory.polling => l10n.polling,
        SettingsCategory.appearance => l10n.appearance,
        SettingsCategory.compose => l10n.compose,
        SettingsCategory.ai => l10n.aiTitle,
        SettingsCategory.push => l10n.pushShort,
        SettingsCategory.diagnostics => l10n.diagnostics,
        SettingsCategory.about => l10n.about,
      };

  IconData get icon => switch (this) {
        SettingsCategory.instances => Icons.dns_outlined,
        // 与侧栏邮箱行（`SidebarMailboxRow` 的默认 icon）同一颗字形 ——
        // 视觉上直接指认「这就是邮箱」。
        SettingsCategory.mailboxes => Icons.alternate_email_outlined,
        SettingsCategory.polling => Icons.schedule_outlined,
        SettingsCategory.appearance => Icons.palette_outlined,
        SettingsCategory.compose => Icons.edit_note_outlined,
        SettingsCategory.ai => Icons.auto_awesome_outlined,
        SettingsCategory.push => Icons.notifications_active_outlined,
        SettingsCategory.diagnostics => Icons.monitor_heart_outlined,
        SettingsCategory.about => Icons.info_outline,
      };

  IconData get selectedIcon => switch (this) {
        SettingsCategory.instances => Icons.dns,
        SettingsCategory.mailboxes => Icons.alternate_email,
        SettingsCategory.polling => Icons.schedule,
        SettingsCategory.appearance => Icons.palette,
        SettingsCategory.compose => Icons.edit_note,
        SettingsCategory.ai => Icons.auto_awesome,
        SettingsCategory.push => Icons.notifications_active,
        SettingsCategory.diagnostics => Icons.monitor_heart,
        SettingsCategory.about => Icons.info,
      };
}

/// 设置页。
///
/// ## 两种形态
///
/// - **宽屏（>= 1024）**：左栏是**固定宽度**的分类菜单（常驻），右栏是选中
///   分类的设置内容。与收件箱 / 发件箱 / 附件缓存同一个两栏形状，只是这条
///   左栏不让拖 —— 它是菜单不是列表。
/// - **窄屏**：先是一张**分类列表**（九个入口），点一个进分类页（`AppBar`
///   带返回箭头，系统返回键也退回列表）。
///
/// 判据是**窗口宽度**（[Breakpoints.panesOf]），跟着窗口走 —— 拖宽拖窄当场
/// 换形态，与收件箱那一套同口径。
///
/// ## 为什么分类切换不改地址、不压栈
///
/// 九个分类是**一页之内的内部翻页**。做成九条路由（窄屏点一个 push 一层、
/// 宽屏选中态进 URL）有两个代价，而收益只有一个「地址能分享」：
///
/// - 宽屏下每一次切换都会重建那一页，AI 里敲了一半的地址、推送向导翻到第 ⑤
///   页，全丢；
/// - 窄屏的返回键语义要分两层说（分类页退分类列表、分类列表退上一支），
///   而 `.go` 与 `.push` 混用时这层语义很容易错。
///
/// 深链那一头没有丢：`/settings/ai`、`/settings/push`、`/settings/diagnostics`
/// 三条旧地址仍然在（`router.dart` 里重定向到 `/settings`）—— 因为它们曾经
/// 是三个独立整页，外面可能有人存过。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  SettingsCategory _selected = SettingsCategory.instances;

  /// 窄屏下「用户已经点进某个分类了没有」。
  ///
  /// 宽屏不用它（分类栏常驻）。拖宽再拖窄会保留它 —— 于是「点进外观 → 拖宽
  /// 看两列 → 拖回来」仍然停在外观，不会莫名退回分类列表。
  bool _opened = false;

  /// **已经构造过**的分类。
  ///
  /// 宽屏右栏用 `IndexedStack` 把构造过的分类留着（切走再切回来，草稿还在），
  /// 但**不一次把九个都建出来**：`PushSection` 一构造就会去读钥匙串、打中转端
  /// 的 `/devices`、还可能自动登记一次设备（见它的 `_load` / `_maybeAutoRegister`）。
  /// 只想改个主题的用户不该因此被发一轮推送请求。
  ///
  /// **初值就是 [_selected] 那一个**：宽屏一进来 `_selected` 已经是「实例」，
  /// 它必须同时是「已构造」的 —— 否则右栏那个 `IndexedStack` 的第 0 格是
  /// 占位，用户看到的是「左栏高亮着实例、右栏一片空白」，得先去点一下别的
  /// 分类再点回来才出内容。
  ///
  /// `ComposeSection` **不需要**加进来：它构造时只读 `PrefsStore`（内存、
  /// 同步），不碰钥匙串也不发请求 —— 那条规矩是为 `PushSection` 那种
  /// 「一构造就有副作用」的正文准备的。
  final Set<SettingsCategory> _built = <SettingsCategory>{
    SettingsCategory.instances,
  };

  void _select(SettingsCategory next) {
    setState(() {
      _selected = next;
      _built.add(next);
      // 窄屏：点分类栏里的项 = 进那一页。
      _opened = true;
    });
  }

  void _back() => setState(() => _opened = false);

  /// 一个分类的正文。宿主已经搭好 Scaffold / AppBar / 分类栏，这里只出内容。
  Widget _body(SettingsCategory category) => switch (category) {
        SettingsCategory.instances => const InstancesSection(),
        SettingsCategory.mailboxes => const MailboxesSection(),
        SettingsCategory.polling => const PollingSection(),
        SettingsCategory.appearance => const AppearanceSection(),
        SettingsCategory.compose => const ComposeSection(),
        SettingsCategory.ai => const AiSettingsSection(),
        SettingsCategory.push => PushSection(onExit: _back),
        SettingsCategory.diagnostics => const DiagnosticsSection(),
        SettingsCategory.about => const AboutSection(),
      };

  /// 分类页的标题：推送与邮箱用长名字（分类栏里那两个短名字是为了塞得下，
  /// 到了整页/右栏顶部的标题就没有宽度压力了）。
  String _titleOf(SettingsCategory category, AppLocalizations l10n) =>
      switch (category) {
        SettingsCategory.push => l10n.pushTitle,
        SettingsCategory.mailboxes => l10n.mailboxTitle,
        _ => category.label(l10n),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final panes = Breakpoints.panesOf(context);

    if (!panes) {
      if (!_opened) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.settings)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              for (final category in SettingsCategory.values)
                _CategoryTile(
                  category: category,
                  onTap: () => _select(category),
                ),
            ],
          ),
        );
      }
      // 分类页：系统返回键当「退回分类列表」，与返回箭头同一个动作。
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _back();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(_titleOf(_selected, l10n)),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _back,
            ),
          ),
          body: _body(_selected),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: Breakpoints.settingsRailWidth,
              child: Column(
                children: <Widget>[
                  PaneHeader(
                    child: Text(
                      l10n.settings,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(top: 4, bottom: 12),
                      children: <Widget>[
                        for (final category in SettingsCategory.values)
                          NavSidebarItem(
                            icon: category.icon,
                            selectedIcon: category.selectedIcon,
                            label: category.label(l10n),
                            selected: category == _selected,
                            onTap: () => _select(category),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: <Widget>[
                  PaneHeader(
                    child: Text(
                      _titleOf(_selected, l10n),
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: SettingsCategory.values.indexOf(_selected),
                      children: <Widget>[
                        for (final category in SettingsCategory.values)
                          if (_built.contains(category))
                            _body(category)
                          else
                            const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 窄屏分类列表里的一行。
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.onTap});

  final SettingsCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: Icon(category.icon),
      title: Text(category.label(l10n)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
