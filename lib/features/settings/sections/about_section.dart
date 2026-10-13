import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../l10n/app_localizations.dart';

/// 设置 → 关于。
///
/// 一行：App 名 + 版本号。`PackageInfo` 是**有最好、没有也行**的信息，
/// 取不到时退化成只有「版本」两个字，不阻塞这一页。
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    // 取版本号是「有最好、没有也行」的信息，失败不该影响设置页。
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _info = info);
    }).catchError((Object error) {
      debugPrint('PackageInfo 不可用：$error');
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final info = _info;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(l10n.appTitle),
          subtitle: Text(
            info == null
                ? l10n.version
                : '${l10n.version} ${info.version}+${info.buildNumber}',
          ),
        ),
      ],
    );
  }
}
