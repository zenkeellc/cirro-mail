// `qi.ClipboardServiceProvider` 是实验性成员（`flutter_quill/internal.dart`
// 顶上就写着 `ignore_for_file: experimental_member_use`），只能这样拿剪贴板的
// HTML / 位图那两种 flavour。
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart' show DropDoneDetails;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
// `LogicalKeyboardKey` / `KeyDownEvent` 在 **services** 里，`material.dart` 不转
// 出口它们 —— 少了这一行报的是「Undefined name」，看着像名字拼错了。
// （`KeyEventResult` 例外：它在 `widgets` 的 `focus_manager.dart` 里，
// `material.dart` 已经带着了，写进 `show` 反而报 `undefined_shown_name`。）
// 只 `show` 这两个名字：`services.dart` 会把 `dart:typed_data`（本文件在用
// `Uint8List`）一起转出口，整包 import 的话上面那行 `dart:typed_data` 就成了
// 多余 import。
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_quill/internal.dart' as qi;
import 'package:flutter_quill/quill_delta.dart' as qd;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ai/ai_prompts.dart';
import '../../features/ai/ai_run.dart';
import '../../features/ai/ai_service.dart';
import '../../features/ai/ai_settings.dart';
import '../../features/ai/inline_continuation.dart';
import '../../features/ai/preflight.dart';
import '../../features/ai/rewrite_selection.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/ai_providers.dart';
import '../../providers/mail_providers.dart';
import '../../providers/settings_providers.dart';
import '../shortcuts/mail_intents.dart';
import 'ai/ai_draft_sheet.dart';
import 'ai/ai_ghost_text.dart';
import 'ai/ai_polish_sheet.dart';
import 'ai/ai_preflight_sheet.dart';
import 'ai/ai_reply_sheet.dart';
import 'ai/ai_rewrite_sheet.dart';
import 'ai/compose_ai.dart';
import 'attachment_chips.dart';
import 'compose_attachments.dart';
import 'compose_controller.dart';
import 'compose_draft.dart';
import 'compose_html.dart';
import 'compose_quote.dart';
import 'compose_sender.dart';
import 'compose_text.dart';
import 'editor/compose_toolbar.dart';
import 'editor/drop_target.dart';
import 'editor/embed_line_break.dart';
import 'editor/image_actions.dart';
import 'editor/image_insert.dart';
import 'editor/mail_quill_editor.dart';
import 'editor/paste_handler.dart';
import 'editor/slash_actions.dart';
import 'editor/slash_menu.dart';
import 'editor/snippet_insert.dart';
import 'html/delta_to_email_html.dart';
import 'html/document_codec.dart';
import 'html/mail_html_to_delta.dart';
import 'recipient_field.dart';
import 'send_progress_sheet.dart';
import 'sender_picker.dart';
import 'table/table_block.dart';
import 'table/table_html_codec.dart';

/// 写邮件页。
///
/// 屏幕只做三件事：把 `ComposeState` 画出来、把点击转给
/// [ComposeController]、把一次性提示（SnackBar / 进度框）放出去。
/// 所有判断都在控制器里 —— 这样「点发送之后会发生什么」只有一个地方要读。
///
/// 两条刻意为之的规矩：
/// 1. **离开页面一律存草稿**（[ComposeController.saveDraftOnExit]）。空信不存，
///    写过东西的必存。不弹「放弃修改？」对话框：那是「内容会丢」的场景才
///    需要问的，而这里的内容不会丢。
/// 2. **发送中不拦返回**，但会提示。发送是一次已经发出去的请求，
///    拦着不让走既拦不住它，也留不住用户。
///
/// 还有一条是**发送成功的收尾**（问题 4）：那封信在本地已经交出去了
/// （直发成功、或已排进发件箱），这一页就没什么可留的 —— 先 `pop`，
/// 再把那句话弹到下面那一屏去。失败则相反：留在页里让用户改。
/// 见 [_scheduleNotice] 里那条「先取 messenger → pop → 再弹」的顺序。
///
/// **正文那一份文档的持有者是 `_quill`，不是 state**：`state.body` 是它被
/// 防抖回写的一份副本（见 [_pushBody]）。反过来（每次 state 变化都重建一份
/// Document）会把光标、选区和撤销栈一起丢掉。
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, this.args = const ComposeArgs()});

  final ComposeArgs args;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

/// 写邮件页的 Esc。**不用框架的 `DismissIntent`**：那一个的 Action 是
/// `ModalRoute._DismissModalAction`，`isEnabled` 判 `barrierDismissible`，
/// 普通推入的页面永远是 false（`routes.dart:983`）—— 这就是「按 Esc 没反应」
/// 的由来。自己起一个类型，语义也清楚。
class _EscCloseIntent extends Intent {
  const _EscCloseIntent();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final TextEditingController _subject = TextEditingController();

  /// 正文那一份 Delta 的**唯一**持有者。
  ///
  /// 它的初值来自 `ComposeController.build()` 预填的 Delta（回复/转发时是带
  /// 引用块的那一份）。之后它自己就是真相，`state.body` 是它**被回写的副本**
  /// 而不是反过来 —— 反过来的话，每次 state 变化都要重建一份 Document，
  /// 光标、选区、撤销栈全都会丢。
  late final q.QuillController _quill;

  final FocusNode _bodyFocus = FocusNode();

  /// 正文回写的防抖。
  ///
  /// `DocumentCodec.encode` 在正文里带一张 5 MB 图时是 **25 ms** 一次
  /// （探针 probe62），而 controller 的通知是**每个字符一次** —— 不防抖的话
  /// 用户打字期间每一帧都在 base64 编码一个 7 MB 的字符串。
  Timer? _writeBack;

  /// 正文的初值**装到第几版**了。每装一次自增 —— 见 `_adoptInitialBody`。
  ///
  /// 起点是 **-1 而不是 0**：初值是 `0` 的那一版（回复/转发的引用块、或空
  /// 写信页的空串）同样要装一次，而 `0 != 0` 不成立。
  int _bodyRevision = -1;

  static const Duration _writeBackDelay = Duration(milliseconds: 250);

  /// 「这一刻的编辑器通知是**装载初值**引起的，不是用户敲的」。
  ///
  /// 只在 [_adoptInitialBody] 里装初值那一小段期间为真（`replaceText` 与随后的
  /// `updateSelection` 都会通知，见那处的注释）。为什么非要这个记号：
  /// [`_onBodyChanged`] 的防抖烧完之后 [`_pushBody`] 会把文档回写进 `state.body`，
  /// 同时**默认**把 `dirty` 置真 —— 可装载初值（读回草稿、预填引用块）是
  /// **我们自己**写的，不是用户写的。不区分的话，打开一封回复、一个字都不动
  /// 就退出，也会留下一份草稿（探针实测 `DRAFTS=2`；E4 之前与 `main` 上都是
  /// `dirty=false`、`DRAFTS=0`）。「空信不存」这条规矩就破了。
  ///
  /// 顺带还压掉了一次无谓的 `setBody`：初值装进去的内容与 `state.body` 本就
  /// 是同一份（`state.body` 正是它的来源），回写等于原地转一圈 —— 只有编码
  /// 之后多出来的那个尾换行是新的。
  bool _adoptingBody = false;

  /// 全篇润色的**结果正要落进文档**。
  ///
  /// 现在只剩一个职责：`_replaceUserBody` 里那次 `replaceText` 的通知
  /// （[_onBodyChanged]）不算「用户写的」。不区分的话，打开一封回复、一个字
  /// 没敲、点了下润色、再退出就会留下一份草稿。
  ///
  /// 早先它还兼着两件事 ——「钉住顶部那条进度条」与「让正文变灰挡住输入」，
  /// 但润色现在改成了**先开面板、点生成才跑**，面板本身是模态的（正文本来
  /// 就被挡住），那两处 UI 已经删掉。
  bool _polishing = false;

  /// 主题栏那颗图标正在转圈（起标题的这一趟还没回来）。
  ///
  /// 单独一个（而不是复用 `_polishing`）：两件事可以同时发生，共用一个 flag
  /// 会让先结束的那个把另一个的转圈关掉。
  bool _subjectSuggesting = false;

  /// 上次**回写**（或装载初值）时正文的样子。判「用户写过没有」就是拿当前
  /// 文档跟它比。
  ///
  /// 判据只能是**文档内容**变没变，不能看「有没有收到通知」：`QuillController`
  /// 是 `ChangeNotifier`，**光换个选区**（点正文某处、拖个选择、输入法动一下
  /// 光标）同样 `notifyListeners`。拿通知当判据的话，在回复页里点一下正文再
  /// 退出，就会留下一条一个字没写的草稿（探针 zz_sel：`X1a dirty=true` →
  /// 退出后 `drafts=1`；完全不碰的对照组是 `drafts=0`）。
  ///
  /// **基准只在装载初值/回写时更新，不在每次通知时更新** —— 这一点很关键：
  /// 每次通知都刷基准的话，用户「打完字 → 点一下正文 → 立刻退出」这串动作里，
  /// 后一次（选区）通知会把基准刷成当前状态，于是刚敲的字被算成「没变」，
  /// 那段字既不置脏也进不了草稿（探针 zz_lost 实测 `Y1 drafts=0`）。基准不
  /// 动，那个「变过」就一直成立，直到真的回写了一次为止。
  Object? _lastBodyFingerprint;

  /// 最近一次编辑器通知算出来的「这算不算用户写的」。
  ///
  /// [_flushBody] 提前插手（打完字立刻返回/发送）时沿用这一份结论 —— 那时
  /// 防抖闭包还没跑过，它自己算不出来。默认 `false`：**没有通知就没有编辑**，
  /// 而这一支只在「有通知、防抖没烧完」时才被读到。
  bool _pendingMarkDirty = false;

