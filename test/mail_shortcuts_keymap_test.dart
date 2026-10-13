// 键位表先当**纯表**钉住，别一上来就开 UI。三件最容易错的事：
//   ① 每个动作在每个平台上都要有一条 —— 漏了某一平台的表现是「按了没反应」，
//      而在 macOS 上开发的人根本看不出来；
//   ② mac 与 linux **不能用同一套修饰键**：mac 上 Ctrl+N/E/A/F/B/P 是
//      `_macShortcuts` 的 emacs 那一套，占了之后光标会乱跳；
//   ③ 我们**不截**剪贴板与撤销那几组键（截了就是把已经好的东西弄坏）。
import 'package:flutter/services.dart';
// `SingleActivator` / `Intent` 在 **widgets** 里，不在 services 里
// （`widgets/shortcuts.dart:433`）—— 少这个 import 的报错是
// 「Couldn't find constructor 'SingleActivator'」，看着像名字写错了。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/shortcuts/mail_intents.dart';

/// 两个激活器是不是同一组「键 + 修饰键」。
///
/// **不能写成 `a == b`**：`SingleActivator` **没有** `operator ==`
/// （`widgets/shortcuts.dart:433` 那个类里只有 `debugFillProperties` /
/// `accepts` / `serialize`），于是它按**身份**比 —— 两个字面量写得一模一样
/// 也是 `false`。探针实测过：`SingleActivator(keyN, meta: true) ==` 自己那一份
/// 是 `false`，而逐字段比出来的 `control/meta/shift` 完全一致。
/// （框架自己的 `Shortcuts` 不靠 map 的键相等，它是遍历 + `accepts`，
/// 所以生产代码不受这个坑影响；只有测试里这种「拿字面量去表里找」会踩。）
bool _sameKey(ShortcutActivator a, ShortcutActivator b) {
  if (a is! SingleActivator || b is! SingleActivator) return a == b;
  return a.trigger == b.trigger &&
      a.control == b.control &&
      a.meta == b.meta &&
      a.shift == b.shift &&
      a.alt == b.alt;
}

/// 表里有没有「这个激活器 → 这个动作」。
bool _has(
  Map<ShortcutActivator, Intent> map,
  ShortcutActivator activator,
  Type intent,
) =>
    map.entries.any(
      (e) => _sameKey(e.key, activator) && e.value.runtimeType == intent,
    );

