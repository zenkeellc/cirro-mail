import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('条目 JSON 往返一字不差', () {
    const item = RoamConfigItem(
      key: 'app.appearance',
      group: 'appearance',
      secret: false,
      data: <String, Object?>{
        'themeMode': 'dark',
        'themePackId': null,
        'locale': 'zh',
      },
    );
    final decoded = RoamConfigItem.fromJson(item.toJson())!;
    expect(decoded.key, 'app.appearance');
    expect(decoded.group, 'appearance');
    expect(decoded.secret, isFalse);
    expect(decoded.toJson(), item.toJson());
  });

  test('不认识的字段原样留住（前向兼容）', () {
    final item = RoamConfigItem.fromJson(<String, Object?>{
      'key': 'app.reading',
      'group': 'reading',
      'secret': false,
      'data': <String, Object?>{
        'pollSeconds': 60,
        'futureFlag': true,
        'futureList': <Object?>[1],
      },
    })!;
    final data = item.toJson()['data']! as Map<String, Object?>;
    expect(data['futureFlag'], isTrue);
    expect(data['futureList'], <Object?>[1]);
  });

  test('坏数据给 null、不抛；secret 只认 true；group 缺失退回 meta', () {
    expect(RoamConfigItem.fromJson(null), isNull);
    expect(RoamConfigItem.fromJson('nope'), isNull);
    expect(
      RoamConfigItem.fromJson(<String, Object?>{
        'key': ' ',
        'data': <String, Object?>{},
      }),
      isNull,
    );
    expect(
      RoamConfigItem.fromJson(<String, Object?>{'key': 'a'}),
      isNull,
    );
    final loose = RoamConfigItem.fromJson(<String, Object?>{
      'key': 'x',
      'data': <String, Object?>{},
      'secret': 'yes',
    })!;
    expect(loose.secret, isFalse);
    expect(loose.group, 'meta');
  });

  test('实例 key：小写、去路径、去默认端口、没邮箱给 null', () {
    expect(
      roamInstanceKey(baseUrl: 'https://Mail.Example.com/api', email: 'A@B.com'),
      'https://mail.example.com|a@b.com',
    );
    expect(
      roamInstanceKey(baseUrl: 'https://mail.example.com/api/', email: 'a@b.com'),
      'https://mail.example.com|a@b.com',
    );
    expect(
      roamInstanceKey(baseUrl: 'mail.example.com', email: 'a@b.com'),
      'https://mail.example.com|a@b.com',
    );
    expect(
      roamInstanceKey(baseUrl: 'http://example.com:8080/api', email: 'a@b.com'),
      'http://example.com:8080|a@b.com',
    );
    expect(
      roamInstanceKey(baseUrl: 'https://example.com:443/api', email: 'a@b.com'),
      'https://example.com|a@b.com',
    );
    expect(roamInstanceKey(baseUrl: 'https://a.com/api', email: '  '), isNull);
    expect(roamInstanceKey(baseUrl: '', email: 'a@b.com'), isNull);
    expect(roamInstanceKey(baseUrl: 'ftp://a.com/api', email: 'a@b.com'), isNull);
  });
}
