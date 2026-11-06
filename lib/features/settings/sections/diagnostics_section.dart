import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/config/session_expiry.dart';
import '../../../core/network/endpoints.dart';
import '../../../data/models/instance_capabilities.dart';
import '../../../data/models/mailbox_account.dart';
import '../../../data/models/profile.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/mail_providers.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/sync_providers.dart';
import '../settings_widgets.dart';

/// 设置 → 诊断的正文（**没有自己的 `Scaffold`**）。
///
/// 目标只有一个：**把「为什么这个实例表现怪」变成可读的事实**。四组信息：
/// 1. 能力探测结论（哪些功能被降级了，为什么）；
/// 2. 站点配置缓存（`websiteConfig` 的当前结论）；
/// 3. 调度状态（间隔 / 上次成功 / 连续失败 / 上次错误）—— 来自调度器自己；
/// 4. **端点自检**：逐个打一遍关键端点，显示 HTTP 状态、耗时与**原始信封**。
///
/// 第 4 组刻意绕开 `ApiClient` / 拦截器：诊断要看到的是「服务端到底回了什么」，
/// 而拦截器会把非 200 的信封抛成异常、把 200 的拆成 data —— 那正是排障时
/// 最需要看见的一层被抹掉了。
///
/// 自检**不会自己跑**（要用户点那颗按钮）—— 所以把它内嵌进设置页的右栏、
/// 或者切走再切回来，都不会替用户打一轮网络请求。
class DiagnosticsSection extends ConsumerWidget {
  const DiagnosticsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];

    // 空态也走同一套外壳/积木：不要一进来是一整屏居中的一句话。
    if (profiles.isEmpty) {
      return SettingsPage(
        children: <Widget>[
          SettingsEmptyState(
            text: l10n.noInstances,
            icon: Icons.monitor_heart_outlined,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          ),
        ],
      );
    }
    return SettingsPage(
      children: <Widget>[
        for (final profile in profiles)
          _ProfileDiagnostics(
            key: ValueKey<String>(profile.id),
            profile: profile,
          ),
      ],
    );
  }
}

