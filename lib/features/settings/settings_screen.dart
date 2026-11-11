import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/breakpoints.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/notification_providers.dart';
import '../mail_list/mail_panes.dart' show PaneHeader;
import '../notifications/push_facade.dart';
import '../shell/nav_sidebar.dart' show NavSidebarItem;
import 'sections/about_section.dart';
import 'sections/ai_section.dart';
import 'sections/appearance_section.dart';
import 'sections/compose_section.dart';
import 'sections/diagnostics_section.dart';
import 'sections/instances_section.dart';
import 'sections/mailboxes_section.dart';
import 'sections/notifications_section.dart';
import 'sections/polling_section.dart';
import 'sections/push_section.dart';
import 'sections/security_section.dart';

/// 分类栏里的**分组带**。
///
/// 分类栏在手机上是十来个入口的一列、在桌面上是 200 来宽的一栏，光靠顺序
/// 表达「这几件事是一类」不够 —— 用户扫视时先看到的是小标题，然后才是标题
/// 下面的那几行。四条带按**邮件流**排：
///
/// - **连接**：我在连哪几台服务器、那几台下面有哪些地址；
/// - **收发**：一封邮件从进来到出去（收信 → 通知 → 写邮件）；
/// - **个性**：这个 App 长什么样、要不要帮我写（外观 / AI）；
/// - **兜底**：出问题或想收紧时才翻（诊断 / 安全 / 关于）。
///
/// 带**归谁**由 [SettingsCategory.band] 决定；扩展栏的归属见
/// [SettingsScreen] 的 `_sections`（置顶的归「连接」，其余归「兜底」）。
enum SettingsBand {
  connect,
  flow,
  personal,
  system;

  /// 小标题文案。
  String label(AppLocalizations l10n) => switch (this) {
        SettingsBand.connect => l10n.settingsBandConnect,
        SettingsBand.flow => l10n.settingsBandFlow,
        SettingsBand.personal => l10n.settingsBandPersonal,
        SettingsBand.system => l10n.settingsBandSystem,
      };
}

/// 设置的十个分类。
///
/// 顺序即分类栏里的顺序，也是窄屏列表里的顺序。分工按「用户要解决什么事」
/// 排，不按代码怎么放，并且**按邮件流走完一圈**：
///
/// 1. **连接**（[SettingsBand.connect]）：**实例**（我在连哪几台服务器）/
///    **邮箱**（那几台服务器下面的地址）—— 同一件事的两个层级，挨着最顺
///    （网页端也把它做成两栏）；
/// 2. **收发**（[SettingsBand.flow]）：**收信**（多久收一次、要不要顺带拉
///    正文）→ **通知**（新邮件到了要不要打扰我）→ **写邮件**（签名 / 常用语 /
///    发送延迟）—— 一封邮件从进来到出去的时间线；
/// 3. **个性**（[SettingsBand.personal]）：**外观** / **AI** —— 与「哪台服务器、
///    哪个地址」无关，只跟这个 App 长什么样、帮不帮我写有关；
/// 4. **兜底**（[SettingsBand.system]）：**诊断** / **安全** / **关于** ——
///    平时不必翻，出问题或想收紧时才来找的三页。
///
/// ## 「通知」为什么取代了「推送」
///
/// 「收信」页里的两张提醒开关、独占一栏的「推送」、商业版独占一栏的
/// 「免打扰」，回答的其实是**同一个问题**（新邮件到了要不要打扰我），却散在
/// 三个分类里。现在前两个合成一栏 **通知**（后台推送那段七页向导降级成这一页
/// 里的一个**子页**，见 [NotificationsSection]），商业版的免打扰由
/// [AppExtension.notificationExtras] 铺进同一页 —— 分类栏少一栏，
/// 「找提醒设置」的路径反而更短：「推送」与「通知」并排时，用户得先猜哪个
/// 才是自己要的。
///
/// ## 「发送延迟」为什么在「写邮件」
///
/// 它管的是「点了发送之后还能反悔多久」，属于**写信这件事的收尾**
/// （`compose_section.dart` 的「发送」组），却一直躺在叫「收信」的页面里 ——
/// 想撤销发送的人不会想到去「收信」找。
///
/// ## 为什么「安全」倒数第二、「关于」永远最后
///
/// 「安全」管的是**邮件正文里能发生什么**（外联资源放不放行、要不要经代理
/// 自动加载），属于「平时不必翻、想收紧或排查时才来找」的兜底开关 —— 与它
/// 上面那些日常要调的分类不是一类，所以收在页尾；「关于」是每套软件的最后
/// 一栏。
///
/// **扩展加进来的栏不在这个枚举里**（[AppExtension.settingsSections]）——
/// 置顶的（`pinFirst`，商业版的「账号」）排在最前、归「连接」带；其余的在
/// 「诊断」之后、「安全」之前，归「兜底」带。枚举只描述**内置**的那十个，
/// `test/settings_layout_test.dart` 钉的也是它们十个数目与顺序，与扩展无关。
enum SettingsCategory {
  instances,
  mailboxes,
  polling,
  notifications,
  compose,
  appearance,
  ai,
  diagnostics,
  security,
  about;

