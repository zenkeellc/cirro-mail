import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'image_insert.dart';

/// 拖进正文区的文件**是不是图片** —— 决定它去正文还是去附件栏。
///
/// 注意 `DropItem.mimeType` 在**桌面三平台都是 null**（探针实测：macOS 的原生
/// 回调只给路径，不给类型），所以判据必须落在**文件名后缀**上，
/// [ImageInsert.isInlineImage] 里的 `lookupMimeType(name)` 那条路才是真的在跑。
abstract final class DropClassifier {
  const DropClassifier._();

  /// 该内联进正文的图。
  ///
  /// 目录**不算**：拖一个文件夹进来时它的 `path` 是个目录，读它会抛
  /// `PathNotFoundException`（探针实测），而当附件传也没有意义。
  static List<DropItem> images(List<DropItem> items) => items
      .where((item) => item is! DropItemDirectory)
      .where((item) => ImageInsert.isInlineImage(mimeType: item.mimeType, name: item.name))
      .toList();

  /// 除图片之外的**文件**（目录仍被排除），它们变成附件 chip。
  static List<DropItem> attachments(List<DropItem> items) => items
      .where((item) => item is! DropItemDirectory)
      .where((item) => !ImageInsert.isInlineImage(mimeType: item.mimeType, name: item.name))
      .toList();

  /// 被丢掉的（目前只有目录）—— 用来决定要不要给一句提示。
  static bool hasIgnoredDirectories(List<DropItem> items) =>
      items.any((item) => item is DropItemDirectory);
}

/// 拖拽悬停时那层遮罩的 key。测试用它区分「我们的遮罩」与 Flutter 内部
/// 到处都有的 `IgnorePointer`。
const Key dropOverlayKey = ValueKey('mail-drop-overlay');

/// 正文区的拖放落点。拖进来时**整块高亮**，并显示一句提示。
///
/// 为什么自己包一层而不是直接用 `DropTarget`：`DropTarget` 只负责「收事件」，
/// 不给任何视觉反馈，用户拖着文件在窗口里晃的时候完全不知道能不能松手。
///
/// `enabled` 必须跟着页面可见性走 —— `DropTarget` 的文档明确警告：**被别的页面
/// 盖住时它照样收事件**，不管的话在设置页拖文件会落到写信页里。
class MailDropTarget extends StatefulWidget {
  const MailDropTarget({
    super.key,
    required this.child,
    required this.onDrop,
    this.enabled = true,
    this.hint = '松手，图片会插进正文',
  });

  final Widget child;

  /// 用户真的松手了。**分类交给调用方**（页面才知道附件额度剩多少）。
  final void Function(DropDoneDetails details) onDrop;

  final bool enabled;

  /// 拖拽悬停时显示的提示语。
  final String hint;

  @override
  State<MailDropTarget> createState() => _MailDropTargetState();
}

class _MailDropTargetState extends State<MailDropTarget> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropTarget(
      // DropTarget 自己会在 enable 翻转时挂/摘监听器，这里直接透传。
      enable: widget.enabled,
      onDragEntered: (_) => _setHovering(true),
      onDragUpdated: (_) => _setHovering(true),
      onDragExited: (_) => _setHovering(false),
      onDragDone: (details) {
        _setHovering(false);
        widget.onDrop(details);
      },
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            // `Positioned.fill` 必须是 `Stack` 的**直接**子节点（ParentData
            // 只能由 Stack 自己读），所以 `IgnorePointer` 套在它**里面** ——
            // 反过来的写法会在挂载时抛 `Incorrect use of ParentDataWidget`。
            //
            // `IgnorePointer` 是**必须的**：这块遮罩盖在正文上，不排除命中测试的
            // 话松手那一瞬间的指针事件会被它吃掉（macOS 上表现为「第一次拖没反应」）。
            Positioned.fill(
              // key 挂在 `IgnorePointer` **自己**身上（而不是里面那个
              // `DecoratedBox`）：测试要断言的就是「它真的在忽略指针」，
              // 挂在子节点上就断言不到这件事。
              child: IgnorePointer(
                key: dropOverlayKey,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.file_download_outlined, size: 18),
                          const SizedBox(width: 8),
                          Text(widget.hint, style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 把落点坐标换算成文档偏移 —— 拖进来的图应该插在**鼠标松开的位置**，
/// 而不是光标处（用户的意图在落点上）。
///
/// 单独成函数是为了能在**没有真实拖放**的情况下测：真拖放的自动化成本很高，
/// 而「算错落点」恰恰是这类交互最常见的 bug。
///
/// [editorState] 拿不到（编辑器还没挂）时返回 null，调用方退回光标处。
int? dropOffsetInDocument({
  required Offset localPosition,
  required GlobalKey<q.EditorState> editorState,
  required double scrollOffset,
}) {
  final render = editorState.currentState?.renderEditor;
  if (render == null) return null;
  // `getPositionForOffset` 吃的是**编辑器内容坐标**，而落点是**视口坐标**，
  // 所以要把滚动偏移加回去 —— 不加的话，正文滚下去之后落点会系统性偏上。
  final position = render.getPositionForOffset(
    localPosition + Offset(0, scrollOffset),
  );
  return position.offset;
}
