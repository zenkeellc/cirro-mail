import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../notifications/relay_client.dart';

/// 推送向导（`sections/push_section.dart`）用的几个小组件。
///
/// 它们原来都私有在那个屏幕里。抽出来是因为那个屏幕现在是**七页的宿主**
/// ——「通知卡片长什么样」这件事如果跟着页面走，会有七个各自漂的答案。
///
/// 只搬不改造：改名之外逻辑一字未动，好让这次搬运不引入行为变化。

/// 通知卡片的三种语气。
enum PushTone { ok, warn, info }

/// 一条通知卡片。
///
/// 这是推送这条链路上唯一的「信息条」样式：`ScaffoldMessenger` 的
/// SnackBar 只适合一次性动作的回执，而这里要表达的是一组**持续存在的
/// 状态**（平台支不支持、配没配、登记上没有），它们得一直在页面上。
class PushNotice extends StatelessWidget {
  const PushNotice({
    super.key,
    required this.icon,
    required this.text,
    required this.tone,
  });

  final IconData icon;
  final String text;
  final PushTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      PushTone.ok => (scheme.primaryContainer, scheme.onPrimaryContainer),
      PushTone.warn => (scheme.errorContainer, scheme.onErrorContainer),
      PushTone.info => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: foreground))),
        ],
      ),
    );
  }
}

/// 一行「标签 + 值 + 复制按钮」。
///
/// 值用 `SelectableText` 而不是 `Text`：这些值最终要被粘到**另一个
/// 网站**的输入框里，长按选中是用户的第一反应；只给一个复制按钮会让人
/// 在「能不能选中」上浪费一次尝试。
class PushCopyRow extends StatefulWidget {
  const PushCopyRow({
    super.key,
    required this.label,
    required this.value,
    required this.emptyHint,
    required this.copyLabel,
    required this.onCopy,
    this.obscure = false,
  });

  final String label;
  final String value;
  final String emptyHint;
  final String copyLabel;
  final Future<void> Function(String value) onCopy;

  /// 密钥默认打码。用户多半是在别人旁边配置这个，遮一下是零成本的善意；
  /// 需要核对时点一下就露出来（或者直接复制）。
  final bool obscure;

  @override
  State<PushCopyRow> createState() => _PushCopyRowState();
}

class _PushCopyRowState extends State<PushCopyRow> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasValue = widget.value.isNotEmpty;
    final hidden = widget.obscure && !_revealed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(widget.label, style: theme.textTheme.labelMedium),
                const SizedBox(height: 2),
                if (!hasValue)
                  Text(
                    widget.emptyHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: SelectableText(
                          hidden ? '•' * widget.value.length : widget.value,
                          maxLines: 2,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      if (widget.obscure)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          tooltip: widget.label,
                          onPressed: () =>
                              setState(() => _revealed = !_revealed),
                          icon: Icon(
                            _revealed
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          if (hasValue)
            TextButton(
              onPressed: () => widget.onCopy(widget.value),
              child: Text(widget.copyLabel),
            ),
        ],
      ),
    );
  }
}

/// 自检结论。三件事分开列 —— 合成一个「失败」会让用户不知道该改哪一处。
///
/// 第 ⑥ 页把那一次「检查整条链路」拆成两段问中转端：`/health`（中转活着吗、
/// 有没有 FCM 服务账号）与 `/verify-webhook`（设备配对码与地址对不对）。两段
/// 的结论都要落到同一个地方 —— 分成两处显示的话，「哪一条不对」又变成
/// 用户自己拼的了。所以 [health] 是可选的补充，不是第二套组件。
class PushSelfCheckResult extends StatelessWidget {
  const PushSelfCheckResult({
    super.key,
    required this.result,
    required this.l10n,
    this.health,
  });

  final RelayVerifyResult result;
  final AppLocalizations l10n;

  /// `/health` 的结论。传 null 就只说凭证与地址那两条。
  final RelayHealth? health;

  @override
  Widget build(BuildContext context) {
    final lines = <({String text, PushTone tone})>[];
    // 只数「凭证 / 地址」那一组。中转那两行不算进来，否则下面那个
    // `isEmpty` 判断会被它们顶掉，永远说不出「凭证与地址都对上了」。
    var credentialLines = 0;

    // 凭证那一项：App 现在送的是设备配对码，中转端回 `codeOk`；`secretOk`
    // 只在老 App / 老中转端那一侧出现（见 `RelayVerifyResult`）。
    final codeOk = result.credentialOk;

    // 中转这一层排在最前面：它不通的话，下面两条根本问不出来。
    final health = this.health;
    if (health != null) {
      lines.add((text: l10n.pushTestOk, tone: PushTone.ok));
      lines.add(
        health.fcmConfigured
            ? (text: l10n.pushPageCheckFcmOk, tone: PushTone.ok)
            : (text: l10n.pushRelayFcmMissing, tone: PushTone.warn),
      );
    }

    if (codeOk == false) {
      lines.add((text: l10n.pushSelfCheckSecretBad, tone: PushTone.warn));
      credentialLines++;
    }
    if (result.urlOk == false) {
      lines.add((text: l10n.pushSelfCheckUrlBad, tone: PushTone.warn));
      credentialLines++;
    }
    if (credentialLines == 0 && codeOk != null && result.urlOk != null) {
      // 两个字段都是 null 时那不是「通过」，只是「没问」—— 所以只有真的
      // 拿到过答案、且都没问题才说 ok。
      final verified = codeOk == true || result.urlOk == true;
      lines.add((
        text: verified ? l10n.pushSelfCheckOk : l10n.pushNeedLoginFirst,
        tone: verified ? PushTone.ok : PushTone.info,
      ));
    }
    // 「静态检查全过」与「链路真的通过」是两件事，所以单独说一句。
    final last = result.lastEventAt;
    lines.add((
      text: last == null || last.isEmpty
          ? l10n.pushSelfCheckNoEventYet
          : l10n.pushSelfCheckGotEvent(formatRelayTime(last)),
      tone: last == null || last.isEmpty ? PushTone.info : PushTone.ok,
    ));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final line in lines)
          PushNotice(
            icon: switch (line.tone) {
              PushTone.ok => Icons.check_circle_outline,
              PushTone.warn => Icons.error_outline,
              PushTone.info => Icons.info_outline,
            },
            text: line.text,
            tone: line.tone,
          ),
      ],
    );
  }
}

/// 中转端给的是 ISO 串（UTC）。只取到分钟就够了 —— 这一行是用来回答
/// 「最近到底有没有真的通过」的，不是用来做审计的。
String formatRelayTime(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