  /// [_lastBodyFingerprint] 的算法：**每条 insert 的长度 + 那一段的属性**。
  ///
  /// 不拿 `document.toDelta() == other`：那会**逐字深比**，而这一页的正文里
  /// 可能嵌着一张 5 MB 的图（base64 就在字符串里）—— 每次通知都比一遍等于
  /// 每次按键都全文扫一次。长度加属性已经能区分「删了一个字」与「把光标挪了
  /// 一下」，而后者代价与文档大小无关。
  ///
  /// 只要 `(长度, 属性)` 的组合对不上就算改过。宁可多标一次脏（空信留一条
  /// 草稿），也不能少标（用户敲的字不落盘）—— 所以这里不做进一步的精简。
  ///
  /// 每段属性用 `Object.hash`（**有序**）而不是 `hashAllUnordered`：`{'bold': true,
  /// 'italic': true}` 与交换书写顺序的同名集合在语义上一样，但有序哈希更省事也
  /// 不会错 —— 同一个文档在同一状态下算出来的属性书写顺序是稳定的，而这一趟的
  /// 全部要求就是「同一个状态两次算出来相等、不同状态算出来不等」。
  static Object _bodyFingerprint(qd.Delta delta) {
    final ops = delta.operations;
    return Object.hash(
      ops.length,
      Object.hashAll(ops.map((op) => op.length ?? 0)),
      Object.hashAll(
        ops.map((op) => op.attributes == null
            ? 0
            : Object.hashAll(
                op.attributes!.entries.map((e) => Object.hash(e.key, e.value)),
              )),
      ),
    );
  }

  /// 「已经在走 `X` 按钮那个出口了」。
  ///
  /// 为什么需要这个闸：`canPop: true` 时 `PopScope` 的回调在**程序化 pop**
  /// 上同样会跑（安卓返回键、iOS 边缘滑动、`Navigator.pop()` 三种来源一视
  /// 同仁）。而 [_leave] 自己要 `await saveDraftOnExit()` 再 `pop()` —— 那次
  /// `pop()` 会把回调再叫一遍，于是**同一封信存两条草稿**：第一次
  /// `_saveDraft()` 拿到的 id 没有回写进 `state.draftId`（[ComposeController.
  /// saveDraftOnExit] 不返回 id），第二次的 `existing` 仍是 null，`saveDraft`
  /// 便又 `insert` 了一行。探针实测：空白页打字后点 `X`，库里两条一模一样的
  /// 记录（`V drafts=[1, 2]`）。系统返回手势那条路只跑一次回调，所以不受影响。
  bool _leavingFromButton = false;

  /// 上一次看过的 notify 序号，用来去重 SnackBar。
  String? _lastNotice;

  @override
  void initState() {
    super.initState();
    // 正文的初值此刻还拿不到（`build()` 是同步的，而 state 要等第一帧）——
    // 所以先建一个空文档，第一帧里由 `_adoptInitialBody` 换上真的。
    _quill = mailQuillController(
      document: DocumentCodec.empty(),
      selection: const TextSelection.collapsed(offset: 0),
      // 图片粘贴**不走** flutter_quill 的 `onImagePaste`：那条路
      // （`quill_controller.dart:610`）拿到 URL 之后直接
      // `replaceText(extent, 0, BlockEmbed.image(url), null)`，
      // **不做占行处理** —— 而 §0.2 第 6b 条说得很清楚，嵌入与文字挤在
      // 一行会让渲染崩。我们自己的 `_onClipboardPaste` 先跑（它在那条路
      // **之前**），所以这里不给 `onImagePaste`。
      onClipboardPaste: _onClipboardPaste,
    );
    _quill.addListener(_onBodyChanged);
    // 基准记成「这个新文档刚建好的样子」。不能留 `null` 表示「还没记过」：
    // 空白写信页上敲进来的**第一个字**会因为「上次没有基准」被判成「没变」而
    // 不置脏，退出时那段字进不了草稿。这里存的就是空文档那一版，装载初值
    // （[_adoptInitialBody]）之后由 [_pushBody] 更新成引用块那一版。
    _lastBodyFingerprint = _bodyFingerprint(_quill.document.toDelta());
  }

  @override
  void dispose() {
    _writeBack?.cancel();
    _quill.removeListener(_onBodyChanged);
    _quill.dispose();
    _bodyFocus.dispose();
    _subject.dispose();
    super.dispose();
  }

  ComposeController get _c =>
      ref.read(composeControllerProvider(widget.args).notifier);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(composeControllerProvider(widget.args));

    // 可选发件人由屏幕 watch（控制器只读一次快照，见其类注释第 1 条）。
    //
    // **源是 `composeSendersProvider` 而不是 `mailboxesProvider(当前实例)`**：
    // 候选现在是跨实例的。它读的是 drift 的流，第一帧之后才吐值 ——
    // 所以这一条 `ref.listen` 是「把真值递进去」的那条路，
    // `ComposeController.build()` 里那次 `ref.read` 只是第一帧的兜底。
    ref.listen<List<SenderGroup>>(composeSendersProvider, (previous, next) {
      _c.syncSenderGroups(next);
    });

    _syncEditor(state);
    _drainNotice(context, state);

    // AI 设置是异步来的（要读 prefs + 钥匙串）。**读不到就按默认走** ——
    // 默认里 `preflightEnabled` 是 true、`hasApiKey` 是 false，于是
    // 「设置还没加载出来」不会让任何一项能力静默关掉，也不会误开。
    final settings = ref.watch(aiSettingsProvider).value ?? const AiSettings();
    // 「配得上 AI」= 有厂商、有模型、且**存过 Key**。三个条件缺一个都
    // 意味着按下去只会收到一句「没配 Key」，那不如不显示这个入口。
    final aiUsable = settings.isUsable && settings.hasApiKey;

    // 当前发件邮箱的签名与常用语（family 的键就是发件地址，见
    // `writingSnippetsProvider`）。发件人还没定时是空串 → 返回空值 →
    // 工具栏那两颗按钮都不画（不知道插谁的签名）。
    final senderEmail = state.sender?.email ?? '';
    final snippets = ref.watch(writingSnippetsProvider(senderEmail));

    // 预填正文：初值装一次，之后 state 里每次**换初值**（读回草稿、发送后
    // 清空）再装一次 —— 判据见 `_adoptInitialBody`。
    if (_bodyRevision != state.bodyRevision) _adoptInitialBody(state);

