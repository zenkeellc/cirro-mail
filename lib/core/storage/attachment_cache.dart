import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 附件在磁盘上的落点。
///
/// 三件事集中在这一个文件里，因为它们互相牵制：**目录布局**决定了
/// 按实例清理能不能一次删干净，**文件名净化**决定了从服务端来的
/// `filename` 会不会写出目录外，**占用统计**决定了缓存管理页显示什么。
///
/// ## 布局
///
/// ```text
/// <support>/attachments/<profileId>/<emailId>/<净化后的文件名>
/// ```
///
/// - 按 `profileId` 一层：设置页「清掉这个实例的附件」就是删一棵子树；
///   而且两个实例的 `emailId` 会重号，不分层会互相覆盖。
/// - 按 `emailId` 一层：同一封邮件的多个附件在一起，删邮件时整目录带走。
///
/// ## 为什么用 support 目录而不是 temp
///
/// `getTemporaryDirectory()` 在 Android 上会被系统在存储紧张时清理，
/// 用户下一层点开附件会「文件不见了」；iOS 的 Caches 同理。
/// 代价是这些文件算进 App 占用 —— 所以缓存管理页必须存在（它是 M4 的一部分，
/// 但清理入口从第一天就在）。
///
/// ## 文件名
///
/// 服务端来的 `filename` 是**不可信输入**：可能含 `../`、`/`、`\`、
/// Windows 保留名（`CON`、`NUL`）、超长名字、或纯粹的空串。
/// 所以落盘前一律走 [sanitize] 而不是直接拼接。
class AttachmentCache {
  AttachmentCache({Directory? root}) : _injectedRoot = root;

  /// 测试用：直接指定根目录（跳开 `path_provider` 的平台通道）。
  final Directory? _injectedRoot;

  Directory? _root;

