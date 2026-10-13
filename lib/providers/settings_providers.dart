import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/compose/writing_snippets.dart';
import 'core_providers.dart';

/// 主题模式。
///
/// 直接读 `PrefsStore`（同步的）而不做成 StreamProvider：
/// SharedPreferences 的读是内存操作，没有「加载中」这个状态，
/// 包一层异步只会让首帧闪一下系统主题。
class ThemeModeController extends Notifier<ThemeMode> {
  static const Map<String, ThemeMode> _byName = <String, ThemeMode>{
    'system': ThemeMode.system,
    'light': ThemeMode.light,
    'dark': ThemeMode.dark,
  };

  @override
  ThemeMode build() =>
      _byName[ref.watch(prefsStoreProvider).themeMode] ?? ThemeMode.system;

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(prefsStoreProvider).setThemeMode(mode.name);
  }
}

final NotifierProvider<ThemeModeController, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
  name: 'themeMode',
);

/// 语言。null = 跟随系统。
class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() {
    final code = ref.watch(prefsStoreProvider).localeCode;
    return (code == null || code.isEmpty) ? null : Locale(code);
  }

  Future<void> set(String? code) async {
    state = (code == null || code.isEmpty) ? null : Locale(code);
    await ref.read(prefsStoreProvider).setLocaleCode(code);
  }
}

final NotifierProvider<LocaleController, Locale?> localeProvider =
    NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
  name: 'locale',
);

/// 收信轮询的间隔。
///
/// 改完立刻写 prefs —— `SyncEngine.currentInterval` 是每轮即时读的，
/// 不需要重启调度器；下一次判定就生效（不必等到当前这一轮跑完）。
class PollIntervalController extends Notifier<Duration> {
  @override
  Duration build() => ref.watch(prefsStoreProvider).pollInterval;

  Future<void> set(Duration value) async {
    state = value;
    await ref.read(prefsStoreProvider).setPollInterval(value);
    state = ref.read(prefsStoreProvider).pollInterval;
  }
}

final NotifierProvider<PollIntervalController, Duration> pollIntervalProvider =
    NotifierProvider<PollIntervalController, Duration>(
  PollIntervalController.new,
  name: 'pollInterval',
);

/// 「后台预取完整正文」。关掉能省流量（列表翻完就不再自动 `full=1`）。
class PrefetchFullController extends Notifier<bool> {
  @override
  bool build() => ref.watch(prefsStoreProvider).prefetchFull;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(prefsStoreProvider).setPrefetchFull(value);
  }
}

final NotifierProvider<PrefetchFullController, bool> prefetchFullProvider =
    NotifierProvider<PrefetchFullController, bool>(
  PrefetchFullController.new,
  name: 'prefetchFull',
);

/// 分栏形态下列表栏的宽度（用户拖出来的）。
///
/// 放 provider 而不是留在 `MailPanes` 的 State 里，只有一个理由：**落盘**。
/// 宽度要在重启后还在，而落盘是异步的，State 里做就得自己管生命周期；
/// Notifier 收 `async` 的写操作是现成的形状（照抄 [PrefetchFullController]）。
///
/// 写盘只在**拖动结束**时发生 —— 每帧写一次 SharedPreferences 没有意义。
class PaneListWidthController extends Notifier<double> {
  @override
  double build() => ref.watch(prefsStoreProvider).paneListWidth;

  Future<void> set(double width) async {
    state = width;
    await ref.read(prefsStoreProvider).setPaneListWidth(width);
  }
}

final NotifierProvider<PaneListWidthController, double> paneListWidthProvider =
    NotifierProvider<PaneListWidthController, double>(
  PaneListWidthController.new,
  name: 'paneListWidth',
);

/// 左侧菜单里「收件箱」下面那组邮箱展开 / 收起。
///
/// 与 [PaneListWidthController] 同一个形状（UI 状态 + 落盘），默认展开。
class SidebarMailboxesController extends Notifier<bool> {
  @override
  bool build() => ref.watch(prefsStoreProvider).sidebarMailboxesExpanded;

  Future<void> set(bool expanded) async {
    state = expanded;
    await ref.read(prefsStoreProvider).setSidebarMailboxesExpanded(expanded);
  }

  Future<void> toggle() => set(!state);
}

final NotifierProvider<SidebarMailboxesController, bool>
    sidebarMailboxesExpandedProvider =
    NotifierProvider<SidebarMailboxesController, bool>(
  SidebarMailboxesController.new,
  name: 'sidebarMailboxesExpanded',
);

