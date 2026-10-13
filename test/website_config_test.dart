// 「要不要人机验证」这件事，网页端 `submit()` 的判据是：
//
//   addEmailVerify == 0                                // OPEN：恒要
//   || (addEmailVerify == 2 && addVerifyOpen)          // COUNT：本 IP 已到阈值
//
// 而 App 今天**根本没有解析 `addVerifyOpen`**（`raw` 里有，字段没有）。
// 三个值各自的含义（服务端 `settingConst`）：
//   addEmailVerify: 0 = OPEN, 1 = CLOSE, 2 = COUNT
// 线上那台实例是 1（CLOSE），所以「今天不需要」——但别的实例会需要，
// 而判错的两种方向都很糟：误判成「需要」= 用户平白被赶去网页端；
// 误判成「不需要」= 用户点「添加」拿到一个 400 emptyBotToken。
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/website_config.dart';

WebsiteConfig _config({
  required int addEmailVerify,
  required Object? addVerifyOpen,
}) =>
    WebsiteConfig.fromJson(<String, dynamic>{
      'addEmailVerify': addEmailVerify,
      'addVerifyOpen': addVerifyOpen,
    });

void main() {
  group('needsTurnstile', () {
    test('addEmailVerify == 0（OPEN）：恒要，与 addVerifyOpen 无关', () {
      expect(_config(addEmailVerify: 0, addVerifyOpen: true).needsTurnstile,
          isTrue);
      expect(_config(addEmailVerify: 0, addVerifyOpen: false).needsTurnstile,
          isTrue);
      expect(_config(addEmailVerify: 0, addVerifyOpen: null).needsTurnstile,
          isTrue);
    });

    test('addEmailVerify == 1（CLOSE）：不要', () {
      expect(_config(addEmailVerify: 1, addVerifyOpen: true).needsTurnstile,
          isFalse);
      expect(_config(addEmailVerify: 1, addVerifyOpen: null).needsTurnstile,
          isFalse);
    });

    test('addEmailVerify == 2（COUNT）：看 addVerifyOpen 这个 per-IP 快照', () {
      expect(_config(addEmailVerify: 2, addVerifyOpen: true).needsTurnstile,
          isTrue);
      expect(_config(addEmailVerify: 2, addVerifyOpen: false).needsTurnstile,
          isFalse);
      // 字段缺失（老版本实例）→ 当作「还没到阈值」：这是**乐观**的那一侧，
      // 与能力探测「unknown → 乐观可用」同一条规矩。代价是偶尔吃一个
      // 400 emptyBotToken，而 §5.4 已经把那个 400 也接到同一条降级告示上。
      expect(_config(addEmailVerify: 2, addVerifyOpen: null).needsTurnstile,
          isFalse);
    });
  });

  group('addVerifyOpen 的解析', () {
    test('真值 / 1 / "1" 都算开', () {
      expect(_config(addEmailVerify: 2, addVerifyOpen: true).addVerifyOpen,
          isTrue);
      expect(_config(addEmailVerify: 2, addVerifyOpen: 1).addVerifyOpen, isTrue);
      expect(_config(addEmailVerify: 2, addVerifyOpen: '1').addVerifyOpen,
          isTrue);
    });

    test('假值 / 0 / "0" / null 都算关', () {
      for (final raw in <Object?>[false, 0, '0', null, '']) {
        expect(
          _config(addEmailVerify: 2, addVerifyOpen: raw).addVerifyOpen,
          isFalse,
          reason: '$raw',
        );
      }
    });
  });

  group('既有的开关不受影响', () {
    test('addMailboxEnabled 仍是 addEmail == 0 && manyEmail == 0', () {
      expect(
        WebsiteConfig.fromJson(<String, dynamic>{
          'addEmail': 0,
          'manyEmail': 0,
        }).addMailboxEnabled,
        isTrue,
      );
      expect(
        WebsiteConfig.fromJson(<String, dynamic>{
          'addEmail': 1,
          'manyEmail': 0,
        }).addMailboxEnabled,
        isFalse,
      );
      expect(
        WebsiteConfig.fromJson(<String, dynamic>{
          'addEmail': 0,
          'manyEmail': 1,
        }).addMailboxEnabled,
        isFalse,
      );
    });
  });
}
