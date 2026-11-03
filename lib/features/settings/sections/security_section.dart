import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';
import '../../mail_detail/external_allowlist.dart' show normalizeDomainPattern;
import '../settings_widgets.dart' show SettingsSectionHeader;

/// 设置 → 安全。
///
/// 内置只有一块：**邮件正文的外联资源白名单**。读信页默认拦截外部图片
/// （否则发件人能从你的 IP 知道你什么时候、从哪里打开了邮件），这一页
/// 让用户按域名放行自己信任的那几个。
///
/// 这一页**还是扩展挂载点**（[AppExtension.securityExtras]）：与「正文里能
/// 发生什么」有关的开关都该合在这里，而不是在分类栏里再占一栏。商业版的
/// 「外部资源代理」（自动经云代理加载外联图片）就铺在白名单之后 —— 它与
/// 白名单是同一件事的两半（拦不拦 / 怎么连），以前那个独立分类**并进来了**。
/// 公开版（空注册表）在末尾什么都不多，逐字不变。
///
/// 外壳（`AppBar` / 分类栏 / 窄屏那一页）由 `SettingsScreen` 给 —— 宽屏
/// 内嵌进右栏、窄屏在一个分类页里显示。所以这里返回的是 `ListView`，
/// 不是 `Scaffold`。
///
/// 三条刻意的做法：
///
/// 1. **规范化只在数据层做一次**。输入框收的是用户敲的原始一行（可能带
///    scheme / 端口 / 路径 / 大写），`externalAllowedHostsProvider.add` 负责
///    把它变成 pattern；这一页再拿 `normalizeDomainPattern` 算一遍，只是
///    为了在回执里显示**落盘的那个样子**（`*.example.com`，不是
///    `https://*.Example.com/a.png`）。
/// 2. **非法输入就地报错，不弹走就忘的 SnackBar**。白名单是安全边界，
///    输错一个字符就静默失败的话，用户会以为「加了但没生效」，于是反复加。
///    错误挂在输入框下方（`errorText`），下一次打字自动消失。
/// 3. **构造时不碰任何有副作用的东西**。这一页只读 prefs 快照，不发请求、
///    不读钥匙串 —— 打开设置页本身不该产生任何网络行为。
class SecuritySection extends ConsumerStatefulWidget {
  const SecuritySection({super.key});

  @override
  ConsumerState<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends ConsumerState<SecuritySection> {
  /// 输入框里的内容。**只活在这一次会话里**，`dispose` 时一起丢掉。
  final TextEditingController _domain = TextEditingController();

  /// 上一次「添加」是不是被判成了非法输入。文案在 `build` 里查 l10n ——
  /// 这个字段只记「有没有错」，不记某一门语言的某一句。
  bool _invalid = false;

  /// 正在写盘。用来防连点（`add` 是异步的），也让按钮在等待时置灰。
  bool _adding = false;

  @override
  void dispose() {
    _domain.dispose();
    super.dispose();
  }

  /// 「添加」按钮与输入框回车走同一条路。
  ///
  /// 空输入**什么都不做**（不报错、不弹条）：用户可能只是点了按钮一下，
  /// 这时候告诉他「空的不合法」是噪音。
  Future<void> _add() async {
    final text = _domain.text.trim();
    if (text.isEmpty || _adding) return;

    setState(() => _adding = true);
    final ok = await ref.read(externalAllowedHostsProvider.notifier).add(text);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _invalid = !ok;
    });
    if (!ok) return;

    // 落盘的是规范化之后的 pattern（`add` 返回 true 说明它非空）。
    final pattern = normalizeDomainPattern(text);
    _domain.clear();
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.securityExternalResourcesAdded(pattern ?? text)),
        ),
      );
  }

  Future<void> _remove(String pattern) =>
      ref.read(externalAllowedHostsProvider.notifier).remove(pattern);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final patterns = ref.watch(externalAllowedHostsProvider);
    // 说明文字与空态共用一种「不是正文」的样式。
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        SettingsSectionHeader(title: l10n.securityExternalResourcesHeader),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(l10n.securityExternalResourcesIntro, style: secondary),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey('security-domain-input'),
                  controller: _domain,
                  textInputAction: TextInputAction.done,
                  // 白名单是「域名」，键盘上把空格/标点换掉没意义；真正的
                  // 校验仍然在数据层，这里只是别让用户白敲一遍。
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: l10n.securityExternalResourcesAddHint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: _invalid
                        ? l10n.securityExternalResourcesInvalid
                        : null,
                  ),
                  onChanged: (_) {
                    if (_invalid) setState(() => _invalid = false);
                  },
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('security-domain-add'),
                onPressed: _adding ? null : _add,
                child: Text(l10n.securityExternalResourcesAdd),
              ),
            ],
          ),
        ),
        if (patterns.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(l10n.securityExternalResourcesEmpty, style: secondary),
          )
        else
          for (final pattern in patterns)
            ListTile(
              key: ValueKey('security-domain-$pattern'),
              leading: const Icon(Icons.public),
              // 等宽：pattern 里 `*` 与 `.` 的位置是它的全部内容，用正文字体
              // 时 `*.` 挤在一起容易看错。
              title: Text(
                pattern,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
              trailing: IconButton(
                key: ValueKey('security-domain-remove-$pattern'),
                icon: const Icon(Icons.delete_outline),
                tooltip: l10n.securityExternalResourcesRemove(pattern),
                onPressed: () => _remove(pattern),
              ),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(l10n.securityExternalResourcesNote, style: secondary),
        ),
        // 扩展（商业版）往这一页加的块。铺在同一个 `ListView` 里、白名单之后
        // —— 见 `AppExtension.securityExtras` 的约定（不要自带滚动容器）。
        ...AppExtensionRegistry.instance.securityExtras(context),
      ],
    );
  }
}