class _ProfileDiagnostics extends ConsumerWidget {
  const _ProfileDiagnostics({super.key, required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final caps = ref.watch(capabilitiesProvider(profile.id)).value ??
        const InstanceCapabilities();
    final config = ref.watch(configRepositoryProvider).peek(profile.id);
    final mailboxes =
        ref.watch(mailboxesProvider(profile.id)).value ?? const <MailboxAccount>[];

    // 调度摘要是同步读的（调度器自己维护），所以这里直接取。
    final schedulerRows = ref.watch(schedulerDiagnosticsProvider);
    String? schedulerStatus;
    for (final row in schedulerRows) {
      if (row.profileId == profile.id) {
        schedulerStatus = row.status;
        break;
      }
    }

    final domains = config?.domainList ?? caps.domainList;

    // 会话到期只能估算：token 里没有 `exp`，服务端那份记录是「用一次续
    // 30 天」的滑动窗口（见 `SessionExpiry`）。
    final session = SessionExpiry.estimate(
      isLoggedIn: profile.isLoggedIn,
      lastActiveAt: profile.lastActiveAt,
      lastSyncAt: profile.lastSyncAt,
    );

    // 版面：一台实例 = 一个页头（名字 / 地址 / 未登录标记）+ 若干张
    // `SettingsGroup` 卡片。卡片标题就是原来那几行 `_GroupTitle` —— 现在
    // 标题、图标与卡片的圆角/描边都由积木统一，行间分隔线也由它画。
    //
    // 端点自检那一块**内部实现原样保留**（`_SelfCheck` / `_ProbeRow` 是专用
    // 排障组件，不拆成设置行），只把它整个包进一张卡片、补上标题与图标。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _InstanceHeader(profile: profile),

        SettingsGroup(
          title: l10n.capabilities,
          icon: Icons.fact_check_outlined,
          children: <Widget>[
            for (final row in caps.toDiagnosticRows().entries)
              _KeyValue(keyText: row.key, value: row.value),
            _KeyValue(
              keyText: l10n.probedAt,
              value: _clock(caps.probedAt?.toLocal()) ?? l10n.probeNotRun,
            ),
          ],
        ),

        SettingsGroup(
          title: l10n.siteConfig,
          icon: Icons.tune,
          children: <Widget>[
            _KeyValue(
              keyText: l10n.fieldTitle,
              value: (config?.title ?? caps.serverTitle).ifEmpty('-'),
            ),
            _KeyValue(
              keyText: l10n.send,
              value: config == null ? '-' : '${config.send}',
            ),
            _KeyValue(
              keyText: 'autoRefresh',
              value: config == null ? '-' : '${config.autoRefresh}',
            ),
            _KeyValue(
              keyText: l10n.fieldR2Domain,
              value: (config?.r2Domain ?? caps.r2Domain).ifEmptyOrNull(
                l10n.missingGoesOssApi,
              ),
            ),
            _KeyValue(
              keyText: l10n.domainList,
              value: domains.isEmpty ? '-' : domains.join('、'),
            ),
          ],
        ),

        SettingsGroup(
          title: l10n.syncStatus,
          icon: Icons.sync,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                schedulerStatus ?? l10n.noScheduler,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: schedulerStatus == null
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                  height: 1.4,
                ),
              ),
            ),
            _KeyValue(
              keyText: l10n.lastSyncedAt,
              value: _stamp(profile.lastSyncAt?.toLocal()) ?? '-',
            ),
          ],
        ),

        SettingsGroup(
          title: l10n.sessionTitle,
          icon: Icons.vpn_key_outlined,
          children: <Widget>[
            _KeyValue(
              keyText: l10n.sessionExpiresAt,
              value: _stamp(session.expiresAt?.toLocal()) ?? '-',
            ),
          ],
        ),
        // 服务端是「用一次续 30 天」的滑动过期：真的连续 30 天没请求，
        // token 会被 KV 清掉，只能重新输密码。提前提示一句，用户打开
        // 收一次信就续上了 —— 比到期当天突然被踢回登录页好得多。
        //
        // 这句是**需要读完**的一整段话，所以用 `SettingsNote`（有底色的
        // 小卡），不是组内的一行灰字。
        if (session.shouldWarn)
          SettingsNote(
            text: l10n.sessionExpiringSoon,
            icon: Icons.schedule_outlined,
            accent: theme.colorScheme.error,
          ),

        SettingsGroup(
          title: l10n.mailbox,
          icon: Icons.alternate_email_outlined,
          children: <Widget>[
            if (mailboxes.isEmpty)
              SettingsEmptyState(
                text: l10n.noMailboxCache,
                icon: Icons.inbox_outlined,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              )
            else
              for (final box in mailboxes)
                _KeyValue(
                  keyText: '#${box.accountId}',
                  value: box.isAllReceive
                      ? '${box.email}（${l10n.allMailboxes}）'
                      : box.email,
                ),
          ],
        ),

        SettingsGroup(
          title: l10n.endpointSelfCheck,
          icon: Icons.network_check,
          children: <Widget>[
            _SelfCheck(profileId: profile.id, enabled: profile.isLoggedIn),
          ],
        ),
      ],
    );
  }

  /// `HH:mm:ss`。
  static String? _clock(DateTime? value) {
    if (value == null) return null;
    return value.toIso8601String().substring(11, 19);
  }

  /// `yyyy-MM-dd HH:mm:ss`。
  static String? _stamp(DateTime? value) {
    if (value == null) return null;
    return value.toIso8601String().substring(0, 19).replaceFirst('T', ' ');
  }
}

/// 一台实例的页头：名字 + （未登录时）标记 + 可复制的服务端地址。
///
/// 它**不是**一张卡片：下面那些 `SettingsGroup` 才是卡片。页头的字号/图标
/// 与 `SettingsGroup` 的标题同一套（图标 16、主题色），所以「实例页头 →
/// 它的几张卡片」是一条从上往下的视觉线。
class _InstanceHeader extends StatelessWidget {
  const _InstanceHeader({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.dns_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  profile.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (!profile.isLoggedIn)
                Text(
                  l10n.needsLogin,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.error),
                ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            profile.baseUrl,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 诊断表里的一行「键 → 值」。值可以选中复制（排障时这一点很重要）。
class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.keyText, required this.value});

  final String keyText;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              keyText,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ 端点自检

/// 一轮自检的结果。
@immutable
class ProbeResult {
  const ProbeResult({
    required this.label,
    required this.path,
    this.httpStatus,
    this.elapsedMs,
    this.body,
    this.error,
  });

  final String label;
  final String path;
  final int? httpStatus;
  final int? elapsedMs;

  /// 服务端原始响应体（**未拆信封**）。
  final Object? body;
  final String? error;

