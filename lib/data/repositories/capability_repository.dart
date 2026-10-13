import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/db/database.dart';
import '../../instance/profile_runtime.dart';
import '../models/instance_capabilities.dart';
import '../models/user_info.dart';
import '../models/website_config.dart';

/// 能力探测：把「这台实例支持什么」变成一份可读、可落库、可降级的结论。
///
/// 设计原则（对着 `data/models/instance_capabilities.dart` 一起看）：
/// - **探测失败不抛错**。任何一个探测项出错都只影响它自己那一格，
///   其余照常；网络不好时整轮探测保持 `unknown`，UI 按「乐观可用」处理。
/// - **`absent` 与 `denied` 分开**。前者是「这个版本/分支没有这个端点」→ 隐藏入口；
///   后者是「有端点但当前账号没权限」→ 保留入口，提示联系管理员。
/// - 只调**便宜且安全**的端点，每轮登录后跑一次，结果落 `capabilities` 表。
///
/// 刻意**不在登录时**探的两项（都需要一个真实 `emailId`，登录时未必有）：
/// - `hasFullFlag`：由第一次 `full=1` 列表的实际返回决定（[noteFullSupport]）；
/// - `hasAttListEndpoint`：由第一次拉附件的结果决定（[noteAttListSupport]）。
class CapabilityRepository {
  CapabilityRepository(this.db);

  final AppDatabase db;

  Stream<InstanceCapabilities?> watch(String profileId) =>
      db.profileDao.watchCapabilities(profileId);

  Future<InstanceCapabilities> of(String profileId) async =>
      await db.profileDao.loadCapabilities(profileId) ??
      const InstanceCapabilities();

  Future<void> save(String profileId, InstanceCapabilities caps) =>
      db.profileDao.saveCapabilities(profileId, caps);

  /// 抹掉某个实例的能力结论。
  ///
  /// 与 `ConfigRepository.forget` 配对：临时探针（`__probe__`）用完两边都要清。
  /// 只清内存缓存是不够的 —— 能力结论是**落库**的，漏掉这一句会在库里留一行
  /// 永远不会有实例来认领的记录（设置页/诊断页会把 `__probe__` 当成一个实例列出来）。
  Future<void> forget(String profileId) =>
      db.profileDao.deleteCapabilities(profileId);

  /// 跑一轮完整探测。
  ///
  /// [websiteConfig] 已在登录流程里拿过一次的话可以传进来，省一次请求。
  /// [userInfo] 用来判定发信权限（`email:send`）。
  Future<InstanceCapabilities> probe(
    ProfileRuntime runtime, {
    WebsiteConfig? websiteConfig,
    UserInfo? userInfo,
    int primaryAccountId = 0,
  }) async {
    final profileId = runtime.profileId;
    final previous = await of(profileId);
    var caps = previous;

    // ---- 1. 站点配置（免鉴权，也是「地址填对了吗」的探针）----
    WebsiteConfig? config = websiteConfig;
    if (config == null) {
      try {
        // 探测这趟本来就是在登录后跑的（`userInfo` 是从 `loginUserInfo` 来的），
        // 带上 token 才能拿到真的 `domainList` —— 而域名单正是「添加邮箱」
        // 那一屏的后缀下拉所依赖的（规格 §5.1）。
        config = await runtime.settingApi.websiteConfig(
          authenticated: runtime.hasToken,
        );
      } catch (_) {
        // 配置拿不到不阻断其余探测 —— 但 r2Domain/autoRefresh 保持原值。
      }
    }
    if (config != null) {
      caps = applyWebsiteConfig(caps, config);
    }

    // ---- 2. 星标 ----
    caps = caps.copyWith(
      hasStar: await _probe(
        () => runtime.starApi.list(profileId: profileId, size: 1),
      ),
    );

    // ---- 3. 邮箱列表（account:query 权限）----
    caps = caps.copyWith(
      hasAccountQuery: await _probe(
        () => runtime.accountApi.list(size: 1),
      ),
    );

    // ---- 4. 增量接口 ----
    // `allReceive=1` 时服务端会跳过 accountId 条件，所以这里不需要真实邮箱。
    caps = caps.copyWith(
      hasLatest: await _probe(
        () => runtime.emailApi.latest(
          profileId: profileId,
          cursorEmailId: 0,
          accountId: primaryAccountId,
          allReceive: true,
        ),
      ),
    );

    // ---- 5. 发信权限 ----
    caps = caps.copyWith(hasSend: _resolveSend(previous, userInfo));

    // ---- 6. 邮箱管理三闸（添加 / 删除 / 改名）----
    caps = caps.copyWith(
      hasAccountAdd: resolveAccountAdd(previous, userInfo),
      hasAccountDelete: resolveAccountPerm(
        previous.hasAccountDelete,
        userInfo,
        'account:delete',
      ),
      hasAccountRename: resolveAccountPerm(
        previous.hasAccountRename,
        userInfo,
        'email:send',
      ),
    );

    caps = caps.copyWith(probedAt: DateTime.now().toUtc());
    await save(profileId, caps);
    return caps;
  }

