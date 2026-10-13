// 剪贴板那组 API 在 flutter_quill 11.6 上标了 `@experimental`，而**没有别的
// 路子**能把假剪贴板塞进去（`QuillEditorConfig` 上根本没有这些口子）。
// 与 `paste_handler.dart` 顶部那条 ignore 是同一条理由。
// ignore_for_file: experimental_member_use

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_quill/internal.dart' as qi;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/paste_handler.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';

/// 假剪贴板：只放 HTML 那一个口子，其余一律 null。
class FakeClipboardService extends qi.ClipboardService {
  FakeClipboardService({this.html});

  final String? html;

  @override
  Future<String?> getHtmlText() async => html;

  @override
  Future<String?> getHtmlFile() async => null;

  @override
  Future<String?> getMarkdownFile() async => null;

  @override
  Future<Uint8List?> getImageFile() async => null;

  @override
  Future<Uint8List?> getGifFile() async => null;

  @override
  Future<void> copyImage(Uint8List imageBytes) async {}
}

/// 慢剪贴板：`getHtmlText` 会先等 [_delay] 再返回。
///
/// 用来复现「读剪贴板期间写信页被关掉」：真实实现走
/// `QuillNativeBridge.getClipboardHtml`，起步就是几十毫秒，用户在读取期间
/// 关掉页面完全够用。返回的 Future 在 delay 内是 pending 的，测试才有机会
/// 在 `await` 中间把 controller dispose 掉。
class SlowClipboardService extends FakeClipboardService {
  SlowClipboardService({super.html, required this.delay});

  final Duration delay;

  @override
  Future<String?> getHtmlText() async {
    await Future<void>.delayed(delay);
    return html;
  }
}

/// 把文档内容装成 [plain]（必须自带换行 —— 那是 Quill 的段落结尾）。
q.QuillController doc(String plain) {
  final controller = q.QuillController.basic();
  controller.document = q.Document.fromJson([
    {'insert': plain},
  ]);
  return controller;
}

void cursorAt(q.QuillController controller, int offset) => controller.updateSelection(
      TextSelection.collapsed(offset: offset),
      q.ChangeSource.local,
    );

void select(q.QuillController controller, int from, int to) =>
    controller.updateSelection(
      TextSelection(baseOffset: from, extentOffset: to),
      q.ChangeSource.local,
    );

const Map<String, dynamic> tableOp = {
  'insert': {'x-email-table': '<table><tr><td>甲</td></tr></table>'},
};

/// 文档里**含 [text] 那一行**的行级属性（行尾那个 `\n` 上的）。
///
/// 直接在文档的整份 Delta 上扫：行级属性挂在每个行尾 `\n` 上（`Document`
/// 把相邻同属性的 op 合并过，所以行尾可能和邻接文字同处一个 op，比如
/// `"段\n"`）。累加 `\n` 之前的文字、遇到 `\n` 就结算一行。没有属性的行
/// 返回 null。
Map<String, dynamic>? lineAttrsOf(q.Document document, String text) {
  final buffer = StringBuffer();
  for (final raw in document.toDelta().toJson()) {
    final op = raw as Map;
    final insert = op['insert'];
    if (insert == '\n') {
      final line = buffer.toString();
      buffer.clear();
      if (line.contains(text)) {
        return (op['attributes'] as Map?)?.cast<String, dynamic>();
      }
      continue;
    }
    if (insert is! String) continue;
    // 行尾可能和后面的文字合并在一个 op 里（`"\n后"`）。
    final at = insert.indexOf('\n');
    if (at < 0) {
      buffer.write(insert);
      continue;
    }
    final line = '$buffer${insert.substring(0, at)}';
    buffer.clear();
    if (line.contains(text)) {
      return (op['attributes'] as Map?)?.cast<String, dynamic>();
    }
    buffer.write(insert.substring(at + 1));
  }
  return null;
}