  bool get ok => error == null && httpStatus == 200;
}

/// 逐个打关键端点。
///
/// 用一条**全新的 Dio**（不挂任何拦截器、`validateStatus` 放行一切），
/// 这样拿到的就是服务端的原始 HTTP 状态与原始 body —— 排障要看的正是这一层。
/// 失败（网络/超时）也记成一条结果，而不是让整轮抛出。
Future<List<ProbeResult>> runSelfCheck({
  required Profile profile,
  String? token,
}) async {
  final dio = Dio(
    BaseOptions(
      baseUrl: profile.baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.json,
      validateStatus: (_) => true,
      headers: <String, dynamic>{
        'User-Agent': AppDefaults.userAgent,
        if (token != null && token.isNotEmpty) 'Authorization': token,
      },
    ),
  );

  final targets = <({String label, String path, Map<String, dynamic>? query})>[
    (label: 'setting/websiteConfig', path: Endpoints.websiteConfig, query: null),
    (label: 'my/loginUserInfo', path: Endpoints.loginUserInfo, query: null),
    (
      label: 'account/list',
      path: Endpoints.accountList,
      query: <String, dynamic>{'size': 1},
    ),
    (
      label: 'email/list?full=1',
      path: Endpoints.emailList,
      query: <String, dynamic>{
        'accountId': 0,
        'type': 0,
        'size': 1,
        'full': 1,
        'allReceive': 1,
      },
    ),
    (
      label: 'email/latest',
      path: Endpoints.emailLatest,
      query: <String, dynamic>{
        'emailId': 0,
        'accountId': 0,
        'allReceive': 1,
      },
    ),
    (
      label: 'star/list',
      path: Endpoints.starList,
      query: <String, dynamic>{'size': 1, 'full': 0},
    ),
  ];

  final results = <ProbeResult>[];
  for (final target in targets) {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await dio.request<Object?>(
        target.path,
        queryParameters: target.query,
      );
      stopwatch.stop();
      results.add(
        ProbeResult(
          label: target.label,
          path: target.path,
          httpStatus: response.statusCode,
          elapsedMs: stopwatch.elapsedMilliseconds,
          body: _trimmed(response.data),
        ),
      );
    } catch (e) {
      stopwatch.stop();
      results.add(
        ProbeResult(
          label: target.label,
          path: target.path,
          elapsedMs: stopwatch.elapsedMilliseconds,
          error: '$e',
        ),
      );
    }
  }
  dio.close(force: true);
  return results;
}

/// 原始 body 可能很长（一页邮件），截断到可读长度 —— 诊断页要看的是**形状**
/// 与 `code`，不是全部内容。
Object? _trimmed(Object? body) {
  if (body == null) return null;
  if (body is List) {
    return <Object?>[
      if (body.isNotEmpty) body.first,
      if (body.length > 1) '…（共 ${body.length} 条）',
    ];
  }
  if (body is Map) {
    if (body.length <= 24) return body;
    final entries = body.entries.take(24).toList(growable: false);
    return <String, Object?>{
      for (final e in entries) '${e.key}': e.value,
      '…': '共 ${body.length} 个字段',
    };
  }
  return body;
}

/// 「逐个端点打一遍」的按钮 + 结果表。
///
/// 刻意**不在 build 里自动发请求**：诊断页往往是在网络已经不对劲的时候打开的，
/// 一进去就并发打六个端点只会让情况更糊。由用户点一下才跑。
class _SelfCheck extends ConsumerStatefulWidget {
  const _SelfCheck({required this.profileId, required this.enabled});

  final String profileId;

  /// 没登录的实例打这些端点只会拿到一串 401，没有诊断价值。
  final bool enabled;

  @override
  ConsumerState<_SelfCheck> createState() => _SelfCheckState();
}

class _SelfCheckState extends ConsumerState<_SelfCheck> {
  Future<List<ProbeResult>>? _future;

  @override
  void didUpdateWidget(covariant _SelfCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一个位置的卡片换了实例（删掉一个实例后列表左移）时把上一轮结果丢掉。
    if (oldWidget.profileId != widget.profileId) _future = null;
  }

