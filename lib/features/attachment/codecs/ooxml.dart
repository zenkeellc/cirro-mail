import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// 解析一个附件时的结果：要么是一份模型，要么是一个**能展示给用户的原因**。
///
/// 为什么用返回值而不是抛异常：这些解析器的输入是**邮件附件**，坏 zip、
/// 缺文件、超限都是家常便饭而不是意外。调用方（预览页）拿到 `failed` 就该
/// 显示一句话并把用户送回去，所以「失败」是这条链路的一等结果，
/// 而不是要从栈里捞出来的异常。
sealed class ParseResult<T> {
  const ParseResult();

  static ParseResult<T> ok<T>(T value) => ParseOk<T>(value);

  static ParseResult<T> fail<T>(ParseFailure reason, [String? detail]) =>
      ParseFailed<T>(reason, detail);

  /// 成功时的值，失败时 null —— 给「有就用、没有就降级」的调用方。
  T? get valueOrNull => this is ParseOk<T> ? (this as ParseOk<T>).value : null;

  ParseFailure? get failureOrNull =>
      this is ParseFailed<T> ? (this as ParseFailed<T>).reason : null;
}

class ParseOk<T> extends ParseResult<T> {
  const ParseOk(this.value);
  final T value;
}

class ParseFailed<T> extends ParseResult<T> {
  const ParseFailed(this.reason, this.detail);

  final ParseFailure reason;

  /// 排错用的补充信息（异常原文之类），**可以给用户看，但不是主句**。
  final String? detail;
}

/// 解析失败的原因。每一档在界面对应一句不同的话。
enum ParseFailure {
  /// 字节压根不是这个格式（不是 zip、不是 OOXML 包）。
  notAPackage,

  /// 是 zip，但里面没有它该有的那个部件（比如 docx 没有 `word/document.xml`）。
  missingPart,

  /// 压缩包本身不合规、或某个部件解不开。
  malformed,

  /// 超过预览的体积 / 条目上限 —— 不是「坏了」，是「太大了」。
  tooLarge,
}

/// OOXML（docx / xlsx / pptx）共用的那一层：把 zip 打开、把里面的 XML 拿出来。
///
/// 这三个格式**本来就是同一个东西**：一个 zip，里面若干 XML 部件，靠
/// `_rels/*.rels` 互相引用。所以只有这一层基建，三个解析器各写各的读法。
///
/// ## 附件是不可信输入，这一层的每一处限制都是必须的
///
/// `archive` 4.5 起有解压炸弹防护：它把每个条目的解码输出**限制在该条目
/// 头部声明的大小**（`ZipFile.decompress` 里的 `decodeLimited`），声明与实际
/// 对不上就抛 `ArchiveException`。也就是说「声明 1KB、解出 1GB」这条路它自己
/// 就堵上了。剩下要我们堵的是：
///
/// - **声明的**大小可以很大（头部是攻击者写的），所以在读之前先按
///   [maxEntryBytes] / [maxTotalBytes] 判一道，别让它有机会开始解。
/// - **条目数量**可以是几万个（每个都建一个 `ArchiveFile` 对象）。
/// - **我们只读我们点名要的那几个部件**，绝不遍历着解压 ——
///   一份正常的 docx 里 `word/media/` 可能占 99% 的体积，那是图片，
///   本来就「明确不做」（见 `docx.dart`）。不读它，炸弹就炸不到。
///
/// XML 那一侧：实测 `xml` 7.0.1 **不展开**内部实体（`<!ENTITY lol9 "…">`
/// 在 `innerText` 里原样是 `&lol9;`），也不解析外部实体（`SYSTEM "file:///…"`
/// 原样留着），所以 billion-laughs 与 XXE 两条经典路子在这个版本上都不成立。
/// 深度也不怕：100 万层嵌套（7MB）实测 1.08 秒、不爆栈（它的解析器是迭代的）。
/// 于是 XML 这边只需要一道**字节数**上限（见 [maxXmlBytes]）。
abstract final class Ooxml {
  const Ooxml._();

  /// 压缩包里最多认多少个条目。
  static const int maxEntries = 512;

