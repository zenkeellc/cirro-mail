import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 在测试里现搭 OOXML 包。
///
/// **不往仓库里提交二进制样本**：仓库现在一个 fixtures 目录都没有，开这个头
/// 之后每次要验一个新的边角（网格跨列、日期格式、幻灯片顺序）都得塞一个
/// 几百 KB 的 `.docx` 进来，而且没人能 review 它里面是什么。现搭的反而
/// 看得清每个字节是怎么来的 —— 顺带还验了「自己写的 zip 能被自己读回来」。
///
/// 压缩级别用 [DeflateLevel.bestSpeed]：测试里的包都只有几 KB，
/// 压得紧不紧无所谓，快更重要。
Uint8List buildPackage(Map<String, String> parts) {
  final archive = Archive();
  for (final entry in parts.entries) {
    final bytes = utf8.encode(entry.value);
    // 用 `ArchiveFile.bytes` 而不是 `ArchiveFile(name, size, data)`：
    // 后者那个位置的参数在新版本里是 `List<int> data`，两个构造签名长得像，
    // 传错不会报错只会得到一个内容不对的条目。
    archive.add(ArchiveFile.bytes(entry.key, bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// 把若干原始字节（非 UTF-8 文本）放进包里。
Uint8List buildPackageBytes(Map<String, List<int>> parts) {
  final archive = Archive();
  for (final entry in parts.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// [buildPackage] 的字符串版：不压 deflate，直接存。
///
/// 给「压缩包本身合规、但部件解不开」那类用例用 —— 需要能自己拼字节。
Uint8List rawBytes(List<int> bytes) => Uint8List.fromList(bytes);

const String wordMain = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const String sheetMain =
    'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const String drawingMain =
    'http://schemas.openxmlformats.org/drawingml/2006/main';
const String presentationMain =
    'http://schemas.openxmlformats.org/presentationml/2006/main';
const String officeRels =
    'http://schemas.openxmlformats.org/package/2006/relationships';

/// 一个最小的 docx 包：`_rels/.rels` + `word/document.xml`。
///
/// [body] 是 `w:body` 的内容（不含 `<w:body>` 自身）。
Uint8List docx(String body, {String mainPart = 'word/document.xml'}) {
  final dir = mainPart.substring(0, mainPart.lastIndexOf('/'));
  return buildPackage(<String, String>{
    '[Content_Types].xml': '<?xml version="1.0"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/></Types>',
    '_rels/.rels': '<?xml version="1.0"?>'
        '<Relationships xmlns="$officeRels">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="$mainPart"/>'
        '</Relationships>',
    mainPart: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="$wordMain"><w:body>$body</w:body></w:document>',
    if (dir != 'word')
      'word/document.xml':
          '<?xml version="1.0"?><w:document xmlns:w="$wordMain"><w:body/></w:document>',
  });
}

/// 一个最小的 xlsx 包。
///
/// [sheets] 是「表名 → `sheetData` 的内容」；[sharedStrings] 是共享字符串表
/// 的 `<si>` 内容串；[styles] 是 `cellXfs` 的 `<xf>` 内容串。
Uint8List xlsx(
  Map<String, String> sheets, {
  String sharedStrings = '',
  String cellXfs = '',
  Map<String, String> extraParts = const <String, String>{},
}) {
  final names = sheets.keys.toList();
  final workbook = StringBuffer('<?xml version="1.0"?>'
      '<workbook xmlns="$sheetMain" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>');
  final rels = StringBuffer('<?xml version="1.0"?>'
      '<Relationships xmlns="$officeRels">');
  for (var i = 0; i < names.length; i++) {
    final id = 'rId${i + 1}';
    workbook.write('<sheet name="${_escape(names[i])}" sheetId="${i + 1}" r:id="$id"/>');
    rels.write('<Relationship Id="$id" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet${i + 1}.xml"/>');
  }
  workbook.write('</sheets></workbook>');
  rels.write('<Relationship Id="rIdStyles" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/>');
  rels.write('</Relationships>');

  return buildPackage(<String, String>{
    '_rels/.rels': '<?xml version="1.0"?>'
        '<Relationships xmlns="$officeRels">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml': workbook.toString(),
    'xl/_rels/workbook.xml.rels': rels.toString(),
    for (var i = 0; i < names.length; i++)
      'xl/worksheets/sheet${i + 1}.xml':
          '<?xml version="1.0"?><worksheet xmlns="$sheetMain">'
              '<sheetData>${sheets[names[i]]}</sheetData></worksheet>',
    if (sharedStrings.isNotEmpty)
      'xl/sharedStrings.xml': '<?xml version="1.0"?>'
          '<sst xmlns="$sheetMain">$sharedStrings</sst>',
    if (cellXfs.isNotEmpty)
      'xl/styles.xml': '<?xml version="1.0"?><styleSheet xmlns="$sheetMain">'
          '<cellXfs count="1">$cellXfs</cellXfs></styleSheet>',
    ...extraParts,
  });
}

/// 一个最小的 pptx 包。[slides] 是每页的 `p:cSld` 内容。
Uint8List pptx(List<String> slides) {
  final presentation = StringBuffer('<?xml version="1.0"?>'
      '<p:presentation xmlns:p="$presentationMain" '
      'xmlns:a="$drawingMain" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<p:sldIdLst>');
  final rels = StringBuffer('<?xml version="1.0"?>'
      '<Relationships xmlns="$officeRels">');
  for (var i = 0; i < slides.length; i++) {
    presentation.write('<p:sldId id="${256 + i}" r:id="rId${i + 1}"/>');
    rels.write('<Relationship Id="rId${i + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
        'Target="slides/slide${i + 1}.xml"/>');
  }
  presentation.write('</p:sldIdLst></p:presentation>');
  rels.write('</Relationships>');

  return buildPackage(<String, String>{
    '_rels/.rels': '<?xml version="1.0"?>'
        '<Relationships xmlns="$officeRels">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="ppt/presentation.xml"/>'
        '</Relationships>',
    'ppt/presentation.xml': presentation.toString(),
    'ppt/_rels/presentation.xml.rels': rels.toString(),
    for (var i = 0; i < slides.length; i++)
      'ppt/slides/slide${i + 1}.xml': '<?xml version="1.0"?>'
          '<p:sld xmlns:p="$presentationMain" xmlns:a="$drawingMain">'
          '<p:cSld>${slides[i]}</p:cSld></p:sld>',
  });
}

/// 一段 `<a:t>` 文本所在的形状（`p:sp`）。
///
/// [placeholder] 是 `p:ph@type`（`title` / `body` / `ctrTitle`…）——
/// 留空就写一个没有占位符的普通文本框。
String slideShape(
  List<String> texts, {
  int? id,
  String? placeholder,
  int? level,
}) {
  final buffer = StringBuffer('<p:sp>');
  if (id != null || placeholder != null) {
    buffer.write('<p:nvSpPr><p:cNvPr id="${id ?? 2}" name="S${id ?? 2}"/>'
        '<p:cNvSpPr/>');
    if (placeholder != null) {
      buffer.write('<p:nvPr><p:ph type="$placeholder"/></p:nvPr>');
    }
    buffer.write('</p:nvSpPr>');
  }
  buffer.write('<p:txBody><a:bodyPr/>');
  for (final text in texts) {
    buffer.write('<a:p>');
    if (level != null) buffer.write('<a:pPr lvl="$level"/>');
    buffer.write('<a:r><a:t>${_escape(text)}</a:t></a:r></a:p>');
  }
  buffer.write('</p:txBody></p:sp>');
  return buffer.toString();
}

/// 一个带项目符号的正文形状（`a:pPr/a:buChar`）。
String slideBullets(List<String> texts, {int level = 0}) {
  final buffer = StringBuffer('<p:sp><p:txBody><a:bodyPr/>');
  for (final text in texts) {
    buffer.write('<a:p><a:pPr lvl="$level"><a:buChar char="•"/></a:pPr>'
        '<a:r><a:t>${_escape(text)}</a:t></a:r></a:p>');
  }
  buffer.write('</p:txBody></p:sp>');
  return buffer.toString();
}

/// 一个带格式的 run（`a:rPr` 上的 b / i / u / strike）。
String slideRun(
  String text, {
  bool bold = false,
  bool italic = false,
  bool underline = false,
  bool strike = false,
}) {
  final attrs = StringBuffer();
  if (bold) attrs.write(' b="1"');
  if (italic) attrs.write(' i="1"');
  if (underline) attrs.write(' u="sng"');
  if (strike) attrs.write(' strike="sngStrike"');
  return '<a:p><a:r><a:rPr$attrs/><a:t>${_escape(text)}</a:t></a:r></a:p>';
}

/// 一个 `<a:t>` 文本所在的形状（`p:sp`），段落内容自己给。**旧接口** ——
/// 需要行内格式时用 [slideRun] 拼段落再塞进来。
String slideBody(String paragraphs) =>
    '<p:sp><p:txBody><a:bodyPr/>$paragraphs</p:txBody></p:sp>';

/// 图片形状（`p:pic`）——用来验「图片位置有占位」。
const String slidePicture = '<p:pic><p:nvPicPr/></p:pic>';

/// 组合形状（`p:grpSp`），里面的形状应当被摊平。
String slideGroup(List<String> shapes) =>
    '<p:grpSp><p:nvGrpSpPr/>${shapes.join()}</p:grpSp>';

/// 一张表里的一行 —— `p:graphicFrame` 包着的 `a:tbl`。
String slideTable(List<List<String>> rows) {
  final buffer = StringBuffer('<p:graphicFrame><a:tbl>');
  for (final row in rows) {
    buffer.write('<a:tr>');
    for (final cell in row) {
      buffer.write('<a:tc><a:txBody><a:p><a:r><a:t>'
          '${_escape(cell)}</a:t></a:r></a:p></a:txBody></a:tc>');
    }
    buffer.write('</a:tr>');
  }
  buffer.write('</a:tbl></p:graphicFrame>');
  return buffer.toString();
}

/// 一个单元格：`r` 是 `A1` 这种引用，`body` 是 `<c>` 的属性与内容的尾部。
String cell(String ref, {String? type, String? style, required String body}) {
  final attrs = StringBuffer('r="$ref"');
  if (type != null) attrs.write(' t="$type"');
  if (style != null) attrs.write(' s="$style"');
  return '<c $attrs>$body</c>';
}

/// 一行单元格。
String row(int index, String cells) => '<row r="$index">$cells</row>';

String sharedString(String text) => '<si><t>${_escape(text)}</t></si>';

String inlineString(String text) => '<is><t>${_escape(text)}</t></is>';

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
