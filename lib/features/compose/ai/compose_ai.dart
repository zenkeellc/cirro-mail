import 'dart:async';

import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../../ai/ai_prompts.dart';
import '../../ai/ai_run.dart';
import '../../ai/ai_service.dart';
import '../../ai/rewrite_selection.dart';
import 'ai_draft_sheet.dart';
import 'ai_rewrite_sheet.dart';

/// [ComposeAi.applyRewrite] 的结局。**四种「没改成」各有各的原因**，调用方
/// 必须能区分 —— 尤其是「被系统拒绝」要提示、「用户自己丢弃」不该提示。
///
/// 取值刻意分成五类（而不是一个 bool）：这是「静默失败」类缺陷的修法 ——
/// 只要结局还能被压成一个 bool，将来就一定会有调用方把「含图片被拒」当成
/// 「用户不采纳」而不给任何提示。
enum RewriteApplyResult {
  /// 文档真的改了。
  applied,

  /// 用户主动选了「丢弃」。**不是错误，不要提示**。
  discarded,

  /// 选区里含块级嵌入（图片等）被拒。**必须提示用户**（改写是纯文本，
  /// 插回去会静默删图）。
  selectionHasEmbed,

  /// 选区已经不在了 / 折叠（用户在面板开着时点了别处）被拒。**必须提示**。
  selectionGone,

  /// 模型返回的内容规范化后是空的，不动文档。不是「失败」也不是「成功」。
  emptyResult,
}

/// 把「界面上的四个面板」与「`AiService` 的四项能力」接起来的那一层。
///
/// **为什么单独一层**：面板只认 `AiRun`（不认识 `AiService`、不认识编辑器），
/// `AiService` 只认纯参数（不认识 widget）。中间这段转化有两处容易写错：
/// 「异步读 Key 的几十毫秒里界面该画什么」与「拿到结果之后怎么落到文档上」。
/// 把它们收在一个地方，两个方向都能单测 —— 不用起 widget 树。
abstract final class ComposeAi {
  const ComposeAi._();

  /// 起一次「改写」。
  ///
  /// `AiRun.pending()` 先顶上：`AiService` 要先读 prefs 再读钥匙串，这几十
  /// 毫秒里用户的界面不能是死的（点了没反应）。拿到 `AiStart` 之后 `adopt`，
  /// 转圈从点下去那一刻就算起。
  static AiRun startRewrite(
    AiService service, {
    required String selection,
    required RewriteTone tone,
    String? extraInstruction,
  }) =>
      _adopt(
        service.rewrite(
          selection: selection,
          tone: tone,
          extraInstruction: extraInstruction,
        ),
      );

  /// 起一次「要点成文」。
  ///
  /// `useSubject` 为 false 时传 `null` 而不是空主题：`AiPrompts.draft` 对
  /// 两者表现一样（都走 `isEmpty` 分支），但 `null` 更明确地表达「这次没有
  /// 主题可给」，也不会把上游传进来的空串当成一个真实主题。
  static AiRun startDraft(AiService service, DraftRequest request, {String? subject}) =>
      _adopt(
        service.draft(
          points: request.points,
          tone: request.tone,
          length: request.length,
          subject: request.useSubject ? subject : null,
        ),
      );

  /// 起一次「起标题」。只要一个标题（`AiPrompts.subject`），[current] 是主题
  /// 栏里已有的字，有就带上当参考 —— 生成完由调用方用
  /// `AiPrompts.subjectLineIn` 抠出那一行直接填进主题栏。
  static AiRun startSubject(AiService service,
          {required String body, String? current}) =>
      _adopt(service.subject(body: body, current: current));

  /// ⑤ 起一次回复建议。拿来信正文当输入，产出 2–3 条回复**开头**（不是
  /// 整封信）。候选的抠取（`AiPrompts.replyCandidates`）由面板在生成结束时
  /// 自己做 —— 这里与 `startSubject` 同一套「先给 pending，拿到之后 adopt」。
  static AiRun startReply(AiService service,
          {required String incoming, int count = 3}) =>
      _adopt(service.replySuggestions(incoming: incoming, count: count));

  static AiRun startReview(
    AiService service, {
    required String subject,
    required String body,
    required int attachmentCount,
  }) =>
      _adopt(
        service.review(
          subject: subject,
          body: body,
          attachmentCount: attachmentCount,
        ),
      );

  static AiRun startContinuation(
    AiService service, {
    required String context,
    String? subject,
  }) =>
      _adopt(service.continuation(context: context, subject: subject));

  /// 起一次生成：立刻给一个「正在跑」的 `AiRun`，等底座就绪之后接管。
  ///
  /// 公开是因为面板之外的三个入口（斜杠菜单、工具栏、Page 的标题按钮）
  /// 也要它 —— 它们与面板拿到的必须是**同一种** run，否则「停止」按钮
  /// 在一边管用、在另一边不管用。
  static AiRun pendingRun(Future<AiStart> pending) => _adopt(pending);

