import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/mailbox_account.dart';
import '../../../data/models/profile.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/mail_providers.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../compose/writing_snippets.dart';
// 小节标题**复用**这个，不要在自己文件里再造一个 `_SectionHeader` ——
// `ai_section.dart` 等**七个调用点**用的都是它。
import '../settings_widgets.dart' show SettingsSectionHeader;

/// 设置 → 写邮件。
///
/// ## 为什么签名要按邮箱分
///
/// 用户心里那个东西叫「我的 `xxx@yyy` 的签名」，不是「我的账号 #3 的签名」。
/// 所以这里按**邮箱地址**分组，每一组一行；点一行进编辑页。
///
/// ## 为什么不做「一封新邮件自动带签名」
///
/// 那要处理「用户手动删掉签名之后别再自动追加」这类状态，
/// 而工具栏那颗插入按钮已经覆盖了真实用法。YAGNI。
///
/// 外壳（`AppBar` / 分类栏 / 窄屏那一页）由 `SettingsScreen` 给 —— 它在
/// 宽屏把这一块内嵌进右栏、窄屏在一个分类页里显示。所以这里返回的是一个
/// `ListView`，不是 `Scaffold`。
class ComposeSection extends ConsumerWidget {
  const ComposeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final store = ref.watch(prefsStoreProvider);
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    // 地址集合 = **已配置邮箱** ∪ **两张表里已有的键**。
    //
    // 为什么不能只取两张表的键（原来那版就是）：两张表是**本文件自己写**的，
    // `setSignature` / `setPhrases` 没有别的调用点 —— 于是全新安装（或某个邮箱
    // 还没配过签名）时这里是空的，页面只剩一句「还没有邮箱」，而**没有任何入口**
    // 能建出第一条签名 / 常用语（鸡生蛋）。
    // 邮箱一条列在这里，那一行才存在、才点得进去，那条邮箱的签名才造得出来。
    //
    // 为什么仍要并上两张表的键：`mailboxesProvider` 是一条**流**，第一帧还没
    // 吐值（`.value == null` → 空列表）。只靠邮箱列表的话，这一行会在加载完成的
    // 那一帧闪出去再闪回来。已存键是同步可读的，用它兜住那几帧。
    //
    // 去重按**地址**（两张表都可能和邮箱列表里的地址撞），排序沿用原来的
    // —— 同一批地址在页面上换个分类就换次序，看起来会像两份数据。
    final emails = <String>{
      for (final profile in profiles)
        for (final box in ref.watch(mailboxesProvider(profile.id)).value ??
            const <MailboxAccount>[])
          if (box.email.isNotEmpty) box.email,
      ...store.signatures.keys,
      ...store.phrases.keys,
    }.toList()
      ..sort();

    // `signatureFor(email)` 每调一次就把整张 `signatures` 表 `jsonDecode` 一遍；
    // 一页里每个邮箱都要问一次（原来连 `subtitle` 都问两遍），N 个邮箱就是 3N
    // 次解码 / 帧。整张表读一次、后面查局部量。
    final signatures = store.signatures;

    if (emails.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // 文案只说一件事：「还没有邮箱」。签名与常用语都按邮箱分，没有邮箱时
          // 两张表都是空的，说一次就够 —— 现在这句话**只在真的一台实例都没登**
          // 时成立（有邮箱、只是还没配签名，会走下面的非空分支）。
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.composeSignatureEmpty),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        SettingsSectionHeader(title: l10n.composeSectionSignatures),
        for (final email in emails)
          ListTile(
            key: ValueKey('signature-$email'),
            leading: const Icon(Icons.draw_outlined),
            title: Text(email),
            // 副标题直接显示签名的第一行：一眼看得出这个地址配没配、配的是哪一条。
            // 空签名给 null（不显示副标题），而不是显示一个空行。
            subtitle: (signatures[email] ?? '').isEmpty
                ? null
                : Text(
                    signatures[email] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _editSignature(context, ref, email),
          ),
        // 签名与常用语按邮箱存，换实例也还在 —— 这句是给「为什么我的签名在
        // 另一台实例上也看得见」这个问题准备的答案。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            l10n.composeSnippetsHint,
            key: const ValueKey('compose-hint'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(),
        SettingsSectionHeader(title: l10n.composePhrases),
        for (final email in emails)
          ListTile(
            key: ValueKey('phrases-$email'),
            leading: const Icon(Icons.short_text_outlined),
            title: Text(email),
            subtitle: Text(l10n.composePhrasesFor(email)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editPhrases(context, ref, email),
          ),
      ],
    );
  }
}

