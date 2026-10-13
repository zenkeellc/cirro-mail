import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';

/// 启动失败页。
///
/// `bootstrap.dart` 里的失败（密钥库不可用、SQLite 打不开、库文件损坏）不抛给
/// `main` —— 那样是黑屏或闪退，用户与日志都拿不到东西。这里把原因显示出来，
/// 并给一个「重试」：重试会把 `bootstrapProvider` 失效，由 `main.dart` 的
/// `ProviderScope` 重建整个依赖图。
///
/// 刻意**不做自动重试**：库文件损坏这类问题自动重试只会一直失败，
/// 让用户看清楚原因（并可能去清一下缓存）比转圈更有用。
class StartupFailureScreen extends ConsumerWidget {
  const StartupFailureScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final error = ref.watch(bootstrapProvider).bootstrapError;
    final tokens = ref.watch(tokenStoreProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  '启动失败',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '本地数据打不开，App 无法继续。下面是具体原因。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      '${error ?? '（没有捕获到异常信息）'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                if (tokens.isDegraded) ...<Widget>[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '系统密钥库不可用，本次运行只能把登录状态放在内存里，'
                        '重启后需要重新登录。Linux 上通常是没装 libsecret。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  // 重试 = 由 `main.dart` 的 BootstrapGate 重跑 bootstrap()，
                  // 并换一个 ProviderScope 的 key 重建整棵依赖图。
                  // 这里直接 invalidate 是没用的（值是 override 进去的）。
                  onPressed: () => ref.read(bootstrapRetryProvider)(),
                  icon: const Icon(Icons.refresh),
                  label: Text(AppLocalizations.of(context).retry),
                ),
                const SizedBox(height: 8),
                Text(
                  '仍然失败时，可以到「设置 → 清理缓存」清除本地数据后重来'
                  '（未发送的草稿会一并丢失）。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
