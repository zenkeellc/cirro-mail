import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';

/// `MailStore` 的**契约**。
///
/// 它由核心实现（drift 适配器）、扩展消费（搜索索引的灌水器）。所以契约得有
/// 两处落地：
/// - 契约本身（这个文件）：用内存假实现钉住语义；
/// - 核心实现对不对得上（`mail-app/test/core_mail_store_test.dart`）。
///
/// 分开的理由是**失败时的指向**：灌水器的 bug 大致分两类，一类是「库给的
/// 顺序/水位线不是我以为的那样」（在这里红），一类是「适配器把列折错了」
/// （在核心那边红）。混在一起的话，两边都得先读一遍才知道是谁坏了。
///
/// 这里钉的是**灌水器真正依赖**的那几条，不是把接口抄一遍：
/// 1. `pageAfter` 的键序是 `(profileId, emailId)` 二元组，不是 id 一维；
/// 2. 不存在的游标不是错误；
/// 3. `updatedSince` 按 `cachedAt` 升序；
/// 4. `changes` 是**广播**流，冷订阅收不到历史 —— 灌水器的
///    「先冷扫、再订阅」那个顺序就是为它写的。
void main() {
  group('LocalMail', () {
    test('常量与服务端协议一致（0=收件 / 1=发件；unread 0=未读）', () {
      expect(LocalMail.kTypeReceive, 0);
      expect(LocalMail.kTypeSend, 1);
      expect(LocalMail.kUnread, 0);
      expect(LocalMail.kRead, 1);
    });

    test('isUnread / isReceive / hasCode 的判据', () {
      const receive = LocalMail(profileId: 'p', emailId: 1, code: '1234');
      expect(receive.isUnread, isTrue);
      expect(receive.isReceive, isTrue);
      expect(receive.hasCode, isTrue);

      const read = LocalMail(
        profileId: 'p',
        emailId: 2,
        unread: LocalMail.kRead,
        type: LocalMail.kTypeSend,
      );
      expect(read.isUnread, isFalse);
      expect(read.isReceive, isFalse);
      expect(read.hasCode, isFalse);
    });

    /// `hasAnyBody` 与 `hasFullBody` 问的**不是同一件事**，而且这个区别是
    /// 灌水器决定「要不要去剥 HTML」的依据。
    test('hasAnyBody 看手上有没有内容，hasFullBody 看拿没拿到完整版', () {
      // 拿到了完整版、但服务端没给纯文本（真机库里 26% 的行如此）。
      const htmlOnly = LocalMail(
        profileId: 'p',
        emailId: 1,
        content: '<p>hi</p>',
        hasFullBody: true,
      );
      expect(htmlOnly.hasAnyBody, isTrue);
      expect(htmlOnly.hasFullBody, isTrue);

      // 摘要行：还没有正文，但也不能说「它没正文」。
      const summary = LocalMail(profileId: 'p', emailId: 2);
      expect(summary.hasAnyBody, isFalse);
      expect(summary.hasFullBody, isFalse);

      // 空串不算有内容 —— 服务端偶尔会发空字符串而不是省略字段。
      const empty = LocalMail(profileId: 'p', emailId: 3, bodyText: '');
      expect(empty.hasAnyBody, isFalse);
    });
  });

  group('MailStoreEvent', () {
    test('三个事件都带 profileId，且 reset 与那两条不同型', () {
      final upserted = MailUpserted('p', <int>[1]);
      final deleted = MailDeleted('p', <int>[1]);
      const reset = MailStoreReset('p');

      expect(upserted.profileId, 'p');
      expect(deleted.profileId, 'p');
      expect(reset.profileId, 'p');

      // sealed：`switch` 是穷尽的。写到这里是为了让「将来加了第四种事件」
      // 在编译期就红，而不是在某个 switch 的 default 里被悄悄吞掉。
      for (final MailStoreEvent event in <MailStoreEvent>[
        upserted,
        deleted,
        reset,
      ]) {
        final kind = switch (event) {
          MailUpserted() => 'upserted',
          MailDeleted() => 'deleted',
          MailStoreReset() => 'reset',
        };
        expect(kind, isNotEmpty);
      }
    });

    test('两条带 id 的事件各自保留那一批', () {
      expect(MailUpserted('p', <int>[1, 2]).emailIds, <int>[1, 2]);
      expect(MailDeleted('p', <int>[3]).emailIds, <int>[3]);
    });
  });

  group('实现方必须满足的语义（对着假实现验）', () {
    late _FakeStore store;

    setUp(() {
      store = _FakeStore();
      store
        ..add('a', 1)
        ..add('a', 2)
        ..add('b', 1)
        ..add('c', 7);
    });

    test('pageAfter 的键序是 (profileId, emailId) 升序', () async {
      final page = await store.pageAfter();
      expect(
        page.map((m) => '${m.profileId}/${m.emailId}'),
        <String>['a/1', 'a/2', 'b/1', 'c/7'],
      );
    });

    /// **这条是灌水器最依赖的一条。**
    ///
    /// `emailId` 只在同一个实例内有序，所以「翻下一页」必须传回
    /// **上一页最后一行的两个值**。只比 id 会在实例边界处漏行 —— 而漏的是
    /// 那种「id 恰好比较小」的信，看起来完全正常。
    test('翻页游标越过实例边界时不漏行', () async {
      final first = await store.pageAfter(limit: 2);
      expect(first.map((m) => '${m.profileId}/${m.emailId}'), <String>['a/1', 'a/2']);

      final second = await store.pageAfter(
        afterProfileId: first.last.profileId,
        afterEmailId: first.last.emailId,
        limit: 2,
      );
      expect(
        second.map((m) => '${m.profileId}/${m.emailId}'),
        <String>['b/1', 'c/7'],
        reason: 'b/1 的 id 比 a/2 小，只按 id 比大小就会跳过它',
      );
    });

    test('游标落在不存在的行上不是错误', () async {
      expect(
        await store.pageAfter(afterProfileId: 'zzz', afterEmailId: 999),
        isEmpty,
      );
      expect(
        (await store.pageAfter(afterProfileId: 'a', afterEmailId: 1))
            .map((m) => '${m.profileId}/${m.emailId}'),
        <String>['a/2', 'b/1', 'c/7'],
      );
    });

    test('updatedSince 按 cachedAt 升序', () async {
      final base = DateTime.utc(2026, 1, 1);
      store
        ..stamp('a', 2, base.add(const Duration(hours: 3)))
        ..stamp('b', 1, base.add(const Duration(hours: 1)))
        ..stamp('c', 7, base.add(const Duration(hours: 2)));

      final rows = await store.updatedSince(base);
      expect(
        rows.map((m) => '${m.profileId}/${m.emailId}'),
        <String>['b/1', 'c/7', 'a/2'],
      );
    });

    /// 广播流：**冷订阅收不到历史**。
    ///
    /// 这一条不是「实现者可以随便选」的细节，而是灌水器那两行代码的顺序
    /// 依据（先冷扫一遍全量、再订阅增量）。反过来的话，冷扫期间发生的
    /// 变更就永远丢了 —— 而且那段时间正好是同步最活跃的时候。
    test('changes 是广播流：订阅之前发的事件收不到', () async {
      final late = <MailStoreEvent>[];
      store.emit(MailUpserted('a', <int>[1]));
      final sub = store.changes().listen(late.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(late, isEmpty);

      store.emit(MailUpserted('a', <int>[2]));
      await Future<void>.delayed(Duration.zero);
      expect((late.single as MailUpserted).emailIds, <int>[2]);
    });

    test('changes 是广播流：多个订阅者各收到一份', () async {
      final a = <MailStoreEvent>[];
      final b = <MailStoreEvent>[];
      final sa = store.changes().listen(a.add);
      final sb = store.changes().listen(b.add);
      addTearDown(sa.cancel);
      addTearDown(sb.cancel);

      store.emit(const MailStoreReset('a'));
      await Future<void>.delayed(Duration.zero);
      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });
  });
}

/// 一个**诚实的**内存实现：它按契约办事，所以契约写错了（或者它自己写错了）
/// 都会在这些用例里现形。
class _FakeStore implements MailStore {
  /// `(profileId, emailId)` → 这一行。
  final Map<String, LocalMail> _rows = <String, LocalMail>{};

  /// `(profileId, emailId)` → 本地写入时间（`updatedSince` 用）。
  final Map<String, DateTime> _cachedAt = <String, DateTime>{};

  final StreamController<MailStoreEvent> _controller =
      StreamController<MailStoreEvent>.broadcast();

  static String _key(String profileId, int emailId) => '$profileId/$emailId';

  /// 按契约的键序排好的一串 key。
  List<String> get _ordered {
    final keys = _rows.keys.toList()
      ..sort((x, y) {
        final (px, ix) = _split(x);
        final (py, iy) = _split(y);
        final byProfile = px.compareTo(py);
        return byProfile != 0 ? byProfile : ix.compareTo(iy);
      });
    return keys;
  }

  static (String, int) _split(String key) {
    final at = key.lastIndexOf('/');
    return (key.substring(0, at), int.parse(key.substring(at + 1)));
  }

  void add(String profileId, int emailId) {
    _rows[_key(profileId, emailId)] =
        LocalMail(profileId: profileId, emailId: emailId);
  }

  void stamp(String profileId, int emailId, DateTime at) {
    _cachedAt[_key(profileId, emailId)] = at;
  }

  /// 直接往广播流里丢 —— 没有监听者时它自己就丢了，这正是要钉的那条语义。
  void emit(MailStoreEvent event) => _controller.add(event);

  @override
  Future<List<LocalMail>> pageAfter({
    String? profileId,
    String? afterProfileId,
    int afterEmailId = 0,
    int limit = 500,
    bool withContent = true,
  }) async {
    final out = <LocalMail>[];
    for (final key in _ordered) {
      final (p, id) = _split(key);
      if (profileId != null && p != profileId) continue;
      if (afterProfileId != null) {
        // 二元组比较：profile 大的直接过；profile 相等再比 id。
        final byProfile = p.compareTo(afterProfileId);
        if (byProfile < 0) continue;
        if (byProfile == 0 && id <= afterEmailId) continue;
      }
      final row = _rows[key]!;
      out.add(withContent
          ? row
          : LocalMail(
              profileId: row.profileId,
              emailId: row.emailId,
              accountId: row.accountId,
              type: row.type,
              unread: row.unread,
              isStar: row.isStar,
              sendEmail: row.sendEmail,
              name: row.name,
              subject: row.subject,
              toEmail: row.toEmail,
              toName: row.toName,
              mailboxEmail: row.mailboxEmail,
              code: row.code,
              hasFullBody: row.hasFullBody,
              sentAt: row.sentAt,
              cachedAt: row.cachedAt,
            ));
      if (out.length >= limit) break;
    }
    return out;
  }

  @override
  Future<int> count({String? profileId}) async => _rows.keys
      .where((k) => profileId == null || _split(k).$1 == profileId)
      .length;

  @override
  Future<Set<int>> existingEmailIds(String profileId, Iterable<int> emailIds) async =>
      <int>{
        for (final id in emailIds)
          if (_rows.containsKey(_key(profileId, id))) id,
      };

  @override
  Future<List<LocalMail>> updatedSince(DateTime since, {String? profileId}) async {
    final hits = <MapEntry<String, DateTime>>[
      for (final entry in _cachedAt.entries)
        if (entry.value.isAfter(since) &&
            (profileId == null || _split(entry.key).$1 == profileId))
          entry,
    ]..sort((a, b) => a.value.compareTo(b.value));
    return <LocalMail>[for (final hit in hits) _rows[hit.key]!];
  }

  @override
  Stream<MailStoreEvent> changes() => _controller.stream;

  Future<void> dispose() => _controller.close();
}
