import 'ai_settings.dart';

/// 发送前检查的一条发现。**只有级别与文案**，不改正文 —— spec §4.3④ 明确
/// 「给出建议，用户可以仍然发送」。
class PreflightFinding {
  const PreflightFinding({
    required this.severity,
    required this.message,
    this.local = true,
  });

  final PreflightSeverity severity;
  final String message;

  /// true = 纯本地规则命中（零成本）；false = 模型给出的建议。
  final bool local;
}

enum PreflightSeverity { info, warning }

/// 发送前检查。
///
/// **一次调用都不发**：这里只做本地规则。模型那一半（语气、错别字）走
/// `AiPreflightService` 的异步版本，是可选增强 —— 于是即使用户没配 Key，
/// 最有价值的那条检查（声明了附件却没有附件）照样生效。
abstract final class AiPreflight {
  const AiPreflight._();

  /// 附件词表。中英各一组 —— 命中率不高没关系，**误报才是代价**，
  /// 所以只认**明确的说法**，不做「包含『附』字」这种模糊匹配。
  ///
  /// 两处刻意的细节：
  /// - 中文短词干 `见附/随附/已附` 后面跟 `近`（「随附近的车」）或 `言`
  ///   （「已附言如下」）时**不算**提到附件 —— 那两个是「附近」「附言」，
  ///   与附件无关。原实现当裸子串匹配，正是这个文件承诺「不做」的模糊匹配。
  /// - 英文用 `\b` 词边界 + **词根**（`attach` 覆盖 attach/attached/
  ///   attachment/attaching），而不是把 `ed`/`ing` 写死：写死就会漏掉
  ///   `attaching` 这类变形。`encl.`/`enc.` 这类缩写要带点号才算，避免
  ///   「encode」「encounter」误命中。
  ///
  /// **取向**：误报的代价（用户从此不信这个提示）比漏报高，拿不准就不报。
  /// 唯一的例外是正文里正面写「不用带附件」这种 —— 它确实出现了「附件」，
  /// 保留是**计划接受**的行为（见测试）。
  static final RegExp _attachmentMention = RegExp(
    r'附件|附上|另附|附表|附图|附文件'
    r'|见附(?!近|言)|随附(?!近|言)|已附(?!近|言)'
    r'|\battach|\benclos|\bencl\.|\benc\.',
    caseSensitive: false,
  );

  /// 本地规则。输入是**已去格式的正文纯文本**、主题、以及当前附件数。
  static List<PreflightFinding> checkLocal({
    required String subject,
    required String bodyText,
    required int attachmentCount,
    required int inlineImageCount,
  }) {
    final findings = <PreflightFinding>[];

    if (subject.trim().isEmpty) {
      findings.add(const PreflightFinding(
        severity: PreflightSeverity.warning,
        message: '主题是空的',
      ));
    }

    final mentionsAttachment = _attachmentMention.hasMatch(bodyText);
    if (mentionsAttachment && attachmentCount == 0) {
      // 内联图不算「附件」—— 它已经在正文里看得见了，这正是用户要的效果。
      findings.add(const PreflightFinding(
        severity: PreflightSeverity.warning,
        message: '正文里提到了附件，但这一封没有附件',
      ));
    }

    if (bodyText.trim().isEmpty) {
      findings.add(const PreflightFinding(
        severity: PreflightSeverity.warning,
        message: '正文是空的',
      ));
    }

    return findings;
  }

  /// 需不需要向用户展示「发送前检查已开启」。设置里关掉就整个不跑。
  static bool shouldRun(AiSettings settings) => settings.preflightEnabled;
}
