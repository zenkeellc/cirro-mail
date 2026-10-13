import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/suggest/mail_action.dart';

void main() {
  group('池子按状态过滤（spec §2.3）', () {
    List<MailAction> pool({
      bool isUnread = true,
      bool isStarred = false,
      bool starEnabled = true,
      bool hasBody = true,
    }) =>
        suggestActionPool(
          isUnread: isUnread,
          isStarred: isStarred,
          starEnabled: starEnabled,
          hasBody: hasBody,
        );

    test('未读、没星、有正文：去掉 markUnread / unstar', () {
      final p = pool();
      expect(p, contains(MailAction.markRead));
      expect(p, isNot(contains(MailAction.markUnread)));
      expect(p, contains(MailAction.star));
      expect(p, isNot(contains(MailAction.unstar)));
    });

    test('已读、已加星：去掉 markRead / star', () {
      final p = pool(isUnread: false, isStarred: true);
      expect(p, isNot(contains(MailAction.markRead)));
      expect(p, contains(MailAction.markUnread));
      expect(p, isNot(contains(MailAction.star)));
      expect(p, contains(MailAction.unstar));
    });

    test('实例没有星标能力：star 与 unstar 一起走', () {
      final p = pool(starEnabled: false);
      expect(p, isNot(contains(MailAction.star)));
      expect(p, isNot(contains(MailAction.unstar)));
    });

    test('正文一个字都拿不到：reply 与 forward 一起走', () {
      final p = pool(hasBody: false);
      expect(p, isNot(contains(MailAction.reply)));
      expect(p, isNot(contains(MailAction.forward)));
    });

    test('none / remind / delete 无条件在池子里', () {
      for (final combo in <List<Object>>[
        <Object>[true, false, true, true],
        <Object>[false, true, false, false],
        <Object>[true, true, false, true],
      ]) {
        final p = pool(
          isUnread: combo[0] as bool,
          isStarred: combo[1] as bool,
          starEnabled: combo[2] as bool,
          hasBody: combo[3] as bool,
        );
        expect(p, contains(MailAction.none));
        expect(p, contains(MailAction.remind));
        expect(p, contains(MailAction.delete));
      }
    });

    test('顺序稳定：过滤只删条目，不打乱先后', () {
      expect(pool(), <MailAction>[
        MailAction.reply,
        MailAction.forward,
        MailAction.remind,
        MailAction.delete,
        MailAction.markRead,
        MailAction.star,
        MailAction.none,
      ]);
    });
  });

  // spec §2.3 末段那个论断是「不需要写空池兜底」的依据 —— 用穷举把它钉住：
  // 四个布尔的全 16 种组合，池子一次都不能空。
  test('池子非空的性质：四个条件所有 16 种组合枚举一遍', () {
    var checked = 0;
    for (final isUnread in <bool>[true, false]) {
      for (final isStarred in <bool>[true, false]) {
        for (final starEnabled in <bool>[true, false]) {
          for (final hasBody in <bool>[true, false]) {
            final p = suggestActionPool(
              isUnread: isUnread,
              isStarred: isStarred,
              starEnabled: starEnabled,
              hasBody: hasBody,
            );
            expect(
              p,
              isNotEmpty,
              reason: 'isUnread=$isUnread isStarred=$isStarred '
                  'starEnabled=$starEnabled hasBody=$hasBody 滤空了',
            );
            expect(p, contains(MailAction.none));
            checked++;
          }
        }
      }
    }
    expect(checked, 16);
  });

  group('id 的往返', () {
    test('每个 id 都能反查回枚举', () {
      for (final action in MailAction.values) {
        expect(MailAction.byId(action.id), action);
      }
    });

    test('认不出来的 id 返回 null，且不认大小写/空白之外的花样', () {
      expect(MailAction.byId('Reply'), isNull);
      expect(MailAction.byId('reply '), MailAction.reply);
      expect(MailAction.byId('archive'), isNull);
      expect(MailAction.byId(''), isNull);
    });

    test('prompt 行每一条都以自己的 id 开头', () {
      for (final action in MailAction.values) {
        expect(action.promptLine, startsWith('- ${action.id}：'));
      }
    });
  });

  group('面板图标', () {
    test('每个动作的图标两两不同', () {
      final icons = <IconData>{
        for (final action in MailAction.values) iconOf(action),
      };
      expect(
        icons,
        hasLength(MailAction.values.length),
        reason: '有两个动作用了同一个图标 —— switch 的穷举管不住这个',
      );
    });

    test('星标那一对按信件状态画：star 空心、unstar 实心', () {
      // `star` 这个动作只在「这封信还没加星」时才在池子里
      // （`suggestActionPool` 的过滤保证了这一点），所以它画空心；
      // 与详情页顶栏那颗星、列表行菜单那一对是同一个约定。
      expect(iconOf(MailAction.star), Icons.star_border);
      expect(iconOf(MailAction.unstar), Icons.star);
    });
  });
}
