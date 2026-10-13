import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;

/// 链接的**输入规范化与落地**。
///
/// 抽成纯逻辑（除 `apply` / `clear` 这两个必须碰 controller 的）是为了能单测：
/// 「用户敲了 `javascript:alert(1)`」这种输入不该靠手点去验。
///
/// ## 与守卫区的关系（**不要**把这两件事合并）
///
/// 真正的裁决有三道，都在 `lib/features/compose/html/**` 里，本文件一律不动：
/// - `email_html_sanitizer.dart` 的 `_allowedLinkSchemes`（白名单，权威）；
/// - `mail_html_to_delta.dart` 的 `_isDangerousLink`（导入端黑名单兜底）；
/// - `delta_to_email_html.dart` 的 `_isDangerousLink`（导出端黑名单兜底）。
///
/// 这里做的是**另一件事**：在用户输入的那一刻就拦住注定会被丢掉的地址，
/// 免得他填完才发现链接没生效。判据比那三道**更严**（白名单而不是黑名单），
/// 所以「UI 放行」不可能让不该出去的东西出去 —— 最坏情况是 UI 多拦了一个
/// 合法地址（比如 `#anchor`），而不是漏放一个危险地址。
abstract final class LinkInsert {
  const LinkInsert._();

  /// 输入框里敲的东西 → 可以写进文档的 URL；认不出来返回 null。
  ///
  /// 三条规则：
  /// 1. 空 → null（调用方把它当「用户没填」处理，与「移除链接」区分开）；
  /// 2. 没有已知 scheme → 补 `https://`（`//host/x` 这种协议相对地址补
  ///    `https:`，见下面的注释）。用户敲 `example.com` 是压倒性多数，逼他
  ///    打全 `https://` 只是白费事；
  /// 3. 只放行 http / https / mailto / tel —— 与 `EmailHtmlSanitizer` 的
  ///    白名单取交集（那里的 `cid:` 是服务端内嵌图用的，用户手输没有意义，
  ///    所以这里不给）。
  ///
  /// 前导/内嵌空白**一律删掉**再判：`java\nscript:alert(1)` 这类「用换行绕
  /// 黑名单」的手法在邮件 HTML 里是真实存在的（sanitizer 的
  /// `_cleanUrlForStorage` 也做同一件事），两边判据必须一致。
  static String? normalize(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final collapsed = trimmed.replaceAll(RegExp(r'[\s\u0000-\u001F\u007F]'), '');
    if (collapsed.isEmpty) return null;

    final withScheme = _hasScheme(collapsed)
        ? collapsed
        // `//example.com/x`（协议相对）当作没 scheme。这里必须补 `https:`
        // 而不是 `https://` —— 地址本身已经带了两条斜杠，补三条斜杠会得到
        // `https:////example.com/x` 这种明知无效却看起来「差不多对」的东西。
        : collapsed.startsWith('//')
            ? 'https:$collapsed'
            : 'https://$collapsed';
    if (!_isAllowed(withScheme)) return null;
    return withScheme;
  }

  /// 这个地址是不是危险/不支持的（用于给用户提示）。
  static bool isRejected(String input) => normalize(input) == null;

  /// 像 `example.com/a:b` 这种「冒号在路径里」的输入不该被当成有 scheme，
  /// 否则会被判成不认识的 scheme 而拒掉。判据是「第一个冒号之前没有 `/`」。
  static bool _hasScheme(String value) {
    final colon = value.indexOf(':');
    if (colon <= 0) return false;
    final slash = value.indexOf('/');
    return slash < 0 || slash > colon;
  }

  static bool _isAllowed(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('tel:');
  }

  /// 给 [selection] 挂上链接。选区折叠时先把 [url] 当文字插进去。
  ///
  /// [selection] 由调用方传进来，**不从 controller 现读**：弹输入框会让编辑器
  /// 失焦，而失焦会把选区收敛掉 —— 现读拿到的是一个空选区。调用方在弹框
  /// **之前**把选区记下来，这里只负责落地。
  ///
  /// 选区在弹框期间可能已经被别的东西改掉（用户点了别处又点回来），所以落地
  /// 前把范围夹回文档长度内；长度对不上就按「插到起点」处理，绝不硬塞一个
  /// 会错位的范围（错位的 `formatSelection` 会把链接挂到隔壁几个字上）。
  static void apply(q.QuillController controller, TextSelection selection, String url) {
    final docLength = controller.document.length;
    final maxOffset = docLength - 1;
    final hasRange = selection.isValid && !selection.isCollapsed;
    var start = selection.isValid ? selection.start : maxOffset;
    var length = hasRange ? selection.end - selection.start : 0;

    start = start.clamp(0, maxOffset < 0 ? 0 : maxOffset);
    if (length <= 0) {
      // 没选中任何东西：把地址本身作为链接文字插进去（用户要的就是一个
      // 可点的地址），再给这段文字挂属性。
      controller.replaceText(
        start,
        0,
        url,
        TextSelection.collapsed(offset: start + url.length),
      );
      length = url.length;
    }
    length = length.clamp(0, controller.document.length - start);
    if (length <= 0) return;
    // `formatSelection` 作用在 controller **当前的**选区上（它不接受范围参数），
    // 所以先把选区摆回弹窗之前记下来的那一段，再格式化。
    controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: start + length),
      q.ChangeSource.local,
    );
    controller.formatSelection(q.LinkAttribute(url));
  }

  /// 去掉选区上的链接（文字留着）。
  static void clear(q.QuillController controller, TextSelection selection) {
    if (!selection.isValid || selection.isCollapsed) return;
    controller.updateSelection(selection, q.ChangeSource.local);
    controller.formatSelection(q.Attribute.clone(q.Attribute.link, null));
  }
}