/// 编辑一个邮箱的签名。**一个多行输入框**，保存即写盘。
Future<void> _editSignature(
  BuildContext context,
  WidgetRef ref,
  String email,
) async {
  final l10n = AppLocalizations.of(context);
  final value = await showDialog<String>(
    context: context,
    builder: (dialogContext) => _SignatureDialog(
      title: l10n.composeSignatureFor(email),
      initial: ref.read(prefsStoreProvider).signatureFor(email),
    ),
  );
  // **`null` 是「取消」，空串是「清除」** —— 两者分开，
  // 不然用户点取消会把签名擦掉。
  if (value == null) return;
  // 走 notifier（设计里唯一的写入口）：它落盘后重读、自己更新 state。
  // 从前是 `store.setSignature` + `ref.invalidate(...)`，那条路径绕开了
  // notifier，让 `setSignature` 一个调用点都没有，也让同一个数据有了两条写法。
  await ref.read(writingSnippetsProvider(email).notifier).setSignature(value);
}

/// 签名编辑对话框。
///
/// 是 `StatefulWidget` 而不是在 `builder:` 里就地 `new` 一个
/// `TextEditingController`：`showDialog` 的 future 在 `Navigator.pop` 那一刻
/// 就完成了，**早于**这条路由的退场动画 —— 退场中的 `TextField` 还会再重建，
/// 它引用的 controller 那时必须仍然活着。就地建的那个既没人 `dispose`
/// （每开一次漏一个），也保证不了退场期间还活着；同时它还会在子树重建时
/// 从 store 快照重新初始化，把用户打了一半的字抹掉。形状照
/// `../../compose/editor/compose_toolbar.dart` 的 `_LinkDialog`。
class _SignatureDialog extends StatefulWidget {
  const _SignatureDialog({required this.title, required this.initial});

  final String title;

