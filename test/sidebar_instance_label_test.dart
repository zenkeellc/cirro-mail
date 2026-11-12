import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/shell/sidebar_mailboxes.dart';

/// 侧栏实例行的标签：**重名才补登录邮箱**。
///
/// 为什么值得钉：配置漫游恢复出来的实例只带备注名，两台都叫「GUIKE」时
/// 侧栏两行一模一样 —— 用户会以为其中一台是重复项，或者以为另一台的邮箱
/// 丢了（2026-11-12 真机反馈的读法）。
void main() {
  Profile profile({
    String name = '',
    String email = '',
    String serverTitle = '',
  }) => Profile(
    id: 'p-$name-$email',
    baseUrl: 'https://mail.gui-ke.com/api',
    name: name,
    email: email,
    serverTitle: serverTitle,
  );

  test('不重名时不重复拼邮箱', () {
    final p = profile(name: 'GUIKE', email: 'kedong@gui-ke.com');
    expect(sidebarInstanceLabel(p, duplicated: false), 'GUIKE');
  });

  test('重名时补上登录邮箱（用户据此分辨两个同名实例）', () {
    final p = profile(name: 'GUIKE', email: 'admin@en.ke');
    expect(sidebarInstanceLabel(p, duplicated: true), 'GUIKE · admin@en.ke');
  });

  test('没有邮箱 / 名字本身就是邮箱时都不加后缀', () {
    expect(
      sidebarInstanceLabel(profile(name: 'GUIKE'), duplicated: true),
      'GUIKE',
    );
    expect(
      sidebarInstanceLabel(profile(email: 'admin@en.ke'), duplicated: true),
      'admin@en.ke',
    );
  });

  test('重名判定大小写不敏感，空显示名不参与', () {
    final dup = duplicatedInstanceNames(<Profile>[
      profile(name: 'GUIKE', email: 'a@gui-ke.com'),
      profile(name: 'guike', email: 'b@gui-ke.com'),
      profile(name: 'riqimi', email: 'c@riqimi.com'),
      profile(email: ''),
    ]);
    expect(dup, <String>{'guike'});
  });
}