/// 单个实例的邮箱列表展开 / 收起（**记忆**的那一层）。
///
/// 状态是「**收起**了哪些实例」的集合，默认展开 —— 与
/// [PrefsStore.collapsedSidebarInstances] 的约定一致：只记偏离默认的那些，
/// 于是新实例、新装 App、老版本升级上来都不需要写任何东西。
///
/// 与 [sidebarMailboxesExpandedProvider] 的分工：
/// - 那个是**一括开关**（整棵子树展不展开），挂在「收件箱」那一项右侧的箭头上；
/// - 这个是**每台实例**的，挂在实例行右侧的箭头上。
///
/// 两者的合成规则在 [instanceMailboxesExpanded] —— 单独抽成纯函数是因为
/// 「哪一台此刻展开着」这件事在界面上看不错也测不到，只能这样钉住。
class SidebarInstanceExpansionController extends Notifier<Set<String>> {
  @override
  Set<String> build() => ref.watch(prefsStoreProvider).collapsedSidebarInstances;

  Future<void> toggle(String profileId) =>
      setExpanded(profileId, state.contains(profileId));

  Future<void> setExpanded(String profileId, bool expanded) async {
    // 同态重复写直接返回：`Set` 的 `==` 是引用比较，不设这道闸的话，
    // 每次点到已经是那个态的箭头都会把整棵树重建一遍
    // （`WritingSnippets` 那段 `==` 的注释讲的是同一件事）。
    if (state.contains(profileId) == !expanded) return;
    final next = <String>{...state};
    if (expanded) {
      next.remove(profileId);
    } else {
      next.add(profileId);
    }
    state = next;
    await ref.read(prefsStoreProvider).setCollapsedSidebarInstances(next);
  }

  /// 「全部展开」：清空偏离记录（每台实例回到默认的展开态）。
  ///
  /// 一括开关往「开」的方向拨时必须连它一起清 —— 否则「全部展开」之后
  /// 上次单独收起的那台还是收起的，用户会以为那颗箭头坏了。
  Future<void> expandAll() async {
    if (state.isEmpty) return;
    state = const <String>{};
    await ref
        .read(prefsStoreProvider)
        .setCollapsedSidebarInstances(const <String>{});
  }
}

final NotifierProvider<SidebarInstanceExpansionController, Set<String>>
    sidebarInstanceExpansionProvider =
    NotifierProvider<SidebarInstanceExpansionController, Set<String>>(
  SidebarInstanceExpansionController.new,
  name: 'sidebarInstanceExpansion',
);

/// 一台实例的邮箱列表此刻该不该展开。
///
/// - [master]：一括开关（[sidebarMailboxesExpandedProvider]）；
/// - [collapsed]：单独收起的那些（[sidebarInstanceExpansionProvider]）；
/// - [forced]：地址正落在这台实例上（实例级列表 / 它的某个邮箱 / 它们的详情）。
///   与原来那句 `expanded = global || pinned != null` 是同一条理由 ——
///   从通知深链回到某个邮箱时，那一行本身必须是看得见的，否则高亮无从谈起。
///
/// **行为比改动前更窄**：原来 `master=false` 且钉住某个邮箱时，整棵子树
/// （所有实例）都会展开，因为 `expanded` 是整棵树的开关。现在只展开被落中的
/// 那一台 —— 这更贴合上面那条理由的本意（「那一行看不见」说的就是这一台）。
bool instanceMailboxesExpanded({
  required bool master,
  required bool forced,
  required Set<String> collapsed,
  required String profileId,
}) =>
    forced || (master && !collapsed.contains(profileId));

/// 点「发送」之后等多久才真的发出去（默认 1 分钟，见
/// [AppDefaults.sendDelayDefault]）。
///
/// 这是需求六里「让用户后悔」的时长本身。做成全局设置而不是写邮件页上的
/// 一个开关：同一个人对「发给同事的附件」和「发给自己的提醒」想要的窗口
/// 长度不一样，但每次写信都调一遍更烦 —— 一个默认值 + 写信页那个
/// 「立即发送」按钮（见 `ComposeScreen`）够用了。
class SendDelayController extends Notifier<Duration> {
  @override
  Duration build() => ref.watch(prefsStoreProvider).sendDelay;

  Future<void> set(Duration delay) async {
    state = delay;
    await ref.read(prefsStoreProvider).setSendDelay(delay);
  }
}

final NotifierProvider<SendDelayController, Duration> sendDelayProvider =
    NotifierProvider<SendDelayController, Duration>(
  SendDelayController.new,
  name: 'sendDelay',
);

/// 「后台轮询与通知」总开关（也决定调度器跑不跑）。
class NotifyEnabledController extends Notifier<bool> {
  @override
  bool build() => ref.watch(prefsStoreProvider).notifyEnabled;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(prefsStoreProvider).setNotifyEnabled(value);
  }
}

final NotifierProvider<NotifyEnabledController, bool> notifyEnabledProvider =
    NotifierProvider<NotifyEnabledController, bool>(
  NotifyEnabledController.new,
  name: 'notifyEnabled',
);

/// 「在 App 里弹通知」——与 [notifyEnabledProvider] 是**两件事**。
///
/// - [notifyEnabledProvider]（轮询与后台拉取）：关了就不收信了，数据也不再更新；
/// - 这个（本地通知横幅）：关了照样收信、照样更新列表，只是**不打扰**。
///
/// 合在一个开关里的话，「我不想被通知打扰」会连收信一起关掉，用户只能
/// 在「被打扰」和「收不到信」之间二选一 —— 这不是他想要的。
/// 默认开，且只在 [notifyEnabledProvider] 也开着时才有意义。
class NotifyBannerController extends Notifier<bool> {
  @override
  bool build() => ref.watch(prefsStoreProvider).notifyBanner;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(prefsStoreProvider).setNotifyBanner(value);
  }
}