  /// 这一栏属于哪条分组带（见 [SettingsBand]）。
  SettingsBand get band => switch (this) {
        SettingsCategory.instances || SettingsCategory.mailboxes =>
          SettingsBand.connect,
        SettingsCategory.polling ||
        SettingsCategory.notifications ||
        SettingsCategory.compose =>
          SettingsBand.flow,
        SettingsCategory.appearance ||
        SettingsCategory.ai =>
          SettingsBand.personal,
        SettingsCategory.diagnostics ||
        SettingsCategory.security ||
        SettingsCategory.about =>
          SettingsBand.system,
      };

  /// 分类栏与窄屏列表里显示的名字。
  ///
  /// 四栏用的都是**短**名字，理由只有一条：分类栏只有
  /// [Breakpoints.settingsRailWidth] 宽，长名字（「系统推送」「邮箱地址」）
  /// 会被省略号吃掉。分类**页内**的标题可以更长，见 `_titleOf`。
  String label(AppLocalizations l10n) => switch (this) {
        SettingsCategory.instances => l10n.instances,
        // 分类栏只有 `Breakpoints.settingsRailWidth` 宽，用短名字 `mailbox`
        // （「邮箱」）；分类**页内**的标题用长的 `mailboxTitle`。
        SettingsCategory.mailboxes => l10n.mailbox,
        SettingsCategory.polling => l10n.polling,
        SettingsCategory.notifications => l10n.notifications,
        SettingsCategory.appearance => l10n.appearance,
        SettingsCategory.security => l10n.security,
        SettingsCategory.compose => l10n.compose,
        SettingsCategory.ai => l10n.aiTitle,
        SettingsCategory.diagnostics => l10n.diagnostics,
        SettingsCategory.about => l10n.about,
      };

  IconData get icon => switch (this) {
        SettingsCategory.instances => Icons.dns_outlined,
        // 与侧栏邮箱行（`SidebarMailboxRow` 的默认 icon）同一颗字形 ——
        // 视觉上直接指认「这就是邮箱」。
        SettingsCategory.mailboxes => Icons.alternate_email_outlined,
        SettingsCategory.polling => Icons.schedule_outlined,
        SettingsCategory.notifications => Icons.notifications_active_outlined,
        SettingsCategory.appearance => Icons.palette_outlined,
        SettingsCategory.security => Icons.shield_outlined,
        SettingsCategory.compose => Icons.edit_note_outlined,
        SettingsCategory.ai => Icons.auto_awesome_outlined,
        SettingsCategory.diagnostics => Icons.monitor_heart_outlined,
        SettingsCategory.about => Icons.info_outline,
      };