  /// 「先给一个 pending，拿到之后 adopt」这套动作只写一遍。
  ///
  /// `onError` 不能省：`AiService` 的失败已经通过流冒出来，但 **它自己** 抛的
  /// （比如 pref 读崩了）也得有个去处 —— 不然就是一个永远不动的转圈。
  static AiRun _adopt(Future<AiStart> pending) {
    final run = AiRun.pending();
    unawaited(pending.then(run.adopt, onError: (Object e) {
      run.adopt(AiNotStarted(AiRun.describeError(e)));
    }));
    return run;
  }

  /// 把改写面板带回来的选择落到文档上，并把**结局**原样回给调用方。
  ///
  /// 以前这里返回一个 `bool`，把四种**完全不同**的结局压成两个值：用户主动
  /// 丢弃、选区含嵌入被拒、选区已经不在了被拒 —— 调用方分不出来，于是
  /// 「选区里含图片，没法改写」这件必须让用户知道的事**没有任何人提示**，
  /// 用户点了替换、什么都没发生、也没有一句解释。返回枚举就是为了让调用方
  /// 能区分：见 [RewriteApplyResult]。
  ///
  /// **调用方（Task E5 的 compose_screen）该怎么用**：
  /// - [RewriteApplyResult.applied] → 正常，不用提示；
  /// - [RewriteApplyResult.discarded] → 用户自己选的不采纳，**不要提示**；
  /// - [RewriteApplyResult.selectionHasEmbed] → **必须提示**，例如
  ///   「选区里含图片，无法改写」；
  /// - [RewriteApplyResult.selectionGone] → **必须提示**，例如
  ///   「原来的选区已经不在了，请重新选中要改写的文字」；
  /// - [RewriteApplyResult.emptyResult] → 可提示可不提示（模型返空），至少
  ///   沉默比一句错误提示好，但**不能**当成成功。
  ///
  /// 所有非 `applied` 的结局都保证**文档逐字节不变**。
  static RewriteApplyResult applyRewrite(
    q.QuillController controller,
    RewriteOutcome outcome,
  ) {
    if (outcome.action == RewriteAction.discard) {
      return RewriteApplyResult.discarded;
    }
    final text = RewriteSelection.normalize(outcome.text);
    if (text.isEmpty) return RewriteApplyResult.emptyResult;
    switch (outcome.action) {
      case RewriteAction.discard:
        // 已在上面提前返回；这行只为穷尽 switch（无 default，将来新增
        // RewriteAction 时编译器会强制在这里处理）。
        return RewriteApplyResult.discarded;
      case RewriteAction.replace:
        // 落地前先问「会不会被拒、为什么」—— 这样界面能预先知道结局，
        // 且判据与真正的 [RewriteSelection.replaceSelection] 是同一套。
        final why = RewriteSelection.replaceability(controller);
        if (why == SelectionReplaceability.hasEmbed) {
          return RewriteApplyResult.selectionHasEmbed;
        }
        if (why != SelectionReplaceability.ok) {
          return RewriteApplyResult.selectionGone;
        }
        return RewriteSelection.replaceSelection(controller, text)
            ? RewriteApplyResult.applied
            : RewriteApplyResult.selectionGone;
      case RewriteAction.insertBelow:
        return RewriteSelection.insertBelow(controller, text)
            ? RewriteApplyResult.applied
            : RewriteApplyResult.selectionGone;
    }
  }

  /// 把 AI 起草的整封正文**换掉**正文区。
  ///
  /// 用「替换全部」而不是「插到光标处」：用户是从「这里什么都没有」的状态
  /// 点进来的，插到中间多半不是他要的。走 `replaceText` 于是能一次撤销。
  static bool applyDraft(q.QuillController controller, String text) {
    final body = RewriteSelection.normalize(text);
    if (body.isEmpty) return false;
    final length = controller.document.length;
    controller.replaceText(
      0,
      length - 1,
      body,
      TextSelection.collapsed(offset: body.length),
    );
    return true;
  }

  /// 把 AI 起草的正文**插到光标后面**（不是替换）—— 用户已经在写的时候，
  /// 起草面板是「帮我往下写」，不是「把我写的全部删掉」。
  static bool insertDraft(q.QuillController controller, String text) {
    final body = RewriteSelection.normalize(text);
    if (body.isEmpty) return false;
    final at = controller.selection.isValid
        ? controller.selection.extentOffset
        : controller.document.length - 1;
    controller.replaceText(
      at,
      0,
      body,
      TextSelection.collapsed(offset: at + body.length),
    );
    return true;
  }
}
