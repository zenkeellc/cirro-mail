import 'package:flutter/material.dart';

import '../../core/theme/avatar_colors.dart';

/// 列表行左侧的发件人首字母头像。
///
/// 只用在一处（邮件列表），但单独成文件的原因与 `_InstanceChip` 那些不一样：
/// 它是一个**可测的视觉单元** —— 颜色稳定性和对比度都有测试钉着
/// （`avatar_colors_test.dart`），放在 `mail_row_tile.dart` 里会让那个文件
/// 继续变胖。
///
/// 头像**不表达已读状态**：未读由标题行那个信封图标承担（见 `MailRowTile`）。
/// 一个圆形里的角标、描边、底色同时表达三件事，最后一件都读不出来。
class SenderAvatar extends StatelessWidget {
  const SenderAvatar({
    super.key,
    required this.label,
    String? seed,
    this.diameter = 40,
  }) : seed = seed ?? label;

  /// 头像上那个字取这里：优先显示名，没有才用地址。
  final String label;

  /// 取色用这个，传**发件地址**。
  ///
  /// 两个参数分开是因为它们是两件事：字要给人看（「张」比「z」认得快），
  /// 色要**稳定唯一**（同一个地址永远同色 —— 换个昵称不该变色；而不同人
  /// 共用「客服」这种显示名时，按名字取色会把它们混成同一个人）。
  final String seed;

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AvatarColors.of(seed),
        shape: BoxShape.circle,
      ),
      child: Text(
        AvatarColors.initial(label),
        // 字号跟着直径走（40pt 时是 16），这样改尺寸不用再调一遍。
        style: TextStyle(
          color: Colors.white,
          fontSize: diameter * 0.4,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
