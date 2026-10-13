import 'package:flutter/material.dart';

import '../../../core/storage/local_file.dart';
import '../../../core/util/attachment_mime.dart';
import '../../../l10n/app_localizations.dart';
import '../../mail_detail/html_body_view.dart';
import '../codecs/markdown_doc.dart';
import '../codecs/text_codec.dart';

/// 文本 / 日志 / 代码 / Markdown 附件的预览。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 为什么不用 `SelectableText`
///
/// 一屏之外的每一行都是白建的：`SelectableText` 内部是 `EditableText`，每建一个
/// 都要造 `TextEditingController`、注册手势、再算一次选区几何。实测同是
/// 4000 行、800×600 视口：`ListView.builder` 里放 `Text` 是 266ms，
/// 放 `SelectableText` 是「每行一个控制器」的量级（同一台机器上单行
/// `SelectableText` 就 351ms，且随行数线性增长）。
///
/// 而**跨行选中**这个真正要的能力来自 `SelectionArea`，与用不用 `SelectableText`
/// 无关：它把 `SelectionContainer(registrar: …)` 放在子树外面，`Scrollable`
/// 因此装上 `_ScrollableSelectionHandler`，于是有了拖到边缘自动滚、滚出已建
/// 范围的选区不被回收。正文页用同一套（见 `mail_detail_screen.dart` 的
/// `_body`）。
///
/// 行号栏**不做**：每一行会多一个 `Text`，更麻烦的是用户选中一大段时会把
/// 行号一起复制走 —— 而那正是看日志的人最不想要的东西。
class TextViewerScreen extends StatefulWidget {
  const TextViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.kind = AttachmentKind.text,
  });

  final String path;
  final String? title;

  /// 只用来判断要不要给 Markdown 的「排版 / 源码」开关。
  final AttachmentKind kind;

  @override
  State<TextViewerScreen> createState() => _TextViewerScreenState();
}

class _TextViewerScreenState extends State<TextViewerScreen> {
  DecodedText? _decoded;
  String? _error;

  /// Markdown 渲染后的 HTML；**null 表示渲染不了**（守卫拦下或本来就不是 md）。
  String? _renderedHtml;

  /// 用户是否选了「看源码」。Markdown 默认看排版。
  bool _showSource = false;

  bool get _isMarkdown => widget.kind == AttachmentKind.markdown;