void main() {
  const platforms = <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ];

  test('七个动作在每个平台上都有激活器', () {
    for (final platform in platforms) {
      final map = mailShortcutsFor(platform);
      final types = map.values.map((i) => i.runtimeType).toSet();
      for (final type in <Type>[
        NewMailIntent,
        ReplyMailIntent,
        ForwardMailIntent,
        DeleteMailIntent,
        SendMailIntent,
        OpenSettingsIntent,
        HideWindowIntent,
      ]) {
        expect(types, contains(type), reason: '$platform 上少了 $type');
      }
    }
  });

  test('macOS 用 Command，其它平台用 Control', () {
    // 同一个动作两边必须是**互斥**的修饰键。macOS 上给 control 版没有意义
    // （会被 `_macShortcuts` 里 emacs 那一套先接走），linux 上给 meta 版更是
    // 没人认 —— 这一条把「只写了一份、另一个平台照抄」钉死。
    expect(
      _has(
        mailShortcutsFor(TargetPlatform.macOS),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
        NewMailIntent,
      ),
      isTrue,
    );
    expect(
      _has(
        mailShortcutsFor(TargetPlatform.linux),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true),
        NewMailIntent,
      ),
      isTrue,
    );
    expect(
      _has(
        mailShortcutsFor(TargetPlatform.macOS),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true),
        NewMailIntent,
      ),
      isFalse,
      reason: 'macOS 上 Ctrl+N 是 emacs 的「下一行」，占了光标会乱跳',
    );
  });

  test('键位就是约定的那七个', () {
    // 写死到具体键上，不写成「表里有什么就是什么」—— 后者在键位被改掉时
    // 照样绿，等于没测。
    final mac = mailShortcutsFor(TargetPlatform.macOS);
    expect(
      _has(mac, const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
          NewMailIntent),
      isTrue,
    );
    expect(
      _has(mac, const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
          ReplyMailIntent),
      isTrue,
    );
    expect(
      _has(
        mac,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true),
        ForwardMailIntent,
      ),
      isTrue,
    );
    expect(
      _has(mac, const SingleActivator(LogicalKeyboardKey.keyD, meta: true),
          DeleteMailIntent),
      isTrue,
    );
    expect(
      _has(mac, const SingleActivator(LogicalKeyboardKey.enter, meta: true),
          SendMailIntent),
      isTrue,
    );
    // 两个「系统通用」的补位。`Cmd+,` 与 `Cmd+W` 都不在 XIB、不在
    // `_macShortcuts`、不在 quill 那张表里（详见 `mail_intents.dart` 的注释）。
    expect(
      _has(mac, const SingleActivator(LogicalKeyboardKey.comma, meta: true),
          OpenSettingsIntent),
      isTrue,
    );
    expect(
      _has(mac, const SingleActivator(LogicalKeyboardKey.keyW, meta: true),
          HideWindowIntent),
      isTrue,
    );
  });

  test('两个新键在其它平台上是 Control，不是 Meta', () {
    // 「macOS 用 Command，其它平台用 Control」那条只钉了 `N` —— 新加两个键时
    // 最容易犯的错是照抄 mac 那一份、把 `meta` 也抄过来（在 linux/windows 上
    // 就是个死键，而在 mac 上开发的人看不出来）。
    for (final platform in <TargetPlatform>[
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      final map = mailShortcutsFor(platform);
      expect(
        _has(map, const SingleActivator(LogicalKeyboardKey.comma, control: true),
            OpenSettingsIntent),
        isTrue,
        reason: '$platform 上少了 Ctrl+,',
      );
      expect(
        _has(map, const SingleActivator(LogicalKeyboardKey.keyW, control: true),
            HideWindowIntent),
        isTrue,
        reason: '$platform 上少了 Ctrl+W',
      );
    }
  });

  test('两个新键不与已有的七个撞', () {
    // 撞了的症状是「后写的把先写的盖掉」：`Shortcuts` 遍历表靠 `accepts`，
    // 同一个键有两个条目时哪一个生效取决于遍历顺序 —— 也就是用户看不见的
    // 一件随机的事。
    for (final platform in platforms) {
      final map = mailShortcutsFor(platform);
      final activators = map.keys.cast<SingleActivator>().toList();
      for (var i = 0; i < activators.length; i++) {
        for (var j = i + 1; j < activators.length; j++) {
          expect(
            _sameKey(activators[i], activators[j]),
            isFalse,
            reason: '$platform 上 ${activators[i].trigger} 被占了两次',
          );
        }
      }
    }
  });

  test('不截编辑、剪贴板与撤销那几组键', () {
    for (final platform in platforms) {
      final mac = platform == TargetPlatform.macOS;
      final map = mailShortcutsFor(platform);
      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyZ,
      ]) {
        final probe = SingleActivator(key, control: !mac, meta: mac);
        expect(
          map.keys.any((k) => _sameKey(k, probe)),
          isFalse,
          reason: '$platform 上 $key 必须留给编辑 / 剪贴板',
        );
      }
    }
  });

  test('发送是修饰键 + Enter，不是裸 Enter', () {
    final mac = mailShortcutsFor(TargetPlatform.macOS);
    expect(
      mac.keys.any(
        (k) => _sameKey(k, const SingleActivator(LogicalKeyboardKey.enter)),
      ),
      isFalse,
      reason: '裸 Enter 是换行',
    );
    expect(
      mac.keys.any(
        (k) => _sameKey(
          k,
          const SingleActivator(LogicalKeyboardKey.enter, shift: true),
        ),
      ),
      isFalse,
      reason: 'Shift+Enter 是软换行',
    );
  });

  test('每个动作只占一个键（没有别名）', () {
    // 别名会让「改键位要改两处」，而且两份迟早不一致。真要加强第二个键时，
    // 这条会红 —— 那时应当先想清楚「为什么需要两条路」。
    for (final platform in platforms) {
      final counts = <Type, int>{};
      for (final intent in mailShortcutsFor(platform).values) {
        counts.update(intent.runtimeType, (n) => n + 1, ifAbsent: () => 1);
      }
      for (final entry in counts.entries) {
        expect(entry.value, 1, reason: '$platform 上 ${entry.key} 占了多个键');
      }
    }
  });
}