  /// 冷启动补探：只按权限重算那几格（不重跑整轮 [probe]）。
  ///
  /// 为什么需要它：[probe] 只在登录时跑一次，而 `hasAccountDelete` /
  /// `hasAccountRename` 的 UI 判据是 `== ProbeState.available` —— 一个已登录
  /// 用户**冷启动之后**永远看不到删 / 改名（`unknown` 直接隐藏），直到他重新
  /// 登录一次。`UserInfo` 又不落库，除了重新登录没有第二条路能拿到权限，
  /// 所以这里按需补一次（调用点见 `providers/sync_providers.dart` 的
  /// `probePermsInBackground`）。
  ///
  /// [userInfo] 为 null 时**原样返回、不写库** —— 与 [resolveAccountPerm]
  /// 的既有口径一致：「没拿到身份」不等于「没权限」，抹掉已探到的结论
  /// 比不写更糟。
  ///
  /// 刻意**不动 `probedAt`**：那是「上一轮完整探测」的时间戳，这里只补了
  /// 权限那几格，写上去会让诊断页把这一轮当成一次完整探测。
  Future<void> applyPerms(String profileId, UserInfo? userInfo) async {
    if (userInfo == null) return;
    final previous = await of(profileId);
    await save(
      profileId,
      previous.copyWith(
        hasSend: _resolveSend(previous, userInfo),
        hasAccountAdd: resolveAccountAdd(previous, userInfo),
        hasAccountDelete: resolveAccountPerm(
          previous.hasAccountDelete,
          userInfo,
          'account:delete',
        ),
        hasAccountRename: resolveAccountPerm(
          previous.hasAccountRename,
          userInfo,
          'email:send',
        ),
      ),
    );
  }

  /// 站点配置里能直接读出来的那几项。
  ///
  /// [previous] 里的部分结论**不覆盖**：`hasStar` / `hasAccountQuery` 只有真调过
  /// 端点才知道，而 `websiteConfig` 是免鉴权的，带 token 与否结果可能不同
  /// （例如 `domainList` 在未登录时是空的）。所以这个方法只写它管的字段。
  InstanceCapabilities applyWebsiteConfig(
    InstanceCapabilities previous,
    WebsiteConfig config,
  ) {
    final hasR2 = (config.r2Domain ?? '').trim().isNotEmpty;
    return previous.copyWith(
      serverTitle: config.title,
      r2Domain: config.r2Domain,
      domainList: config.domainList,
      hasR2Domain:
          hasR2 ? ProbeState.available : ProbeState.absent,
      hasAutoRefresh: config.hasConfiguredAutoRefresh
          ? ProbeState.available
          : ProbeState.absent,
      // `send == 1` 是「服务端明确关掉了发信」，与「端点不存在」不是一回事。
      sendDisabledByConfig: !config.sendEnabled,
      registerDisabledByConfig: !config.registerEnabled,
      // `addMailboxEnabled`（`addEmail == 0 && manyEmail == 0`）这个 getter
      // 此前**零调用者** —— 它正是服务端 `accountService.add` 开头那一句的
      // 客户端镜像，这里用上。
      addMailboxDisabledByConfig: !config.addMailboxEnabled,
    );
  }

  /// 从权限推导发信能力。
  ///
  /// `send: false`（站点关掉了）→ `absent`（隐藏入口）；
  /// 有配置但缺 `email:send` 权限 → `denied`（提示，不隐藏）；
  /// 权限未知（探测时没拿到 userInfo）→ 保持原值，别把已探到的结论抹掉。
  static ProbeState _resolveSend(
    InstanceCapabilities previous,
    UserInfo? userInfo,
  ) {
    if (previous.sendDisabledByConfig) return ProbeState.absent;
    if (userInfo == null) return previous.hasSend;
    return userInfo.hasPerm('email:send')
        ? ProbeState.available
        : ProbeState.denied;
  }

