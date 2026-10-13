import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_defaults.dart';
import '../../core/error/app_exception.dart';
import '../../core/util/diag_log.dart';
import '../../data/models/profile.dart';
import '../../data/models/website_config.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/profile_providers.dart';
import '../../router.dart' as app_router;

/// 「服务器设置」页：填地址 → 测试连接 → 建实例 → 去登录。
///
/// 关键设计：**先测连通性再建实例**。测试调的是免鉴权的
/// `GET /setting/websiteConfig`（见 `SettingApi`），能通就说明地址填对了、
/// 也确认了对面确实是个 cloud-mail 实例 —— 否则用户会在登录页反复输密码，
/// 而问题其实在地址上。
///
/// 建实例和登录是**两步**：建完 profile 立刻跳到 `/login/<profileId>`，
/// 登录失败时 profile 已经存在，用户可以直接重试而不用重填地址。
class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key, this.returnToCaller = false});

  /// 从设置页进来时为 true：登录成功后回设置页（而不是被 redirect 送去聚合页）。
  final bool returnToCaller;

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  final TextEditingController _url = TextEditingController(
    text: AppDefaults.defaultBaseUrl,
  );
  final TextEditingController _name = TextEditingController();

  WebsiteConfig? _config;
  Object? _error;
  bool _testing = false;
  bool _creating = false;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final hasInstances = ref.watch(profilesProvider).value?.isNotEmpty ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addInstance),
        // 一个实例都没有时不给返回 —— 退回去是一个空壳（redirect 又会送回来）。
        automaticallyImplyLeading: hasInstances,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              TextField(
                controller: _url,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.serverAddress,
                  hintText: l10n.serverAddressHint,
                  prefixIcon: const Icon(Icons.dns_outlined),
                ),
                // 地址改了，之前的测试结论就作废 —— 不然用户会以为新地址也通了。
                onChanged: (_) {
                  if (_config != null || _error != null) {
                    setState(() {
                      _config = null;
                      _error = null;
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l10n.nickname,
                  prefixIcon: const Icon(Icons.label_outline),
                  // 备注名可空：留空时用站点标题或邮箱（见 `Profile.displayName`）。
                  helperText: l10n.nicknameHint,
                ),
              ),
              const SizedBox(height: 20),
              if (_testing)
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(l10n.testing),
                  ],
                )
              else
                OutlinedButton.icon(
                  onPressed: _test,
                  icon: const Icon(Icons.wifi_tethering),
                  label: Text(l10n.testConnection),
                ),
              const SizedBox(height: 16),
              if (_config != null) _ConnectedCard(config: _config!),
              if (_error != null)
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(Icons.error_outline,
                                size: 18,
                                color: theme.colorScheme.onErrorContainer),
                            const SizedBox(width: 8),
                            Text(
                              l10n.connectionFailed,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _describe(_error!),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l10n.checkAddress,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton.icon(
                // 没测通就不让建 —— 建出来只会是一个登不进去的空实例。
                onPressed: _config == null || _creating ? null : _create,
                icon: const Icon(Icons.login),
                label: Text(l10n.addAndSignIn),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _test() async {
    final raw = _url.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = _EmptyAddress());
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
      _config = null;
    });

    const probeId = '__probe__';
    final registry = ref.read(runtimeRegistryProvider);
    DiagLog.log('测试连接', '开始，地址=$raw');
    try {
      // 用一个临时 profile 去请求 —— `ProfileRuntime` 需要一个完整 profile，
      // 但它不会被落库。请求前必须先 `ensure`（`ConfigRepository` 只认已建好的
      // runtime，这是刻意的：它不该自己造 Dio）。
      final probe = Profile(id: probeId, baseUrl: raw);
      registry.ensure(probe);
      final config = await DiagLog.trace(
        '测试连接',
        'fetch websiteConfig',
        () => ref
            .read(configRepositoryProvider)
            .fetch(probe, force: true, allowStaleOnError: false),
      );
      if (!mounted) return;
      setState(() {
        _config = config;
        _testing = false;
        // 站点标题回填到备注名，用户少打一次字（可以再改）。
        if (_name.text.trim().isEmpty && config.title.isNotEmpty) {
          _name.text = config.title;
        }
      });
      DiagLog.log('测试连接', '成功，标题=${config.title}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _testing = false;
      });
      DiagLog.log('测试连接', '失败：${e.runtimeType}: $e');
    } finally {
      // 把这条临时 runtime 丢掉，否则每点一次「测试连接」都会多留一条 Dio。
      //
      // ⚠️ 这一步会 `dispose()` 掉探针的 runtime，而在途请求此时**可能还没回来**
      // （`dispose` 里 `close(force: true)` 会取消它们）。所以上面那句成功的
      // 日志一定在 `finally` 之前打，别把结论挪到这里来 —— 那会看到一个
      // 永远是「已取消」的假象。
      DiagLog.log('测试连接', '清理探针 runtime');
      registry.discard(probeId);
      // `forget` 是同步的（只清内存里的三个 map）。
      ref.read(configRepositoryProvider).forget(probeId);
      // 能力结论是**落库**的：`fetch` 成功时会把站点标题同步进 `capabilities`
      // 表（见 `ConfigRepository._syncCapabilities`），那一下是 fire-and-forget，
      // 到这里可能还没写完 —— 所以不能只删一次就走，要等它落地之后再删干净。
      unawaited(_clearProbeCapabilities(ref, probeId));
    }
  }

  /// 抹掉探针在 `capabilities` 表里留下的那行。
  ///
  /// 库里留一个 `__probe__` 条目看着无害，其实会在诊断页/实例相关的地方
  /// 冒出一个「幽灵实例」；而这个探测结论对用户没有任何价值（它属于一个
  /// 不存在的 profile）。做法：先同步删一次（正常路径下写入已完成，一次即中），
  /// 再延后复查几次 —— 只为兜住那条 fire-and-forget 的写晚于本次删除的窄窗口。
  static Future<void> _clearProbeCapabilities(
    WidgetRef ref,
    String probeId,
  ) async {
    final capabilities = ref.read(capabilityRepositoryProvider);
    for (final delay in const <Duration>[
      Duration.zero,
      Duration(milliseconds: 300),
      Duration(seconds: 2),
    ]) {
      await Future<void>.delayed(delay);
      try {
        await capabilities.forget(probeId);
      } catch (e) {
        // 清理是尽力而为的收尾动作，不能因为它把「测试连接」的结果搞崩。
        DiagLog.log('测试连接', '清理探针能力表失败：${e.runtimeType}: $e');
        return;
      }
    }
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final profile = await ref.read(profileRepositoryProvider).create(
            baseUrl: _url.text.trim(),
            name: _name.text.trim(),
            serverTitle: _config?.title ?? '',
          );
      if (!mounted) return;
      // 建完立刻去登录；登录失败时 profile 还在，用户能直接重试。
      // 从设置页进来的话登完回设置页（`?next=settings`），否则回聚合。
      final next = widget.returnToCaller ? '?next=settings' : '';
      context.go('${app_router.Routes.login}/${profile.id}$next');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _creating = false;
      });
    }
  }

  /// 把异常翻成一句人看得懂的话。
  String _describe(Object error) {
    if (error is AppException) {
      final raw = error.rawMessage;
      return raw == null || raw == error.userMessage
          ? error.userMessage
          : '${error.userMessage}\n$raw';
    }
    return '$error';
  }
}

