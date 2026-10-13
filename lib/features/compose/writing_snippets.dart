import 'package:flutter/foundation.dart' show immutable;

// 分层说明：这个模型住在 `features/compose/` 下，而 `core/storage/prefs_store.dart`
// 会 import 它 —— 方向是反的（core 引 features）。这是一处**已知的妥协**：
// 把模型挪到 `lib/core/storage/` 能让依赖方向正过来，但那样「写信页的概念」
// 就住进了存储层，两边都不干净。这里选妥协，写在这里免得下一个人以为是疏漏。

/// 常用语的形状（**签名不走这个类** —— 签名在存储里就是纯文本）。
/// 一段可复用的文字：有名字的一段纯文本。
@immutable
class WritingSnippet {
  const WritingSnippet({
    required this.id,
    required this.name,
    required this.text,
  });

  final String id;
  final String name;

  /// 纯文本，`\n` 分段。插入时按 `\n` 拆成多个段落。
  final String text;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'id': id, 'name': name, 'text': text};

  /// 字段不全就给 null（**不抛**）—— 调用方跳过这一条。
  /// 这是 `PrefsStore.instanceColors` 那套「垃圾输入退回默认」的延伸：
  /// 一条坏数据不该让整组读不出来。
  static WritingSnippet? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final text = raw['text'];
    if (id is! String || name is! String || text is! String) return null;
    return WritingSnippet(id: id, name: name, text: text);
  }

  @override
  bool operator ==(Object other) =>
      other is WritingSnippet &&
      other.id == id &&
      other.name == name &&
      other.text == text;

  @override
  int get hashCode => Object.hash(id, name, text);

  @override
  String toString() => 'WritingSnippet($id, $name)';
}
