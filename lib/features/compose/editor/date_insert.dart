import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// 按界面语言格式化一个日期（默认今天）。
///
/// ## 两个必须知道的坑
///
/// 1. **`DateFormat` 的本地化数据必须先初始化**，否则**任何** locale
///    （包括 `en`）都会 `throw LocaleDataException`（探针实测：`en` 与 `zh`
///    在裸测试进程里都抛）。真 widget 树里是安全的 ——
///    `AppLocalizations.localizationsDelegates` 里那个
///    `GlobalMaterialLocalizations.delegate`，它的 `load` 会调
///    `loadDateIntlDataIfNotLoaded()`（`material_localizations.dart:735`），
///    把 **generated** 的那份 CLDR 表装进 intl。
///
///    **触发条件要写准**：光秃秃的 `MaterialApp(home: …)`（不带 delegates）
///    在**中文环境**下这里会炸 —— 但这个「中文环境」要靠
///    `supportedLocales` 里真的有 `zh`。只写 `locale: Locale('zh')` 而
///    `supportedLocales` 没列它的话，`Localizations.localeOf` 会**静默回退
///    到 `en_US`**（实测），而 `en` 在 intl 的默认表里有数据，于是**不炸、
///    给的是英文格式** —— 看起来「警告是假的」。写测试时 `pumpWidget` 的
///    那棵树必须**同时**带上 delegates 与 `supportedLocales`。
/// 2. **`toLanguageTag()` 给的是 `zh` / `en`（语言码），不是 `zh-Hans`。**
///    实测：`AppLocalizations.supportedLocales` 只有 `Locale('en')` /
///    `Locale('zh')`（`app_localizations.dart:96`），
///    `Localizations.localeOf(context)` 于是返回 `Locale('zh')`，
///    `toLanguageTag()` → `'zh'`。`DateFormat` 对这两个都能出对的结果，
///    所以照原样传即可 —— 但**别在注释里写它会给出 `zh-Hans`**，
///    那是错的（写测试时同理，见 Step 2 的说明）。
String formatDateForLocale(BuildContext context, {DateTime? now}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final date = now ?? DateTime.now();
  return DateFormat.yMMMMd(locale).format(date);
}