  /// 从权限推导「能不能加邮箱」。
  ///
  /// 比 [InstanceCapabilities.accountAddEnabled] 多一层：站点关掉添加时
  /// 直接给 `absent`。两处判断**都要保留** —— 这一处是「探测时就知道」，
  /// 那一处是「UI 渲染时再确认一次」，而 `applyWebsiteConfig` 与 `probe()`
  /// 可能不是同一次运行里发生的（配置来自缓存、权限来自刚刚的登录）。
  ///
  /// `@visibleForTesting`：两条早退（`addMailboxDisabledByConfig` 优先、
  /// 无 `userInfo` 保持原值）是规格点名的规矩，必须能被直接钉住 ——
  /// 走 `probe()` 端到端太贵（要真打网络、要 `ProfileRuntime`）。
  @visibleForTesting
  static ProbeState resolveAccountAdd(
    InstanceCapabilities previous,
    UserInfo? userInfo,
  ) {
    if (previous.addMailboxDisabledByConfig) return ProbeState.absent;
    return resolveAccountPerm(
      previous.hasAccountAdd,
      userInfo,
      'account:add',
    );
  }

  /// 从权限推导一项能力。[previous] 只在拿不到 `userInfo` 时兜底 ——
  /// 「没拿到身份」不等于「没权限」，抹掉已探到的结论会让用户每次冷启动
  /// 都看见功能闪一下又回来。
  ///
  /// `@visibleForTesting`：理由同 [resolveAccountAdd]。
  @visibleForTesting
  static ProbeState resolveAccountPerm(
    ProbeState previous,
    UserInfo? userInfo,
    String perm,
  ) {
    if (userInfo == null) return previous;
    return userInfo.hasPerm(perm) ? ProbeState.available : ProbeState.denied;
  }

  /// 记录「这一次 `full=1` 的实际返回里到底有没有 `content` / `attList`」。
  ///
  /// 有些分支会在 `full` 参数上做手脚（永远返回摘要），客户端不该等到
  /// 用户点开详情才发现。列表侧拿到真实行之后回写一次。
  Future<void> noteFullSupport(
    String profileId, {
    required bool supported,
  }) async {
    final current = await of(profileId);
    final next = supported ? ProbeState.available : ProbeState.absent;
    if (current.hasFullFlag == next) return;
    await save(profileId, current.copyWith(hasFullFlag: next));
  }

  /// 记录 `GET /email/attList` 的真实可用性（老版本没有这个端点）。
  Future<void> noteAttListSupport(
    String profileId, {
    required bool supported,
  }) async {
    final current = await of(profileId);
    final next = supported ? ProbeState.available : ProbeState.absent;
    if (current.hasAttListEndpoint == next) return;
    await save(profileId, current.copyWith(hasAttListEndpoint: next));
  }

  /// 记录一次明确的 403（例如点发信时才发现没权限），立刻降级。
  Future<void> noteDenied(String profileId, CapabilityFlag flag) async {
    final current = await of(profileId);
    await save(
      profileId,
      switch (flag) {
        CapabilityFlag.star => current.copyWith(hasStar: ProbeState.denied),
        CapabilityFlag.accountQuery =>
          current.copyWith(hasAccountQuery: ProbeState.denied),
        CapabilityFlag.send => current.copyWith(hasSend: ProbeState.denied),
        CapabilityFlag.latest => current.copyWith(hasLatest: ProbeState.denied),
        CapabilityFlag.accountAdd =>
          current.copyWith(hasAccountAdd: ProbeState.denied),
        CapabilityFlag.accountDelete =>
          current.copyWith(hasAccountDelete: ProbeState.denied),
        CapabilityFlag.accountRename =>
          current.copyWith(hasAccountRename: ProbeState.denied),
      },
    );
  }

  /// 探测一项。任何异常都映射成 `ProbeState.fromCode` 的结果，
  /// **绝不让探测失败冒泡成用户可见的错误**。
  static Future<ProbeState> _probe(Future<Object?> Function() run) async {
    try {
      await run();
      return ProbeState.available;
    } catch (e) {
      return ProbeState.fromCode(probeCodeOf(e));
    }
  }

  /// 从异常里取出信封码（`ApiException.code` 就是服务端的 `code`）。
  /// 拿不到就返回 null → `ProbeState.unknown`（下次再探，不误判为不支持）。
  static int? probeCodeOf(Object error) {
    try {
      final code = (error as dynamic).code;
      return code is int ? code : null;
    } catch (_) {
      return null;
    }
  }
}

/// 可单独降级的能力项。
enum CapabilityFlag {
  star,
  accountQuery,
  send,
  latest,
  accountAdd,
  accountDelete,
  accountRename,
}

/// 判断一封邮件该不该走 `full=1` 补拉。
///
/// `hasFullBody == false` 说明本地只有摘要；但如果实例**根本不支持** `full`，
/// 补拉也没有意义，不如直接用摘要渲染（正文里那 300 字至少能看）。
bool shouldFetchFull(InstanceCapabilities caps, {required bool hasFullBody}) {
  if (hasFullBody) return false;
  return caps.fullFlagEnabled;
}

/// 是否该用 `/email/latest` 做增量（否则退化成「列表首页比对游标」）。
bool shouldUseLatestCursor(InstanceCapabilities caps) => caps.latestEnabled;
