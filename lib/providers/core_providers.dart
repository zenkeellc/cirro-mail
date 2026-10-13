import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/database.dart';
import '../core/notify/new_mail_bus.dart';
import '../core/network/auth_events.dart';
import '../core/storage/attachment_cache.dart';
import '../core/storage/prefs_store.dart';
import '../core/storage/token_store.dart';
import '../core/util/diag_log.dart';
import '../l10n/app_localizations.dart';
import '../data/repositories/account_repository.dart';
import '../data/repositories/attachment_repository.dart';
import '../data/repositories/capability_repository.dart';
import '../data/repositories/config_repository.dart';
import '../data/repositories/email_repository.dart';
import '../data/repositories/profile_repository.dart';
import '../data/repositories/send_repository.dart';
import '../instance/runtime_registry.dart';
import '../instance/sync_scheduler.dart';

/// 启动时**必须**注入的那几样东西。
///
/// 它们都依赖平台（`shared_preferences` / 密钥库 / 原生 SQLite），只能在
/// `runApp` 之前异步建好，没法在 provider 里 await。另外它们要么不可再建
/// （drift 库同一时刻只能有一个连接），要么必须全局唯一（总线、事件流），
/// 所以用不可变容器一次性传进来，而不是每个各占一个 provider 去 `throw`。
///
/// 启动失败（例如密钥库不可用、库文件损坏）时不抛异常 —— 把错误塞进
/// [bootstrapError]，让 App 起来后显示一个能重试的页面，
/// 而不是黑屏或直接崩在 `main` 里。
@immutable
class BootstrapData {
  const BootstrapData({
    required this.db,
    required this.tokens,
    required this.prefs,
    this.bootstrapError,
  });

  final AppDatabase db;
  final TokenStore tokens;
  final PrefsStore prefs;

  /// 启动流程里捕获到的异常（非空时 App 落在启动失败页）。
  final Object? bootstrapError;

  bool get isHealthy => bootstrapError == null;
}

/// 在 `bootstrap.dart` 里 `overrideWithValue`。
final Provider<BootstrapData> bootstrapProvider = Provider<BootstrapData>(
  (ref) => throw StateError(
    'bootstrapProvider 必须被 override —— 见 lib/bootstrap.dart',
  ),
  name: 'bootstrap',
);

/// 「重新跑一遍启动流程」的钩子。
///
/// 启动失败页不能用 `ref.invalidate(bootstrapProvider)` 来重试 —— 那个值是被
/// `overrideWithValue` 钉死的，重算只会又拿到同一个坏实例。真正的重试必须由
/// `main.dart` 的 `BootstrapGate` 重新执行 `bootstrap()` 并换一个 `ProviderScope`
/// 的 key 重建整棵依赖图，所以这里只暴露那个回调。
final Provider<void Function()> bootstrapRetryProvider =
    Provider<void Function()>(
  (ref) => () {},
  name: 'bootstrapRetry',
);

final Provider<AppDatabase> databaseProvider = Provider<AppDatabase>(
  (ref) => ref.watch(bootstrapProvider).db,
  name: 'database',
);

final Provider<TokenStore> tokenStoreProvider = Provider<TokenStore>(
  (ref) => ref.watch(bootstrapProvider).tokens,
  name: 'tokenStore',
);

final Provider<PrefsStore> prefsStoreProvider = Provider<PrefsStore>(
  (ref) => ref.watch(bootstrapProvider).prefs,
  name: 'prefsStore',
);

/// 本地化字符串，给**控制器**用（屏幕有自己的 `AppLocalizations.of(context)`）。
///
/// 控制器要在状态里放错误文案（「附件最多 10 个」这类），而它拿不到
/// `BuildContext`；放在状态里而不是让屏幕去翻译的原因是：
/// 文案与产生它的那件事是同一份知识（比如「收件人格式不对」要指名哪一个
/// 地址），分到两个地方写迟早会分叉。
///
/// 它读的是 `PrefsStore.localeCode` 这份**同步**的偏好，而不是 `localeProvider`
/// 的 `Locale?` —— 后者为 null 时表示「跟随系统」，那要看平台当前的语言，
/// 是同步拿不到的。用 `localeCode` 的语义：留空 = 中文（`zh`），
/// 与 App 的默认语言一致。
final Provider<AppLocalizations> l10nProvider = Provider<AppLocalizations>(
  (ref) => lookupAppLocalizations(
    Locale(ref.watch(prefsStoreProvider).localeCode == 'en' ? 'en' : 'zh'),
  ),
  name: 'l10n',
);

