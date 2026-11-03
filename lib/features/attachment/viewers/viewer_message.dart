import 'package:flutter/material.dart';

/// 预览页上「说一句就完了」的那种状态：文件不在了、这格式解不开、这封信没有
/// 正文。
///
/// 收在一处而不是每个 viewer 各写一份：五个 viewer 里曾经有四份长得几乎一样的
/// `Center(Column(Icon, SizedBox, Text))`，改一次字号要改四处。
class ViewerMessage extends StatelessWidget {
  const ViewerMessage({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
