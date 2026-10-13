import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

/// 点一张正文里的图时回调，参数是**这个嵌入在文档里的偏移**
/// （`build` 那一帧现算的 `embedContext.node.documentOffset`，见下面的订正）。
///
/// **放在这个文件里**（而不是 `mail_image_embed.dart`）：这组动作的语义就是
/// 「拿着一个偏移去改那一张图」，偏移从哪来、过来之后怎么复核，都在这里；
/// 渲染那边只是把它绑上。
typedef EmbedTapCallback = void Function(int documentOffset);

/// 图片的文档偏移们（一张图一个，**按文档顺序**）。
///
/// 为什么还要遍历找：**`EmbedContext.node.documentOffset` 是有的**（见下面
/// 的「订正」），但它只在 `build` 里成立 —— 点击回调存下来的那个值是
/// **上一帧**算的，文档一变就可能失效。所以：
/// - **点图那一手带的是真偏移**（`build` 里的 `node.documentOffset`），
///   不是靠「离光标最近的那张」猜；
/// - `imageOffsets` 留作**校验与兜底**：存下来的偏移此刻指着的还是不是一张图？
///   不是（文档改过了）就用它重新认一张。
///
/// **订正（2026-10-11，D3 实施前实测）**：这份计划的早先版本写着
/// 「`EmbedContext` 不告诉你 `node.documentOffset`」—— **那是错的**。
/// `leaf.Embed extends Node`，而 `Node.documentOffset`（`node.dart:88`）
/// 是沿 `parent` 链路现算的，`EmbedContext.node` 拿到的就是当前文档里的
/// 那个节点。六种文档形状（平铺 / 首行就是图 / 两张图 / 标题+图 / 列表+图 /
/// 引用+图 / 代码块+图）实测全部给出正确偏移。
///
/// **遍历走 Delta，不走节点树。** 这一点实施时实测推翻过两版写法：
///
/// 1. `document.root.queryChild(i, false)` 的返回值是 `ChildQuery`，它**没有
///    `.value`**（要 `.node`）—— 初版计划写成 `node.value.type` 编译不过；
/// 2. 更致命的是**它根本找不到图**：`queryChild` 会一路钻进 `Block` 里的
///    `Line`，所以每个偏移都给你 `Line`，永远不给 `Embed`。实测
///    `[{image},{'\n'},{'\n后\n'}]` 这种文档，逐偏移扫一遍返回 `[]`（空表），
///    而正确答案是 `[2]`。**恒空的 `imageOffsets` 会让「点图没反应」，
///    且本机跑不了真机 UI，这类错只能靠单测抓。**
/// 3. 手写 `root.children` → `Line` → `line.children` 也不是好办法：
///    `list` / `blockquote` / `code-block` 的文档里 `root.children` 是
///    **`Block`，不是 `Line`**，`as q.Line` 直接抛
///    `type 'Block' is not a subtype of type 'Line'`（实测三种形状全抛）。
///
/// Delta 的坐标就是文档坐标（一个嵌入占 1，与 `replaceText` 的 `len` 同源），
/// 且与文档结构无关。实测过的六种形状（平铺 / 首行就是图 / 两张图 / 引用 /
/// 列表 / 代码块 / 空文档）全部给出正确偏移，且**逐张偏移处 `replaceText(o, 1,
/// BlockEmbed.image(...))` 都恰好是「换掉那一张」**（两张图时只换掉目标那张）。
List<int> imageOffsets(q.Document document) {
  final out = <int>[];
  var at = 0;
  for (final op in document.toDelta().toJson()) {
    final data = op['insert'];
    if (data is Map && data[q.BlockEmbed.imageType] != null) {
      out.add(at);
    }
    at += data is String ? data.length : 1;
  }
  return out;
}

/// 把一张图的对齐设成 [align]（或传 `null` 清掉）。
///
/// **走 `formatSelection` 而不是直接改属性**：图片的对齐是它**所在那一行**
/// 的属性（落在线尾那个 `\n` 上，实测），而 `formatSelection` 正是
/// 「按选区找行、把行属性设上去」那件事。选区就放在图片的偏移上。
///
/// 先 `updateSelection` 再 `formatSelection`：`formatSelection` 用的是
/// **控制器当前的选区**，不是参数。而改完要把选区**还回去** ——
/// 用户点了一下图片，光标不该从此钉在图片上（他接着还要打字）。
void setImageAlign(
  q.QuillController controller,
  int offset,
  q.Attribute<Object?>? align,
) {
  final restore = controller.selection;
  controller.updateSelection(
    TextSelection.collapsed(offset: offset),
    q.ChangeSource.local,
  );
  if (align == null) {
    for (final attr in <q.Attribute<Object?>>[
      q.Attribute.leftAlignment,
      q.Attribute.centerAlignment,
      q.Attribute.rightAlignment,
      q.Attribute.justifyAlignment,
    ]) {
      controller.formatSelection(q.Attribute.clone(attr, null));
    }
  } else {
    controller.formatSelection(align);
  }
  controller.updateSelection(restore, q.ChangeSource.local);
}

/// 把 [offset] 处那张图换成 [newSource]。
///
/// **`1` 这个长度是对的**：嵌入在文档里就占一个位置（§0.2 第 22 条）。
/// 第二个参数**必须是 `q.BlockEmbed.image(src)`** —— 裸 Map 会在
/// `replaceText` 的类型断言上炸（`quill_controller.dart:273`：
/// `data is String || data is Embeddable || data is Delta`）。
void replaceImage(q.QuillController controller, int offset, String newSource) {
  controller.replaceText(
    offset,
    1,
    q.BlockEmbed.image(newSource),
    TextSelection.collapsed(offset: offset),
  );
}