  /// 打开时预填的当前签名。
  final String initial;

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('signature-input'),
        controller: _input,
        maxLines: 6,
        minLines: 3,
        // 故意不给提示语：对话框标题已经写着「<邮箱> 的签名」，
        // 框里再放一句占位反而画蛇添足。别顺手补一个回去。
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            MaterialLocalizations.of(context).cancelButtonLabel,
          ),
        ),
        TextButton(
          key: const ValueKey('signature-save'),
          onPressed: () => Navigator.of(context).pop(_input.text),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// 打开一个邮箱的常用语列表。
///
/// 编辑在页面里**只改一份本地列表**，回来时**整组写一次盘**（见
/// [_PhrasesPage]）—— 「每敲一个键就写盘」会给每次按键铸一个新 id、
/// 也会把敲了一半的文字持久化下去。
Future<void> _editPhrases(
  BuildContext context,
  WidgetRef ref,
  String email,
) async {
  final result = await Navigator.of(context).push<List<WritingSnippet>>(
    MaterialPageRoute<List<WritingSnippet>>(
      builder: (_) => _PhrasesPage(
        email: email,
        initial: ref.read(prefsStoreProvider).phrasesFor(email),
      ),
    ),
  );
  if (result == null) return;
  // 同签名那条：写入口只留 notifier 这一条。
  await ref.read(writingSnippetsProvider(email).notifier).setPhrases(result);
}

/// 一个邮箱的常用语：增 / 改 / 删都在本地列表上做，**返回时整组交回**。
///
/// 普通 `StatefulWidget`（不是 `ConsumerStatefulWidget`）：整页只碰本地列表，
/// 从不读 provider —— 写入（`setPhrases`）在这一页**返回之后**由 `_editPhrases`
/// 做。做成 `ConsumerState` 只会让人以为这里跟某个 provider 有关。
class _PhrasesPage extends StatefulWidget {
  const _PhrasesPage({required this.email, required this.initial});

  final String email;
  final List<WritingSnippet> initial;

  @override
  State<_PhrasesPage> createState() => _PhrasesPageState();
}

class _PhrasesPageState extends State<_PhrasesPage> {
  late final List<WritingSnippet> _items =
      List<WritingSnippet>.of(widget.initial);

  Future<void> _add() async {
    final draft = await _editSnippet(WritingSnippet(
      // 只给新增的这一条铸 id。`microsecondsSinceEpoch` 对一个用户一次
      // 打开面板来说够用了；为一个 id 引 uuid 依赖不值当。
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: '',
      text: '',
    ));
    if (draft == null) return;
    // 对话框是异步的：等待期间这一页可能已经被弹掉了（`setState` 打在
    // 已卸载的 State 上是框架异常）。
    if (!mounted) return;
    setState(() => _items.add(draft));
  }

  Future<void> _edit(int index) async {
    final draft = await _editSnippet(_items[index]);
    if (draft == null) return;
    if (!mounted) return;
    setState(() => _items[index] = draft);
  }

  void _delete(int index) => setState(() => _items.removeAt(index));

  /// 一条常用语的编辑对话框。取消（null）时调用方什么都不做 ——
  /// 与签名那边同一个约定：`null` 是取消，不是「清空」。
  Future<WritingSnippet?> _editSnippet(WritingSnippet snippet) {
    return showDialog<WritingSnippet>(
      context: context,
      builder: (_) => _PhraseDialog(snippet: snippet),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 返回键与返回箭头同一个动作：把手上的列表整组交回去（**不是** null，
        // null 是「取消」，那会把这一页里的编辑全丢掉）。这里没有「取消」
        // 这条语义 —— 用户改完就退，改变的就是结果。
        Navigator.of(context).pop(_items);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.composePhrasesFor(widget.email)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_items),
          ),
          actions: <Widget>[
            IconButton(
              key: const ValueKey('phrase-add'),
              icon: const Icon(Icons.add),
              tooltip: l10n.composePhrases,
              onPressed: _add,
            ),
          ],
        ),
        body: _items.isEmpty
            ? Center(child: Text(l10n.composePhrases))
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 32),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text(
                      item.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _edit(index),
                    trailing: IconButton(
                      key: ValueKey('phrase-delete-${item.id}'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(index),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// 一条常用语的编辑对话框（新增与编辑共用）。
///
/// 同 [_SignatureDialog]：controller 由这个 `State` 持有、在 `dispose` 里释放。
/// 原来在 `_editSnippet` 的 `finally` 里 `dispose` —— `showDialog` 的 future
/// 在 `Navigator.pop` 时完成、**早于**退场动画，于是退场中的 `TextField` 会
/// 撞上「A TextEditingController was used after being disposed」，新加的这一条
/// 也留不下来。
class _PhraseDialog extends StatefulWidget {
  const _PhraseDialog({required this.snippet});

  /// 要编辑的那条（新增时是一条 name / text 都为空的草稿，id 已在调用方铸好）。
  final WritingSnippet snippet;

  @override
  State<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends State<_PhraseDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.snippet.name);
  late final TextEditingController _text =
      TextEditingController(text: widget.snippet.text);

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.composePhrases),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            key: const ValueKey('phrase-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: l10n.composePhraseName,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('phrase-text'),
            controller: _text,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: l10n.composePhraseText,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            MaterialLocalizations.of(context).cancelButtonLabel,
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            WritingSnippet(
              id: widget.snippet.id,
              name: _name.text.trim(),
              text: _text.text,
            ),
          ),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