  /// 单个部件解压后的上限。
  ///
  /// 32MB：一份带大量文本的 docx 的 `document.xml` 也就是几 MB，
  /// 而我们的整份预览上限本来就是 20MB（见 `AppDefaults.attachmentPreviewLimit`）。
  static const int maxEntryBytes = 32 * 1024 * 1024;

  /// 全部条目**声明**大小之和的上限。
  ///
  /// 单看每一个条目都不超，合起来仍然可以把内存吃光 —— 512 个 32MB 的部件
  /// 是 16GB。这个数是「解压后」的量级，比 20MB 的输入上限宽得多，
  /// 正常的 Office 文件（体积主要在媒体上）根本到不了。
  static const int maxTotalBytes = 256 * 1024 * 1024;

  /// 一段 XML 部件允许的字节上限。
  ///
  /// 12MB。上限不是为了防爆栈（见类注释），而是为了别让一次预览在纯文本
  /// 解析上耗时过秒 —— 病态的 7MB / 100 万层嵌套实测 1.08 秒。
  static const int maxXmlBytes = 12 * 1024 * 1024;

  /// 打开一个 OOXML 包。
  static ParseResult<OoxmlPackage> open(List<int> bytes) {
    if (bytes.isEmpty) {
      return ParseResult.fail(ParseFailure.notAPackage);
    }
    // zip 的魔数。先看一眼能省下一次必然失败的解析，也让「这不是个 zip」
    // 与「是个坏 zip」分得开。
    if (!_looksLikeZip(bytes)) {
      return ParseResult.fail(ParseFailure.notAPackage);
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on ArchiveException catch (e) {
      return ParseResult.fail(ParseFailure.malformed, e.message);
    } catch (e) {
      // `RangeError` 之类：头部里的长度越过了数据。README 里那条
      // 「解码器只认自己的异常」在这里不成立 —— 坏 zip 能抛出各种东西。
      return ParseResult.fail(ParseFailure.malformed, '$e');
    }

    final files = <String, ArchiveFile>{};
    var total = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (files.length >= maxEntries) {
        return ParseResult.fail(ParseFailure.tooLarge);
      }
      if (entry.size > maxEntryBytes) {
        return ParseResult.fail(ParseFailure.tooLarge);
      }
      total += entry.size;
      if (total > maxTotalBytes) {
        return ParseResult.fail(ParseFailure.tooLarge);
      }
      files[_normalize(entry.name)] = entry;
    }

    if (files.isEmpty) {
      // 魔数对得上、却一个条目都没读出来 —— 那不是一个空文档，那是一份
      // 断掉的 zip（截断的文件、写坏的下载）。**分得开很重要**：
      // 「不是 OOXML 包」会让用户以为下错了文件，「包坏了」才是实情。
      return ParseResult.fail(ParseFailure.malformed);
    }
    return ParseResult.ok(OoxmlPackage._(files));
  }

  static bool _looksLikeZip(List<int> bytes) {
    if (bytes.length < 4) return false;
    // `PK\x03\x04` 本地文件头。空 zip（只有中央目录）会以 `PK\x05\x06`
    // 开头，那不是一个能放 OOXML 的包，但仍然认出来，让后面去说
    // 「缺部件」而不是「不是个包」—— 对用户来说更准确。
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);
  }

  /// 统一部件路径：反斜杠换成斜杠、去掉开头的 `/` 与 `./`。
  ///
  /// zip 规范里路径就该用 `/`，但 Windows 上有些打包工具写的是 `\`
  /// （`ArchiveFile` 也照原样保留），而 rels 里写的永远是 `/` —— 不归一
  /// 就会「按 rels 找不到部件」。
  static String _normalize(String name) =>
      name.replaceAll('\\', '/').replaceAll(RegExp(r'^\.?/+'), '');
}

/// 一个解开的 OOXML 包。**按需**取部件 —— 见 [Ooxml] 类注释最后一节。
class OoxmlPackage {
  OoxmlPackage._(this._files);

  final Map<String, ArchiveFile> _files;

