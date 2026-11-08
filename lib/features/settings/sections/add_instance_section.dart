import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/theme/breakpoints.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/util/diag_log.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/website_config.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/core_providers.dart';
import '../../../router.dart' as app_router;
import '../settings_widgets.dart';

/// 「设置 → 实例 → 添加实例」那张表单 —— **嵌在设置页里的形态**。
///
/// ## 为什么不再是一张独立整页
///
/// 它原来是一条顶层路由（`/settings/add-instance`，挂着自己的一整个
/// `Scaffold`）。全 App 只有它和 `/setup` 两处要「填地址 → 测连通 → 建实例」，
/// 而它们的形状在界面上是同一件事。用户在新装（一个实例都没有）时点设置，
/// 会**整窗**被这张表单接走：一级导航（宽屏侧栏 / 窄屏底部导航）与设置页的
/// 分类菜单（宽屏分类栏 / 窄屏分类列表）全都不在。那不是用户要的
/// 「设置里的一个功能」，看着像另一个 App。
///
/// 现在它是设置页的一栏正文：宽屏留在分类栏右侧，窄屏是设置分类页
/// （`SettingsScreen` 负责壳与返回）。`/setup` 与 `/settings/add-instance`
/// 两个旧地址保留成重定向（见 `router.dart`），深链不会 404。
///
/// ## 关键设计：**先测连通性再建实例**
///
/// 测试调的是免鉴权的 `GET /setting/websiteConfig`（见 `SettingApi`），能通
/// 就说明地址填对了、也确认了对面确实是个 cloud-mail 实例 —— 否则用户会在
/// 登录页反复输密码，而问题其实在地址上。
///
/// 建实例和登录是**两步**：建完 profile 立刻跳到 `/login/<profileId>`，登录
/// 失败时 profile 已经存在，用户可以直接重试而不用重填地址。登录成功后的
/// 落点是设置页（`?next=settings`）—— 用户是从设置里点进来的。
class AddInstanceSection extends ConsumerStatefulWidget {
  const AddInstanceSection({
    super.key,
    required this.onCancel,
    this.onCreated,
  });

  /// 退回「实例」列表（宽屏那颗返回箭头、窄屏设置页返回都落到这里）。
  final VoidCallback onCancel;

  /// 实例**已经建好**、即将跳登录页时调一次。
  ///
  /// 宿主（`InstancesSection` 的 `adding` 状态）靠它回到列表形态 —— 否则
  /// 用户在登录页按返回、或者登录成功之后回设置页，会看到那张已经提交过的
  /// 表单还开着。
  final VoidCallback? onCreated;

  @override
  ConsumerState<AddInstanceSection> createState() => _AddInstanceSectionState();
}

class _AddInstanceSectionState extends ConsumerState<AddInstanceSection> {
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

    return SettingsPage(
      children: <Widget>[
        // 宽屏：一颗显式的「退回实例列表」。分类栏虽然常驻，但那一栏的
        // 高亮还停在「实例」上，不给箭头的话用户只能靠「再点一次实例」
        // 猜出来。窄屏**不画**这一行 —— 设置页 AppBar 那颗返回箭头就是
        // 同一个落点，画两个是两颗一样的箭头。
        if (Breakpoints.panesOf(context))
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onCancel,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: Text(l10n.instances),
              ),
            ),
          ),
        // 两个输入框装进设置页那张卡片里，与其余分类同一门语言。
        SettingsGroup(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                ],
              ),
            ),
          ],
        ),
        if (_config != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: _ConnectedCard(config: _config!),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: _ErrorCard(error: _error!, describe: _describe),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: FilledButton.icon(
            // 没测通就不让建 —— 建出来只会是一个登不进去的空实例。
            onPressed: _config == null || _creating ? null : _create,
            icon: const Icon(Icons.login),
            label: Text(l10n.addAndSignIn),
          ),
        ),
      ],
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
      // 表单已经提交掉，宿主先退回列表形态，再跳登录页 —— 登录失败/成功
      // 回到设置页时看到的该是实例列表，而不是一张填过的旧表单。
      widget.onCreated?.call();
      // 建完立刻去登录；登录失败时 profile 还在，用户能直接重试。
      // 从设置页进来的，登完回设置页（`?next=settings`）。
      context.go('${app_router.Routes.login}/${profile.id}?next=settings');
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

/// 连接失败的那张卡。
///
/// 单独一层是因为它要跟着表单一起嵌进设置页（设置页自己的正文容器是
/// `SettingsPage`，卡片得是它的直接子项才能吃到同一套限宽/内边距）。
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.describe});

  final Object error;
  final String Function(Object) describe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.onErrorContainer),
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
              describe(error),
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
    );
  }
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
