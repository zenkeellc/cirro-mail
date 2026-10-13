import 'dart:io';
import 'dart:typed_data';

/// 本地文件那一层：问「在不在」「多大」「把字节读出来」。
///
/// 单独开一个文件，是为了让**写邮件页**（它要检查用户在写信期间有没有把
/// 附件删掉/被系统清掉）与**附件预览页**（文本 / CSV / office 都要读字节）
/// 不必各自 import `dart:io`。README 里那条约定把 `dart:io` 收在附件相关的
/// 少数几处，`core/storage/` 正是其中之一。
abstract final class LocalFile {
  const LocalFile._();

  static bool exists(String path) => File(path).existsSync();

  /// 读不到长度就返回 0 —— 调用方（总量校验）会因此把它当成一个空文件，
  /// 而不是让整个写信页崩掉。
  static int length(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// 把整份文件读进内存。
  ///
  /// 两个上限各管一件事，**别混用**：
  /// - [maxBytes]：文件超过它就**返回 null**。给「整份解析」的调用方用
  ///   （CSV、docx/xlsx/pptx）—— 截一半的字节解出来的文档是坏的，与其给一个
  ///   残缺的结果，不如让调用方据此关掉「预览」。
  /// - [limitBytes]：**最多读这么多个字节**，多的不要。给「反正只看开头」
  ///   的调用方用（文本预览：一个 20MB 的日志文件也只需要前 800KB，
  ///   读完再丢掉 96% 是白花的时间与内存）。
  ///
  /// 两个都传时先看 [maxBytes] 再按 [limitBytes] 截。先看 length 而不是读完
  /// 再判，是为了不必为一个注定要拒绝的大文件付一次读盘。
  ///
  /// 也**不**抛：文件在预览页打开到读取之间被系统清掉是正常事
  /// （缓存管理页本来就在删这些），调用方拿到 null 就该显示「文件已经不在了」。
  static Uint8List? readBytes(
    String path, {
    int? maxBytes,
    int? limitBytes,
  }) {
    try {
      final file = File(path);
      final size = file.lengthSync();
      if (maxBytes != null && size > maxBytes) return null;
      final want = limitBytes == null || limitBytes >= size
          ? size
          : limitBytes;
      if (want <= 0) return Uint8List(0);
      // `readAsBytesSync` 只能整份读，读前缀得自己开文件句柄。
      final handle = file.openSync();
      try {
        return handle.readSync(want);
      } finally {
        handle.closeSync();
      }
    } catch (_) {
      return null;
    }
  }
}