  @override
  void initState() {
    super.initState();
    // 让第一帧先画出来，再开始读。
    //
    // 这条链路上全是**同步**调用（`readBytes` 是 `openSync`/`readSync`，
    // `decodeText` 与 markdown 解析也都是纯计算），直接在 `initState` 里做会把
    // 首帧一起卡住 —— 用户点开附件看到的是「界面半天才动」。代价还是有界的：
    // 读盘按 `kTextProbeBytes`（800KB）封顶，解码也是这个量级。
    //
    // **必须用一个宏任务（`Future.microtask` 不够）**：microtask 会在当前帧
    // 结束前就排到队列头跑掉，等于什么都没推迟。这里排一个 timer，
    // `addPostFrameCallback` 里排的 `Future` 就是这样一个宏任务。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 这里排的是个**宏任务**（timer）；`Future.microtask` 不够 —— microtask
      // 会在当前帧结束前就排到队列头跑掉，等于什么都没推迟。
      Future<void>(_load);
    });
  }

  Future<void> _load() async {
    // 只读前缀：文本预览从来不看后面（见 `kTextProbeBytes`）。
    final bytes = LocalFile.readBytes(
      widget.path,
      limitBytes: kTextProbeBytes,
    );
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _error = 'unreadable');
      return;
    }

    final decoded = decodeText(bytes);
    // Markdown 只在**确实要看排版**时才解析；`toHtml` 内部还有一道深度守卫，
    // 拦住那种「几十 KB 就能让解析器跑 20 秒」的嵌套（见 `MarkdownDoc`）。
    final html = _isMarkdown ? MarkdownDoc.toHtml(decoded.text) : null;

    if (!mounted) return;
    setState(() {
      _decoded = decoded;
      _renderedHtml = html;
      _showSource = _isMarkdown && html == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final decoded = _decoded;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          if (_isMarkdown && _renderedHtml != null)
            TextButton.icon(
              onPressed: () => setState(() => _showSource = !_showSource),
              icon: Icon(
                _showSource ? Icons.article_outlined : Icons.code,
                size: 18,
              ),
              label: Text(_showSource ? l10n.viewerRendered : l10n.viewerSource),
            ),
        ],
      ),
      body: _error != null
          ? _Message(icon: Icons.error_outline, text: l10n.viewerFileGone)
          : decoded == null
              ? const Center(child: CircularProgressIndicator())
              : _content(decoded, l10n),
    );
  }

  Widget _content(DecodedText decoded, AppLocalizations l10n) {
    final html = _renderedHtml;
    if (!_showSource && html != null) {
      // 复用正文渲染（`HtmlBodyView` 会再过一遍 `sanitizeEmailHtml`）。
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: HtmlBodyView(html: html, ossBase: '', shrinkWrap: true),
      );
    }

    final lines = _splitLines(decoded.text);
    return Column(
      children: <Widget>[
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: lines.length,
              itemBuilder: (_, index) => _Line(lines[index]),
            ),
          ),
        ),
        _Footer(
          notes: <String>[
            if (_isMarkdown && html == null && decoded.text.trim().isNotEmpty)
              l10n.viewerMarkdownTooDeep,
            if (decoded.isLossy) l10n.viewerEncodingLossy(decoded.encoding),
            if (decoded.truncated)
              l10n.viewerTruncated(kTextPreviewMaxChars),
          ],
        ),
      ],
    );
  }

  /// 按行切，**并且把超长的行再切开**。
  ///
  /// 一个 200KB 的日志文件如果只有一行（压缩过的 JSON、base64），切完还是一行，
  /// 那一行就得由**一个** `Text` 排版 20 万个字符 —— 实测 1.2 秒。切成
  /// 2000 字符一段后是 100 个 `Text`，10ms，而且 `ListView` 让它们逐屏建。
  ///
  /// 段与段之间**不插换行**：这是同一行的延续，插了就等于篡改内容。
  ///
  /// 结尾那一个换行不算一行：`a\nb\n` 是两行（编辑器也是这么数的）。不去掉的话
  /// 每个正常结尾的文件底下都会多出一条空行。
  static List<String> _splitLines(String text) {
    if (text.isEmpty) return const <String>[''];
    var body = text;
    if (body.endsWith('\n')) body = body.substring(0, body.length - 1);

    final out = <String>[];
    for (final line in body.split('\n')) {
      if (line.length <= _maxChunk) {
        out.add(line);
        continue;
      }
      for (var i = 0; i < line.length; i += _maxChunk) {
        out.add(line.substring(i, (i + _maxChunk).clamp(0, line.length)));
      }
    }
    return out;
  }

  static const int _maxChunk = 2000;
}

/// 一行等宽文本。
///
/// 用 `Text` 而不是 `SelectableText`：选中由外层 `SelectionArea` 统一负责
/// （见 [TextViewerScreen] 的类注释）。
class _Line extends StatelessWidget {
  const _Line(this.text);

  final String text;

  static const TextStyle _style = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    height: 1.45,
  );

  @override
  Widget build(BuildContext context) {
    // 空行也要占一行的高度 —— 否则段落之间会挤在一起，看不出原文的换行。
    if (text.isEmpty) return const SizedBox(height: 13 * 1.45);
    return Text(text, style: _style, softWrap: true);
  }
}

/// 底部那一条说明。没有任何一条时不占位置。
class _Footer extends StatelessWidget {
  const _Footer({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        notes.join(' · '),
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 48),
          const SizedBox(height: 16),
          Text(text),
        ],
      ),
    );
  }
}