  /// 包里全部部件的路径（已归一）。给测试与排错用。
  List<String> get parts => _files.keys.toList(growable: false);

  bool has(String path) => _files.containsKey(_key(path));

  /// 读一个部件的原始字节。
  ParseResult<Uint8List> bytes(String path) {
    final entry = _files[_key(path)];
    if (entry == null) return ParseResult.fail(ParseFailure.missingPart, path);
    try {
      final data = entry.readBytes();
      if (data == null) return ParseResult.fail(ParseFailure.malformed, path);
      return ParseResult.ok(data);
    } on ArchiveException catch (e) {
      // 走到这里多半是解压输出超过了头部声明的大小 —— 炸弹的形状。
      return ParseResult.fail(ParseFailure.malformed, e.message);
    } catch (e) {
      return ParseResult.fail(ParseFailure.malformed, '$e');
    }
  }

  /// 读一个部件并解析成 XML。
  ParseResult<XmlDocument> xml(String path) {
    final raw = bytes(path);
    if (raw is ParseFailed<Uint8List>) {
      return ParseFailed<XmlDocument>(raw.reason, raw.detail);
    }
    final data = (raw as ParseOk<Uint8List>).value;
    if (data.length > Ooxml.maxXmlBytes) {
      return ParseResult.fail(ParseFailure.tooLarge, path);
    }
    try {
      // OOXML 的部件声明一律是 UTF-8（规范要求）。`allowMalformed` 是因为
      // 宁可让 XML 解析器去报「格式不对」，也不要在这里抛一个编码异常
      // 把「这个文件坏了」说成「读不出来」。
      final text = utf8.decode(data, allowMalformed: true);
      return ParseResult.ok(XmlDocument.parse(_stripBom(text)));
    } catch (e) {
      return ParseResult.fail(ParseFailure.malformed, '$e');
    }
  }

  /// 按 `_rels` 关系找部件。
  ///
  /// OOXML 里「主部件在哪」是**声明**出来的，不是约定死的：docx 的
  /// `_rels/.rels` 里有一条 `Type=…/officeDocument` 的 `Target`。
  /// 按约定猜 `word/document.xml` 在 99% 的文件上是对的，剩下 1%
  /// 恰恰是那些用工具重新打包过的 —— 读一眼 rels 就能都接住。
  ///
  /// [relsPath] 是关系文件的位置（根是 `_rels/.rels`，
  /// 部件级是 `<dir>/_rels/<name>.rels`）。找不到就返回 null，
  /// 由调用方退回约定路径。
  String? relationshipTarget(String relsPath, {required String typeSuffix}) {
    final doc = xml(relsPath).valueOrNull;
    if (doc == null) return null;
    for (final rel in doc.rootElement.childElements) {
      if (rel.name.local != 'Relationship') continue;
      final type = rel.getAttribute('Type') ?? '';
      if (!type.endsWith(typeSuffix)) continue;
      final target = rel.getAttribute('Target');
      if (target == null || target.isEmpty) continue;
      return _resolve(relsPath, target);
    }
    return null;
  }

  static String _key(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'^\.?/+'), '');

  /// 把 rels 里那条**相对**路径解成包内绝对路径。
  ///
  /// `Target` 的基准是 rels 文件所在部件的**目录**：`word/_rels/document.xml.rels`
  /// 里的 `Target="media/image1.png"` 指的是 `word/media/image1.png`，而
  /// `../customXml/item1.xml` 要往上退一级。`_rels` 自己在哪不算在内。
  static String _resolve(String relsPath, String target) {
    if (target.startsWith('/')) return _key(target);
    final parts = _key(relsPath).split('/');
    // 去掉 `_rels/<file>.rels` 两段，剩下的是「这个部件在哪个目录」。
    final base = parts.length >= 2 ? parts.sublist(0, parts.length - 2) : <String>[];
    final stack = <String>[...base];
    for (final segment in target.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isNotEmpty) stack.removeLast();
        continue;
      }
      stack.add(segment);
    }
    return stack.join('/');
  }

  static String _stripBom(String text) =>
      text.startsWith('﻿') ? text.substring(1) : text;
}
