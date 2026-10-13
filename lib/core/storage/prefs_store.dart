import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 与 `mail_dao.dart` 同样的方向（core → features）：换来的是筛选值对象
// 只有一份定义。见 `mail_dao.dart` 顶部那段注释。
import '../../features/compose/writing_snippets.dart';
import '../../features/mail_list/mailbox_filter.dart';
import '../config/app_defaults.dart';
import '../theme/breakpoints.dart';

/// 非敏感的 UI 偏好设置。
///
/// 与 [TokenStore] 的分工：**token 走密钥库，其他一律走这里**。
/// 这里的东西丢了只会让用户重新点几下，不会导致登录态泄漏或丢失。
///
/// 约定：所有 key 都带 `cm_` 前缀，避免与将来引入的其他 SDK 撞名。
class PrefsStore {
  PrefsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<PrefsStore> open() async =>
      PrefsStore(await SharedPreferences.getInstance());

  // ---- key ----
  static const String _kActiveProfile = 'cm_active_profile';
  static const String _kLocale = 'cm_locale';
  static const String _kThemeMode = 'cm_theme_mode';
  /// 收信轮询的间隔（秒）。**只有一个** —— 活跃/空闲两档已合并，见
  /// `AppDefaults.pollDefault`。旧版本那两个 key（`cm_poll_active_seconds`
  /// / `cm_poll_idle_seconds`）不再读，也不清：用户降级回旧版本时那两档
  /// 还能原样用回来（这里不迁移，因为两档合成一档时「取谁」都是丢信息）。
  static const String _kPollSeconds = 'cm_poll_seconds';
  /// 「后台轮询与通知」总开关（见 `settings_providers.dart`）。
  static const String _kPrefetchFull = 'cm_prefetch_full';
  static const String _kInstanceColors = 'cm_instance_colors';
  static const String _kSignatures = 'cm_signatures';
  static const String _kPhrases = 'cm_phrases';
  static const String _kMailboxFilter = 'cm_mailbox_filter';
  static const String _kNotifyEnabled = 'cm_notify_enabled';
  static const String _kNotifyBanner = 'cm_notify_banner';
  static const String _kOnboarded = 'cm_onboarded';
  static const String _kPaneListWidth = 'cm_pane_list_width';
  static const String _kSendDelay = 'cm_send_delay_seconds';
  static const String _kSidebarMailboxes = 'cm_sidebar_mailboxes_expanded';
  /// 单独收起的那些实例 id（默认展开，所以只在偏离默认时才写）。
  static const String _kSidebarCollapsed = 'cm_sidebar_collapsed_instances';
  static const String _kAiSettings = 'cm_ai_settings';
  static const String _kAiUsage = 'cm_ai_usage';

  // ---- 当前实例 ----
  String? get activeProfileId => _prefs.getString(_kActiveProfile);

