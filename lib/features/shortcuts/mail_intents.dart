import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 快捷键要触发的那些动作。
///
/// **分成多个 `Intent` 子类，而不是一个带枚举字段的 Intent**：动作查表是按
/// `runtimeType` 做的（`Actions._findDispatcher` 拿 `actions[IntentType]`），
/// 不同类型才能在 `Actions` 里各挂一个。同一个类带不同参数的话，几个动作会
/// 挤在同一个 key 上，后挂的把先挂的盖掉。
///
/// 除了 [SendMailIntent]，其余都在宿主层（`MailShortcutHost`）挂。
/// [SendMailIntent] 要拿写邮件页的控制器，只能挂在那**页面自己**那一层（见
/// `compose_screen.dart`）。宿主层挂它的话，`Cmd+Enter` 在正文里会一路走到
/// 一个拿不到内容的动作上，表现是「按了没反应」。
class NewMailIntent extends Intent {
  const NewMailIntent();
}

class ReplyMailIntent extends Intent {
  const ReplyMailIntent();
}

class ForwardMailIntent extends Intent {
  const ForwardMailIntent();
}

class DeleteMailIntent extends Intent {
  const DeleteMailIntent();
}

class SendMailIntent extends Intent {
  const SendMailIntent();
}

/// 打开设置页（`Cmd/Ctrl+,`）。系统通用键位，与 macOS 的
/// 「Preferences…」一致。
class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

/// 把主窗口藏起来（`Cmd/Ctrl+W`）。
///
/// **语义是「藏起来」不是「退出」**：这个 App 关窗不退出，留在菜单栏 /
/// 托盘里继续收信（`macos/Runner/AppDelegate.swift:31`、
/// `windows/runner/flutter_window.cpp` 的 `HideToTray`、
/// `linux/runner/my_application.cc` 的 `on_delete_event`）。所以它做的是
/// **和点窗口关闭按钮同一件事**，而不是另开一条路径。
class HideWindowIntent extends Intent {
  const HideWindowIntent();
}

/// 平台 → 激活器表。
///
/// ## 键位是挑过的，不是随手取的
///
/// 两条硬约束：
///
/// 1. **`macos/Runner/Base.lproj/MainMenu.xib` 里 56 个 `keyEquivalent`
///    是全局的**（AppKit 先于 Flutter 处理），其中 Find 那一组占了
///    `f`（Find…）/ `g`（Find Next）/ `e`（Use Selection for Find）/
///    `j`（Jump to Selection）/ `a` `c` `v` `x` `z`。挑 `Cmd+R` 与
///    `Cmd+D` 正是因为那张表里**没有** `r` / `d` / `n`。
/// 2. **`DefaultTextEditingShortcuts._macShortcuts` 是一张封闭表**
///    （它不展开 `_commonShortcuts` / `_clipboardShortcuts`，自己带一份），
///    里面除了剪贴板那五组，还塞了 emacs 的 `Ctrl+A/B/E/F/N/P` 与
///    quill 的 `Cmd+B/I/U/S/K/L/O/M/G/F` 等格式键。所以：
///    - mac 上**不能**用 `Ctrl+*`（那是 emacs 那一套）；
///    - 我们的五个动作与它们**一个都不撞**（`N`/`R`/`D`/`F+Shift`/`Enter`
///      在两张表里都不存在）。
///
/// 其它平台一律 Control：`_linuxShortcuts` / `_windowsShortcuts` 由
/// 公共表 + 剪贴板表拼成，**没有任何裸字母**，`Ctrl+N/R/D/F` 干净。
///
/// ## 两个「系统通用」的补位
///
/// `Cmd+,`（设置）与 `Cmd+W`（藏窗口）是这一轮补的。两条都不在 XIB、不在
/// `_macShortcuts`、不在 quill 的表里：
///
/// - `,` —— XIB 里那个 `Preferences…` **带着 keyEquivalent 但没接 action**
///   （`macos/Runner/Base.lproj/MainMenu.xib:36`），AppKit 把它判成 disabled，
///   于是这个键**不会被系统吃掉**，一直是空着的；
/// - `w` —— XIB 里**压根没有 Close Window 这一项**（`grep -c performClose` = 0），
///   框架与 quill 的表里也没有 `keyW`（两边都 grep 过）。
///
/// ## 为什么转发是 `Cmd+Shift+F` 而不是 `Cmd+F`
///
/// `Cmd+F` 被 XIB 的 Find… 占了，按下去出来的是系统的查找条。`Shift` 那一版
/// 在 XIB、`_macShortcuts`、quill 三张表里都不存在（`Cmd+Shift+F` 在别处常被
/// 用作「退出全屏」，但那个是 **Ctrl+Cmd+F**，不冲突）。
///
/// ### ⚠️ 本轮**没有动** `MainMenu.xib`
///
/// 所以上面那条「XIB 的 56 个 keyEquivalent 是全局的」的约束**依然成立**。
/// 曾经考虑过改走 Dart 的 `PlatformMenuBar`，但引擎二进制里
/// `-[FlutterMenuPlugin setMenus:]` 是 `removeAllObjects` → 新 `NSMenu` →
/// `-[NSApp setMainMenu:]`，**整份替换** —— 「Dart 加一个 Mail 菜单、保留 XIB
/// 的 Edit / Find」这个混合方案不成立；而 `PlatformProvidedMenuItemType` 的
/// 12 个类型里也没有 Close Window，给不了 Find / 拼写和语法 / 替换 / 朗读 /
/// 转换那五个子菜单与 Help 搜索框。所以这一次决定**不动它**。
/// 原生 Edit 菜单里那几项仍然是灰的 —— 那是 Flutter 层
/// `intentForMacOSSelector` 缺 `copy:`/`paste:`/`cut:`/`selectAll:` 造成的，
/// **应用内 `Cmd+C/V/X/A` 不受影响**（框架的 `DefaultTextEditingShortcuts`
/// 管着；详情页正文这一轮也接上了选区）。
///
/// ## 为什么发送是修饰键 + Enter
///
/// 裸 `Enter` 在编辑器里是换行、`Shift+Enter` 是软换行，都不能占。quill 那张
/// 表里 `enter` 只有**裸键**一条，所以 `Cmd/Ctrl+Enter` 会一路上行到写邮件页
/// 自己那层（不必走 `onKeyPressed`）。
Map<ShortcutActivator, Intent> mailShortcutsFor(TargetPlatform platform) {
  // mac 用 Command、其它一律 Control。Windows / Linux / Android / iOS 都走
  // 这一支 —— 它们共用同一套 `_clipboardShortcuts` 的约定。
  final mac = platform == TargetPlatform.macOS;
  SingleActivator mod(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, control: !mac, meta: mac, shift: shift);

  return <ShortcutActivator, Intent>{
    mod(LogicalKeyboardKey.keyN): const NewMailIntent(),
    mod(LogicalKeyboardKey.keyR): const ReplyMailIntent(),
    mod(LogicalKeyboardKey.keyD): const DeleteMailIntent(),
    mod(LogicalKeyboardKey.keyF, shift: true): const ForwardMailIntent(),
    mod(LogicalKeyboardKey.enter): const SendMailIntent(),
    mod(LogicalKeyboardKey.comma): const OpenSettingsIntent(),
    mod(LogicalKeyboardKey.keyW): const HideWindowIntent(),
  };
}