  IconData get selectedIcon => switch (this) {
        SettingsCategory.instances => Icons.dns,
        SettingsCategory.mailboxes => Icons.alternate_email,
        SettingsCategory.polling => Icons.schedule,
        SettingsCategory.notifications => Icons.notifications_active,
        SettingsCategory.appearance => Icons.palette,
        SettingsCategory.security => Icons.shield,
        SettingsCategory.compose => Icons.edit_note,
        SettingsCategory.ai => Icons.auto_awesome,
        SettingsCategory.diagnostics => Icons.monitor_heart,
        SettingsCategory.about => Icons.info,
      };
}

/// 分类栏里的一项 —— **内置分类**或**扩展分类**。
///
/// ## 为什么要多这一层
///
/// 分类栏里的东西以前恒等于 `SettingsCategory.values`，于是「选中态」直接
/// 存成枚举值就够了。扩展分类进来之后不行了：枚举描述不了它，而扩展栏是
/// 每次 `build` 时从注册表现造的（`settingsSections(context)` 返回新对象），
/// 所以**身份必须按 [key] 字符串比**，不能按对象 identity。
///
/// 内置用枚举名（`instances`…），扩展用 `ext:<SettingsSection.id>` ——
/// 两者拼得出不同前缀，不会撞。
class _SectionRef {
  const _SectionRef.builtIn(SettingsCategory this.category) : section = null;

  const _SectionRef.extension(SettingsSection this.section) : category = null;

  final SettingsCategory? category;
  final SettingsSection? section;

  String get key => category?.name ?? 'ext:${section!.id}';

  IconData get icon => category?.icon ?? section!.icon;

  IconData get selectedIcon => category?.selectedIcon ?? section!.selectedIcon;

  @override
  bool operator ==(Object other) => other is _SectionRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '_SectionRef($key)';
}

/// 分类内顶在最上面的一层**子页**。
///
/// 只有一个用处：把一个塞不进卡片流、又不值得独占一栏的正文（目前只有
/// 「通知 → 后台推送」那七页向导）挂到分类里。标题与正文都**现算** ——
/// 标题要按 locale 选、正文要拿当前的 `pop` 回调（窄屏「完成」与宽屏返回
/// 箭头做的是同一件事）。
class _SubPage {
  const _SubPage({required this.titleOf, required this.build});

  /// 页头标题（窄屏是 `AppBar`，宽屏是右栏 `PaneHeader`）。
  final String Function(AppLocalizations l10n) titleOf;

  /// 正文。[pop] 关掉这个子页、回到分类正文。
  final Widget Function(BuildContext context, VoidCallback pop) build;
}

