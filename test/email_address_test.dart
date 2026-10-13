// 地址规则的**唯一实现处**就是 `lib/core/util/email_address.dart`，这一条
// 钉的是「它现在是几份实现里最权威的那一份」。
//
// 为什么必须逐字照抄服务端而不是「另写一个差不多的」：客户端用一套规则预
// 校验、服务端用另一套，两者的差集里的每一个地址都会给出两种结论 ——
// 本地拦下的地址服务端其实收，或者反过来本地放过去、服务端回 501 让人
// 一头雾水。规格 §5.2 已经把「逐字照抄」定成契约。
//
// 正则原文（`mail-worker/src/utils/verify-utils.js`）：
//   /^[a-zA-Z0-9!#$%&'*+/=?^_`{|}~.-]+@([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$/
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/util/email_address.dart';

void main() {
  group('isEmailAddress', () {
    test('服务端会收的，客户端也必须收', () {
      for (final ok in <String>[
        'a@b.co',
        'admin@example.com',
        'kedong+tag@example.com',
        "o'brien@example.org",
        'a!#\$%&\'*+/=?^_`{|}~-@example.com',
        'x@sub.domain.example.com',
      ]) {
        expect(isEmailAddress(ok), isTrue, reason: ok);
      }
    });

    test('服务端会挡的，客户端也必须挡', () {
      for (final bad in <String>[
        '', // 空
        'nope', // 没有 @
        '@example.com', // 本地部分为空（正则的 `+` 要求至少一个字符）
        'a@', // 域名部分为空
        'a@b', // 顶级域不足两位
        'a@b.c', // 顶级域只有一个字符
        'a b@example.com', // 空格不在字符集里
        'a@b..com', // 空标签：`([a-zA-Z0-9-]+\.)+` 每段至少要一个字符
        'a@@example.com',
        'a@example.com ', // 尾随空格 —— 服务端不 trim
      ]) {
        expect(isEmailAddress(bad), isFalse, reason: '"$bad"');
      }
    });

    test('不做 trim、不做小写归一 —— 服务端就是这么判的', () {
      // `normalizeEmail` 是**归属判断**用的，与**合法性**是两件事。
      // 在这里顺手 trim 一下会让「本地放过去、服务端挡回来」，
      // 正好是这条契约想避免的那类偏差。
      expect(isEmailAddress(' a@b.co'), isFalse);
      expect(isEmailAddress('A@B.CO'), isTrue, reason: '大写在字符集里，合法');
    });
  });

  group('既有的三个函数不动', () {
    test('normalizeEmail / baseEmailOf / accountIdForEmail 行为不变', () {
      expect(normalizeEmail('  A@B.co '), 'a@b.co');
      expect(baseEmailOf('news+abc@x.com'), 'news@x.com');
      expect(baseEmailOf('nope'), 'nope');
      expect(
        accountIdForEmail(<String, int>{'news@x.com': 7}, 'news+abc@x.com'),
        7,
      );
      expect(accountIdForEmail(<String, int>{'a@x.com': 1}, 'a+b@x.com'), 1);
    });
  });
}