final NotifierProvider<NotifyBannerController, bool> notifyBannerProvider =
    NotifierProvider<NotifyBannerController, bool>(
  NotifyBannerController.new,
  name: 'notifyBanner',
);

/// 当前发件邮箱的签名与常用语。
///
/// **family 的键是发件邮箱地址**（spec §7），不是 `accountId`。
/// 地址为空串时给空值 —— 发件人还没选出来时工具栏那颗按钮本来就该是灰的
/// （`compose_screen.dart` 只有在 `state.sender != null` 时才传回调）。
///
/// 基类是 `Notifier`、参数走构造函数 —— 这是 riverpod 3.x 的 family 写法
/// （`FamilyNotifier` 在 3.0 被删了，见 `third_party/riverpod/CHANGELOG.md`：
/// "Removed `FamilyNotifier` and variants, in favour of `Notifier`"）。
/// 仓里现成的同款：`compose_controller.dart:269` 的
/// `class ComposeController extends Notifier<ComposeState> { ComposeController(this.args); }`
/// —— 别写成 `build(String email)`，那个签名在这个版本里不存在。
class WritingSnippetsController extends Notifier<WritingSnippets> {
  WritingSnippetsController(this.email);

  /// 这个实例属于哪个发件邮箱，由 family 的键传进来。
  final String email;

  @override
  WritingSnippets build() {
    final store = ref.watch(prefsStoreProvider);
    return WritingSnippets(
      signature: store.signatureFor(email),
      phrases: store.phrasesFor(email),
    );
  }

  /// 写盘之后**重读一遍**（不做本地拼装：写盘的是 store，
  /// 在这里再拼一次就有两份真相）。`signatureFor` 对空串返回 `''`，
  /// 所以「清空签名」这条分支不用单独写 —— 读回来就是空。
  Future<void> setSignature(String text) async {
    final store = ref.read(prefsStoreProvider);
    await store.setSignature(email, text);
    state = WritingSnippets(
      signature: store.signatureFor(email),
      phrases: state.phrases,
    );
  }

  Future<void> setPhrases(List<WritingSnippet> items) async {
    final store = ref.read(prefsStoreProvider);
    await store.setPhrases(email, items);
    state = WritingSnippets(
      signature: state.signature,
      phrases: store.phrasesFor(email),
    );
  }
}

/// 一个发件邮箱的签名与常用语。
@immutable
class WritingSnippets {
  const WritingSnippets({
    this.signature = '',
    this.phrases = const <WritingSnippet>[],
  });

  final String signature;
  final List<WritingSnippet> phrases;

  bool get hasSignature => signature.isNotEmpty;

  // **值相等不是可选的**：riverpod 的 `Notifier` 每次 `state = WritingSnippets(...)`
  // 都新建实例，没有 `==` 就永远 != 旧值，写信页那棵子树会为一次「存了内容
  // 一模一样的签名」白重建一遍（`ref.watch(writingSnippetsProvider(...))`）。
  // 形状照 `WritingSnippet`（`features/compose/writing_snippets.dart:39`）：
  // 逐字段比，List 用 `listEquals` 逐元素比（Dart 的 List `==` 是引用比）。
  @override
  bool operator ==(Object other) =>
      other is WritingSnippets &&
      other.signature == signature &&
      listEquals(other.phrases, phrases);

  @override
  int get hashCode => Object.hash(signature, Object.hashAll(phrases));
}

/// 这里**不写 `NotifierProviderFamily<...>` 的类型注解**，与
/// `compose_controller.dart:1042` 同一个理由：那个类只在
/// `flutter_riverpod/misc.dart` 里导出，写全名就得为一条注解多一条 import。
///
/// **故意不加 `isAutoDispose`**（与 `composeControllerProvider` 相反）：
/// 那个 provider 被写信页 `ref.watch` 着用，写都发生在「有人看着」的时候；
/// 这个不是 —— 设置页是 `read(...notifier)` 拿一下再写，全程**没有 watcher**
/// （`compose_section.dart` 只 watch `prefsStoreProvider`，写信页也不在同一个
/// 路由）。探针（把 store 的写包成跨一个事件循环的 await）实测：没有 watcher
/// 时 autoDispose 会在那次 await 期间把元素拆掉，写回来的 `state = ...`
/// 直接抛 `UnmountedRefException`。所以这里让 family 条目随容器存活
/// （值本来也就是内存里的 prefs 快照，不涨）。
final writingSnippetsProvider =
    NotifierProvider.family<WritingSnippetsController, WritingSnippets, String>(
  WritingSnippetsController.new,
  name: 'writingSnippets',
);
