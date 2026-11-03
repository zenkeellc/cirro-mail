import 'package:flutter/widgets.dart' show Locale;

/// 「关于」页最末尾那个**通用推广位**的构建期配置（设计稿 §7.1）。
///
/// ## 全是构建期注入，公开仓没有值
///
/// 七个字段全部来自 `--dart-define-from-file=…/promo_defaults.json`（键名就是
/// 构造函数参数名的大写形式，见 [injected]）。公开仓库不提供那份 json，于是
/// 七个字段都是空串、[enabled] 为 false —— 关于页上**什么都不会多出来**。
/// 私有构建注入一份，卡片就出现；换活动只改 json，不用改核心代码。
///
/// **公开仓里不写任何商业文案**：标题/正文/按钮/链接都不在这里，也不进 ARB
/// —— 核心只负责「有就画、没有就什么都不画」。
///
/// ## 可见条件（两层）
///
/// 1. [enabled]：URL 是 `http` / `https` 的绝对地址。`javascript:`、相对路径、
///    空串一律视为「没注入」—— 关于页不是一个该拿来跳危险协议的地方；
/// 2. [visibleFor]：**当前 locale** 的标题、正文、按钮三样都非空。**不跨语言
///    兜底**：英文用户看不到中文卡，反之亦然（缺 EN 文案的构建在 en 下就是
///    不显示，而不是把中文摆到英文界面里）。只认 `zh` / `en`（App 只支持这两
///    种语言），其余语言的 [visibleFor] 恒为 false。
///
/// ## 为什么是常量类而不是 Provider
///
/// `--dart-define` 是**编译期**的事：值编进二进制之后不会再变，一个 `const`
/// 单例就够。测试要换配置时由调用方（`AboutSection.promo`）传入另一份实例，
/// 不必去动全局。
class PromoConfig {
  const PromoConfig({
    required this.url,
    required this.titleZh,
    required this.titleEn,
    required this.bodyZh,
    required this.bodyEn,
    required this.ctaZh,
    required this.ctaEn,
  });

  /// 构建期注入的那一份。公开仓没有注入 → 全空串 → [enabled] 为 false。
  ///
  /// **必须 `const`**：`String.fromEnvironment` 只有在常量上下文里才拿得到
  /// `--dart-define` 的值，写成运行时 `String.fromEnvironment(...)` 会静默拿到
  /// 空串。
  static const PromoConfig injected = PromoConfig(
    url: String.fromEnvironment('PROMO_URL'),
    titleZh: String.fromEnvironment('PROMO_TITLE_ZH'),
    titleEn: String.fromEnvironment('PROMO_TITLE_EN'),
    bodyZh: String.fromEnvironment('PROMO_BODY_ZH'),
    bodyEn: String.fromEnvironment('PROMO_BODY_EN'),
    ctaZh: String.fromEnvironment('PROMO_CTA_ZH'),
    ctaEn: String.fromEnvironment('PROMO_CTA_EN'),
  );

  /// 链接。由注入方带上 `?src=…` 之类的来源参数 —— 核心**不拼 query**。
  final String url;
  final String titleZh;
  final String titleEn;
  final String bodyZh;
  final String bodyEn;
  final String ctaZh;
  final String ctaEn;

  /// URL 是不是一个能交给系统浏览器打开的绝对 http(s) 地址。
  ///
  /// 只看这三样：`Uri.tryParse` 成功、scheme 是 http/https、host 非空。
  /// `javascript:` / `file:` / 相对路径都被挡在外面。
  bool get enabled => _isOpenableUrl(url);

  /// 当前语言下这张卡该不该出现（见类注释那两层条件）。
  bool visibleFor(Locale locale) =>
      enabled &&
      titleFor(locale) != null &&
      bodyFor(locale) != null &&
      ctaFor(locale) != null;

  /// 当前语言的标题；没注入 / 当前语言缺这条时是 null。
  String? titleFor(Locale locale) => _localized(locale, zh: titleZh, en: titleEn);

  /// 当前语言的正文；没注入 / 当前语言缺这条时是 null。
  String? bodyFor(Locale locale) => _localized(locale, zh: bodyZh, en: bodyEn);

  /// 当前语言的按钮文案；没注入 / 当前语言缺这条时是 null。
  String? ctaFor(Locale locale) => _localized(locale, zh: ctaZh, en: ctaEn);

  /// 只按 **语言码**选，**不跨语言兜底**。
  ///
  /// `zh` / `en` 之外的语言一律返回 null（App 的 `supportedLocales` 只有这两种，
  /// 理论上走不到；但注入方把系统语言之外的 `Locale` 交给这一层时，宁可
  /// 不显示，也不要把一门用户没选的语言摆上去）。
  static String? _localized(
    Locale locale, {
    required String zh,
    required String en,
  }) {
    final value = switch (locale.languageCode) {
      'zh' => zh,
      'en' => en,
      _ => '',
    };
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _isOpenableUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }
}
