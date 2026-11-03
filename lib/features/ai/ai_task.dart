import 'package:cirro_mail_ext/cirro_mail_ext.dart';

import 'ai_prompts.dart';

/// 七项 AI 能力与**托管通道协议**之间的翻译层：能力参数 → [AiCall]。
///
/// BYOK 那条路走的是 `AiPrompts`（客户端自己拼 prompt、自己发请求）；托管通道
/// 那条路走这里 —— 只把「要做什么」翻成稳定的 task id + input map，交给
/// `AppExtension.aiTransport` 的实现方。两条路**共用同一个 `AiService`** 与同一
/// 套 UI 状态机，所以这里的字段名、码值、截断长度必须与网关 Schema 逐字一致
/// （设计稿 §3.4）。
///
/// ## 三条硬规矩
///
/// 1. **字段名是协议，不是变量名。** `extraInstruction`、`actionIds` 这些
///    名字直接对应服务端 Schema，改一个字母就是 400；测试里用 JSON 快照钉住。
/// 2. **枚举翻成稳定字符串码，不翻成给人看的文案。** 界面上是「润色」「更
///    正式」，协议里是 `polish` / `formal` —— 文案会改，协议不能改。加枚举值
///    时两处同时加（这里的 `switch` 是穷尽的，漏一边直接编译不过）。
/// 3. **客户端先截断。** 超长由服务端 400 `input_too_large` 硬拦，但用户看到
///    的是「这次内容太长」这种无从下手的错误；先在客户端截到上限，体验上就是
///    「按能处理的部分处理」。截断长度与 §3.4 的表一一对应。
///
/// ## 不在这里做的事
///
/// - **不拼 prompt**：那是服务端模板的事（`AiPrompts` 只管 BYOK 那条路）。
/// - **不校验 actionIds 白名单**：池子由调用方（`suggestActionPool`）按当前
///   邮件状态过滤好再传进来，这里只做长度保险（§3.4 的「≤12 项」）。
/// - **不碰网络/设置**：纯函数，于是七个 map 可以离线快照。
abstract final class AiTask {
  const AiTask._();

  // task id（稳定码，与服务端 §3.4 的表逐字一致）。
  static const String _rewrite = 'rewrite';
  static const String _draft = 'draft';
  static const String _continuation = 'continuation';
  static const String _subject = 'subject';
  static const String _review = 'review';
  static const String _replySuggestions = 'reply_suggestions';
  static const String _suggest = 'suggest';

  // 字数上限（§3.4）。服务端也拦；这里是「先截断而不是报错」的那一半。
  static const int selectionLimit = 8000;
  static const int extraInstructionLimit = 200;
  static const int pointsLimit = 4000;
  static const int contextLimit = 6000;
  static const int bodyLimit = 8000;
  static const int currentLimit = 200;
  static const int incomingLimit = 8000;

  /// `actionIds` 的项数上限（§3.4「≤12 项」）。
  static const int actionIdsLimit = 12;

  /// 回复建议的条数范围（§3.4「1–5」）。
  static const int replyCountMin = 1;
  static const int replyCountMax = 5;

  /// ① 选中即改（也是「整篇润色」走的那一条 —— 选区等于全文）。
  static AiCall rewrite({
    required String selection,
    required RewriteTone tone,
    String? extraInstruction,
  }) {
    final extra = _optional(extraInstruction);
    return AiCall(
      task: _rewrite,
      input: <String, Object?>{
        'selection': _truncate(selection, selectionLimit),
        'tone': tone.code,
        if (extra != null)
          'extraInstruction': _truncate(extra, extraInstructionLimit),
      },
    );
  }

  /// ② 要点成文。
  static AiCall draft({
    required String points,
    required RewriteTone tone,
    required DraftLength length,
    String? subject,
    String? recipient,
  }) {
    final trimmedSubject = _optional(subject);
    final trimmedRecipient = _optional(recipient);
    return AiCall(
      task: _draft,
      input: <String, Object?>{
        'points': _truncate(points, pointsLimit),
        'tone': tone.code,
        'length': length.code,
        // §3.4 没给 subject / recipient 的上限，这里**不截断**（只去首尾空白、
        // 空串就不带这个字段）—— 自己编一个上限，等于替服务端改协议。
        'subject': ?trimmedSubject,
        'recipient': ?trimmedRecipient,
      },
    );
  }