  Future<void> _run() async {
    final profile = ref.read(profileByIdProvider(widget.profileId));
    if (profile == null) return;
    // token 要先 `read` 一次进缓存，self-check 用的是自己那条 Dio，
    // 拿不到 `AuthInterceptor` 的同步缓存。
    final token = await ref.read(tokenStoreProvider).read(widget.profileId);
    if (!mounted) return;
    final pending = runSelfCheck(profile: profile, token: token);
    // 必须写成块体：`setState(() => _future = pending)` 的箭头体是**表达式**，
    // 闭包会把赋值结果（一个 Future）当返回值交出去，Flutter 的 assert
    // 就会抛「setState() callback argument returned a Future」。
    setState(() {
      _future = pending;
    });
    // `runSelfCheck` 内部已经逐条捕获异常，不会走到这里；但 `setState`
    // 之后到 `FutureBuilder` 拿到它之间若真出了别的错，别让它成为一条
    // 未捕获的异步错误（会红屏）。
    await pending.catchError((Object _) => const <ProbeResult>[]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final future = _future;
    // 卡片标题（`端点自检`）已经由外层 `SettingsGroup` 给，这里只留
    // 一句说明 + 右上角那颗按钮 —— 同一句提示不再重复画两遍。
    final hint = !widget.enabled
        ? l10n.selfCheckLoginFirst
        : future == null
            ? l10n.selfCheckHint
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: hint == null
                    ? const SizedBox.shrink()
                    : Text(
                        hint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: widget.enabled ? _run : null,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(l10n.retry),
              ),
            ],
          ),
        ),
        if (widget.enabled && future != null)
          FutureBuilder<List<ProbeResult>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  child: LinearProgressIndicator(),
                );
              }
              final results = snapshot.data ?? const <ProbeResult>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final result in results) _ProbeRow(result: result),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _ProbeRow extends StatelessWidget {
  const _ProbeRow({required this.result});

  final ProbeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final envelope = _envelopeCode(result.body);
    final ok = result.ok && (envelope == null || envelope == 200);
    return ExpansionTile(
      dense: true,
      // 卡片里每一行都从 16 起（与组内其他行同一条左边线）。
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      // 卡片的描边已经给出边界，这里不要再画 `ExpansionTile` 自带的上下分隔线。
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        size: 18,
        color: ok ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text(result.label, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        'HTTP ${result.httpStatus ?? '-'}'
        '${envelope == null ? '' : ' · code=$envelope'}'
        '${result.elapsedMs == null ? '' : ' · ${result.elapsedMs}ms'}'
        '${result.error == null ? '' : ' · ${result.error}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            result.body == null
                ? (result.error ?? '（无响应体）')
                : _pretty(result.body),
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  /// 信封里的 `code` —— 真正决定成败的那一位（HTTP 恒 200）。
  static int? _envelopeCode(Object? body) {
    if (body is Map) {
      final raw = body['code'];
      if (raw is int) return raw;
      return int.tryParse('$raw');
    }
    return null;
  }

  static String _pretty(Object? body) {
    try {
      return const _PrettyJson().convert(body);
    } catch (_) {
      // 形状再怪也不该把诊断页弄崩 —— 退化成 toString。
      return '$body';
    }
  }
}

/// 极简 JSON 美化器：只做缩进，不做排序，且对异常形状保持健壮。
///
/// 不用 `JsonEncoder.withIndent` 是有意的：它要求整棵树是可编码类型，
/// 而这里的数据来自网络、形状不可控（比如某个字段被上游塞了非 JSON 类型）。
class _PrettyJson {
  const _PrettyJson();

  /// HTML 正文动辄几十 KB，把这个面板撑爆没有意义。
  static const int _scalarLimit = 400;

  String convert(Object? value) {
    final buffer = StringBuffer();
    _write(value, buffer, 0);
    return buffer.toString();
  }

  void _write(Object? value, StringBuffer out, int depth) {
    final pad = '  ' * depth;
    final innerPad = '  ' * (depth + 1);
    if (value is Map) {
      if (value.isEmpty) {
        out.write('{}');
        return;
      }
      out.writeln('{');
      final entries = value.entries.toList(growable: false);
      for (var i = 0; i < entries.length; i++) {
        out.write('$innerPad"${entries[i].key}": ');
        _write(entries[i].value, out, depth + 1);
        out.writeln(i == entries.length - 1 ? '' : ',');
      }
      out.write('$pad}');
      return;
    }
    if (value is List) {
      if (value.isEmpty) {
        out.write('[]');
        return;
      }
      out.writeln('[');
      for (var i = 0; i < value.length; i++) {
        out.write(innerPad);
        _write(value[i], out, depth + 1);
        out.writeln(i == value.length - 1 ? '' : ',');
      }
      out.write('$pad]');
      return;
    }
    out.write(_scalar(value));
  }

  String _scalar(Object? value) {
    if (value == null) return 'null';
    if (value is num || value is bool) return '$value';
    final text = value.toString();
    final clipped = text.length > _scalarLimit
        ? '${text.substring(0, _scalarLimit)}…（${text.length} 字符）'
        : text;
    return '"${clipped.replaceAll('"', r'\"')}"';
  }
}

extension on String {
  /// 空串换成占位符（诊断表里空单元格看不出是「没值」还是没画）。
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

extension on String? {
  String ifEmptyOrNull(String fallback) =>
      (this ?? '').isEmpty ? fallback : this!;
}