    return PopScope(
      // 系统返回手势（安卓返回键、iOS 边缘滑动、桌面端的 Esc/返回）
      // **不走 [_leave]** —— 那是给 `X` 按钮用的。少了这一层，用户打完最后
      // 一句话就按返回键时，那段字还在编辑器里、连 250 ms 的防抖都没烧完，
      // 而 `saveDraftOnExit` 读的是 `state.body` 这份**副本** —— 于是它既进
      // 不了草稿也去不了别处，静默丢掉。这一层与 [_leave] 走同一个出口。
      //
      // `canPop: true`：**不拦**返回，只借这次回调落一次盘。拦下来自己再
      // `pop()`（`canPop: false` 那种写法）会多一次 `didPop` 翻转，而这一页
      // 本来就没有「确定要离开吗」要问 —— 内容会存进草稿，不会丢。
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        // `X` / 放弃草稿那两个按钮**已经自己存过一次**了（见 `_leavingFromButton`），
        // 它们随后那次 `pop()` 会走到这里 —— 直接放过。
        if (_leavingFromButton) return;
        // 回调在 `dispose` **之前**跑（探针 probe_popscope2：日志里
        // `invoked` 永远排在 `dispose` 前面），所以 `_quill` 还活着，
        // `_flushBody` 读得到它。
        _flushBody();
        unawaited(_c.saveDraftOnExit());
      },
      child: Shortcuts(
        // 页面自己的一层快捷键。
        //
        // **为什么必须有一层**：光标在主题栏 / 收件人 / 发件人这些普通输入框里
        // 时，宿主层（`MailShortcutHost`）那一层其实够得着 —— 但页面层比它近，
        // 而 `SendMailIntent` 要拿这一页的控制器，宿主层拿不到。光标在 quill
        // 正文里时页面层**够不着**：quill 的 `Shortcuts` 无条件绑了
        // `escape → HideSelectionToolbarIntent`
        // （`default_single_activator_intents.dart:14`），它在焦点树上比这一层
        // 近，Esc 在正文里被 quill 吃掉。正文那条路由
        // `MailQuillEditor.onKeyPressed` 补（编辑器那个口子比 quill 自己的表
        // 更早，见 `MailQuillEditor` 上那个参数的注释）。
        //
        // `Cmd/Ctrl+Enter` 只有这一条路就够了：quill 那张表里 `enter` 只有
        // **裸键**一条，带修饰键的会一路上行到这里。
        shortcuts: <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.escape): const _EscCloseIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _EscCloseIntent: CallbackAction<_EscCloseIntent>(
              onInvoke: (_) {
                // 正在发，不能把页面从流程底下抽走。
                //
                // `_leavingFromButton` 那条是防**连按两次**：`_leave()` 里要
                // `await saveDraftOnExit()`，那一段窗口里页面还在，第二次 Esc
                // 会再走一遍并把 `Navigator.pop()` 多弹一次（弹掉的是**下面
                // 那一页**）。
                if (state.busy || _leavingFromButton) return null;
                _leave(context);
                return null;
              },
            ),
            SendMailIntent: CallbackAction<SendMailIntent>(
              onInvoke: (_) {
                if (!state.canSendNow) return null;
                _send(context);
                return null;
              },
            ),
          },
          child: Stack(
            children: <Widget>[
              _buildScaffold(context, l10n, state, settings, aiUsable, snippets),
              // 发送中盖一层不可点掉的进度框：`/email/send` 没有幂等键，
              // 半途撤掉可能已经在服务端落库了（详见 SendProgressSheet）。
              //
              // **只在这封信真的在网络上时才盖**：现在「发送」默认只是入队
              // （需求六的后悔窗口），那一步是本地落库、瞬间完成，弹一个
              // 「正在发送…」的模态框会让人以为信已经走了 —— 而它其实还在
              // 队列里等着被取消。
              if (state.busy && state.progress != null)
                ColoredBox(
                  color:
                      Theme.of(context).colorScheme.scrim.withValues(alpha: 0.4),
                  child: SendProgressSheet(progress: state.progress),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    AppLocalizations l10n,
    ComposeState state,
    AiSettings settings,
    bool aiUsable,
    WritingSnippets snippets,
  ) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(l10n, state)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.close_,
          onPressed: state.busy ? null : () => _leave(context),
        ),
        actions: <Widget>[
          if (state.draftId != null)
            IconButton(
              tooltip: l10n.discard,
              icon: const Icon(Icons.delete_outline),
              onPressed: state.busy ? null : () => _discard(context),
            ),
          // ④ 润色全文。原来这里是「起标题」—— 起标题挪到了主题栏里那颗
          // 内联图标（它属于那一行），这颗图标改成「把整篇正文润一遍」。
          //
          // 只在设置里开着、且配得上 AI 时出现：没配 Key 的用户不该看到一个
          // 点了只回一句「去设置」的图标。
          if (settings.isUsable && settings.polishEnabled)
            IconButton(
              tooltip: l10n.aiPolishTooltip,
              icon: const Icon(Icons.auto_fix_high_outlined),
              onPressed: state.busy ? null : _polishAll,
            ),
          // 配了延迟时，旁边多一个「立即发送」—— 那封信不必先排队再等。
          // 只在延迟不为 0 时出现：为 0 时它与主按钮是同一件事，
          // 并排两个一样的按钮只会让人犹豫点哪个。
          if (ref.watch(sendDelayProvider) > Duration.zero)
            IconButton(
              tooltip: l10n.sendNow,
              icon: const Icon(Icons.bolt),
              onPressed: state.canSendNow ? () => _sendNow(context) : null,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: state.canSendNow ? () => _send(context) : null,
              icon: const Icon(Icons.send, size: 18),
              label: Text(l10n.send),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SenderField(
            sender: state.sender,
            groups: state.senderGroups,
            onChanged: _c.setSender,
          ),
          const Divider(height: 1),
          RecipientField(controller: _c),
          const Divider(height: 1),
          // 主题。与上面的发件人/收件人两行**同构**（左侧一个 label）：
          // 裸一个 hint 的话，那一行看着像正文的开始，用户得先读一遍
          // 「主题」两个字才知道它不是。
          //
          // 有了 label 就不再留 hint —— 两个都写「主题」的话，空着的时候
          // 那一行会显示成「主题　主题」。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  // 与 `RecipientField` 的 label 同一处对齐：输入框里的字
                  // 比 label 低 10px（`contentPadding` 的 14 减 4）。
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(l10n.composeSubject),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _subject,
                    onChanged: _c.setSubject,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(0, 14, 0, 14),
                    ),
                  ),
                ),
                // ③ 起标题：就嵌在主题这一行的右端。
                //
                // 以前它是 AppBar 上的一颗图标、点开一个候选面板让用户挑一行。
                // 那一步是多余的 —— 用户点「起标题」要的就是**一个**标题，而
                // 挑哪一行需要的判断力比直接改主题栏里的字还大。现在点一下
                // 直接填进去，不喜欢就再点一次（已有主题会作为参考传给模型，
                // 于是第二次多半是在上一版基础上改，而不是另起一个）。
                //
                // 没配 AI 时**整颗不出现**：留一个点了没反应的图标比没有更糟。
                if (aiUsable && settings.subjectSuggestEnabled)
                  Padding(
                    // 与上面 label 的 `top: 10` 同一个基准 —— TextField 的字
                    // 比行顶低 14px（`contentPadding`），图标 20px 高，居中的
                    // 偏移就是 (14 + 20 - 20) / 2 - ... 取 10 与 label 齐平。
                    padding: const EdgeInsets.only(top: 10),
                    child: _subjectSuggesting
                        ? const Padding(
                            padding: EdgeInsets.all(2),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            key: const ValueKey('compose-subject-ai'),
                            tooltip: l10n.aiSubjectSuggest,
                            icon: const Icon(Icons.auto_fix_high_outlined,
                                size: 20),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            // 生成中转圈 —— 连点两下就是两次调用、两笔账。
                            onPressed: state.busy ? null : _suggestSubject,
                          ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ① 常驻编辑工具栏：正文上方**一直在**的那一条。
          //
          // 原来格式按钮只在选中文字时浮出（那份 `EditorToolbar` 仍在、也仍然
          // 浮出），代价是「想加粗还没打的字」得先选中点什么 —— 空行上没有东西
          // 可选。插入能力原来藏在底部「+」面板里，附件又是另一颗独立按钮；
          // 现在按类拆进这一条，底部那两处随之删掉。
          ComposeToolbar(
            slashContext: _slashContext(settings),
            // 没配 AI 就不画 `ct-ai`。下拉里选的**语气**一路带到面板的
            // `initialTone`；分流仍在：折叠时是「起草」（开面板），有选区时是
            // 「改写」（那份面板要原文）。
            onAiTone: aiUsable
                ? (tone) => _quill.selection.isCollapsed
                    ? _draftWithAi(settings, tone: tone)
                    : _rewriteSelection(context, tone: tone)
                : null,
            // ⑤ 回复建议：**只有回复模式且拿到来信正文时才画**。普通写邮件、
            // 转发、或回复模式下 `mail` 为空时都不画（spec §6.3）——
            // 与 `aiUsable` 是两个独立的闸，逐一见 `_canSuggestReply`。
            onAiReply: aiUsable && _canSuggestReply
                ? () => _suggestReply(settings, _incomingBody!)
                : null,
            onAttach: () => _pickAttachments(context),
            onInsertSignature:
                snippets.hasSignature ? () => _insertSnippet(snippets.signature) : null,
            onInsertPhrase:
                snippets.phrases.isEmpty ? null : (snippet) => _insertSnippet(snippet.text),
            phrases: snippets.phrases,
          ),
          Expanded(
            // 斜杠菜单**罩在编辑器外面**（它是 `Stack` + `Positioned`，
            // 要有盒子可以定位）。
            child: Stack(
              children: <Widget>[
                SlashMenuHost(
                  controller: _quill,
                  slashContext: _slashContext(settings),
                  // 没配 AI 就不显示「AI 起草」那一条 —— 与工具栏上
                  // 「没有回调就不显示 AI 按钮」是同一条规矩。
                  allowAi: aiUsable,
                  // **必须把正文的 FocusNode 传进去**：不传时 [`SlashMenuHost`]
                  // 的键盘处理不做焦点判断，于是「焦点在主题框时按回车」会被
                  // 斜杠菜单吃掉（实测后果是斜杠被清掉、正文里凭空插进一张表格）。
                  editorFocusNode: _bodyFocus,
                  child: MailQuillEditor(
                    controller: _quill,
                    focusNode: _bodyFocus,
                    placeholder: l10n.composeBodyHint,
                    // 工具栏上那个「AI 改写」按钮：只在这封信真的配得上 AI 时才给 ——
                    // 没 Key 的用户不该看到一个点了没反应的图标。
                    onAiRewrite:
                        aiUsable ? () => _rewriteSelection(context) : null,
                    // 表格块要跟外界说话（行列操作后把新 HTML 写回文档）。
                    //
                    // `onChanged` 给一个空实现是**对的**：写回文档那件事由
                    // `MailTableEmbedBuilder` 自己做（它拿着 `embedContext`），
                    // 上层在这里没有别的活要干。
                    //
                    // `onRequestImageInCell` **刻意不给** —— Task B3 已经把它
                    // 定义成「本轮不实现，先留出接口位置」。给一个回调等于开一个
                    // 半成品的入口：单元格里的一张图在邮件 HTML 里的落法（内联
                    // data URI？还是当成附件再引 cid？）没定下来之前，让它可点
                    // 只会产出会丢内容的信。
                    tableCallbacks: TableBlockCallbacks(onChanged: (_) {}),
                    // 文件拖进来：图片内联、其余的当附件。
                    onDropFiles: (details, dropOffset) =>
                        _onDropFiles(context, details, dropOffset),
                    // **页面被别的路由盖住时必须传 false**（`DropTarget.enable`
                    // 的语义）—— 否则在设置页拖文件会落到写信页里。
                    dropEnabled: ModalRoute.of(context)?.isCurrent ?? true,
                    // 点正文里的图 → 对齐 / 换图 的小菜单。**收信侧那份编辑器
                    // 不传这个**，所以那边的图不可点。
                    onImageTap: _onImageTap,
                    // 正文里的 Esc。**必须从这里接**：光标在正文里时页面那层
                    // `Shortcuts` 被 quill 自己的表挡住（见上面那段注释），
                    // 而这个是唯一比它更早的口子。只有 Esc 一个键 ——
                    // `Cmd/Ctrl+Enter` 不带修饰键的那一支会一路上行到页面层
                    // （quill 表里 `enter` 只有裸键），不必在这里重复。
                    //
                    // **不认识的键返回 null 而不是 `ignored`**：quill 判的是
                    // `!= null`，`ignored` 也是非 null，会连打字一起吞掉
                    // （见 `MailQuillEditor.onKeyPressed` 的注释）。
                    onKeyPressed: (event) {
                      if (event is! KeyDownEvent) return null;
                      if (event.logicalKey != LogicalKeyboardKey.escape) {
                        return null;
                      }
                      // 正在发（或正在离开）：吞掉，别落回 quill 去关它自己的
                      // 选区工具栏 —— 那时页面还在，用户还该看得到发送结果。
                      if (state.busy || _leavingFromButton) {
                        return KeyEventResult.handled;
                      }
                      _leave(context);
                      return KeyEventResult.handled;
                    },
                    overlayBuilder: (editorKey, viewportKey) => AiGhostText(
                      controller: _quill,
                      focusNode: _bodyFocus,
                      // 总开关在设置里，且**默认关**（spec §4.3③）。
                      enabled: aiUsable && settings.inlineContinuationEnabled,
                      start: () => _startContinuation(settings),
                      // 这两个 key 由 `MailQuillEditor` 递进来 —— 页面拿不到
                      // 它们，也不该拿到（见那个参数的文档注释）。
                      editorKey: editorKey,
                      viewportKey: viewportKey,
                    ),
                  ),
                ),
                // 润色落地那一瞬间的正文变灰：`_polishing` 现在是**同步的一小段**
                // （`_replaceUserBody` 里那个 try/finally），用户看不到闪一下。
                // 留着它是因为 `IgnorePointer` 仍是必要的守卫 —— 万一将来有人
                // 把落地改回异步，这一段能挡住「生成回来之前继续改正文」。
                if (_polishing)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Color(0x0D000000)),
                    ),
                  ),
              ],
            ),
          ),
          if (state.problems.isNotEmpty)
            _Problems(
              problems: state.problems,
              onDismiss: _c.clearProblems,
            ),
          _Footer(state: state, l10n: l10n),
          AttachmentChips(
            attachments: state.attachments,
            onRemove: _c.removeAttachment,
          ),
          const SizedBox(height: 4),
        ],
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }

  String _title(AppLocalizations l10n, ComposeState state) => switch (state.args.mode) {
        ComposeMode.reply => l10n.reply,
        ComposeMode.forward => l10n.forward,
        ComposeMode.blank => l10n.compose,
      };

  // ------------------------------------------------------------ 编辑器同步

  /// **挂 `QuillController` 而不是 `document.changes`**：后者是 per-Document
  /// 的、且**异步投递**（探针 probe64：`replaceText` 返回后立刻看到的次数是
  /// 0）。挂在 controller 上是同步且跟着文档换的。
  void _onBodyChanged() {
    _writeBack?.cancel();
    // 这次通知算不算「用户写的」？**只比内容，不比通知** —— 换个选区也会走到
    // 这里，那不是编辑。判据与理由见 [_lastBodyFingerprint]。
    //
    // 结论存在 [_pendingMarkDirty] 里而不只闭在闭包中：[_flushBody] 可能在
    // 计时器烧完之前就被叫到（打完字立刻按返回），它要沿用同一个结论 ——
    // 那时闭包还没跑过。基准**不在这里更新**，留给 [_pushBody] 与装载初值。
    _pendingMarkDirty = !_adoptingBody &&
        !_polishing &&
        _bodyFingerprint(_quill.document.toDelta()) != _lastBodyFingerprint;
    _writeBack =
        Timer(_writeBackDelay, () => _pushBody(markDirty: _pendingMarkDirty));
  }

  void _pushBody({bool markDirty = true}) {
    if (!mounted) return;
    // 从 controller 读，不从 state 读 —— state 是副本。
    //
    // **回写时把「初值版次」一起追平**：这一路是编辑器 → state 的自回写，
    // 不该被 `_adoptInitialBody` 当成「state 换了初值」而把文档再装回去
    // （那会丢掉光标与撤销栈）。见 `ComposeState.bodyRevision`。
    _c.setBody(
      DocumentCodec.encode(_quill.document),
      bodyRevision: _bodyRevision,
      markDirty: markDirty,
    );
    // 记下**这次回写的正文**：这就是「用户写过没有」的比较基准。
    // 放在回写之后、无论置不置脏都记 —— 装载初值那一趟回写（`markDirty: false`）
    // 记的正是引用块那一版，于是它在 `dirty` 判据里天然不算「用户写的」。
    _lastBodyFingerprint = _bodyFingerprint(_quill.document.toDelta());
  }

  /// 把**还在防抖里**的正文立刻推到 `state`。
  ///
  /// 用户打完最后一个字到 `_writeBack` 触发之间最多有 [_writeBackDelay]
  /// （250 ms）的窗口。这期间 `state.body` 还是上一次回写的版本，而
  /// `buildPayload()` 与 `saveDraftOnExit()` 读的都是 `state.body` ——
  /// 于是「打完就点发送」发出去的是**少一段、甚至整篇空白**的信，
  /// 「打了字立刻关掉」那段字连草稿都进不去。
  ///
  /// 真正的写入者是 `_quill`，所以这里取消计时器、直接推一次就够了。
  /// 没有待办时不推：省掉一次 base64 编码（正文带 5 MB 图时是 25 ms）。
  ///
  /// 置不置脏**沿用这次通知算不算编辑的判断**（[_onBodyChanged] 里算好的那
  /// 一份 `markDirty`），不在这里一律 `markDirty: true` 了事：用户只是点了
  /// 一下正文（换了选区、文档没变）时不该给这封信记一条「用户改过」。
  /// 真正的判据是那个闭包里算出来的值 —— [_flushBody] 拿到的是**最近一次
  /// 通知**算的那一份，所以把通知的结论留在 [_pendingMarkDirty] 里。
  void _flushBody() {
    if (_writeBack?.isActive ?? false) {
      _writeBack?.cancel();
      _pushBody(markDirty: _pendingMarkDirty);
    }
  }

  /// 把 `state.body` 里的正文装进编辑器。**每换一次初值装一次**。
  ///
  /// 什么时候算「换了初值」：第一帧永远算（那一帧 `state.body` 是回复/转发的
  /// 引用块、或空写信页的空串），之后每次 `state.bodyRevision` 变了才算。
  ///
  /// **为什么不能只装第一帧那次**：草稿是异步读出来的（控制器在 `build()`
  /// 里只能排一个 `scheduleMicrotask`），而第一帧的 `build()` 跑在它前面 ——
  /// 那一次 `state.body` 还是预填值。早先的实现就是「只装一次」，于是从草稿箱
  /// 点开一条草稿时，读回来的正文**再也没有任何路子进编辑器**（另一个方向只有
  /// 用户在编辑器里敲字 → `_pushBody`）。用户看到的是一个空白写信页，
  /// 随手敲一个字再关窗，回写的就是这么一份「只有那个字」的文档 ——
  /// **库里那条写了一半的草稿被静默覆盖**。
  ///
  /// 反过来，用户自己在编辑器里打字时**绝不能**走这条路：那时 `state.body`
  /// 是编辑器被回写的副本，装回去就等于每次回写都重建一份 Document，光标、
  /// 选区、撤销栈全丢。`_pushBody` 在回写前把 `bodyRevision` 追平（它和
  /// `setBody` 在同一次同步 `set` 里，读者仍在 250 ms 防抖窗口里），
  /// 就是为了让这种自回写不触发装载。
  ///
  /// 用 `replaceText` 而不是 `_quill.document = …`：探针 probe72 实测两者都能
  /// 换掉整篇，但 `set document` 会把光标重置到 0 且**只通知一次** —— 而
  /// 「只通知一次」在这里恰恰是个坑：它不会触发 `_onBodyChanged` 的防抖，
  /// 于是初次装载的正文永远不回写进 `state.body`，只靠引用块发出去的邮件
  /// 会在 `buildPayload()` 里拿到一个空正文。
  ///
  /// 光标：回复/转发时给 `collapsed(0)`（用户要写在引用块上方，probe72 实测
  /// 光标在 0 时引用块原样留着，敲的字落在它前面）；**读回草稿时给文末** ——
  /// 用户是接着上次写，光标不该回到开头。判据是「有没有预填的引用块」，而不是
  /// 「装的是第几版」。
  void _adoptInitialBody(ComposeState state) {
    _bodyRevision = state.bodyRevision;
    // **空正文什么都不做**。控制器本来就是从一个空文档起步的，而
    // `replaceText(0, 0, emptyDelta)` 会真的往那个空文档里再插一个换行 ——
    // 文档从「空」变成「一个空行」，占位提示（`doc.isEmpty()` 为真才显示）
    // 于是永远不出现（实测：`isEmpty` 变 false）。空写信页与「发送后清空」
    // 都走这一支，正好是我们要的。
    if (DocumentCodec.isEmptyDelta(state.body)) return;
    // 光标落到文末的是「读回来的草稿」，落到 0 的是「我们预填的引用块」。
    // 用「这一版装的是不是文档最初的预填内容」来区分 —— 第一帧那一版才是。
    final quoted = state.bodyRevision == 0;
    final document = DocumentCodec.decode(state.body);
    // 这次装载会**通知两回**：`replaceText` 一回，随后那次 `updateSelection`
    // 又一回（QuillController 是 ChangeNotifier，选区变化同样 `notifyListeners`）。
    // 两回都落在同一个防抖计时器上，后一回会把前一回盖掉 —— 所以记号必须罩住
    // **两**回，只罩 `replaceText` 的话，收尾那次通知带着 `_adoptingBody == false`
    // 重新起一个计时器，回写照样把页面标脏（探针实测：只罩 replaceText 时
    // `+400ms dirty=true body 117→133`）。
    //
    // 放 `finally` 里收：装的过程中抛了也不能把记号永远留在原地（留着的话用户
    // 之后每一下键盘敲击都不会再标脏，草稿就再也不存了）。
    _adoptingBody = true;
    try {
      _quill.replaceText(
        0,
        _quill.document.length - 1,
        qd.Delta.fromJson(document.toDelta().toJson()),
        // 选中**不在这里给**：`replaceText` 会把传进来的选区按 positionDelta
        // 一起推走（实测传 `collapsed(0)` 整篇替换之后它落在文档末尾 8，不是 0），
        // 于是「回复时写在引用块上方」会落空 —— 用户一进页面就在引用块下面打字。
        null,
      );
      // 所以换完再自己钉一次：预填的引用块把光标放回 0（引用块之前），
      // 读回来的草稿放到文末（接着上次写）。
      _quill.updateSelection(
        quoted
            ? const TextSelection.collapsed(offset: 0)
            // 用户自己写的那一段的末尾（引用区之前）。
            //
            // **没有引用时 `userEnd` 返回的就是 `document.length - 1`**
            // （`compose_quote.dart:70-71`）—— 与改动前逐字相同，所有老路径
            // 一点没动。这条等价性由「点开草稿时光标在文末」那条用例守着。
            //
            // 有引用时必须落这里：用户的字在引用块**上方**，落文末就落到
            // 别人的原信末尾去了 —— 他接着敲的第一句话会敲进对方的信里。
            // 这正是「从 AI 建议面板点答复」造出来的那一种草稿（spec §6.2）。
            : TextSelection.collapsed(
                offset:
                    ComposeQuote.userEnd(_quill.document.toDelta().toJson()),
              ),
        q.ChangeSource.local,
      );
    } finally {
      _adoptingBody = false;
    }
  }

  /// `TextField` 是**有状态的**，而状态在控制器里。两边必须单向同步：
  /// 只在「控制器里的值和编辑框里的值不一样」时写回编辑框，否则会打断输入法
  /// 的组词（中文/日文输入时，每敲一个字母都会触发 onChanged → 写回 →
  /// 光标跳到末尾，拼音就废了）。
  void _syncEditor(ComposeState state) {
    if (_subject.text != state.subject) {
      _subject.value = TextEditingValue(
        text: state.subject,
        selection: TextSelection.collapsed(offset: state.subject.length),
      );
    }
    // 正文**不在这里同步**：`_quill` 自己就是真相，`state.body` 是它被回写
    // 的副本（见 `_pushBody`）。在这里反向写回会让每一次 state 变化都重建
    // 一份 Document —— 光标、选区、撤销栈全都会丢。
  }

  /// 一次性提示 → SnackBar。
  ///
  /// 用文案本身当去重键：`notice` 在 state 里会一直留着直到屏幕消费它，
  /// 而 `build` 会跑很多次 —— 不去重的话同一条提示会叠好几层。
  ///
  /// **只登记不弹**：`showSnackBar` 内部会 `setState`，在 `build` 期间调用
  /// 会撞上「setState() or markNeedsBuild() called during build」的断言 ——
  /// 而这一条是在 debug 模式下**真的会抛**的（断言在
  /// `ScaffoldMessengerState.showSnackBar` 里，不是给 release 用的空壳）。
  /// 异常从 `build()` 里炸出去，Flutter 会把这一整棵子树换成 ErrorWidget，
  /// 用户看到的就是「点了发送，整个页面变红」——这也正是 4 号 bug 的现场。
  ///
  /// 所以这里只把提示记下来，真正的弹出推迟到帧结束之后
  /// （见 [_scheduleNotice]）。状态本身由 `_lastNotice` 去重。
  ///
  /// **成功的提示要连页面一起收摊**（问题 4）：非错误的那条提示意味着
  /// 「这封信已经交出去了」（直发成功或已排进发件箱），写邮件页没有继续
  /// 留着的理由 —— 内容已经在 [_finishCompose] 里清空，用户会盯着一个空
  /// 编辑框发呆。所以先 pop 再提示，那句话落在下面的主窗口上。
  void _drainNotice(BuildContext context, ComposeState state) {
    final notice = state.notice;
    if (notice == null) {
      _lastNotice = null;
      return;
    }
    if (notice == _lastNotice) return;
    _lastNotice = notice;
    final isError = state.noticeIsError;
    _scheduleNotice(
      context,
      notice: notice,
      isError: isError,
      // 错误要留在页里改（`_afterFailure` 已经把内容存进草稿了），只有
      // 成功那一支关窗口。
      close: !isError,
    );
  }

  /// 把 SnackBar 推迟到当前帧画完之后。
  ///
  /// 用 `ScaffoldMessengerState` / `NavigatorState` 而不是 post-frame 里再用
  /// 那个 `BuildContext`：回调跑的时候这一页可能已经没了（[close] 那一支
  /// 正是要把它关掉），而这两个对象挂在 `MaterialApp.router` / 根 Navigator
  /// 上，页面没了也还在。
  ///
  /// **顺序照抄 `send_queue_sheet._sendNow`**（先取 messenger → pop → 再弹）：
  /// messenger 是根实例，pop 之后由外壳那一屏承接，正是「在主窗口弹出队列
  /// 提示」。反过来先弹再 pop 的话，SnackBar 会随着页面一起被收走，
  /// 用户根本看不见。
  void _scheduleNotice(
    BuildContext context, {
    required String notice,
    required bool isError,
    required bool close,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    // 关的必须是**这一页**，不能是「栈顶那一页」。这一条是防一个很窄但
    // 真实存在的窗口：post-frame 回调还没跑，用户先按了返回键 ——
    // 那时 `PopScope` 已经放行、这一页正在被弹走，再 pop 一次就把
    // **下面那一屏**也关掉了。`ModalRoute.of` 在这一帧里恰好就是本页的
    // route（判定依据是它此刻在不在栈顶），对不上就不关。
    final route = ModalRoute.of(context);
    // 颜色要在 build 上下文还有效时读出来 —— post-frame 里再读
    // `Theme.of` 会踩到「在 dispose 后访问 context」。
    final errorColor = Theme.of(context).colorScheme.error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 消费掉，否则下次进这个页面还会弹一遍。
      if (mounted) _c.consumeNotice();
      if (close && (route?.isCurrent ?? false)) navigator.pop();
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(notice),
          backgroundColor: isError ? errorColor : null,
          duration: Duration(seconds: isError ? 8 : 3),
        ),
      );
    });
  }

  // ---------------------------------------------------------------- 动作

  Future<void> _send(BuildContext context) async {
    if (!await _maybePreflight()) return;
    // 输入框里那半截地址还没回车的，先收下 —— 用户点了发送就意味着
    // 「我写完了」，此时再去要求他先按一次回车是荒谬的。
    _c.commitRecipientInput();
    // **发送前必须把防抖中的正文推到 state**：`buildPayload()` 读的是
    // `state.body`，而 `_writeBack` 有 250 ms 延迟 —— 打完最后一个字就点发送
    // 的话，导出的正文会是上一次回写的版本（打第一个字就发，甚至整篇为空）。
    _flushBody();
    await _c.send();
  }

  /// 「立即发送」：跳过设置里的延迟，当场发出去。
  Future<void> _sendNow(BuildContext context) async {
    if (!await _maybePreflight()) return;
    _c.commitRecipientInput();
    _flushBody();
    await _c.sendImmediately();
  }

  /// 发送前检查。返回 true = 继续发，false = 用户退回去改。
  ///
  /// 三道短路，顺序不能反：
  /// 1. 设置里关着 → 直接发（**用户明确关掉的东西不该被塞回来**）；
  /// 2. 正文是空的 → 直接发，让 `buildPayload` 那条 `emptyContent` 去报错。
  ///    在这里弹检查面板的话，用户会先看到一句「主题是空的」，点完「仍然发送」
  ///    再被一句「正文不能为空」拦下 —— 两句话在两个地方说同一件事；
  /// 3. 其余情况一律弹面板。
  Future<bool> _maybePreflight() async {
    final settings = ref.read(aiSettingsProvider).value ?? const AiSettings();
    if (!settings.preflightEnabled) return true;
    if (DocumentCodec.isEmptyDelta(DocumentCodec.encode(_quill.document))) {
      return true;
    }
    return _preflight(settings);
  }

  /// ④b 发送前检查。
  ///
  /// **本地那段零成本、永远先跑**（spec §4.3④）—— 没配 Key 的用户也能拿到
  /// 最有价值的那条「声明了附件却没附件」。模型检查要点一下才跑，且按钮上
  /// 写明「会消耗一次调用」（面板自己的事）。
  Future<bool> _preflight(AiSettings settings) async {
    final bodyText = composePlainText();
    // `_c.state` 是 `Notifier.state`（protected，直接读会踩 lint）—— 从
    // provider 上读是公开且等价的读法。
    final attachmentCount =
        ref.read(composeControllerProvider(widget.args)).attachments.length;
    final local = AiPreflight.checkLocal(
      subject: _subject.text,
      bodyText: bodyText,
      attachmentCount: attachmentCount,
      inlineImageCount: ImageInsert.countInlineImages(
        _quill.document.toDelta().toJson(),
      ),
    );
    final decision = await showModalBottomSheet<PreflightDecision>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiPreflightSheet(
        local: local,
        startReview: settings.isUsable && AiPreflight.shouldRun(settings)
            ? () => ComposeAi.startReview(
                  ref.read(aiServiceProvider),
                  subject: _subject.text,
                  body: bodyText,
                  attachmentCount: attachmentCount,
                )
            : null,
      ),
    );
    // null = 用户点了外面把面板划走了 → **不发送**。返回 true 只在
    // 「仍然发送」被明确点下时发生。
    return decision == PreflightDecision.sendAnyway;
  }

  /// 选附件。`file_picker` 只给路径不给内容，附件始终不整体进内存。
  Future<void> _pickAttachments(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      final picked = await ComposeAttachments.pick(
        dialogTitle: l10n.composeAttachmentTitle,
      );
      if (picked.isEmpty) return;
      _c.addAttachments(picked);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  /// 离开页面：先把草稿存下来（空信不存，见控制器），再 pop。
  ///
  /// 这是 `X` 按钮的出口。**系统返回手势不经过这里**，它走 `build()` 里那层
  /// `PopScope` —— 两处都要 `_flushBody()` + `saveDraftOnExit()`，只是手势那
  /// 一路不需要 `pop`（Navigator 已经在弹了）。
  ///
  /// 发送成功之后再 pop 也不会被重新存一遍空草稿：`_finishCompose` 已经把
  /// `dirty` 置回 false，而 [ComposeController.saveDraftOnExit] 第一行就是
  /// `if (!state.dirty) return`。
  Future<void> _leave(BuildContext context) async {
    // 先落一次盘再走：防抖没烧完就退出的话，`state.body` 还是旧的，
    // 用户最后那几秒打的字会既进不了草稿、也没有别的地方留着（见 [_flushBody]）。
    _flushBody();
    await _c.saveDraftOnExit();
    // 下面这次 `pop()` 会**再触发一遍** `PopScope` 的回调（`canPop: true` 时
    // 程序化 pop 与返回手势一视同仁）—— 竖起闸门，别让它把同一封信存第二遍。
    if (!context.mounted) return;
    _leavingFromButton = true;
    Navigator.of(context).pop();
  }

  Future<void> _discard(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.draftDiscardConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.discard),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _c.discardDraft();
    if (!context.mounted) return;
    // 同一道闸：用户刚刚选择「放弃」，下面这次 `pop()` 不能让 `PopScope`
    // 又把内容存回草稿箱。
    _leavingFromButton = true;
    Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ 斜杠 / 插入

  /// 斜杠菜单 / 「+」面板执行条目时手头要有的东西。
  SlashContext _slashContext(AiSettings settings) => SlashContext(
        controller: _quill,
        focusNode: _bodyFocus,
        onInsertTable: (rows, columns) => _insertTable(rows, columns),
        onPickImage: () => _pickImage(context),
        onAiDraft: () => _draftWithAi(settings),
      );

  /// 插入一张空表格。
  ///
  /// `SlashMenuHostState._run` 的顺序是「清掉 `/query` → 焦点还回编辑器 →
  /// 跑动作」，所以走到这里时光标已经在正确的位置、文档里也没有残留的
  /// `/表格` 了 —— 这里只负责把嵌入放进去。
  void _insertTable(int rows, int columns) {
    final model = emptyTable(rows: rows, columns: columns);
    final maxOffset = _quill.document.length - 1;
    var at = _quill.selection.isValid
        ? _quill.selection.extentOffset.clamp(0, maxOffset < 0 ? 0 : maxOffset)
        : (maxOffset < 0 ? 0 : maxOffset);
    // **先腾出一整行**：表格是块级嵌入，插进一行中间会得到「文字 + 表格同在
    // 一行」的非法 Line（用户报的缺陷 5 的第二种表现，也是插图路径早就修过的
    // 同一个坑）。见 [EmbedLineBreak.at]。
    at = EmbedLineBreak.at(_quill, at);
    _quill.replaceText(
      at,
      0,
      q.BlockEmbed(tableEmbedType, TableHtmlCodec.encode(model)),
      TextSelection.collapsed(offset: at + 1),
    );
  }

  /// 选一张图内联进正文。
  ///
  /// 与拖放走**同一套额度判定**（`ImageInsert.canInsert`）—— 两条路各写一份
  /// 的话，「还能插几张」迟早会给出两个答案。
  Future<void> _pickImage(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    // 取在 await **之前**（`use_build_context_synchronously`：await 之后
    // `context` 可能已经不在树上）。额度不够那条提示由**这里**放，不放在
    // [_pickImageDataUri] 里 —— 那个方法对「选图」这一半是无状态的，
    // 额度是「插」那半边的事。
    final messenger = ScaffoldMessenger.of(context);
    final dataUri = await _pickImageDataUri();
    if (dataUri == null) return;
    final used = ImageInsert.countInlineImages(_quill.document.toDelta().toJson());
    final bytes = base64Decode(dataUri.split(',').last);
    final decision = ImageInsert.canInsert(used: used, bytes: bytes.length);
    if (decision != ImageInsertDecision.ok) {
      messenger.showSnackBar(SnackBar(
        content: Text(decision == ImageInsertDecision.tooLarge
            ? l10n.composeImageTooLarge
            : l10n.composeImageTooMany),
      ));
      return;
    }
    ImageInsert.insertDataImage(
      _quill,
      dataUri: dataUri,
      used: used,
      byteLength: bytes.length,
    );
  }

  /// 「选一张图 → 读成一个 data URI」。取消 / 太大 / 读不出来都给 null。
  ///
  /// **从 `_pickImage` 里拆出来的**：点正文里的图换图也要走选图，两处共用
  /// 这一半，别抄一份（抄一份的下场是两条路对「太大」各说各话）。
  ///
  /// `messenger` / `l10n` 都在**第一个 `await` 之前**取好：这一串里有两处
  /// await（选文件、读盘），await 之后再用 `context` 会被
  /// `use_build_context_synchronously` 拦下，而那两个值本来就与
  /// 「widget 还在不在树上」无关。
  Future<String?> _pickImageDataUri() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: l10n.composeAttachmentTitle,
        // 只要路径：`readFileAsDataUri` 自己读盘，读的时候才知道真实大小，
        // 而 `file_picker` 在某些平台给的 `size` 是 0。
        // **别加 `withData:`** —— 13.1.0 的 `pickFiles` 没有这个参数。
        type: FileType.image,
      );
      if (picked.isEmpty) return null;
      final path = picked.first.path;
      if (path == null || path.isEmpty) return null;

      final dataUri = await ImageInsert.readFileAsDataUri(path);
      if (dataUri == null) {
        // 读不出来只有三种原因：文件没了、太大、不是认得的图片类型。
        // 对用户是同一句话（其中「太大」是压倒性的多数），不做区分。
        messenger.showSnackBar(SnackBar(content: Text(l10n.composeImageTooLarge)));
        return null;
      }
      return dataUri;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      return null;
    }
  }

  // ------------------------------------------------------------ 点图改图

  /// 点一张正文里的图：给一个「对齐 / 换图」的小菜单。
  ///
  /// **偏移用传进来的那个**（`build` 里现算的 `node.documentOffset`），
  /// 但**先校验它此刻还是不是一张图** —— 回调存的是上一帧的值，用户完全可能
  /// 点了图、菜单还没弹出来就敲了两个字。不是图了就退回「离当前选区最近的
  /// 一张」（多张时这是最贴近意图的选法）。
  ///
  /// 菜单收尾一律 `_bodyFocus.requestFocus()`：桌面端点编辑器外面会让正文
  /// 失焦，而用户点图之后接着要打字。
  Future<void> _onImageTap(int documentOffset) async {
    final offsets = imageOffsets(_quill.document);
    if (offsets.isEmpty) return;
    var offset = documentOffset;
    if (!offsets.contains(offset)) {
      final here =
          _quill.selection.baseOffset.clamp(0, _quill.document.length);
      offset = offsets.reduce(
        (a, b) => (a - here).abs() <= (b - here).abs() ? a : b,
      );
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => const _ImageActionsSheet(),
    );
    switch (action) {
      case 'left':
        setImageAlign(_quill, offset, q.Attribute.leftAlignment);
      case 'center':
        setImageAlign(_quill, offset, q.Attribute.centerAlignment);
      case 'right':
        setImageAlign(_quill, offset, q.Attribute.rightAlignment);
      case 'replace':
        final dataUri = await _pickImageDataUri();
        if (dataUri != null) replaceImage(_quill, offset, dataUri);
    }
    _bodyFocus.requestFocus();
  }

  // ------------------------------------------------------------- 剪贴板

  /// 自定义剪贴板处理。返回 true = 「我处理完了」。
  ///
  /// 顺序不能反：**先试图片，再试 HTML**。
  ///
  /// - 为什么图片要抢在前面：从「截图工具 / 浏览器里右键复制图片」粘过来时，
  ///   剪贴板里**同时**有 HTML（一个 `<img>`）和位图。让 HTML 先走的话，
  ///   我们会得到一个指向外部地址的 `<img src="https://…">` —— 那在收信人
  ///   那边多半是一张被拦掉的裂图，而用户以为自己是把图**附**进去了。
  /// - 为什么 HTML 不能让上游接：它走的是被弃用的 `DeltaX.fromHtml`，
  ///   表格会转换两次（§0.2 第 2 条）。见 `MailPasteHandler.handleHtmlPaste`。
  ///
  /// 纯文本**绝不在这里拦**：记事本里复制一段字也要能粘进来，而那条通路
  /// 落在这个回调之后（`quill_controller.dart:656`）。
  Future<bool> _onClipboardPaste() async {
    try {
      final bytes =
          await qi.ClipboardServiceProvider.instance.getImageFile();
      if (bytes != null && bytes.isNotEmpty) {
        return _insertPastedImage(bytes);
      }
    } catch (_) {
      // 剪贴板读不到（平台不支持、被别的进程占着）—— 让位给下面的 HTML 与
      // 纯文本通路，绝不把异常抛给编辑器。
    }
    return MailPasteHandler.handleHtmlPaste(_quill);
  }

  bool _insertPastedImage(Uint8List bytes) {
    final used = ImageInsert.countInlineImages(_quill.document.toDelta().toJson());
    if (ImageInsert.canInsert(used: used, bytes: bytes.length) !=
        ImageInsertDecision.ok) {
      // 超额度的图**静默丢弃**：粘贴不是一次明确的「我要插一张图」，
      // 为它弹一条错误会打断用户正在写的东西。
      return true;
    }
    // `bytes` 有可能是 `Uint8List` 的一个视图（`view:` 出来的），
    // `ImageInsert.toDataUri` 认的是完整字节 —— 先铺平一次。
    return ImageInsert.insertDataImage(
      _quill,
      dataUri: ImageInsert.toDataUri(Uint8List.fromList(bytes)),
      used: used,
      byteLength: bytes.length,
    );
  }

  // ------------------------------------------------------------- 拖放

  /// 有文件被拖进正文区。
  ///
  /// 分类交给 `DropClassifier`（它才认识 `DropItem` 那套继承），
  /// 但**图片与附件各走各的额度**：图片是正文的一部分（10 张上限由
  /// `ImageInsert` 管），附件是 `_c.addAttachments` 那一套（10 个 / 20 MB）。
  Future<void> _onDropFiles(
    BuildContext context,
    DropDoneDetails details,
    int? dropOffset,
  ) async {
    final items = details.files;
    if (items.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);

    // 目录读不了（`PathNotFoundException`，§0.2 第 13 条），先摘出去并说一句。
    if (DropClassifier.hasIgnoredDirectories(items)) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).composeDropFolderIgnored)),
      );
    }

    for (final item in DropClassifier.images(items)) {
      // `readFileAsDataUri` 自己读盘 —— 它在 `testWidgets` 的假时钟里会挂死
      // （§0.2 第 14 条），所以这一条路只在真机上跑得到，测试走
      // `ImageInsert` 的单测。
      final dataUri = await ImageInsert.readFileAsDataUri(item.path);
      if (dataUri == null) continue;
      final bytes = base64Decode(dataUri.split(',').last);
      final used = ImageInsert.countInlineImages(_quill.document.toDelta().toJson());
      if (ImageInsert.canInsert(used: used, bytes: bytes.length) !=
          ImageInsertDecision.ok) {
        continue;
      }
      // 落点是**松手那一下的位置**（`MailQuillEditor` 算好的），拿不到就
      // 退回光标处 —— 探针实测拿不到几何信息时它就返回 null。
      final at = dropOffset ?? _quill.selection.extentOffset;
      _quill.updateSelection(
        TextSelection.collapsed(offset: at.clamp(0, _quill.document.length - 1)),
        q.ChangeSource.local,
      );
      ImageInsert.insertDataImage(
        _quill,
        dataUri: dataUri,
        used: used,
        byteLength: bytes.length,
      );
    }

    final files = DropClassifier.attachments(items);
    if (files.isEmpty) return;
    // 走**路径**而不是 `PlatformFile`：13.1.0 里 `PlatformFile` 是
    // `abstract base class`，**没有公开构造函数**（实体是
    // `DarwinPlatformFile` 之类的平台类），测试里也造不出来。
    final attachments = await ComposeAttachments.fromPaths(
      [for (final item in files) item.path],
    );
    _c.addAttachments(attachments);
  }

  // ------------------------------------------------------------ AI 面板

  /// 把一段文字插到光标处。签名与常用语走同一条 —— 它们在数据上没区别。
  ///
  /// **插入之后把焦点还给编辑器**：这两颗按钮都在工具栏上，点完不还焦点的话
  /// 用户接着敲字会发现打不进去（与 emoji 那颗同一个理由）。
  void _insertSnippet(String text) {
    insertSnippet(_quill, text);
    _bodyFocus.requestFocus();
  }

  /// 回复建议这颗按钮**该不该画**：必须同时是「回复模式」且「拿得到来信正文」。
  ///
  /// **为什么单把模式拿出来判**：转发时 `args.mail` 也是非 null
  /// （`compose_entry.dart` 转发也传 `mail: _row`），而
  /// `_incomingBody` 只看 `mail` 不看模式 —— 光靠它放行，转发页也会冒出
  /// 「回复建议」，点下去是拿一封**你正要转出去**的信去生成回信开头。
  /// 普通写邮件（`blank`）与 `mail == null` 则由 `_incomingBody` 那一道拦下。
  /// 别再把它「简化」掉：模式这半条是 spec §6.3 点名的三种情形之一。
  bool get _canSuggestReply =>
      widget.args.mode == ComposeMode.reply && _incomingBody != null;

  /// 回复模式下**来信的纯文本正文**（没有就是 null）。
  ///
  /// 走 `ComposeHtml.originalBody(mail, ossBase: ...)` 拿到**净化过的** HTML
  /// （`compose_html.dart:32` 里 `sanitizeEmailHtml` 一步没少），再
  /// `MailHtmlToDelta.convert(html)` → `Document.fromJson(...).toPlainText()`。
  ///
  /// **为什么不直接用 `mail.content`**：那是**没净化过**的原文，而且
  /// `{{domain}}` 占位符没替换（`ComposeHtml.originalBody` 两件事都做了）。
  /// 把生 HTML 甩给模型还会把标签也塞进 prompt，浪费配额又干扰结果。
  ///
  /// **为什么不用 `widget.args.mail` 里的 `text`**：`originalBody` 已经把
  /// 「有 HTML 用 HTML、没有才退回 text」这条优先级写好了，照它走即可。
  ///
  /// 拿不到 / 净化后为空 → 返回 null，调用方据此**不画那颗按钮**（spec §6.3）。
  ///
  /// **用 `widget.args`，不要 `_c.state.args`。** `Notifier.state` 标着
  /// `@protected`，在 Notifier 类外读会踩 `invalid_use_of_protected_member`
  /// （`compose_screen.dart:841` 那条注释记的就是这件事）。`widget.args`
  /// 与它**是同一个对象** —— `ComposeScreen` 就是拿 `widget.args` 去
  /// `ref.watch(composeControllerProvider(...))` 的（见 `:250` / `:255`）。
  String? get _incomingBody {
    final mail = widget.args.mail;
    if (mail == null) return null;
    final html = ComposeHtml.originalBody(
      mail,
      ossBase: ref.read(ossBaseProvider(mail.profileId)),
    );
    if (html.trim().isEmpty) return null;
    final ops = MailHtmlToDelta.convert(html);
    final text = q.Document.fromJson(ops).toPlainText().trim();
    return text.isEmpty ? null : text;
  }

  /// ① 选中即改。
  ///
  /// **没有选中就没有原文**：`RewriteSelection.selectedText` 会返回空串，
  /// 这时给一句提示而不是开一个空面板。
  Future<void> _rewriteSelection(BuildContext context,
      {RewriteTone tone = RewriteTone.polish}) async {
    final selected = RewriteSelection.selectedText(_quill);
    if (selected.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).composeAiSelectFirst)),
      );
      return;
    }
    final outcome = await showModalBottomSheet<RewriteOutcome>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiRewriteSheet(
        original: selected,
        // **传进去而不是什么都不传**：用户点「更简洁」时面板打开就该是
        // 「更简洁」已经选中，否则那颗按钮等于只做了一半。
        initialTone: tone,
        start: (tone, extra) => _adopt(
          ref.read(aiServiceProvider).rewrite(
                selection: selected,
                tone: tone,
                extraInstruction: extra,
              ),
        ),
      ),
    );
    if (outcome == null) return;
    // **结局要分开处理**（Task E5 的偏离点）：`applyRewrite` 现在返回四类
    // 结局而不是 bool，因为「用户主动丢弃」（不该提示）与「系统拒绝了这次
    // 改写」（必须提示）以前被压成同一个 `false`，用户点了替换、什么都没发生、
    // 也没有一句解释。
    final result = ComposeAi.applyRewrite(_quill, outcome);
    // 用 `context.mounted`（不是 State 的 `mounted`）：这里要用的就是传进来的
    // 这个 `context`，用 State 的守卫会被 lint 判成「不相关的守卫」。
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context);
    switch (result) {
      case RewriteApplyResult.applied:
      case RewriteApplyResult.discarded:
      case RewriteApplyResult.emptyResult:
        // 丢弃是用户自己的选择；空结果沉默比一句错误提示好（见
        // `RewriteApplyResult` 的文档）。
        break;
      case RewriteApplyResult.selectionHasEmbed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.composeAiSelectionHasEmbed)),
        );
      case RewriteApplyResult.selectionGone:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.composeAiSelectionGone)),
        );
    }
  }

  /// ② 要点成文。
  Future<void> _draftWithAi(AiSettings settings,
      {RewriteTone tone = RewriteTone.polish}) async {
    final subject = _subject.text;
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiDraftSheet(
        subject: subject,
        initialTone: tone,
        start: (request) => ComposeAi.startDraft(
          ref.read(aiServiceProvider),
          request,
          subject: subject,
        ),
      ),
    );
    if (text == null) return;
    // 两种落地。**由「正文是不是空的」决定**：
    // - 正文是空的（新开一封 / 点了斜杠菜单里的「AI 起草」）→ 替换全部；
    // - 正文已经有东西 → 插到光标后面。
    // 反过来的话，用户写了一行字再点「AI 起草」会把自己写的那行删掉。
    final hasContent = !DocumentCodec.isEmptyDelta(
      DocumentCodec.encode(_quill.document),
    );
    if (hasContent) {
      ComposeAi.insertDraft(_quill, text);
    } else {
      ComposeAi.applyDraft(_quill, text);
    }
  }

  /// ⑤ 回复建议。
  ///
  /// 面板返回的是**用户选中的那一条**（没选就是 null），这里把它插到光标处。
  /// 不做「正文非空」的分支（与起草那边的区别）：回复建议是**新增**内容，
  /// 无论正文空不空都该插在光标后面，而不是替换掉用户已经写的东西。
  Future<void> _suggestReply(AiSettings settings, String incoming) async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiReplySheet(
        incoming: incoming,
        start: () => ComposeAi.startReply(
          ref.read(aiServiceProvider),
          incoming: incoming,
        ),
      ),
    );
    if (text == null) return;
    insertSnippet(_quill, text);
    _bodyFocus.requestFocus();
  }

  /// ④a 起标题：主题栏那颗内联图标点下去走这里。
  ///
  /// **不再开面板、不要候选**：点一下 → 图标转圈 → 生成完把第一行直接填进
  /// 主题栏。用户不满意就再点一次 —— 这次的提示词里会带上已经填进去的那句
  /// 当参考（见 `AiPrompts.subject`），于是第二次多半是在那一版上改得更贴切，
  /// 而不是另起一个。
  ///
  /// 正文本就是空的时，拦一句：标题是**从正文里长出来的**，没有正文就只能靠
  /// 模型编，那标题必然是错的。
  Future<void> _suggestSubject() async {
    if (DocumentCodec.isEmptyDelta(DocumentCodec.encode(_quill.document))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).aiSubjectEmpty)),
      );
      return;
    }
    setState(() => _subjectSuggesting = true);
    final run = ComposeAi.startSubject(
      ref.read(aiServiceProvider),
      body: composePlainText(),
      current: _subject.text,
    );
    // 等「不再生成」而不是等 `run.done`：`done` 只在正常收尾时完成，出错那
    // 一路是靠 `running` 翻假 + `message` 通知的 —— 只等 done 的话，一次 401
    // 会让图标一直转圈（`AiRun._finish` 在出错时也会把 running 关掉）。
    final completer = Completer<void>();
    void check() {
      if (run.running.value || completer.isCompleted) return;
      completer.complete();
    }

    run.text.addListener(check);
    run.running.addListener(check);
    try {
      await completer.future;
    } finally {
      run.text.removeListener(check);
      run.running.removeListener(check);
      run.dispose();
      if (mounted) setState(() => _subjectSuggesting = false);
    }
    if (!mounted) return;
    final line = AiPrompts.subjectLineIn(run.text.value);
    // 出错、或模型一句都没回 → **安静地什么都不做**（转圈已经关了）。主题栏
    // 保持原样，用户再点一次就是了；为它弹一句错会打断正在写字的人（与幽灵
    // 文本出错时安静消失同一条规矩）。
    if (line == null) return;
    _c.setSubject(line);
    // 主题那一行是 `[label][TextField][icon]`，而 `_subject` 是屏幕自己的
    // 控制器 —— `ComposeState` 变了不会自动铺回输入框（`_syncEditor` 只在
    // 页面 rebuild 时跑）。这里手动同步一次，值立刻出现，不用等下一帧。
    _syncEditor(ref.read(composeControllerProvider(widget.args)));
  }

  /// ④b 润色：AppBar 上那颗图标点下去走这里 —— **只开面板，不发请求**。
  ///
  /// **只润色用户自己写的那部分，引用一字不动**。四个取舍：
  ///
  /// 1. **不去掉选区也能用**。走 `RewriteSelection.replaceSelection` 那条路要先
  ///    有一份选中的原文，而「把整封信润一遍」根本不需要用户先全选。
  /// 2. **引用不喂给模型、也不被改写**。回复/转发时引用块是正文文档的一部分
  ///    （spec §3.6），但用户点润色要理顺的是**自己写的措辞**，不是让模型把
  ///    别人发来的原信重写一遍 —— 改写过再发出去比不改更糟。边界与落地都走
  ///    [ComposeQuote]：喂给模型的是 `userEnd` 之前那段，`replaceText` 也只
  ///    覆盖那一段，引用（含分隔线）与它上面的横线一个字节都不动。
  /// 3. **撤销要能一次退回原文**。`replaceText(0, userEnd, 用户那段, …)` 两头
  ///    都是「局部编辑」，`History` 认得 —— 于是 `Cmd/Ctrl+Z` 一路退回原样。
  ///    刻意**不清空撤销栈**：用户可能先改了几笔再点润色，那几笔也该还在。
  /// 4. **用户写的那段里有图片/表格时不润色**：模型只回纯文本，替换会把那些
  ///    嵌入一起抹掉 —— 那是静默的数据丢失。宁可什么都不做（并告诉用户）。
  ///    判据只看**用户区**：引用里带的图片不归这条管（它本来就要原样留着），
  ///    早先「整篇任何嵌入都拦」会让「回复一封带图的邮件」整条润色都用不了。
  ///
  /// **参数由面板收**（语气 + 自定义指令），用户点面板里的「生成」才发请求；
  /// 两次占位检查（正文空、用户区含嵌入）放在**开面板之前** —— 那两件是正文
  /// 状态，不是参数。
  ///
  /// 不收 `BuildContext` 参数：这一趟要跨几次 `await`，用的是页面自己的
  /// `context` —— 那样 `mounted`（State 的）就是正确的守卫，不会撞上
  /// `use_build_context_synchronously`。
  Future<void> _polishAll() async {
    final body = composeUserPlainText();
    if (body.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).aiPolishEmpty)),
      );
      return;
    }
    final l10n = AppLocalizations.of(context);
    // 用户区里有没有嵌入（图片/表格）。判据与改写那边同一套思路：非字符串的
    // op 就是嵌入；范围收在 `userEnd` 之前（见上面第 4 条）。
    final delta = _quill.document.toDelta().toJson();
    if (ComposeQuote.hasEmbed(delta, before: ComposeQuote.userEnd(delta))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.composeAiSelectionHasEmbed)),
      );
      return;
    }

    // 参数与生成都在面板里。`start` 每次都现取一次 `body`（用户可能在面板
    // 开着时改了正文 —— 虽然模态面板盖住了正文，但这条不改也不会有害）。
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiPolishSheet(
        start: (tone, extra) => _adopt(
          ref.read(aiServiceProvider).rewrite(
                selection: composeUserPlainText(),
                tone: tone,
                extraInstruction: extra,
              ),
        ),
      ),
    );
    if (!mounted) return;
    // null = 用户没点「替换全文」（划走面板或点了丢弃）。
    if (text == null) return;
    final polished = RewriteSelection.normalize(text);
    if (polished.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.aiPolishFailed)),
      );
      return;
    }
    _replaceUserBody(polished);
  }

  /// 用 [text] 换掉**用户自己写的那一段**（引用区原样留着）。
  ///
  /// 一次 `replaceText` 就够 —— 它内部是「插入 + 删除」两条局部编辑
  /// （`document.replace` 先 `insert(replaceLength: len)` 再 `delete`），
  /// `History` 两条都认得，于是 `Cmd/Ctrl+Z` 一次退回原文。
  ///
  /// 范围 `[0, userEnd)` 的两头都由 [ComposeQuote.userEnd] 定死：
  ///
  /// - **有引用**（带 `mail-quote` 标记）：`userEnd` 是引用前**那个 `\n`** 的
  ///   位置，于是那个 `\n` 留在原地。模型给的是一段不带行尾的文字，留着它
  ///   `---` 才还是一条独立的线 —— 否则 `你好\n---` 会变成 `您好---`，
  ///   横线的判据（`delta_to_email_html.dart:52` 的 `html == '---'`）当场失效。
  /// - **没引用**（旧草稿、或用户把引用整段删了）：`userEnd` 是 `长度 - 1`，
  ///   也就是**末尾那个 `\n` 不动** —— 删掉再插会走 `Document` 的「空文档整篇
  ///   替换」分支，撤销栈在那一路会作废。与这个文件早先的行为逐字相同。
  ///
  /// 光标落在新正文末尾（引用区之前）—— 润色之后最可能的下一步就是接着往下写。
  void _replaceUserBody(String text) {
    final end = ComposeQuote.userEnd(_quill.document.toDelta().toJson());
    // 用户区是空的（引用顶上连那个空行都没有）：什么都不做。
    // 正常路径到不了这里 —— [_polishAll] 已经拿空正文早退过一次。
    if (end <= 0) return;
    _polishing = true; // 这一趟的通知不算「用户写的」（见 [_onBodyChanged]）
    try {
      _quill.replaceText(
        0,
        end,
        text,
        TextSelection.collapsed(offset: text.length),
      );
    } finally {
      _polishing = false;
    }
  }

  /// 正文的纯文本（整篇，含引用）—— 起标题与发送前检查用。**不是
  /// `document.toPlainText()`** —— 那个会把图片与表格渲染成 `￼`，而模型看不懂
  /// `￼`。
  ///
  /// 绕一圈（Delta → HTML → 纯文本）而不是直接 `toPlainText()`：这一圈走的是
  /// **同一个导出器**，于是「模型看到的正文」与「收信人看到的正文」是同一个
  /// 形状。直接 `toPlainText()` 的话，块级嵌入会变成一个个孤零零的 `￼`，
  /// 标题/列表的层级也全丢了，而模型正好要靠这些判断语气。
  ///
  /// **润色不用这个** —— 它要的是 [composeUserPlainText]（把引用排除在外）。
  String composePlainText() {
    final delta = _quill.document.toDelta().toJson();
    final html = DeltaToEmailHtml.convert(delta);
    return PlainText.fromHtml(html);
  }

  /// 正文的纯文本，**只含用户自己写的那部分**（引用区整段排除）—— 润色用。
  ///
  /// 边界与切法都在 [ComposeQuote] 里（引用区的行尾带 `mail-quote` 标记）。
  /// 没有引用时它与 [composePlainText] 结果一致。
  String composeUserPlainText() =>
      ComposeQuote.plainText(_quill.document.toDelta().toJson());

  /// ③ 行内续写的一次请求。
  ///
  /// 发出去的是**整封邮件（含引用）+ 光标标记**（`InlineContinuation.build`），
  /// 不再只是光标前面那一段 —— 模型因此看得见光标后面还有什么、以及对方发来
  /// 的原信。超长时的那条剪裁规则（**先剪引用**）也在 `build` 里。
  AiRun? _startContinuation(AiSettings settings) {
    if (!settings.inlineContinuationEnabled) return null;
    final input = InlineContinuation.build(_quill);
    if (input.marked.replaceAll(InlineContinuation.marker, '').trim().isEmpty) {
      return null;
    }
    return ComposeAi.startContinuation(
      ref.read(aiServiceProvider),
      context: input.marked,
      subject: _subject.text,
    );
  }

  /// 起一次生成 → 一个 `AiRun`。
  ///
  /// `startXxx` 返回的是 `Future<AiStart>`（它要先读 prefs 再读钥匙串），
  /// 而面板要的是一到手就能显示的 `AiRun` —— `ComposeAi` 里那个私有的
  /// `_adopt` 就是干这个的（Task D17），所以这里走它的公开包装。
  AiRun _adopt(Future<AiStart> pending) => ComposeAi.pendingRun(pending);
}