/// 401 的广播源。全局唯一 —— `DioFactory` 为每个实例建的拦截器都往这里发。
final Provider<AuthEvents> authEventsProvider = Provider<AuthEvents>(
  (ref) {
    final events = AuthEvents();
    ref.onDispose(events.dispose);
    return events;
  },
  name: 'authEvents',
);

/// 新邮件总线（通知服务订阅）。
final Provider<NewMailBus> newMailBusProvider = Provider<NewMailBus>(
  (ref) {
    final bus = NewMailBus();
    ref.onDispose(bus.dispose);
    return bus;
  },
  name: 'newMailBus',
);

/// `profileId → ProfileRuntime`。全局唯一持有 runtime 的地方。
final Provider<RuntimeRegistry> runtimeRegistryProvider =
    Provider<RuntimeRegistry>(
  (ref) {
    // 注意这里是 `ref.read` 而不是 `ref.watch`：回调里拿的是**当下**的仓储，
    // 而 `profileRepositoryProvider` 本身不依赖 registry（它只碰数据库、
    // 密钥库和 prefs），所以在构建期 watch 反而会多一条无谓的依赖边。
    final profiles = ref.read(profileRepositoryProvider);
    final registry = RuntimeRegistry(
      authEvents: ref.watch(authEventsProvider),
      tokens: ref.watch(tokenStoreProvider),
      prefs: ref.watch(prefsStoreProvider),
      enableLog: kDebugMode,
      // 401 必须**落库**：`Profile.isLoggedIn` 是 `router` 的 `redirect` 依据，
      // 只标内存的话杀掉重启又会变回「已登录」，用户被困在一个只会 401 的
      // 收件箱里。见 `RuntimeRegistry.onAuthExpired` 的注释。
      onAuthExpired: (String profileId) {
        unawaited(profiles.markNeedsLogin(profileId));
      },
    );
    ref.onDispose(registry.dispose);
    return registry;
  },
  name: 'runtimeRegistry',
);

final Provider<CapabilityRepository> capabilityRepositoryProvider =
    Provider<CapabilityRepository>(
  (ref) => CapabilityRepository(ref.watch(databaseProvider)),
  name: 'capabilityRepository',
);

final Provider<ConfigRepository> configRepositoryProvider =
    Provider<ConfigRepository>(
  (ref) => ConfigRepository(
    registry: ref.watch(runtimeRegistryProvider),
    capabilities: ref.watch(capabilityRepositoryProvider),
  ),
  name: 'configRepository',
);

final Provider<ProfileRepository> profileRepositoryProvider =
    Provider<ProfileRepository>(
  (ref) => ProfileRepository(
    db: ref.watch(databaseProvider),
    tokens: ref.watch(tokenStoreProvider),
    prefs: ref.watch(prefsStoreProvider),
  ),
  name: 'profileRepository',
);

final Provider<AccountRepository> accountRepositoryProvider =
    Provider<AccountRepository>(
  (ref) => AccountRepository(
    db: ref.watch(databaseProvider),
    registry: ref.watch(runtimeRegistryProvider),
    capabilities: ref.watch(capabilityRepositoryProvider),
    onDiskPurge: (profileId, emailId) =>
        ref.watch(attachmentRepositoryProvider).purgeMail(profileId, emailId),
  ),
  name: 'accountRepository',
);

