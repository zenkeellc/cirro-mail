import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error/app_exception.dart';
import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/auth_providers.dart';
import '../../providers/profile_providers.dart';
import '../../router.dart' as app_router;

/// 登录页。一个实例一页（`/login/<profileId>`）。
///
/// 三件事值得说明：
/// 1. **登录编排全在 `AuthRepository`**，这个页面只管收集输入与展示错误。
///    顺序（先测连通 → 换 token → 落 token → 拉身份 → 回写 profile）写在那边。
/// 2. **成功后不是 `context.go` 到聚合页就完事**：还要把 userId 写回库，
///    否则 `Profile.isLoggedIn` 仍为 false，`redirect` 会立刻把用户弹回登录页
///    （形成「登录成功又回到登录页」的诡异循环）。所以先 `completeSignIn` 再导航。
/// 3. **401 的文案要提到「可能被其他设备挤掉」**：服务端同一账号只保留 10 个
///    token，第 11 次登录会把最老的顶下去（见 `AuthApi` 的注释）。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  bool _obscure = true;
  bool _busy = false;
  Object? _error;
  bool _seeded = false;
  bool _released = false;

  @override
  void dispose() {
    _release();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// 释放控制器。
  ///
  /// 登录成功后这个页面会被 `context.go` 整个换掉，而**换掉不等于 dispose**
  /// （新路由的构建可能先发生）。控制器不释放会漏，释放两次会触发
  /// `ChangeNotifier` 的断言，所以用一个幂等开关兜住两种调用路径。
  void _release() {
    if (_released) return;
    _released = true;
    _email.dispose();
    _password.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final profile = ref.watch(profileByIdProvider(widget.profileId));

    // 实例被删掉了（设置页里删的，而这条路由还在栈上）。
    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.login)),
        body: Center(child: Text(l10n.noInstances)),
      );
    }

    // 预填上次登录用的邮箱（以及换服务器的场景下，profile 里存的邮箱）。
    if (!_seeded) {
      _seeded = true;
      if (profile.email.isNotEmpty) _email.text = profile.email;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.login),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                '${profile.displayName}  ·  ${profile.host}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              if (profile.needsLogin)
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.info_outline,
                            size: 18, color: theme.colorScheme.outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.instanceNeedsLoginHint,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.email,
                  prefixIcon: const Icon(Icons.alternate_email),
                ),
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                focusNode: _passwordFocus,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.password,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? '显示密码' : '隐藏密码',
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onSubmitted: (_) => _submit(profile),
              ),
              const SizedBox(height: 20),
              if (_error != null) ...<Widget>[
                _ErrorCard(
                  error: _error!,
                  // 401 时额外提示「可能是被别的设备挤掉」。
                  hint: _isAuthExpired(_error!) ? l10n.sessionExpiredHint : null,
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                onPressed: _busy ? null : () => _submit(profile),
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(_busy ? l10n.signingIn : l10n.login),
              ),
              const SizedBox(height: 8),
              Text(
                // 服务端同一账号最多 10 个 token，第 11 次登录会挤掉最老的。
                '同一账号最多保留 10 个登录会话，多设备登录会互相顶掉最旧的那个。',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isAuthExpired(Object error) =>
      error is AuthExpiredException ||
      (error is AppException && error.code == 401);

  Future<void> _submit(Profile profile) async {
    final l10n = AppLocalizations.of(context);
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty) {
      setState(() => _error = _Required(l10n.emailRequired));
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = _Required(l10n.passwordRequired));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // 登录编排（测连通 → 换 token → 落 token → 拉身份 → 回写 profile
      // → 播种邮箱/配置 → 后台探测能力）全在 AuthRepository 里。
      await ref.read(authRepositoryProvider(profile.id)).loginAndApply(
            email: email,
            password: password,
          );

      if (!mounted) return;
      // 从设置页的「添加实例」进来时回设置页，其余情况回主屏的收件箱。
      final next = GoRouterState.of(context).uri.queryParameters['next'];
      context.go(
        next == 'settings'
            ? app_router.Routes.settings
            : app_router.Routes.mailAll,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }
}

/// 本地校验失败。
class _Required implements Exception {
  const _Required(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, this.hint});

  final Object error;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    _describe(error),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                hint!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _describe(Object error) {
    if (error is _Required) return error.message;
    if (error is AppException) {
      final raw = error.rawMessage;
      return raw == null || raw == error.userMessage
          ? error.userMessage
          : '${error.userMessage}（$raw）';
    }
    return '$error';
  }
}
