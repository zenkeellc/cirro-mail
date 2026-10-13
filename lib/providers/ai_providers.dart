import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/token_store.dart';
import '../features/ai/ai_service.dart';
import '../features/ai/ai_settings.dart';
import '../features/ai/ai_settings_store.dart';
import 'core_providers.dart';

/// AI 设置与 Key 的存取。
///
/// 单独一个 provider（而不是让 `AiSettingsController` 自己 new 一个）是为了
/// **测试能换掉钥匙串**：注入一个走内存的 `AiApiKeyStore` 就不用碰平台通道。
final Provider<AiSettingsStore> aiSettingsStoreProvider =
    Provider<AiSettingsStore>(
  (ref) => AiSettingsStore(
    prefs: ref.watch(prefsStoreProvider),
    // 复用 `token_store.dart` 的实例构造：macOS 必须关掉 data protection
    // keychain，否则读写一律 `errSecMissingEntitlement`（见那里的长注释）。
    keys: AiApiKeyStore(storage: defaultSecureStorage()),
  ),
  name: 'aiSettingsStore',
);

/// 每日调用计数。
final Provider<AiUsageCounter> aiUsageProvider = Provider<AiUsageCounter>(
  (ref) => AiUsageCounter(prefs: ref.watch(prefsStoreProvider)),
  name: 'aiUsage',
);

/// 四项能力共用的接线层。
final Provider<AiService> aiServiceProvider = Provider<AiService>(
  (ref) => AiService(
    store: ref.watch(aiSettingsStoreProvider),
    usage: ref.watch(aiUsageProvider),
  ),
  name: 'aiService',
);

/// 当前 AI 设置。**异步** —— 「有没有 Key」只有钥匙串知道，读它要走平台通道。
///
/// 用 `AsyncNotifier` 而不是 `FutureProvider`：设置页要能改它（保存设置、填 Key、
/// 清 Key），而这些动作要立刻反映到 `state`，不能等一次 `invalidate` 重读 ——
/// 重读会把界面上「正在保存」的中间态又打回「加载中」。
class AiSettingsController extends AsyncNotifier<AiSettings> {
  /// 「钥匙串里到底有没有 Key」。**三态**：
  /// - `null` —— **还不知道**（首读还在飞，或首读失败）；
  /// - `true` / `false` —— 一次**成功的**回读给出的结论。
  ///
  /// 为什么不照计划原文从 `state.value?.hasApiKey` 推：`build()` 是异步的，
  /// 冷启动时 state 先是 `AsyncLoading`、`.value` 是 `null`。原文用
  /// `?? const AiSettings()` 兜底，等于把这段时间的结论定成 `false` ——
  /// 而 `false` 是「确知没有 Key」这个断言，冷启动时我们**并没有**这个断言
  /// （Key 在钥匙串里，那半边还没读到）。于是「钥匙串里明明有 Key」会被显示成
  /// 「没配过」，AI 入口凭空变灰（缺陷①，复核者实测复现）。这个字段只由
  /// 「成功的读」来更新，专门守住「已知的 Key 存在性」。
  bool? _hasKey;

  @override
  Future<AiSettings> build() async {
    // 每开始一次读，存在性先退回「未知」—— 否则一次失败的**重读**会拿着上
    // 一次成功读留下的布尔值冒充结论（与缺陷③同一种病：把没验证的东西当真的）。
    _hasKey = null;
    final loaded = await ref.watch(aiSettingsStoreProvider).load();
    _hasKey = loaded.hasApiKey;
    return loaded;
  }

  AiSettingsStore get _store => ref.read(aiSettingsStoreProvider);

  /// 保存非敏感设置。**不碰 Key**。
  Future<void> save(AiSettings next) async {
    await _store.save(next);
    final known = _hasKey;
    if (known == null) {
      // 「有没有 Key」还没有答案：首读在飞（`AsyncLoading`），或首读已经失败
      // （`AsyncError`）。这里**刻意什么都不改 state**：
      // - 用 `state.value ?? const AiSettings()` 兜底会把 `hasApiKey` 抹成
      //   false（缺陷①）；
      // - 直接落一个 `AsyncData` 又等于替那次失败的读背书，把 `AsyncError`
      //   吞成成功态（缺陷③）。
      // 保持原状最诚实：非敏感那半已经写进 prefs，等 `build()` 的读落地
      // （或下一次 [setApiKey] 的回读）自然会把一份完整、可信的 `AiSettings`
      // 铺上去 —— 设置不会丢，只是这一刻「够不够可信」还不成立。
      return;
    }
    // 只把「有没有 Key」从**已读到的**事实带过来 —— Key 本身不在这个对象里，
    // 不带的话 `hasApiKey` 会被 `save` 的入参覆盖成调用方以为的值。
    state = AsyncData(next.copyWith(hasApiKey: known));
  }

  /// 设 Key。空串 = 清掉。
  Future<void> setApiKey(String key) async {
    await _store.setApiKey(key);
    // **写完回读一次校准**：`AiApiKeyStore.write` 会把平台异常吞掉
    // （Linux 没装 libsecret / 钥匙串被锁 / 插件没注册），只看入参的话会报出
    // 一个「写进去了」的假象（缺陷②，复核者实测复现）。以回读为准：
    // - 读得到值 → `true`（写成功，或钥匙串里本来就有别的值）；
    // - 读不到   → `false`（值确实没进去，重启后也不会有）。
    // 不去猜「本次运行还能不能用」：`AiApiKeyStore` **没有内存兜底**，读不回来
    // 就是真的读不回来，谎报 `true` 会让上面那句 `aiKeyDegraded`（「这次能用」）
    // 变成空话。而「这台设备存不住 Key」这层提示由 `isKeychainDegraded` 单独
    // 带出去（设置页 `aiKeyDegraded` 文案读的就是它），与 `hasApiKey` 各管一段。
    final stored = await _store.readApiKey();
    _hasKey = stored != null;
    state = AsyncData(
      (state.value ?? const AiSettings()).copyWith(hasApiKey: _hasKey!),
    );
  }
}

final AsyncNotifierProvider<AiSettingsController, AiSettings> aiSettingsProvider =
    AsyncNotifierProvider<AiSettingsController, AiSettings>(
  AiSettingsController.new,
  name: 'aiSettings',
);