  /// 根目录（懒建）。
  ///
  /// `path_provider` 在某些平台（Linux 无 XDG 目录时）会抛 —— 那种情况下
  /// 退回系统临时目录，附件仍然可用，只是重启后可能被清掉。
  Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;
    final injected = _injectedRoot;
    if (injected != null) {
      await injected.create(recursive: true);
      return _root = injected;
    }
    final base = await _supportOrTemp();
    final dir = Directory('${base.path}${Platform.pathSeparator}attachments');
    await dir.create(recursive: true);
    return _root = dir;
  }

  static Future<Directory> _supportOrTemp() async {
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return getTemporaryDirectory();
    }
  }

  /// 某个邮件附件所在目录。
  Future<Directory> directoryFor(String profileId, int emailId) async {
    final base = await root();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}${_segment(profileId)}'
      '${Platform.pathSeparator}$emailId',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 给一个附件挑一个**不与已有文件冲突**的落点。
  ///
  /// 同名加序号（`报告.pdf` → `报告 (2).pdf`），而不是覆盖：
  /// 同一封邮件里两个附件重名是常见的（尤其是「附件」「image.png」这种）。
  Future<File> targetFor({
    required String profileId,
    required int emailId,
    required String filename,
  }) async {
    final dir = await directoryFor(profileId, emailId);
    final safe = sanitize(filename);
    final dot = safe.lastIndexOf('.');
    final stem = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';

    var candidate = File('${dir.path}${Platform.pathSeparator}$safe');
    var index = 2;
    // 上限只是为了不写出一个无界的循环；正常一两轮就出来了。
    while (await candidate.exists() && index < 1000) {
      candidate = File(
        '${dir.path}${Platform.pathSeparator}$stem ($index)$ext',
      );
      index++;
    }
    return candidate;
  }

  /// 已下载文件的落点是否还在（用户可能手动删过、系统可能清理过）。
  Future<bool> exists(String? path) async =>
      path != null && path.isNotEmpty && await File(path).exists();

  /// 删掉单个文件（缓存管理页的单条删除）。
  Future<void> deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    final file = File(path);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 文件被占用（比如正被系统应用打开着）：删不掉就算了，
      // 库里的记录照常清 —— 下次下载会重新挑一个落点。
    }
  }

  Future<void> deleteMail(String profileId, int emailId) async {
    try {
      final dir = await directoryFor(profileId, emailId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // 同上：占用中、或已经被删了。
    }
  }

  /// 清空一个实例的附件目录（设置页「删除该实例」时调用）。
  Future<void> clearProfile(String profileId) async {
    final base = await root();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}${_segment(profileId)}',
    );
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // 忽略。
    }
  }

  Future<void> clearAll() async {
    final base = await root();
    try {
      await for (final entry in base.list()) {
        if (entry is Directory) await entry.delete(recursive: true);
      }
    } on FileSystemException {
      // 忽略。
    }
  }

  /// 目录占用（缓存管理页的总占用）。
  ///
  /// 遍历全部文件而不是从库里加总：库里可能记着一批已经被系统删掉的文件，
  /// 那样显示的数字会比真实占用大，用户会以为「清了没效果」。
  Future<({int bytes, int files})> usage() async {
    final base = await root();
    var bytes = 0;
    var files = 0;
    try {
      await for (final entity in base.list(recursive: true)) {
        if (entity is! File) continue;
        try {
          bytes += await entity.length();
          files++;
        } on FileSystemException {
          // 统计期间文件被删了：跳过这一条。
        }
      }
    } on FileSystemException {
      // 目录被整个删掉了。
    }
    return (bytes: bytes, files: files);
  }

  // ------------------------------------------------------------ 文件名净化

  /// 把服务端给的文件名变成一个**只能落在自己目录里**的名字。
  ///
  /// 处理的东西（都来自真实世界的邮件附件）：
  /// - 路径分隔符与 `..` —— 防目录穿越，这是安全性上唯一真正要紧的一条；
  /// - 控制字符与 URL 编码的残留（`%2F`）；
  /// - Windows 保留名（`CON`/`NUL`/`COM1`…）—— 桌面端会直接写失败；
  /// - 首尾的点与空格（Windows 会静默去掉，导致「下载成功但找不到」）；
  /// - 超长（大多文件系统 255 字节，留余量到 120 字符 + 扩展名）；
  /// - 空串。
  static String sanitize(String raw) {
    var name = raw.trim();

    // URL 编码残留（有些分支会把 filename 编一次码再发出来）。
    if (name.contains('%') && !name.contains(' ')) {
      final decoded = _tryDecode(name);
      if (decoded != null) name = decoded;
    }

    // 只取最后一段：`../../etc/passwd` → `passwd`，`a/b/c.png` → `c.png`。
    name = name.replaceAll('\\', '/');
    final slash = name.lastIndexOf('/');
    if (slash >= 0) name = name.substring(slash + 1);

    // 控制字符既不该进文件名，也会让某些文件系统直接报错。
    name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');

    // Windows 上非法的一批字符，统一换成下划线。
    name = name.replaceAll(RegExp(r'[<>:"|?*]'), '_');

    // 首尾的点与空格：`...` 和 `a.png ` 在 Windows 上会被静默改写。
    name = name.replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');

    if (name.isEmpty) return 'attachment';
    if (_windowsReserved.contains(_stem(name).toUpperCase())) {
      name = '_$name';
    }
    return _truncate(name);
  }

  /// 扩展名（带点，小写）；没有则空串。
  static String extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return '';
    return filename.substring(dot).toLowerCase();
  }

  static String _stem(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String _truncate(String name) {
    // 按**字节**算：中文文件名一个字符 3 字节，按字符数截会超。
    const maxBytes = 180;
    if (_utf8Length(name) <= maxBytes) return name;

    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 12 ? name.substring(dot) : '';
    final stem = dot > 0 ? name.substring(0, dot) : name;

    var kept = '';
    var used = 0;
    final budget = maxBytes - _utf8Length(ext);
    for (final rune in stem.runes) {
      final size = _runeBytes(rune);
      if (used + size > budget) break;
      kept += String.fromCharCode(rune);
      used += size;
    }
    return kept.isEmpty ? 'attachment$ext' : '$kept$ext';
  }

  static int _utf8Length(String value) {
    var total = 0;
    for (final rune in value.runes) {
      total += _runeBytes(rune);
    }
    return total;
  }

  static int _runeBytes(int rune) {
    if (rune <= 0x7f) return 1;
    if (rune <= 0x7ff) return 2;
    if (rune <= 0xffff) return 3;
    return 4;
  }

  static String? _tryDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return null;
    }
  }

  /// 目录名也要净化一次 —— `profileId` 是本地生成的 UUID（安全），
  /// 但这个类不该依赖调用方传对，多一道检查很便宜。
  static String _segment(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'default' : cleaned;
  }

  static const Set<String> _windowsReserved = <String>{
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
}