  /// ③ 行内续写。[context] 是整封邮件（含光标标记，见 `InlineContinuation`）。
  static AiCall continuation({
    required String context,
    String? subject,
  }) {
    final trimmedSubject = _optional(subject);
    return AiCall(
      task: _continuation,
      input: <String, Object?>{
        'context': _truncate(context, contextLimit),
        'subject': ?trimmedSubject,
      },
    );
  }

  /// ④a 标题生成。[current] 是主题栏里已有的字。
  static AiCall subject({
    required String body,
    String? current,
  }) {
    final trimmedCurrent = _optional(current);
    return AiCall(
      task: _subject,
      input: <String, Object?>{
        'body': _truncate(body, bodyLimit),
        if (trimmedCurrent != null)
          'current': _truncate(trimmedCurrent, currentLimit),
      },
    );
  }

  /// ④b 发送前检查的**模型那一半**（本地那一半在 `preflight.dart`）。
  static AiCall review({
    required String subject,
    required String body,
    required int attachmentCount,
  }) =>
      AiCall(
        task: _review,
        input: <String, Object?>{
          'subject': _truncate(subject, currentLimit),
          'body': _truncate(body, bodyLimit),
          'attachmentCount': attachmentCount,
        },
      );

  /// ⑤ 回复建议。[count] 越界时**夹到 1–5**，而不是让服务端 400。
  static AiCall replySuggestions({
    required String incoming,
    int count = 3,
  }) =>
      AiCall(
        task: _replySuggestions,
        input: <String, Object?>{
          'incoming': _truncate(incoming, incomingLimit),
          'count': count.clamp(replyCountMin, replyCountMax),
        },
      );

  /// ⑥ AI 邮件建议。[actionIds] 是**已按当前状态过滤过**的池子。
  ///
  /// 超过 12 项时**只发前 12 项**：§3.4 的上限是服务端硬拦，客户端先截；
  /// 真实池子（`suggestActionPool`）最多 9 项，这条保险不会碰到。
  static AiCall suggest({
    required String input,
    required List<String> actionIds,
  }) =>
      AiCall(
        task: _suggest,
        input: <String, Object?>{
          'input': _truncate(input, incomingLimit),
          'actionIds': actionIds.take(actionIdsLimit).toList(growable: false),
        },
      );

  /// 按**字符**（Unicode 码点）截断，不拆代理对。
  ///
  /// 用 `runes` 而不是 `substring`：中文在 UTF-16 里各占一个 code unit，但
  /// emoji 是代理对 —— 按下标切会切出半个字符（界面上是一个替换符）。
  static String _truncate(String value, int max) {
    final runes = value.runes;
    if (runes.length <= max) return value;
    return String.fromCharCodes(runes.take(max));
  }

  /// 可选字段的规整：去首尾空白，空串当作「没给」。
  ///
  /// 与 `AiPrompts` 里那几处判断同一个口径（`trim().isEmpty` 即不传），于是
  /// BYOK 与托管两条路对「这个字段到底有没有」的判断一致。
  static String? _optional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// [RewriteTone] → 协议里的稳定字符串码（§3.4 的 `tone`）。
///
/// **穷尽 `switch`**：枚举加了新值而这里没加，编译就过不去 —— 「两边同时加」
/// 这条规矩靠编译器落实，不靠记性。
extension RewriteToneCode on RewriteTone {
  String get code => switch (this) {
    RewriteTone.polish => 'polish',
    RewriteTone.formal => 'formal',
    RewriteTone.friendly => 'friendly',
    RewriteTone.concise => 'concise',
    RewriteTone.translateEn => 'translateEn',
    RewriteTone.translateZh => 'translateZh',
  };
}

/// [DraftLength] → 协议里的稳定字符串码（§3.4 的 `length`）。
extension DraftLengthCode on DraftLength {
  String get code => switch (this) {
    DraftLength.short => 'short',
    DraftLength.medium => 'medium',
    DraftLength.long => 'long',
  };
}