/// 发送前本地校验攒下来的问题，**一次全列出来**。
class _Problems extends StatelessWidget {
  const _Problems({required this.problems, required this.onDismiss});

  final List<String> problems;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final problem in problems)
                  Text(
                    problem,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: scheme.onErrorContainer,
            tooltip: AppLocalizations.of(context).cancel,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// 底部：配额 + 「为什么现在不能发」。
class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.l10n});

  final ComposeState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = state.sendDisabledReason;
    final quota = _quotaLabel();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: <Widget>[
          if (disabled != null)
            Expanded(
              child: Text(
                disabled,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            )
          else
            Expanded(
              child: Text(
                quota,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          // 服务端不支持 cc/bcc（约束 13），与其做一个点了没反应的「抄送」，
          // 不如把这件事说清楚。
          if (state.quota.known && state.quota.internalOnly)
            Tooltip(
              message: l10n.composeInternalOnlyHint,
              child: Icon(
                Icons.info_outline,
                size: 16,
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
    );
  }

  /// 配额一行字。**探测不到就什么都不显示** —— 猜一个「不限量」比不显示更糟。
  String _quotaLabel() {
    final quota = state.quota;
    if (!quota.known) return '';
    if (!quota.allowed) return l10n.composeQuotaBanned;
    if (quota.internalOnly) return l10n.composeQuotaInternal;
    if (quota.unlimited) return l10n.composeQuotaUnlimited;
    return quota.isDay
        ? l10n.composeQuotaDay(quota.used, quota.limit)
        : l10n.composeQuotaTotal(quota.used, quota.limit);
  }
}

/// 点正文里的一张图之后弹的那个小菜单（`_onImageTap` 用）。
///
/// **只说「点了哪一档」，不碰 controller**：这一层 `pop` 的是一个动作名字符串，
/// 落地由 `_onImageTap` 做。面板自己拿不到「现在还是不是那张图」的校验结果
/// （菜单弹着的时候文档还能变），把动作与生效对象分开，就不会出现「面板里
/// 抓了一个偏移、落地时已经过期」。
///
/// 对齐那三档的字面量与 `compose_toolbar.dart` 上那三个按钮**逐字相同**
/// （`'左对齐'` / `'居中'` / `'右对齐'`）—— 同一件事在两个地方说成两种话，
/// 比不做 l10n 更糟。所以这里**不加 l10n key**：一是全项目现有先例就是硬编码，
/// 二是加了反而与工具栏不一致。
///
/// 整块包在 [TextFieldTapRegion] 里（spec §1.3：每个新弹层都要声明自己是
/// 输入框的点击区域）。面板盖在编辑器上，不声明的话点它会先把正文失焦，
/// 接着 `onTapOutside` 那一串跟着来。手法与 `editor_context_menu.dart`、
/// `toolbar_button.dart` 一致。
class _ImageActionsSheet extends StatelessWidget {
  const _ImageActionsSheet();

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                dense: true,
                leading: const Icon(Icons.format_align_left),
                title: const Text('左对齐'),
                onTap: () => Navigator.of(context).pop('left'),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.format_align_center),
                title: const Text('居中'),
                onTap: () => Navigator.of(context).pop('center'),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.format_align_right),
                title: const Text('右对齐'),
                onTap: () => Navigator.of(context).pop('right'),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.image_outlined),
                title: const Text('换图…'),
                onTap: () => Navigator.of(context).pop('replace'),
              ),
            ],
          ),
        ),
      );
}