/// 本地校验失败（不是服务端错误）。
///
/// 用异常形态是为了让它和网络错误走同一条展示路径 —— 页面里只有一处
/// `_error` 卡片，分两个状态字段会让 UI 分叉。
class _EmptyAddress implements Exception {
  const _EmptyAddress();

  @override
  String toString() => '请填写服务器地址';
}

/// 连通成功后的回显：站点标题 + 发信开关 + 域名列表。
///
/// 回显这几项不只是「好看」—— 它是用户确认「连到我以为的那台机器」的唯一依据
/// （自建实例可能有好几个，标题一样、发信开关不同）。
class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.config});

  final WebsiteConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.check_circle_outline,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.connectedTo(config.title),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _row(context, '发信', config.sendEnabled ? '开放' : '关闭'),
            _row(context, '注册', config.registerEnabled ? '开放' : '关闭'),
            _row(
              context,
              '附件域名',
              // r2Domain 为 null 时是**正常**的（走 /api/oss/），要说清楚，
              // 否则用户会以为少配了什么。
              (config.r2Domain ?? '').isEmpty ? '未配置（走 /api/oss/）' : config.r2Domain!,
            ),
            _row(
              context,
              '域名',
              config.domainList.isEmpty ? '未返回（登录后再看）' : config.domainList.join('、'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
