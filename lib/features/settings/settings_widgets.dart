import 'package:flutter/material.dart';

/// 设置页各分类里共用的分组小标题。
///
/// 实际用它的只有两个文件、**一共七处调用**：`ai_section.dart` 五处、
/// `compose_section.dart` 两处（写邮件那一类加进来时多出来的两处）。
/// 以前它在 `settings_screen.dart` 与 AI 那一页里各有一份私有实现（后者
/// 还特意写了一行注释说不复用，理由是「换来的收益抵不上多一个公共
/// widget」）；现在它在 `sections/` 下共享，那个理由反过来了。
///
/// 用法：分类正文自己排 `ListView`，每段前面放一个它。
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