/// 设置页。
///
/// ## 两种形态
///
/// - **宽屏（>= 1024）**：左栏是**固定宽度**的分类菜单（常驻，按
///   [SettingsBand] 分成四条带），右栏是选中分类的设置内容。与收件箱 /
///   发件箱 / 附件缓存同一个两栏形状，只是这条左栏不让拖 —— 它是菜单不是
///   列表。
/// - **窄屏**：先是一叠**分类列表**（十条带小标题的卡片，十个入口），点一个
///   进分类页（`AppBar` 带返回箭头，系统返回键也退回列表）。
///
/// 判据是**窗口宽度**（[Breakpoints.panesOf]），跟着窗口走 —— 拖宽拖窄当场
/// 换形态，与收件箱那一套同口径。
///
/// ## 分类内的**子页**（`_subPage`）
///
/// 分类里的某一行可能通向一层更细的正文 —— 目前只有「通知 → 后台推送」
/// （七页向导塞不进卡片流，但它只是「通知」这一页的一个细节，不够格再占
/// 一栏）。子页由宿主顶在分类正文的位置上，返回箭头**先退子页、再退分类、
/// 最后退列表**（窄屏三级）；宽屏不压栈，右栏顶部那颗返回箭头把分类正文
/// 换回来。
///
/// ## 为什么分类切换不改地址、不压栈
///
/// 十个分类（以及分类内的子页）是**一页之内的内部翻页**。做成十条路由
/// （窄屏点一个 push 一层、宽屏选中态进 URL）有两个代价，而收益只有一个
/// 「地址能分享」：
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
  /// 用户点过的分类。`null` = 还没点过，默认落在**当前分类清单的第一项**。
  ///
  /// 不能写死成「实例」：扩展可以声明 [SettingsSection.pinFirst]（商业版的
  /// 「账号」就排在最前），那时第一栏不是实例。默认项必须跟着清单走 —
  /// 否则宽屏一进来会出现「分类栏第一项高亮着账号、右栏却是实例」。
  _SectionRef? _selected;

  /// 窄屏下「用户已经点进某个分类了没有」。
  ///
  /// 宽屏不用它（分类栏常驻）。拖宽再拖窄会保留它 —— 于是「点进外观 → 拖宽
  /// 看两列 → 拖回来」仍然停在外观，不会莫名退回分类列表。
  bool _opened = false;

  /// 「实例」那一栏此刻是不是开着**添加实例表单**。
  ///
  /// 状态归宿主（而不是 `InstancesSection` 自己）：窄屏那颗设置页返回箭头
  /// 要先退回实例列表、再退回分类列表，两级语义只有宿主分得清。
  ///
  /// 表单不占地址、不压栈 —— 与其余分类的切换同一套规矩（见类文档）。
  bool _addingInstance = false;

  /// 分类内顶在最上面的一层**子页**；`null` = 正在看分类本身。
  ///
  /// 状态归宿主，理由与 [_addingInstance] 完全相同：窄屏的返回箭头要分得清
  /// 「退子页」与「退分类」，而子页自己不知道外面还有几层。目前只有
  /// 「通知 → 后台推送」用它（见 [NotificationsSection.onOpenPush]）。
  ///
  /// 子页**不缓存**：关掉就 dispose，下次进来重新建 —— 推送向导一建出来
  /// 就会读钥匙串、打中转端 `/devices`，留一份常驻的旧状态比多打一次请求
  /// 更容易骗人。
  _SubPage? _subPage;

  /// **已经构造过**的分类，按 [_SectionRef.key] 记。
  ///
  /// 宽屏右栏用 `IndexedStack` 把构造过的分类留着（切走再切回来，草稿还在），
  /// 但**不一次把十个都建出来**：`PushSection` 一构造就会去读钥匙串、打中转端
  /// 的 `/devices`、还可能自动登记一次设备（见它的 `_load` / `_maybeAutoRegister`）。
  /// 只想改个主题的用户不该因此被发一轮推送请求。
  ///
  /// **默认项必须同时是「已构造」的**：宽屏一进来右栏就是它的正文 —— 否则
  /// `IndexedStack` 里那一格是占位，用户看到的是「左栏高亮着某一项、右栏
  /// 一片空白」，得先去点一下别的分类再点回来才出内容。
  ///
  /// 默认项由 [build] 按**当前分类清单的第一项**补进来（不能在这里写死：
  /// 扩展可以 `pinFirst`），所以这里只留空集，不预填。
  ///
  /// `ComposeSection` **不需要**加进来：它构造时只读 `PrefsStore`（内存、
  /// 同步），不碰钥匙串也不发请求 —— 那条规矩是为 `PushSection` 那种
  /// 「一构造就有副作用」的正文准备的。
  ///
  /// **扩展那一栏一律懒建**（点进去才构造），与内置同一套规矩 ——
  /// 扩展正文多半要读盘或者打接口，「打开设置页」不该等于「把每个扩展都跑一遍」。
  final Set<String> _built = <String>{};

  void _select(_SectionRef next) {
    setState(() {
      _selected = next;
      _built.add(next.key);
      // 换了分类，「添加实例」那张表单与分类内的子页就一起收起来 —— 它们
      // 只属于刚才那一栏，用户已经走开了。
      _addingInstance = false;
      _subPage = null;
      // 窄屏：点分类栏里的项 = 进那一页。
      _opened = true;
    });
  }

  /// 返回。窄屏三级：**子页 / 表单 → 分类页 → 分类列表**。
  ///
  /// 宽屏也走这里（子页顶部那颗返回箭头），但那时 `_opened` 恒为 true，
  /// 只走第一级 —— 分类栏本来就一直在。
  void _back() {
    setState(() {
      if (_subPage != null) {
        _subPage = null;
        return;
      }
      if (_addingInstance) {
        _addingInstance = false;
        return;
      }
      _opened = false;
    });
  }

  void _openAddInstance() => setState(() => _addingInstance = true);

  /// 打开「通知 → 后台推送」子页。
  void _openPush() {
    setState(() {
      _subPage = _SubPage(
        titleOf: (l10n) => l10n.notificationsPush,
        build: (context, pop) => _pushBody(onExit: pop),
      );
    });
  }

  /// 关掉子页（回到分类正文）。子页自己的「完成」按钮与页头那颗返回箭头
  /// 都走这里。
  VoidCallback get _closeSubPage => () => setState(() => _subPage = null);

  /// 这一栏的正文。宿主已经搭好 Scaffold / AppBar / 分类栏，这里只出内容。
  ///
  /// 扩展的正文由扩展自己给（[SettingsSection.body]），宿主只负责把它放在
  /// 同一个位置。
  Widget _bodyOf(_SectionRef ref) {
    final builder = ref.section?.body;
    if (builder != null) return builder(context);
    return switch (ref.category!) {
      SettingsCategory.instances => InstancesSection(
          adding: _addingInstance,
          onAdd: _openAddInstance,
          onCancel: _back,
          // 建完实例就往登录页跳了：先把表单收起来，回设置页时看到的是
          // 实例列表（新实例以「需要登录」的状态躺在里面）。
          onCreated: () => setState(() => _addingInstance = false),
        ),
      SettingsCategory.mailboxes => const MailboxesSection(),
      SettingsCategory.polling => const PollingSection(),
      SettingsCategory.appearance => const AppearanceSection(),
      SettingsCategory.security => const SecuritySection(),
      SettingsCategory.compose => const ComposeSection(),
      SettingsCategory.ai => const AiSettingsSection(),
      SettingsCategory.notifications =>
        NotificationsSection(onOpenPush: _openPush),
      SettingsCategory.diagnostics => const DiagnosticsSection(),
      SettingsCategory.about => const AboutSection(),
    };
  }

  /// 「设置 → 通知 → 后台推送」子页的正文。
  ///
  /// 公开展示的七页向导（[PushSection]）只是**回退路径**：扩展可以把整块换
  /// 成自己的面板（见 [AppExtension.pushSettings]）—— 「三条值由托管服务
  /// 下发」的版本不该让用户看见地址与配对码。空注册表时这里恒等于
  /// `PushSection(onExit: pop)`，公开版行为逐字不变。
  ///
  /// [onExit] 是「离开这个子页、回到『通知』」：[PushSection] 用它画窄屏
  /// 末页那颗「完成」，也用它把系统返回键在向导中段解释成「上一步」。
  ///
  /// [fallback] 是**惰性构造**的：`PushSection` 一建出来就会读钥匙串、打
  /// 中转端的 `/devices`、还可能自动登记一次（见它的 `_load`）。所以只有
  /// 扩展明确拒绝时才该把它建出来 —— 那也正是「托管推送」这一类实现最想要
  /// 的形状（自己画，不让核心先跑一轮网络）。
  Widget _pushBody({required VoidCallback onExit}) {
    final facade = PushFacadeImpl(
      push: ref.read(pushServiceProvider),
      prefs: ref.read(prefsStoreProvider),
      tokens: ref.read(tokenStoreProvider),
    );
    return AppExtensionRegistry.instance.pushSettings(
      context,
      facade,
      () => PushSection(onExit: onExit),
    );
  }

  /// 分类页的标题：邮箱用长名字（`mailboxTitle`；分类栏里那个短名字是为了
  /// 塞得下，到了整页/右栏顶部的标题就没有宽度压力了）。
  ///
  /// 扩展栏的标题就是它自己给的那个（扩展自己按 locale 选好了）。
  String _titleOf(_SectionRef ref, AppLocalizations l10n) {
    // 「实例」那一栏开着添加表单时，页头说清楚现在在干什么 —— 窄屏它是
    // AppBar 的标题，宽屏是右栏顶部那条 `PaneHeader`。分类栏里高亮的仍然
    // 是「实例」，用户知道自己还在这一栏里。
    if (ref.category == SettingsCategory.instances && _addingInstance) {
      return l10n.addInstance;
    }
    final section = ref.section;
    if (section != null) return section.title;
    return switch (ref.category!) {
      SettingsCategory.mailboxes => l10n.mailboxTitle,
      _ => ref.category!.label(l10n),
    };
  }

  /// 分类栏 / 分类列表里的短名字。
  String _labelOf(_SectionRef ref, AppLocalizations l10n) =>
      ref.section?.title ?? ref.category!.label(l10n);

  /// 当前要铺出来的分类清单：**N 个置顶扩展 + 十个内置 + M 个扩展**。
  ///
  /// 顺序规则（全部由宿主落实，扩展只交标志）：
  ///
  /// 1. 声明了 [SettingsSection.pinFirst] 的扩展按注册顺序排最前 —— 它们
  ///    是「用户身份」这一类入口（商业版的「账号」），要出现在设置的第一排，
  ///    归「连接」带（账号就是「我这个人在哪台服务上」那一层）；
  /// 2. 十个内置分类，按 [SettingsCategory] 的枚举顺序（`instances` 开头）；
  /// 3. 其余扩展插在「诊断」之后、「安全」之前，与它俩同属「兜底」带；
  /// 4. 「安全」「关于」固定收尾 —— 这条规矩写在 `SettingsSection` 的文档里，
  ///    扩展各自决定不了自己该排第几，只能由宿主统一插在一个固定位置。
  ///
  /// 分成几条带由 [_bandOf] 现算，不额外维护一份顺序表 —— 枚举上的
  /// [SettingsCategory.band] 是唯一事实来源，改带只动那一处。
  List<_SectionRef> _sections(BuildContext context) {
    final extensions = <_SectionRef>[
      for (final section in AppExtensionRegistry.instance.settingsSections(context))
        _SectionRef.extension(section),
    ];
    final pinned = <_SectionRef>[
      for (final ref in extensions)
        if (ref.section!.pinFirst) ref,
    ];
    final rest = <_SectionRef>[
      for (final ref in extensions)
        if (!ref.section!.pinFirst) ref,
    ];
    final security = _SectionRef.builtIn(SettingsCategory.security);
    final about = _SectionRef.builtIn(SettingsCategory.about);
    return <_SectionRef>[
      ...pinned,
      for (final category in SettingsCategory.values)
        if (category != SettingsCategory.about &&
            category != SettingsCategory.security)
          _SectionRef.builtIn(category),
      ...rest,
      security,
      about,
    ];
  }

  /// 某一栏归哪条分组带。
  ///
  /// 内置的看 [SettingsCategory.band]；扩展的只有两条路 —— 置顶的（「账号」
  /// 那一类身份入口）归「连接」，其余跟「诊断 / 安全 / 关于」一道收在
  /// 「兜底」。扩展**不能**自己挑带：它挑不了「排在几栏之间」这件事，与
  /// 它决定不了自己排第几是同一个理由。
  SettingsBand _bandOf(_SectionRef ref) {
    final category = ref.category;
    if (category != null) return category.band;
    return ref.section!.pinFirst ? SettingsBand.connect : SettingsBand.system;
  }

  /// 按带分组，保持 [_sections] 给出的相对顺序（`LinkedHashMap` 的插入序）。
  ///
  /// 分组本身不重排：`_sections` 已经把每一段连续排好了，这里只是把它们
  /// 装进带里 —— 于是「带内顺序」与「清单顺序」永远是同一份事实，不会出现
  /// 两处各排一次、彼此对不上。
  Map<SettingsBand, List<_SectionRef>> _banded(List<_SectionRef> sections) {
    final out = <SettingsBand, List<_SectionRef>>{};
    for (final ref in sections) {
      out.putIfAbsent(_bandOf(ref), () => <_SectionRef>[]).add(ref);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final panes = Breakpoints.panesOf(context);
    final sections = _sections(context);
    // 注册表可能在本次 build 之前变过（只有测试会这么做）—— 选中的那一栏
    // 没了就退回第一栏，不然窄屏会停在一个点不回去的空页上。
    //
    // 默认项是**清单第一项**（可能被扩展置顶，见 `_sections`），并在这里
    // 补进 `_built`：宽屏一进来右栏必须已经有正文。
    final selected = _selected != null && sections.contains(_selected)
        ? _selected!
        : sections.first;
    _built.add(selected.key);

    final bands = _banded(sections);
    final subPage = _subPage;

    if (!panes) {
      if (!_opened) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.settings)),
          // 分类列表也走同一套积木：**一条带一张卡片**，卡片标题就是带名
          // （「连接 / 收发 / 个性 / 兜底」），行间分隔线由 `SettingsGroup`
          // 画。与页内各分组同一个圆角/描边/底色 —— 一进设置就是同一门语言。
          //
          // 手机上这一列是十来项，一条带一张卡比一整张长卡好扫：用户先按
          // 「这是哪一类事」定位，再在三四行里挑。
          body: SettingsPage(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: <Widget>[
              for (final band in SettingsBand.values)
                if (bands[band]?.isNotEmpty ?? false)
                  SettingsGroup(
                    title: band.label(l10n),
                    children: <Widget>[
                      for (final ref in bands[band]!)
                        SettingsCategoryTile(
                          icon: ref.icon,
                          label: _labelOf(ref, l10n),
                          onTap: () => _select(ref),
                        ),
                    ],
                  ),
            ],
          ),
        );
      }
      // 分类页（或它上面那层子页）：系统返回键当「退回上一层」，与返回箭头
      // 同一个动作 —— [_back] 自己知道现在该退哪一层。
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _back();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(subPage?.titleOf(l10n) ?? _titleOf(selected, l10n)),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _back,
            ),
          ),
          body: subPage == null
              ? _bodyOf(selected)
              : subPage.build(context, _back),
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
                      padding: const EdgeInsets.only(top: 2, bottom: 12),
                      children: <Widget>[
                        // 分组带的小标题：字号/颜色/内边距与宽屏侧栏
                        // （`NavSidebar` 的 `NavSidebarGroup`）那一套逐字相同
                        // —— 同一个 App 里两条常驻左栏不该有两门语言。
                        for (final band in SettingsBand.values)
                          if (bands[band]?.isNotEmpty ?? false) ...<Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
                              child: Text(
                                band.label(l10n),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ),
                            for (final ref in bands[band]!)
                              NavSidebarItem(
                                icon: ref.icon,
                                selectedIcon: ref.selectedIcon,
                                label: _labelOf(ref, l10n),
                                // 子页打开时高亮的仍然是它所属的那一栏
                                // （「通知 → 后台推送」时「通知」保持选中）：
                                // 用户得知道自己在哪一栏里，而不是「什么都没
                                // 选中」。
                                selected: ref == selected,
                                onTap: () => _select(ref),
                              ),
                          ],
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
                    // 子页打开时页头左侧多一颗返回箭头：分类栏还在，用户
                    // 当然也能点别的分类走掉，但「回到刚才那一页」这条最顺
                    // 的路得摆在页头上（窄屏那颗箭头在 AppBar 里，同一个
                    // 位置、同一个动作）。
                    child: Row(
                      children: <Widget>[
                        if (subPage != null)
                          IconButton(
                            icon: const Icon(Icons.arrow_back, size: 20),
                            onPressed: _closeSubPage,
                            tooltip: MaterialLocalizations.of(context)
                                .backButtonTooltip,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                          ),
                        if (subPage != null) const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            subPage?.titleOf(l10n) ?? _titleOf(selected, l10n),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    // 外层 `IndexedStack`：第 0 格是各分类正文（大 `IndexedStack`
                    // 留着构造过的那些，切换不丢草稿），第 1 格是子页。子页
                    // 关掉时第 1 格换回 `SizedBox` —— 子页随之 dispose，下次
                    // 进来重新建（见 `_subPage` 的注释）。
                    child: IndexedStack(
                      index: subPage == null ? 0 : 1,
                      children: <Widget>[
                        IndexedStack(
                          index: sections.indexOf(selected),
                          children: <Widget>[
                            for (final ref in sections)
                              if (_built.contains(ref.key))
                                _bodyOf(ref)
                              else
                                const SizedBox.shrink(),
                          ],
                        ),
                        if (subPage != null)
                          subPage.build(context, _closeSubPage)
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
///
/// **与宽屏分类栏的行是同一颗**（[NavSidebarItem]）—— 只有两个参数不同：
///
/// - 行高 48（宽屏分类栏 40，见 [NavSidebarItem.height]）。窄屏这一列是设置页
///   的**唯一**入口列表，行矮一截时图标与文字贴得太紧，点起来也挤；
/// - 永远不选中：窄屏的「你在这一栏」由**进到那一页 + 返回箭头**表示，列表
///   本身没有选中态。
///
/// ## 为什么不再自己画一颗 `ListTile`
///
/// 以前这里是一颗 `ListTile`：32dp 浅色圆角图标底 + 18dp 字形 + 右侧
/// `chevron_right`，而宽屏分类栏是 20dp 裸字形、没有箭头。同一个设置页换一次
/// 窗口宽度，图标就换一副长相、行高也矮一截（用户报的就是这个）。现在两处
/// **共用同一份行实现**：20dp 图标、12dp 间距、`bodyMedium` 文字、圆角 10、
/// hover / 选中底色全部一致 —— 只有高度按上一条分开。
///
/// 图标也不再套那颗浅色圆角底：宽屏分类栏已经证明「20dp 裸字形 + 文字」在
/// 二百来宽的栏里够辨认；窄屏列表的行更宽，缺的从来不是图标的存在感，而是
/// **行高**。底块还会把图标列画成一条粗竖线，反而与宽屏不是一门语言。
class SettingsCategoryTile extends StatelessWidget {
  const SettingsCategoryTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 未选中态的字形（窄屏列表没有选中态，`selectedIcon` 用不上）。
  final IconData icon;

  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return NavSidebarItem(
      // 48 而不是 40：手机上的触控行。宽屏分类栏那一列旁边常驻正文，
      // 40 已经够用，见 `NavSidebarItem.height`。
      height: 48,
      icon: icon,
      // 这一行恒为未选中，`selectedIcon` 不会被画出来 —— 给同一颗字形，
      // 免得「这里为什么传了另一颗」变成下一个读代码的人的疑问。
      selectedIcon: icon,
      label: label,
      selected: false,
      onTap: onTap,
    );
  }
}
