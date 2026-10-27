import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error/app_exception.dart';
import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/auth_providers.dart';
import '../../providers/core_providers.dart';
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
  bool _removing = false;

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

    // 这条页**是全屏的**（`/login/:profileId` 是顶层路由，壳之外），所以它
    // 必须自己给出「怎么出去」—— 壳的侧栏 / 底部导航在这一屏都不在。
    //
    // 两种进入方式都要照顾到，而**现在实际发生的只有第 2 种**：
    // 1. **被 push 上来的**（`context.canPop()`）：`AppBar` 的
    //    `automaticallyImplyLeading` 会给一颗返回箭头，`Navigator.pop`
    //    就回得去。仓库里目前没有 `push` 到登录页的入口，这一支是护栏 ——
    //    将来真有人改成 push，也不该变成两颗箭头。
    // 2. **`go` 上来的**（`canPop() == false`）：这一屏是顶层路由，`go`
    //    不压栈，`automaticallyImplyLeading` 因此**一颗按钮都不给** ——
    //    用户看到的是一条全屏的登录页，没有任何出口。
    //    **现在的入口全是这一种**：`server_setup_screen` 的「添加并登录」、
    //    设置页的「登录 / 重新登录」、同步面板的「去登录」，清一色 `go`。
    //    所以这颗箭头不是可有可无的补丁，它是唯一的出口（见 `_leave`）。
    //
    // 第 2 种只在**确实走得掉**时才给按钮：一个登录好的实例都没有时，
    // `resolveRedirect` 会把任何别的地址立刻弹回登录页，给一颗点了没用的
    // 箭头比不给更糟。那时用户本来也必须先登录，没有可去的地方。
    final canPop = context.canPop();
    final canLeave = ref.watch(profilesProvider).value
            ?.any((p) => p.isLoggedIn) ??
        false;

    // 实例被删掉了（设置页里删的，而这条路由还在栈上）。
    if (profile == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.login),
          automaticallyImplyLeading: canPop,
          leading: canPop || !canLeave ? null : BackButton(onPressed: _leave),
        ),
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
        // 见上面那一段：被 push 上来的这一颗由 `AppBar` 自己给；`go` 上来的
        // 那一颗我们显式补上，否则整页没有任何出口。
        automaticallyImplyLeading: canPop,
        leading: canPop || !canLeave ? null : BackButton(onPressed: _leave),
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
              // 走不掉的时候（一个已登录实例都没有，`redirect` 会把任何
              // 别的地址弹回来）必须留一条删除的路 —— 否则地址填错一个字
              // 就再也出不去（见 `_remove`）。
              if (!canPop && !canLeave) ...<Widget>[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _removing ? null : () => _remove(profile),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(l10n.removeInstance),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static bool _isAuthExpired(Object error) =>
      error is AuthExpiredException ||
      (error is AppException && error.code == 401);

  /// 删掉这个实例，从根上离开这一屏。
  ///
  /// **这是初次安装时唯一的出路**，不是可选的便利功能：只有一个实例、且它
  /// 还没登录时，`resolveRedirect` 会把**任何**别的地址（`/settings`、
  /// `/mail/all`、`/setup`）立刻弹回这一页，而这一页此前没有任何删除入口 ——
  /// 地址填错一个字，整个 App 就永久卡在登录页，只能删 App 重装。
  ///
  /// 所以它不是「设置页那个删除」的重复：那个入口在只有一个待登录实例时
  /// 根本走不到。两个入口共用同一套清理顺序（runtime → token → profile），
  /// 少一步都会留下「实例删了却还带着上一个 token」的脏状态。
  Future<void> _remove(Profile profile) async {
    if (_removing) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.removeInstanceConfirm(profile.displayName)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.removeInstance),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _removing = true);
    // runtime 持着一条指向该实例的 Dio，先丢掉。
    ref.read(runtimeRegistryProvider).discard(profile.id);
    // token 要显式删：否则下次新建实例拿到同一个 id 时会「凭空登录」。
    // 但**它失败不能把用户卡死在这一页** —— `ProfileRepository.delete` 里
    // 自己也会删一次 token，真正决定「能不能出去」的是 profile 行没了没有。
    try {
      await ref.read(tokenStoreProvider).delete(profile.id);
    } catch (e) {
      debugPrint('删除实例时清 token 失败（继续删 profile）：$e');
    }
    try {
      await ref.read(profileRepositoryProvider).delete(profile.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _removing = false;
        _error = e;
      });
      return;
    }
    if (!mounted) return;
    // 删完之后这一页已经没有对应的实例了：交给 `redirect` 决定去哪儿
    // （还有别的实例 → 第一个待登录的；一个都不剩 → 服务器设置页）。
    context.go(app_router.Routes.mailAll);
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.removeInstance)),
    );
  }

  /// 离开这一屏。
  ///
  /// 正常情况下**只有 `go` 上来、栈里没有可 pop 的东西时**才会被按到 ——
  /// 被 push 上来时那颗箭头是 `AppBar` 自己给的，走的是 `Navigator.pop`。
  /// 这里仍然先判一次 `canPop`：万一按下时栈已经变了，`pop` 比 `go`
  /// 更接近用户按那颗箭头时想要的东西。
  ///
  /// 去处按「用户是从哪儿进来的」挑，而不是一律回首页：带着 `?next=settings`
  /// 进来的（加实例流程 `returnToCaller`、设置页的「登录 / 重新登录」）是
  /// **远路** —— 用户退出来多半是填错了地址或临时改主意，回到设置页才接得上
  /// 前面的操作；那也正是登录成功之后的落点，退出与登完走同一个去处。
  ///
  /// 其余入口（同步面板的「去登录」、实例掉线后 `redirect` 把人送来的）
  /// 没有「上一页」这回事，回聚合列表。
  void _leave() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    final next = GoRouterState.of(context).uri.queryParameters['next'];
    context.go(
      next == 'settings' ? app_router.Routes.settings : app_router.Routes.mailAll,
    );
  }

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
