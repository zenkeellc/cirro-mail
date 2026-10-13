import 'package:flutter/material.dart';

import 'style_dropdown.dart';

/// 内置 emoji 面板。**纯数据 + 一个网格**，不引第三方包。
///
/// 为什么不做搜索 / 肤色变体 / 最近使用（spec §5.1 明确划掉）：
/// 前两个各有几十行的实现量而收益接近零（能记住在图里第几行的人不需要搜），
/// 后一个要再加一个本地存储键与一套 LRU —— 撑不起它带来的复杂度。
class EmojiGroup {
  const EmojiGroup(this.label, this.emojis);

  final String label;
  final List<String> emojis;
}

/// 四组，共 64 个。
///
/// **只收「无论客户端怎么渲染都不会退化成黑白字形」的那些**，也就是两类：
/// 1. 本身就是 `Emoji_Presentation=Yes` 的单一码位（绝大多数，如 `😀` U+1F600）；
/// 2. **显式写了 `U+FE0F` 变体选择符**的基础字符 —— 实测这一份里有 6 个是这类：
///    `✌️` U+270C、`✉️` U+2709、`🖋️` U+1F58B、`🗂️` U+1F5C2、`⚠️` U+26A0、
///    `➡️` U+27A1。它们的**字面量里就带着 `U+FE0F`**（不是「不需要变体符」）。
///
/// 不收的是「基础字符裸着写、指望客户端自己换成彩色」的那一类（裸 `©` U+00A9、
/// `™` U+2122、`☺` U+263A）：`Emoji_Presentation=No`，不补 `U+FE0F` 时部分
/// Windows 邮件客户端会渲染成黑白字形。**「不收」与「不需要变体符」不是同一件事**
/// —— 上面这类是「补了变体符也不收」，别把两个判据混着写。
const List<EmojiGroup> kEmojiGroups = <EmojiGroup>[
  EmojiGroup('表情', <String>[
    '😀', '😃', '😄', '😁', '😆', '😅', '😂', '🙂',
    '😉', '😊', '😍', '😘', '😜', '🤔', '😐', '😴',
    '😢', '😭', '😤', '😱', '🥳', '😎', '🤗', '🙄',
  ]),
  EmojiGroup('手势', <String>[
    '👍', '👎', '👌', '🙏', '👏', '🙌', '💪', '👋',
    '✌️', '🤝', '👀', '🫡',
  ]),
  EmojiGroup('物品', <String>[
    '📎', '📅', '📌', '📝', '📄', '📁', '💡', '🔔',
    '⏰', '🔗', '📱', '💻', '✉️', '📦', '🖋️', '🗂️',
  ]),
  EmojiGroup('符号', <String>[
    '✅', '❌', '⚠️', '❓', '❗', '⭐', '🔥', '🎉',
    '💯', '🚀', '🏆', '➡️',
  ]),
];

/// 面板本体：一个 [ToolbarMenu] 包着的网格。
///
/// 每颗 emoji 用 [ToolbarMenuItem] 那条路径吗？不行 —— 它的布局是
/// 「图标 + 一行文字」，而这里要的是方格子。所以这里自己写 `InkWell`，
/// 于是 [MenuItemButton] 替我们做的那两件事（关菜单、把 `onPressed` 推到
/// 焦点还原之后的下一帧）**这里一件都没有**，得自己补：
///
/// - **焦点**：`onPick` 的调用方（工具栏的 `_insertText`）末尾要 `_back()`。
/// - **关菜单**：`onClose` 要**真的把菜单关上**，不是只还焦点。
///   `MenuController.maybeOf(context)?.close()` 在这里可用 ——
///   Panel 的 context 在那棵面板子树里（`MenuController.maybeOf` 走
///   `_MenuControllerScope`，由面板子树里的 `RawMenuAnchorGroup` 提供，
///   `raw_menu_anchor.dart:1083` / `:676`）。只把焦点要回来而菜单不关，
///   表现是「点完 emoji 面板还杵在那儿」，而且每点一颗就再插一颗。
///
/// （`close()` 之所以够：`EmojiPanel.build` 拿到的是**调用方 `Builder` 那层**的
/// context，而叫上来的 `close()` 是 `_MenuControllerScope` 记的那个
/// `menuController` —— 与触发器 `InkWell` 用的是同一个。焦点不归它管，
/// 那是 `onPick` 那条的事。）
class EmojiPanel extends StatelessWidget {
  const EmojiPanel({
    super.key,
    required this.onPick,
    required this.onClose,
  });

  /// 选了一个 emoji。调用方负责插入并 `focusNode.requestFocus()`。
  final ValueChanged<String> onPick;

  /// 关掉这个面板（**真的关**，见类文档）。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 280,
        height: 240,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView(
            // **`primary: false` 不能省**（实测）：`MenuAnchor` 的面板子树在
            // `PrimaryScrollController` 里（`menu_anchor.dart:3709`）包着一个
            // `Scrollbar`，而它自己的 `SingleChildScrollView` 显式带了 controller。
            // 这个 grid 是它的后代，`primary` 为真（默认）时会**再挂上同一个**
            // controller —— `Scrollbar` 的断言 `The PrimaryScrollController is
            // attached to more than one ScrollPosition`（`scrollbar.dart:1534`）
            // 当场把整棵树判红，面板根本打不开。
            primary: false,
            padding: const EdgeInsets.all(8),
            children: <Widget>[
              for (final group in kEmojiGroups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                  child: Text(
                    group.label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Wrap(
                  children: <Widget>[
                    for (final emoji in group.emojis)
                      InkWell(
                        key: ValueKey('emoji-$emoji'),
                        onTap: () {
                          onPick(emoji);
                          onClose();
                        },
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: Text(emoji, style: const TextStyle(fontSize: 18)),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      );
}