/// 每一个嵌入都**独占一行**：它前面那段内容以换行收尾，它后面紧跟的 op 以
/// 换行开头。
///
/// 这是 flutter_quill 的硬约束（`Line` 的「一行里有嵌入就不能再有文字」），
/// 破了编辑器会白屏。断言不变量本身，而不是某个具体字符串。注意 `Document`
/// 会把相邻同属性的 op 合并（嵌入后面的裸 `\n` 可能与下一段文字合成
/// `"\n后"`），所以这里用「以换行收尾 / 开头」而不是「恰好等于换行」。
void expectEmbedsIsolated(List<dynamic> json) {
  for (var i = 0; i < json.length; i++) {
    if ((json[i] as Map)['insert'] is! Map) continue;
    final before = i == 0 ? null : (json[i - 1] as Map)['insert'];
    final after = i + 1 < json.length ? (json[i + 1] as Map)['insert'] : null;
    expect(
      before == null || (before is String && before.endsWith('\n')),
      isTrue,
      reason: '嵌入前面必须以换行收尾，实际是 $before',
    );
    expect(
      after is String && after.startsWith('\n'),
      isTrue,
      reason: '嵌入后面必须紧跟一个换行，实际是 $after',
    );
  }
}

void main() {
  late q.QuillController controller;

  setUp(() {
    controller = q.QuillController.basic();
  });

  tearDown(() {
    controller.dispose();
    qi.ClipboardServiceProvider.setInstanceToDefault();
  });

  group('handleHtmlPaste', () {
    test('剪贴板没有 HTML → 返回 false（让给默认通路）', () async {
      qi.ClipboardServiceProvider.setInstance(FakeClipboardService());
      expect(await MailPasteHandler.handleHtmlPaste(controller), isFalse);
      expect(controller.document.toPlainText(), '\n');
    });

    test('剪贴板 HTML 是空白 → 返回 false，不插空段落', () async {
      qi.ClipboardServiceProvider.setInstance(FakeClipboardService(html: '   '));
      expect(await MailPasteHandler.handleHtmlPaste(controller), isFalse);
      expect(controller.document.toPlainText(), '\n');
    });

    test('有 HTML → 插入并返回 true', () async {
      qi.ClipboardServiceProvider.setInstance(
        FakeClipboardService(html: '<p>粘进来的</p>'),
      );
      expect(await MailPasteHandler.handleHtmlPaste(controller), isTrue);
      expect(controller.document.toPlainText(), contains('粘进来的'));
    });

    test('带表格的 HTML → 表格变成 x-email-table 嵌入（不会白屏）', () async {
      qi.ClipboardServiceProvider.setInstance(
        FakeClipboardService(
          html: '<p>前</p><table><tr><td>甲</td><td>乙</td></tr></table>',
        ),
      );
      expect(await MailPasteHandler.handleHtmlPaste(controller), isTrue);
      final json = controller.document.toDelta().toJson();
      // `whereType<Map>()` 依次筛掉「不是 map 的 op」与「insert 不是 map 的 op」，
      // 这样不用写 `as Map` 强转（强转在类型不符时是**抛异常**，在测试里表现为
      // 一个毫不相干的报错）。
      final inserts =
          json.whereType<Map>().map((op) => op['insert']).whereType<Map>();
      expect(inserts.any((op) => op.containsKey('x-email-table')), isTrue);
    });

    // P-1：`MailHtmlToDelta.convert` **从不返回空列表** —— 它保底返回
    // `[{"insert":"\n"}]`。所以 `ops.isEmpty` 对「清洗后什么都不剩」的剪贴板
    // 是**假**，原实现会走 insertOps 把用户的选区替换成一个空段落（数据丢失）。
    // 这组用例把七种「可解析、清洗后为空」的输入逐一钉住：它们必须让位。
    group('P-1 转换结果没有实际内容 → 让位，绝不吞掉选区', () {
      // 每种输入都真的走一遍选区替换：文档是 `AB\nCD\n`，选中 `AB`，
      // 粘贴后断言返回值与文档**逐字**不变（不是「trim 之后不变」——
      // 那会放过空段落）。
      for (final html in <String>[
        '<script>x</script>',
        '<style>p{color:red}</style>',
        '<iframe src="x"></iframe>',
        '<video src="x"></video>',
        '<svg><rect/></svg>',
        '<template><b>x</b></template>',
        '<div></div>',
      ]) {
        test('$html → 返回 false 且文档逐字不变', () async {
          final c = doc('AB\nCD\n');
          select(c, 0, 2);
          qi.ClipboardServiceProvider.setInstance(FakeClipboardService(html: html));
          final consumed = await MailPasteHandler.handleHtmlPaste(c);
          expect(consumed, isFalse);
          expect(c.document.toPlainText(), 'AB\nCD\n');
          c.dispose();
        });
      }

      test('真正有内容的 HTML（<p>甲</p>）仍然返回 true 并插进去', () async {
        final c = doc('AB\nCD\n');
        select(c, 0, 2);
        qi.ClipboardServiceProvider.setInstance(
          FakeClipboardService(html: '<p>甲</p>'),
        );
        expect(await MailPasteHandler.handleHtmlPaste(c), isTrue);
        expect(c.document.toPlainText(), contains('甲'));
        c.dispose();
      });
    });

    // P-2：剪贴板读取是异步的。读取期间用户关掉写信页会 dispose controller，
    // 读完之后 insertOps 对已销毁的 controller `replaceText`，
    // `Document.compose` 的 `assert(!documentChangeObserver.isClosed)` 会
    // 直接抛穿 `clipboardPaste` 的调用方（上游 `raw_editor_state.dart:150`）。
    // 「转换失败一律让位，绝不抛出去」这条承诺必须把**写入阶段**也包进来。
    test('P-2 读取期间 controller 被销毁 → 不抛异常，安静让位', () async {
      final c = doc('原文\n');
      qi.ClipboardServiceProvider.setInstance(
        SlowClipboardService(html: '<p>粘进来的</p>', delay: const Duration(milliseconds: 40)),
      );
      final pending = MailPasteHandler.handleHtmlPaste(c);
      // 在真正 await 之前让「读剪贴板」先挂起，再模拟用户关页。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      c.dispose();
      // 不包 try：原实现会在这里抛 Failed assertion isClosed。
      final consumed = await pending;
      expect(consumed, isFalse);
    });
  });

  group('insertOps', () {
    test('插到光标处，不是文档末尾', () {
      final c = doc('你好世界\n');
      cursorAt(c, 2);
      MailPasteHandler.insertOps(c, [
        {'insert': '插入的\n'},
      ]);
      // 落点在一行中间 → 末尾那个换行被削掉，粘贴的字接在原句里。
      expect(c.document.toPlainText(), '你好插入的世界\n');
      expect(c.document.root.children.length, 1);
    });

    test('落点在行首 → 粘贴内容自成一段', () {
      final c = doc('甲\n乙\n');
      cursorAt(c, 2);
      MailPasteHandler.insertOps(c, [
        {'insert': '新段落\n'},
      ]);
      expect(c.document.toPlainText(), '甲\n新段落\n乙\n');
      expect(c.document.root.children.length, 3);
    });

    test('选中一段文字被替换掉', () {
      final c = doc('旧内容\n');
      select(c, 0, 3);
      MailPasteHandler.insertOps(c, [
        {'insert': '新\n'},
      ]);
      // 选中的是「文字」不是「段落」：新段落进来，剩下的（空）被挤到下一行。
      expect(c.document.toPlainText(), '新\n\n');
    });

    test('空列表什么都不做', () {
      final c = doc('原文\n');
      MailPasteHandler.insertOps(c, []);
      expect(c.document.toPlainText(), '原文\n');
    });

    test('只剩一个换行的粘贴在行中 → 什么都不做', () {
      final c = doc('原文\n');
      cursorAt(c, 2);
      MailPasteHandler.insertOps(c, [
        {'insert': '\n'},
      ]);
      expect(c.document.toPlainText(), '原文\n');
    });

    test('落点在一行中间 + 内容以块嵌入开头 → 前面补换行', () {
      final c = doc('半句话\n');
      cursorAt(c, 3);
      MailPasteHandler.insertOps(c, [
        tableOp,
        {'insert': '\n'},
      ]);
      // 嵌入独占一行 —— 这是「不白屏」那条不变量。
      expect(c.document.toPlainText(), '半句话\n￼\n\n');
      expect(c.document.root.children.length, 3);
    });

    test('落点已在行首 + 块嵌入 → 不补多余换行', () {
      final c = doc('甲\n乙\n');
      cursorAt(c, 2);
      MailPasteHandler.insertOps(c, [
        tableOp,
        {'insert': '\n'},
      ]);
      expect(c.document.toPlainText(), '甲\n￼\n乙\n');
      expect(c.document.root.children.length, 3);
    });

    // P-6：原 `_fitToContext` 只处理「ops **以**嵌入开头」。嵌入落在**中间**
    // 时（`甲<img>乙`）走的是另一条分支，原样插进去 —— 得到「图片和文字同居
    // 一行」的 Delta，而 flutter_quill 的 `Line` 要求「一行里有嵌入就不能再
    // 有文字」。断言的是**文档结构**（嵌入独占一行），不是收件端的渲染效果。
    test('P-6 落点在行中 + 嵌入夹在文字中间 → 嵌入独占一行', () {
      final c = doc('前面的文字\n');
      cursorAt(c, 3);
      MailPasteHandler.insertOps(c, [
        {'insert': '甲'},
        {
          'insert': {'image': 'data:image/png;base64,AAAA'},
        },
        {'insert': '乙\n'},
      ]);
      // 光标落在原行「前面的|文字」中间：「前面的」与粘贴的「甲」续写
      // （内联，不是嵌入）；嵌入被劈到新的一行、独占；「乙」另起一行；
      // 原行剩下的「文字」被推到嵌入那行之后。关键是嵌入前后各有一个换行，
      // 不与任何文字同居一行。
      expect(c.document.toPlainText(), '前面的甲\n￼\n乙\n文字\n');
    });

    // P-6 的真实形状：用 `MailHtmlToDelta.convert` 的产物（而不是手搓的 op）
    // 走一遍。这条正是复核者复现的那份输入 —— `<p>半句甲<img>乙</p><p>话尾</p>`
    // 的 ops 是 `[甲, 图片嵌入, 乙, \n, 话尾, \n]`，嵌入夹在文字中间。
    test('P-6 真实 convert 产物：行中粘贴，行的图片嵌入独占一行', () {
      final c = doc('前面的文字\n');
      cursorAt(c, 3);
      MailPasteHandler.insertOps(
        c,
        MailHtmlToDelta.convert(
          '<p>半句甲<img src="data:image/png;base64,AAAA">乙</p><p>话尾</p>',
        ),
      );
      // 嵌入与「半句甲」挤在一行正是原来的病：现在它被劈出来独占一行。
      expect(c.document.toPlainText(), '前面的半句甲\n￼\n乙\n话尾\n文字\n');
    });

    test('光标在文档末尾（offset 就是 length-1）不越界', () {
      final c = doc('末尾\n');
      cursorAt(c, c.document.length - 1);
      MailPasteHandler.insertOps(c, [
        {'insert': '另一句\n'},
      ]);
      expect(c.document.toPlainText(), '末尾另一句\n');
    });

    test('空文档粘贴一段文字', () {
      MailPasteHandler.insertOps(controller, [
        {'insert': '粘的\n'},
      ]);
      expect(controller.document.toPlainText(), '粘的\n');
    });

    test('空文档粘贴表格 → 整篇替换，不留下空段落', () {
      MailPasteHandler.insertOps(controller, [
        tableOp,
        {'insert': '\n'},
      ]);
      expect(controller.document.toPlainText(), '￼\n');
      expect(controller.document.root.children.length, 1);
    });

    test('多段粘贴落在行中 → 只有末段并入原句', () {
      final c = doc('你好世界\n');
      cursorAt(c, 2);
      MailPasteHandler.insertOps(c, [
        {'insert': '甲\n'},
        {'insert': '乙\n'},
      ]);
      expect(c.document.toPlainText(), '你好甲\n乙世界\n');
      expect(c.document.root.children.length, 2);
    });

    // P-8：嵌入所在那一行的**行级属性**（header / list / blockquote /
    // code-block / …）整行丢失。
    //
    // `MailHtmlToDelta._splitLines` 把行级属性留在**行尾那个 `\n`** 上，
    // 于是 `<h1>标<img></h1>` 是 `[标, 图片嵌入, \n/header:1]`。旧实现会在
    // 嵌入前补一个**裸**换行把「标」断成普通段落，那个 `header:1` 就落到后面
    // 一个空行上、被收尾处理丢掉 —— 用户从网页复制「标题里带图」粘进来，
    // 标题格式整行消失、还凭空多一个空行。
    //
    // 断言的是**结构不变量**（嵌入独占一行 + 行级属性不丢 + 没有多余空行），
    // 不是某个凑出来的字符串。
    group('P-8 嵌入所在行的行级属性保住', () {
      final img = '<img src="data:image/png;base64,AAAA">';

      /// 把 [html] 粘进空文档，返回文档。
      q.Document pasteIntoBlank(String html) {
        final c = q.QuillController.basic();
        MailPasteHandler.insertOps(c, MailHtmlToDelta.convert(html));
        // 顺便钉住「产物能装回 Document」这条底线（转换产物必须合法）。
        final json = c.document.toDelta().toJson();
        expect(q.Document.fromJson(json), isNotNull);
        expectEmbedsIsolated(json);
        return c.document;
      }

      test('<h1>标<img></h1> → 「标」仍是 header:1，图片独占一行、无多余空行', () {
        final document = pasteIntoBlank('<h1>标$img</h1>');
        expect(lineAttrsOf(document, '标'), <String, dynamic>{'header': 1});
        // 没有多余空行：整段只有两行（标题行 + 图片行），不是三行。
        expect(document.toPlainText(), '标\n￼\n');
        expect(document.root.children.length, 2);
      });

      test('<ul><li>项<img></li></ul> → list:bullet 保住', () {
        final document = pasteIntoBlank('<ul><li>项$img</li></ul>');
        expect(lineAttrsOf(document, '项'), <String, dynamic>{'list': 'bullet'});
        expect(document.toPlainText(), '项\n￼\n');
      });

      test('<blockquote>引<img></blockquote> → blockquote:true 保住', () {
        final document = pasteIntoBlank('<blockquote>引$img</blockquote>');
        expect(
          lineAttrsOf(document, '引'),
          <String, dynamic>{'blockquote': true},
        );
        expect(document.toPlainText(), '引\n￼\n');
      });

      test('<h1>标<table>…</table></h1> → header:1 保住（属性上浮）', () {
        final document = pasteIntoBlank(
          '<h1>标<table><tr><td>甲</td></tr></table></h1>',
        );
        expect(lineAttrsOf(document, '标'), <String, dynamic>{'header': 1});
        expect(document.toPlainText(), '标\n￼\n');
      });

      test('嵌入前、后文字同属一个块 → 两段都保住行级属性', () {
        final document = pasteIntoBlank('<h1>前$img后</h1>');
        expect(lineAttrsOf(document, '前'), <String, dynamic>{'header': 1});
        expect(lineAttrsOf(document, '后'), <String, dynamic>{'header': 1});
        expect(document.toPlainText(), '前\n￼\n后\n');
      });

      // 回归：本来就没有块级属性的段落行为不变（不因上浮凭空长属性）。
      test('回归 <p>段<img></p>：无属性输入行为不变', () {
        final document = pasteIntoBlank('<p>段$img</p>');
        expect(lineAttrsOf(document, '段'), isNull);
        expect(document.toPlainText(), '段\n￼\n');
      });

      // 回归：**以嵌入开头**的那一支原来直接原样返回（`_startsWithBlockEmbed`
      // 判中就 `return ops`），于是嵌入后面那段文字跟它同居一行。
      // 判据现在换成「ops 里有没有嵌入」，两支都过 `_isolateEmbeds`。
      test('回归 $img 后（嵌入打头、后面还有字）：嵌入仍独占一行', () {
        final document = pasteIntoBlank('$img后');
        expect(document.toPlainText(), '￼\n后\n');
        // 拆成两行：嵌入一行、「后」一行 —— 不是 `￼后` 挤一行。
        expect(document.root.children.length, 2);
      });

      // 回归：嵌入前后都没文字时，不因此崩、也不变怪。
      test('回归 <img> 单独一段：嵌入自己独占一行，不多不少', () {
        final document = pasteIntoBlank(img);
        expect(document.toPlainText(), '￼\n');
        expect(document.root.children.length, 1);
      });

      test('回归 <h1><img></h1>：嵌入独占一行，header 落在它那一行', () {
        final document = pasteIntoBlank('<h1>$img</h1>');
        expect(document.toPlainText(), '￼\n');
        // 嵌入行不跟任何文字同居，属性挂在它自己的行尾上也不违背不变量。
        expect(document.root.children.length, 1);
      });
    });
  });

  group('normalizePlainText', () {
    test('没有换行 → null（交给默认通路）', () {
      expect(MailPasteHandler.normalizePlainText('一句话'), isNull);
    });

    test('全是空白 → null', () {
      expect(MailPasteHandler.normalizePlainText('  \n \n '), isNull);
    });

    test('单换行不折成空行 —— 相邻两行保持相邻', () {
      expect(MailPasteHandler.normalizePlainText('甲\n乙'), '甲\n乙');
    });

    test('空行保留一个（段落分隔），多余空行压成一个', () {
      expect(MailPasteHandler.normalizePlainText('甲\n\n\n\n乙'), '甲\n\n乙');
    });

    test('首尾空行去掉', () {
      expect(MailPasteHandler.normalizePlainText('\n\n甲\n乙\n\n'), '甲\n乙');
    });

    test('行尾空白去掉（从终端拷贝常带进来）', () {
      expect(MailPasteHandler.normalizePlainText('甲   \n乙\t'), '甲\n乙');
    });
  });
}