final Provider<EmailRepository> emailRepositoryProvider =
    Provider<EmailRepository>(
  (ref) => EmailRepository(
    db: ref.watch(databaseProvider),
    registry: ref.watch(runtimeRegistryProvider),
    capabilities: ref.watch(capabilityRepositoryProvider),
    profiles: ref.watch(profileRepositoryProvider),
    prefs: ref.watch(prefsStoreProvider),
    // 删邮件后清磁盘上的附件目录（`AttachmentCache.deleteMail`）。
    onDiskPurge: (profileId, emailId) =>
        ref.watch(attachmentRepositoryProvider).purgeMail(profileId, emailId),
    // 老行（`account_id = 0`）被归位时把那一页列表顶一下，用户不用自己下拉。
    // 归位本身由 repository 写库，这里只负责让 UI 知道「刚才发生过」。
    onAccountIdsRepaired: (profileId, repaired) {
      DiagLog.log('sync', '归位 $repaired 封老邮件（$profileId）');
    },
  ),
  name: 'emailRepository',
);

/// 附件在磁盘上的落点与占用统计。
///
/// 做成 provider 是为了让测试能 override 一个指向临时目录的实例
/// （`path_provider` 在单测里没有平台通道）。
final Provider<AttachmentCache> attachmentCacheProvider =
    Provider<AttachmentCache>(
  (ref) => AttachmentCache(),
  name: 'attachmentCache',
);

final Provider<AttachmentRepository> attachmentRepositoryProvider =
    Provider<AttachmentRepository>(
  (ref) => AttachmentRepository(
    db: ref.watch(databaseProvider),
    registry: ref.watch(runtimeRegistryProvider),
    cache: ref.watch(attachmentCacheProvider),
    profiles: ref.watch(profileRepositoryProvider),
  ),
  name: 'attachmentRepository',
);

final Provider<SendRepository> sendRepositoryProvider =
    Provider<SendRepository>(
  (ref) => SendRepository(
    db: ref.watch(databaseProvider),
    registry: ref.watch(runtimeRegistryProvider),
    profiles: ref.watch(profileRepositoryProvider),
    emails: ref.watch(emailRepositoryProvider),
  ),
  name: 'sendRepository',
);

/// 多实例串行调度器。
///
/// **不在这个 provider 里启动** —— 启动/停止由 `SyncController` 按
/// 「有没有已登录的实例」和 App 前后台状态决定，见 `sync_providers.dart`。
final Provider<SyncScheduler> syncSchedulerProvider = Provider<SyncScheduler>(
  (ref) {
    // 注意 `ref.read`：回调里要的是**当下**的仓储实例，而不是让调度器
    // 依赖 `profileRepositoryProvider` 的构建（那会多一条无用的依赖边）。
    final profiles = ref.read(profileRepositoryProvider);
    final tokens = ref.watch(tokenStoreProvider);
    final scheduler = SyncScheduler(
      db: ref.watch(databaseProvider),
      registry: ref.watch(runtimeRegistryProvider),
      emails: ref.watch(emailRepositoryProvider),
      accounts: ref.watch(accountRepositoryProvider),
      capabilities: ref.watch(capabilityRepositoryProvider),
      prefs: ref.watch(prefsStoreProvider),
      bus: ref.watch(newMailBusProvider),
      sends: ref.watch(sendRepositoryProvider),
      // 「401 其实是虚惊一场」—— 预热之后拿到了 token，把落库的
      // `needs_login` 撤掉。与 `RuntimeRegistry.onAuthExpired` 是一对：
      // 那边出错时把它置上，这边确认其实没事时把它摘掉。
      //
      // **必须落库**：内存标记活不过重启，坏 token 会在杀掉重开之后
      // 又变回「已登录」（`Profile.isLoggedIn` 是路由 redirect 的依据），
      // 于是每次冷启动都要重演一遍「打开就 401、还跳不回登录页」。
      onSessionRecovered: (profileId) async {
        if (tokens.isDegraded) {
          // 钥匙串不可用时「读到 token」是内存态，重启就没了 ——
          // 这时候摘标记只会让用户在下一次冷启动再吃一遍 401。
          DiagLog.log('sync', '钥匙串降级中，不撤销 needs_login（$profileId）');
          return;
        }
        await profiles.markNeedsLogin(profileId, needsLogin: false);
      },
    );
    ref.onDispose(scheduler.dispose);
    return scheduler;
  },
  name: 'syncScheduler',
);