  Future<void> setActiveProfileId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(_kActiveProfile);
    } else {
      await _prefs.setString(_kActiveProfile, id);
    }
  }

  // ---- 语言 ----
  /// `'zh'` / `'en'`；null 表示跟随系统。
  String? get localeCode => _prefs.getString(_kLocale);

  Future<void> setLocaleCode(String? code) async {
    if (code == null || code.isEmpty) {
      await _prefs.remove(_kLocale);
    } else {
      await _prefs.setString(_kLocale, code);
    }
  }

  // ---- 主题 ----
  /// `'system'` / `'light'` / `'dark'`。
  String get themeMode => _prefs.getString(_kThemeMode) ?? 'system';

  Future<void> setThemeMode(String mode) => _prefs.setString(_kThemeMode, mode);

  // ---- 轮询间隔 ----
  /// 每隔多久检查一次新邮件。服务端 `autoRefresh` 只作建议（线上为 0），
  /// 真实值以用户设置为准，并夹在 [AppDefaults.pollMin] / [pollMax] 之间
  /// —— 手改 prefs 写进来的 0 或 24 小时都在这里被拉回区间。
  Duration get pollInterval {
    final seconds =
        _prefs.getInt(_kPollSeconds) ?? AppDefaults.pollDefault.inSeconds;
    return _clamp(seconds);
  }

  Future<void> setPollInterval(Duration d) =>
      _prefs.setInt(_kPollSeconds, _clamp(d.inSeconds).inSeconds);

  static Duration _clamp(int seconds) {
    if (seconds < AppDefaults.pollMin.inSeconds) return AppDefaults.pollMin;
    if (seconds > AppDefaults.pollMax.inSeconds) return AppDefaults.pollMax;
    return Duration(seconds: seconds);
  }

  // ---- 分栏宽度 ----
  /// 分栏形态下用户拖出来的列表栏宽度。
  ///
  /// 存的是**内容宽**，不是窗口宽 —— 窗口一改（换显示器、开分屏）这个数
  /// 就不再合适，所以每次用之前都要过一遍 [Breakpoints.clampListWidth]，
  /// 让它自己收敛回合法区间；这里不做校验，只负责记。
  double get paneListWidth =>
      _prefs.getDouble(_kPaneListWidth) ?? Breakpoints.listMinWidth;

  Future<void> setPaneListWidth(double width) =>
      _prefs.setDouble(_kPaneListWidth, width);

  // ---- 侧栏的邮箱下级菜单 ----

  /// 左侧菜单里「收件箱」下面那组邮箱是展开的还是收起的。
  ///
  /// **默认展开**：这一组是「某一个邮箱的收件箱」这条路径的唯一入口，
  /// 默认收着等于新功能没人看得见。取消这个 key（而不是存 false）就是展开 ——
  /// 与 `?? true` 同一个意思，所以没写过的老用户第一次升级上来看到的是展开态。
  ///
  /// 这是**一括开关**：关掉时整棵子树（所有实例的所有邮箱）都收起来。
  /// 单个实例的展开态见 [collapsedSidebarInstances]。
  bool get sidebarMailboxesExpanded =>
      _prefs.getBool(_kSidebarMailboxes) ?? true;

  Future<void> setSidebarMailboxesExpanded(bool value) =>
      _prefs.setBool(_kSidebarMailboxes, value);

  /// 用户在侧栏里**单独收起**了哪些实例的邮箱列表。
  ///
  /// 存的是「偏离默认」的那些 id —— 默认态是展开（与
  /// [sidebarMailboxesExpanded] 同一条理由：默认收着等于这棵子树没人看得见），
  /// 所以新实例、新装的 App、老版本升级上来这三种情况**都不需要写任何东西**。
  ///
  /// 反过来存「展开的 id」是不行的：空列表与「这个 key 根本没写过」会分不开，
  /// 而它们必须分开 —— 一个是「每台都收起」，一个是「每台都展开」。
  ///
  /// 里面可能留着已经删掉的实例 id：不清，读的时候对不上就忽略
  /// （清理它的唯一收益是省几个字节，而漏清的代价是零）。
  Set<String> get collapsedSidebarInstances =>
      (_prefs.getStringList(_kSidebarCollapsed) ?? const <String>[]).toSet();

  Future<void> setCollapsedSidebarInstances(Set<String> ids) async {
    if (ids.isEmpty) {
      await _prefs.remove(_kSidebarCollapsed);
    } else {
      await _prefs.setStringList(
        _kSidebarCollapsed,
        ids.toList(growable: false),
      );
    }
  }

  // ---- 发送延迟 ----

  /// 点「发送」之后等多久才真的发出去（见 [AppDefaults.sendDelayDefault]）。
  ///
  /// 夹在 `0..sendDelayMax` 之间：0 是「立即发送」这个合法档位，不需要特殊处理；
  /// 上限拦住手改 prefs 写进来的荒唐值（比如一年），不然那封信会在发件箱里
  /// 躺到用户以为 App 坏了。
  Duration get sendDelay {
    final seconds = _prefs.getInt(_kSendDelay) ??
        AppDefaults.sendDelayDefault.inSeconds;
    if (seconds <= 0) return Duration.zero;
    if (seconds > AppDefaults.sendDelayMax.inSeconds) {
      return AppDefaults.sendDelayMax;
    }
    return Duration(seconds: seconds);
  }

  Future<void> setSendDelay(Duration d) => _prefs.setInt(
        _kSendDelay,
        d.inSeconds.clamp(0, AppDefaults.sendDelayMax.inSeconds),
      );

  /// 列表翻完之后是否后台补拉 `full=1` 详情（费流量，可关）。
  bool get prefetchFull => _prefs.getBool(_kPrefetchFull) ?? true;

  Future<void> setPrefetchFull(bool value) =>
      _prefs.setBool(_kPrefetchFull, value);

  // ---- 实例色标 ----
  /// profileId → 色标下标。用户可固定某个实例的颜色。
  Map<String, int> get instanceColors {
    final raw = _prefs.getString(_kInstanceColors);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      return decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          value is int ? value : int.tryParse('$value') ?? 0,
        ),
      );
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> setInstanceColors(Map<String, int> colors) =>
      _prefs.setString(_kInstanceColors, jsonEncode(colors));

  // ---- 签名（按发件邮箱）----

  /// 发件邮箱地址 → 签名的纯文本。没有的地址就是**没有签名**。
  ///
  /// **键用邮箱地址而不是 `accountId`**：用户心里那个东西叫「我的
  /// `xxx@yyy` 的签名」。换实例、重装 App 之后只要地址还在，签名就还在。
  Map<String, String> get signatures {
    final raw = _prefs.getString(_kSignatures);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      decoded.forEach((key, value) {
        if (key is! String || value is! String || value.isEmpty) return;
        out[key] = value;
      });
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  /// 这个发件邮箱的签名。**没配过给空串**（调用方不用判 null）。
  String signatureFor(String email) => signatures[email] ?? '';

  /// 存一个签名。**传空串 = 删掉这一条**，而不是存一个空签名 ——
  /// 否则「清除签名」会在存储里留一个 `"a@b.com": ""`，
  /// 下次读出来还要再判一次空。
  Future<void> setSignature(String email, String text) {
    final next = Map<String, String>.of(signatures);
    if (text.isEmpty) {
      next.remove(email);
    } else {
      next[email] = text;
    }
    return _prefs.setString(_kSignatures, jsonEncode(next));
  }

  // ---- 常用语（按发件邮箱）----

  /// 发件邮箱地址 → 那一组的常用语。顺序即用户排的顺序。
  Map<String, List<WritingSnippet>> get phrases {
    final raw = _prefs.getString(_kPhrases);
    if (raw == null || raw.isEmpty) return <String, List<WritingSnippet>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<WritingSnippet>>{};
      final out = <String, List<WritingSnippet>>{};
      decoded.forEach((key, value) {
        if (key is! String || value is! List) return;
        final items = <WritingSnippet>[];
        for (final entry in value) {
          final snippet = WritingSnippet.fromJson(entry);
          if (snippet != null) items.add(snippet);
        }
        if (items.isNotEmpty) {
          out[key] = List<WritingSnippet>.unmodifiable(items);
        }
      });
      return out;
    } catch (_) {
      return <String, List<WritingSnippet>>{};
    }
  }

  List<WritingSnippet> phrasesFor(String email) =>
      phrases[email] ?? const <WritingSnippet>[];

  /// 整组替换（设置页增删改之后整组写回）。**空组 = 删掉这个地址**。
  Future<void> setPhrases(String email, List<WritingSnippet> items) {
    final next = Map<String, List<WritingSnippet>>.of(phrases);
    if (items.isEmpty) {
      next.remove(email);
    } else {
      next[email] = List<WritingSnippet>.unmodifiable(items);
    }
    return _prefs.setString(
      _kPhrases,
      jsonEncode(<String, dynamic>{
        for (final entry in next.entries)
          entry.key: <Map<String, dynamic>>[
            for (final snippet in entry.value) snippet.toJson(),
          ],
      }),
    );
  }

  // ---- 收件箱邮箱筛选 ----

  /// 用户在筛选面板里勾的邮箱。
  ///
  /// **null 表示「没筛过」= 全部邮箱**，与 `MailboxSelection.resolve` 的约定
  /// 一致 —— 不要用空列表表示「全部」，那会让「一项都读不出来」和「全选」
  /// 无法区分。
  ///
  /// 这一项以前叫 `cm_timeline_filter`，存的是 profileId 列表（聚合页的实例
  /// 过滤）。语义升级之后换了 key：老值读进来会被新解析器当成坏数据丢掉，
  /// 用户回到「全部」这个默认态，不会看到一份张冠李戴的筛选。
  List<MailboxFilter>? get mailboxFilter =>
      prefsToMailboxes(_prefs.getStringList(_kMailboxFilter));

  Future<void> setMailboxFilter(List<MailboxFilter>? boxes) async {
    if (boxes == null || boxes.isEmpty) {
      await _prefs.remove(_kMailboxFilter);
    } else {
      await _prefs.setStringList(_kMailboxFilter, mailboxesToPrefs(boxes));
    }
  }

  // ---- 通知 ----
  bool get notifyEnabled => _prefs.getBool(_kNotifyEnabled) ?? true;

  Future<void> setNotifyEnabled(bool value) =>
      _prefs.setBool(_kNotifyEnabled, value);

  /// 收到新邮件时**在 App 里弹不弹横幅**。与 [notifyEnabled] 分开：
  /// 那个关掉是「连收信都停」，这个关掉只是「别打扰我」。默认开。
  bool get notifyBanner => _prefs.getBool(_kNotifyBanner) ?? true;

  Future<void> setNotifyBanner(bool value) =>
      _prefs.setBool(_kNotifyBanner, value);

  /// 是否已经走过首次引导（决定冷启动落在引导页还是聚合页）。
  bool get onboarded => _prefs.getBool(_kOnboarded) ?? false;

  Future<void> setOnboarded(bool value) => _prefs.setBool(_kOnboarded, value);

  // ---- 推送中转（mail-push）------------------------------------------------
  //
  // 这几项描述「这台设备订阅了哪个中转的哪个实例」。都**不是秘密**
  // （秘密是配对码，那份在 TokenStore 里），放 prefs 是为了让设置页
  // 和诊断页能同步读到，不用走异步。

  static const String _kPushRelayUrl = 'cm_push_relay_url';
  static const String _kPushInstanceId = 'cm_push_instance_id';
  static const String _kPushDeviceId = 'cm_push_device_id';
  static const String _kPushMailboxes = 'cm_push_mailboxes';
  static const String _kPushEnabled = 'cm_push_enabled';

  /// 中转 Worker 的地址（形如 `https://push.example.com`）。空 = 没配。
  String get pushRelayUrl => _prefs.getString(_kPushRelayUrl) ?? '';

  Future<void> setPushRelayUrl(String url) async {
    if (url.isEmpty) {
      await _prefs.remove(_kPushRelayUrl);
    } else {
      await _prefs.setString(_kPushRelayUrl, url);
    }
  }

  /// 本机在中转端占用的实例位 id（部署者用 `/admin/instances` 开的那个）。
  String get pushInstanceId => _prefs.getString(_kPushInstanceId) ?? '';

  Future<void> setPushInstanceId(String id) async {
    if (id.isEmpty) {
      await _prefs.remove(_kPushInstanceId);
    } else {
      await _prefs.setString(_kPushInstanceId, id);
    }
  }

  /// 本机在中转端的设备号，注册时生成后**不再变** —— 它同时是
  /// 「注销哪些注册」的依据，重装才会换。
  String get pushDeviceId => _prefs.getString(_kPushDeviceId) ?? '';

  Future<void> setPushDeviceId(String id) async {
    if (id.isEmpty) {
      await _prefs.remove(_kPushDeviceId);
    } else {
      await _prefs.setString(_kPushDeviceId, id);
    }
  }

  /// 已在中转端登记过推送的收件邮箱（小写）。
  ///
  /// 存下来是为了「取消订阅」时知道要删哪些 —— 中转端的 `/unregister`
  /// 不带邮箱是「全删」，而用户可能只想退掉其中一个。
  List<String> get pushMailboxes =>
      _prefs.getStringList(_kPushMailboxes) ?? const <String>[];

  Future<void> setPushMailboxes(List<String> mailboxes) async {
    if (mailboxes.isEmpty) {
      await _prefs.remove(_kPushMailboxes);
    } else {
      await _prefs.setStringList(_kPushMailboxes, mailboxes);
    }
  }

  /// 推送总开关。关掉只是不注册 / 注销，**不影响轮询与本地通知**。
  bool get pushEnabled => _prefs.getBool(_kPushEnabled) ?? false;

  Future<void> setPushEnabled(bool value) =>
      _prefs.setBool(_kPushEnabled, value);

  static const String _kPushIsAdmin = 'cm_push_is_admin';

  /// 推送向导第 ⑤ 页那句话的答案：「这个实例是你在管吗」。
  ///
  /// 它只决定要不要显示「复制转达文案」，不影响任何行为 —— 但**必须记住**：
  /// 一个只问一次的分岔，每次进来都回到「两个都没选中」，用户看到的是
  /// 「我从没答过」而不是「它没记」。`null` = 还没答过。
  bool? get pushIsAdmin => _prefs.getBool(_kPushIsAdmin);

  Future<void> setPushIsAdmin(bool value) =>
      _prefs.setBool(_kPushIsAdmin, value);

  /// AI 设置的非敏感部分（JSON 串）。**里面绝不含 Key** —— 见 `AiSettingsCodec`。
  String? get aiSettingsJson => _prefs.getString(_kAiSettings);

  Future<void> setAiSettingsJson(String? json) async {
    if (json == null || json.isEmpty) {
      await _prefs.remove(_kAiSettings);
    } else {
      await _prefs.setString(_kAiSettings, json);
    }
  }

  /// 每日调用计数，形如 `2026-10-10:7`（见 `AiUsageCounter`）。
  String? get aiUsage => _prefs.getString(_kAiUsage);

  Future<void> setAiUsage(String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(_kAiUsage);
    } else {
      await _prefs.setString(_kAiUsage, value);
    }
  }

  @visibleForTesting
  Future<void> clearAll() => _prefs.clear();
}
