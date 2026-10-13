import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/theme/avatar_colors.dart';

/// 头像色板的两条硬要求：**同一个地址永远同色**（跨进程、跨版本、跨平台）
/// 与**白字压得住**（对比度）。
///
/// 两条都容易被一次「顺手优化」破坏，而且破坏了不会立刻看出来：
/// 前者要等到用户升级 App 之后才发现整列头像换了颜色；后者只有特定几个
/// 颜色不够，肉眼在某一台显示器上未必分得出。
void main() {
  group('取色', () {
    test('同一个地址永远同一个颜色，且大小写/空白不参与', () {
      final base = AvatarColors.of('Bob@Example.com');

      expect(AvatarColors.of('bob@example.com'), base);
      expect(AvatarColors.of('  BOB@EXAMPLE.COM  '), base);
      expect(AvatarColors.of('bob@example.com'), base,
          reason: '反复调用必须稳定 —— 哈希里不能有随机成分');
    });

    test('用 FNV-1a 而不是 String.hashCode（跨版本的稳定性）', () {
      // 这一条是**字面值断言**，看着像在重复实现，但它钉的正是那个理由：
      // `String.hashCode` 不保证跨 Dart 版本稳定，一旦有人把它换回去，
      // 所有人列表里的头像会集体变色。下面的数字一旦变了就说明算法被改过。
      expect(AvatarColors.indexOf('alice@example.com'), 2);
      expect(AvatarColors.indexOf('bob@example.com'), 9);
      expect(AvatarColors.indexOf(''), 1);
    });

    test('不同的地址不会全都撞在同一个颜色上', () {
      final colors = <int>{
        for (var i = 0; i < 200; i++) AvatarColors.indexOf('user$i@example.com'),
      };
      expect(colors.length, greaterThan(4),
          reason: '200 个地址只落到 4 个色上，说明哈希是坏的');
    });

    test('色板本身：每个颜色都能被取到（没有永远取不到的项）', () {
      final hit = <int>{for (var i = 0; i < 5000; i++) AvatarColors.indexOf('a$i@x.com')};
      expect(hit.length, AvatarColors.length);
    });
  });

  group('白字对比度', () {
    test('每个底色压白字都 ≥ 4.5:1（WCAG AA 正文级）', () {
      for (final color in AvatarColors.palette) {
        expect(_contrastWithWhite(color), greaterThanOrEqualTo(4.5),
            reason: '$color 上的白字读不清 —— 换成更深的色，'
                '或者把 SenderAvatar 的文字颜色换成 onDark 的计算色');
      }
    });
  });

  group('首字母', () {
    test('空字符串回落 ?（不能是空白圆）', () {
      expect(AvatarColors.initial(''), '?');
      expect(AvatarColors.initial('   '), '?');
    });

    test('取第一个字而不是第一个 code unit', () {
      // 中文、emoji 都是多 code unit 的，`[0]` 会切出半个字符。
      expect(AvatarColors.initial('张三'), '张');
      expect(AvatarColors.initial('👍赞'), '👍');
    });

    test('拉丁字母转大写', () {
      expect(AvatarColors.initial('bob'), 'B');
    });
  });
}

/// WCAG 相对亮度对比度。手写而不是引依赖：这里有测试就够，不值得多一个包。
double _contrastWithWhite(Color color) {
  final l1 = 1.0; // 白
  final l2 = _luminance(color);
  return (l1 + 0.05) / (l2 + 0.05);
}

double _luminance(Color color) {
  double channel(double v) {
    v = v / 255.0;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(color.r * 255) +
      0.7152 * channel(color.g * 255) +
      0.0722 * channel(color.b * 255);
}
