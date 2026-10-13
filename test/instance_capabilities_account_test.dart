// 「这个账号能不能加/删/改这台实例上的邮箱」是**三条不同的闸**（规格 §3），
// 合成一个 `canManage` 就是把「实例关掉了添加」与「这个账号没权限」说成
// 同一句话 —— 而它们要给用户看的提示完全不同。
//
// 这一组钉三件事：① 三个字段能往返序列化；② **老行兼容** ——`capabilities`
// 表里已有的行根本没有这三个键，读出来必须是 `unknown`（乐观可用），不能抛；
// ③ `addMailboxDisabledByConfig` 是站点级开关，与 perm 无关。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/user_info.dart';
import 'package:mail_app/data/models/website_config.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';

void main() {
  group('序列化往返', () {
    test('三个 ProbeState 能 toJson → fromJson', () {
      const caps = InstanceCapabilities(
        hasAccountAdd: ProbeState.available,
        hasAccountDelete: ProbeState.denied,
        hasAccountRename: ProbeState.absent,
        addMailboxDisabledByConfig: true,
      );
      final back = InstanceCapabilities.fromJson(caps.toJson());
      expect(back.hasAccountAdd, ProbeState.available);
      expect(back.hasAccountDelete, ProbeState.denied);
      expect(back.hasAccountRename, ProbeState.absent);
      expect(back.addMailboxDisabledByConfig, isTrue);
    });

    test('toJson 里真的有这四个键', () {
      final json = const InstanceCapabilities().toJson();
      for (final key in <String>[
        'hasAccountAdd',
        'hasAccountDelete',
        'hasAccountRename',
        'addMailboxDisabledByConfig',
      ]) {
        expect(json.containsKey(key), isTrue, reason: key);
      }
    });

    test('copyWith 是全字段手写的 —— 新字段必须跟着走', () {
      // 这条看起来多余，其实是最容易出的错：`copyWith` 少写一个字段，
      // 那个字段会在**每一次局部更新**时被打回默认值。`probe()` 一路都是
      // `caps = caps.copyWith(...)`，漏一个就静默丢结论。
      const caps = InstanceCapabilities(
        hasAccountAdd: ProbeState.available,
        hasAccountDelete: ProbeState.available,
        hasAccountRename: ProbeState.available,
        addMailboxDisabledByConfig: true,
      );
      final next = caps.copyWith(hasStar: ProbeState.available);
      expect(next.hasAccountAdd, ProbeState.available);
      expect(next.hasAccountDelete, ProbeState.available);
      expect(next.hasAccountRename, ProbeState.available);
      expect(next.addMailboxDisabledByConfig, isTrue);
    });
  });

  group('老行兼容（回归）', () {
    test('缺四个键的旧 payload → unknown + false，不抛', () {
      // 本机 App 库 `capabilities` 表里现存的几行就是这个形状。
      final caps = InstanceCapabilities.fromJson(<String, dynamic>{
        'hasStar': 'available',
        'hasSend': 'denied',
        'serverTitle': 'Cloud Mail',
      });
      expect(caps.hasAccountAdd, ProbeState.unknown);
      expect(caps.hasAccountDelete, ProbeState.unknown);
      expect(caps.hasAccountRename, ProbeState.unknown);
      expect(caps.addMailboxDisabledByConfig, isFalse);
      // 老字段照常读。
      expect(caps.hasStar, ProbeState.available);
      expect(caps.hasSend, ProbeState.denied);
    });

    test('值是 null / 空串 / 垃圾串 → unknown', () {
      for (final raw in <Object?>[null, '', 'nonsense', 7]) {
        expect(ProbeState.parse(raw), ProbeState.unknown, reason: '$raw');
      }
    });
  });

  group('getter', () {
    test('addMailboxDisabledByConfig 为 true 时，即便 perm 可用也不能加', () {
      const caps = InstanceCapabilities(
        hasAccountAdd: ProbeState.available,
        addMailboxDisabledByConfig: true,
      );
      expect(caps.accountAddEnabled, isFalse,
          reason: '「实例关掉了」比「有权限」更靠前 —— 服务端 add() 开头就查它');
    });

    test('denied / absent / unknown 都不能加 —— 破坏性动作不猜', () {
      // 与 [starEnabled] / [accountQueryEnabled] **刻意不同**：那几条是
      // `!= absent`，`unknown` 时按可用算（冷启动不该整块变灰）。这三条是
      // `== available`。理由见 `instance_capabilities.dart` 里 getter 上面
      // 那段注释：加 / 删是在别人的服务器上动真东西，`unknown` 时用户等一轮
      // 探测的代价极小，而在没登录 / 没权限的实例上点出一个 401/403 的代价
      // 是他会看到一次莫名其妙的登出。
      for (final state in <ProbeState>[
        ProbeState.denied,
        ProbeState.absent,
        ProbeState.unknown,
      ]) {
        expect(
          InstanceCapabilities(hasAccountAdd: state).accountAddEnabled,
          isFalse,
          reason: '$state',
        );
        expect(
          InstanceCapabilities(hasAccountDelete: state).accountDeleteEnabled,
          isFalse,
          reason: '$state',
        );
        expect(
          InstanceCapabilities(hasAccountRename: state).accountRenameEnabled,
          isFalse,
          reason: '$state',
        );
      }
    });

    test('只有 available 才开；删除与改名各看各的，互不牵连', () {
      expect(
        const InstanceCapabilities(hasAccountDelete: ProbeState.available)
            .accountDeleteEnabled,
        isTrue,
      );
      expect(
        const InstanceCapabilities(hasAccountRename: ProbeState.available)
            .accountRenameEnabled,
        isTrue,
      );
      // 少了改名的权限不等于少了一切 —— 置顶没有权限要求，删除有自己的 perm。
      expect(
        const InstanceCapabilities(
          hasAccountRename: ProbeState.denied,
          hasAccountDelete: ProbeState.available,
        ).accountDeleteEnabled,
        isTrue,
      );
    });
  });

  group('诊断行', () {
    test('多出 account:add / account:delete / account:rename 三行', () {
      final rows = const InstanceCapabilities(
        hasAccountAdd: ProbeState.available,
        hasAccountDelete: ProbeState.denied,
        hasAccountRename: ProbeState.absent,
      ).toDiagnosticRows();
      expect(rows['account:add'], '可用');
      expect(rows['account:delete'], '无权限');
      expect(rows['account:rename'], '不支持');
      // 既有那八行还在（诊断页与实例详情面板直接 `for ... entries` 渲染，
      // 少了行不会报错，只会静默少一格）。
      for (final key in <String>[
        'star',
        'account:query',
        'send',
        'latest',
        'full',
        'attList',
        'autoRefresh',
        'r2Domain',
      ]) {
        expect(rows.containsKey(key), isTrue, reason: key);
      }
    });
  });

  group('_resolveAccountPerms（经 applyWebsiteConfig + probe）', () {
    // 这三条的规矩**逐字**照抄 `_resolveSend`：
    //   - 站点明确关掉 → absent（隐藏入口）；
    //   - 有 userInfo → 按 hasPerm 给 available / denied；
    //   - 没有 userInfo → 保持原值（别把已探到的结论抹掉）。
    //
    // 用 `CapabilityRepository` 的公开面来测这三条：把 `websiteConfig`
    // 直接给 `applyWebsiteConfig`，权限那一半走 `probe()` 太贵，
    // 所以这里只测「站点关掉」与「没有 userInfo 时保持原值」两个能纯着测的，
    // 权限那一半在 Task 6 的 `test/mailboxes_section_test.dart` 里用
    // 假 adapter 端到端钉。

    test('站点关掉添加 → accountAddEnabled 为 false', () {
      final repo = CapabilityRepository(_NoDb());
      final caps = repo.applyWebsiteConfig(
        const InstanceCapabilities(hasAccountAdd: ProbeState.available),
        const WebsiteConfig(addEmail: 1, manyEmail: 0),
      );
      expect(caps.addMailboxDisabledByConfig, isTrue);
      expect(caps.accountAddEnabled, isFalse);
    });

    test('站点开启（addEmail == 0 && manyEmail == 0）→ 开关为 false', () {
      final repo = CapabilityRepository(_NoDb());
      final caps = repo.applyWebsiteConfig(
        const InstanceCapabilities(hasAccountAdd: ProbeState.available),
        const WebsiteConfig(addEmail: 0, manyEmail: 0),
      );
      expect(caps.addMailboxDisabledByConfig, isFalse);
      expect(caps.accountAddEnabled, isTrue);
    });

    test('applyWebsiteConfig 不碰三个 ProbeState（那是 probe() 的事）', () {
      final repo = CapabilityRepository(_NoDb());
      final caps = repo.applyWebsiteConfig(
        const InstanceCapabilities(
          hasAccountAdd: ProbeState.denied,
          hasAccountDelete: ProbeState.available,
          hasAccountRename: ProbeState.absent,
        ),
        const WebsiteConfig(addEmail: 0, manyEmail: 0),
      );
      expect(caps.hasAccountAdd, ProbeState.denied);
      expect(caps.hasAccountDelete, ProbeState.available);
      expect(caps.hasAccountRename, ProbeState.absent);
    });
  });

  group('两条早退（直接调 @visibleForTesting 的静态方法）', () {
    // 上面那一组走公开面，钉不到 `resolveAccountAdd` 的「站点关掉优先」与
    // `resolveAccountPerm` 的「无 userInfo 保持原值」—— 它们都藏在私有早退里。
    // 于是把这两个静态方法开成 `@visibleForTesting` 直接调：走 `probe()` 的
    // 端到端太贵（要真打网络、要 ProfileRuntime），而这两条早退是**规格点名
    // 的规矩**，实现里删掉它们必须是红的。

    UserInfo userWith(List<String> perms) => UserInfo(permKeys: perms);

    test('resolveAccountAdd：站点关掉优先于权限 → absent', () {
      // 即便这个账号**有** `account:add` 权限，站点关掉了也得是 absent ——
      // 服务端 `add()` 开头查的就是站点开关，报「无权限」会误导用户。
      final state = CapabilityRepository.resolveAccountAdd(
        const InstanceCapabilities(
          hasAccountAdd: ProbeState.available,
          addMailboxDisabledByConfig: true,
        ),
        userWith(const <String>['account:add']),
      );
      expect(state, ProbeState.absent);
    });

    test('resolveAccountAdd：站点开着时按 account:add 权限判定', () {
      const previous = InstanceCapabilities(); // 站点开关默认 false
      expect(
        CapabilityRepository.resolveAccountAdd(
          previous,
          userWith(const <String>['account:add']),
        ),
        ProbeState.available,
      );
      expect(
        CapabilityRepository.resolveAccountAdd(
          previous,
          userWith(const <String>['account:delete']),
        ),
        ProbeState.denied,
      );
    });

    test('resolveAccountPerm：userInfo == null 时保持原值，不抹结论', () {
      // 「没拿到身份」不等于「没权限」：冷启动那一轮不该把上次探到的结论抹掉。
      for (final previous in <ProbeState>[
        ProbeState.denied,
        ProbeState.available,
        ProbeState.unknown,
        ProbeState.absent,
      ]) {
        expect(
          CapabilityRepository.resolveAccountPerm(
            previous,
            null,
            'account:delete',
          ),
          previous,
          reason: '$previous',
        );
      }
    });

    test('resolveAccountPerm：按传入的 perm 字面量判定', () {
      expect(
        CapabilityRepository.resolveAccountPerm(
          ProbeState.unknown,
          userWith(const <String>['account:delete']),
          'account:delete',
        ),
        ProbeState.available,
      );
      expect(
        CapabilityRepository.resolveAccountPerm(
          ProbeState.available,
          userWith(const <String>['account:add']),
          'account:delete',
        ),
        ProbeState.denied,
      );
    });

    test('改名闸用的 perm 就是字面量 email:send（照抄网页端）', () {
      // `probe()` 里 `hasAccountRename` 传的第三个参数必须是 `'email:send'` ——
      // 服务端 `/account/setName` 其实不在 `requirePerms` 里，这是纯客户端约定。
      // 这条把字符串本身钉住：改成别的 perm 会红。
      expect(
        CapabilityRepository.resolveAccountPerm(
          ProbeState.unknown,
          userWith(const <String>['email:send']),
          'email:send',
        ),
        ProbeState.available,
      );
      expect(
        CapabilityRepository.resolveAccountPerm(
          ProbeState.unknown,
          userWith(const <String>['account:add']),
          'email:send',
        ),
        ProbeState.denied,
      );
      // 超管（`*`）在任何 perm 上都算有。
      expect(
        CapabilityRepository.resolveAccountPerm(
          ProbeState.unknown,
          userWith(const <String>['*']),
          'email:send',
        ),
        ProbeState.available,
      );
    });
  });
  group('applyPerms（冷启动补探写库）', () {
    // 这一组要**真库**：`applyPerms` 是 `of()`（读）+ `save()`（写），
    // 与上面那几组纯函数不同 —— 它钉的是「冷启动补探之后库里真的变了」。
    late AppDatabase db;
    late CapabilityRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = CapabilityRepository(db);
      addTearDown(db.close);
    });

    test('从 unknown 写成 available（三格一起活）', () async {
      const id = 'p1';
      await repo.save(id, const InstanceCapabilities()); // 三格都是 unknown

      await repo.applyPerms(
        id,
        UserInfo(
          permKeys: const <String>['account:add', 'account:delete', 'email:send'],
        ),
      );

      final caps = await repo.of(id);
      expect(caps.hasSend, ProbeState.available);
      expect(caps.hasAccountAdd, ProbeState.available);
      expect(caps.hasAccountDelete, ProbeState.available);
      expect(caps.hasAccountRename, ProbeState.available);
      // 冷启动之后这三条 UI 判据必须当场为真 —— 否则就是本 bug 的现场。
      expect(caps.accountAddEnabled, isTrue);
      expect(caps.accountDeleteEnabled, isTrue);
      expect(caps.accountRenameEnabled, isTrue);
    });

    test('没权限写成 denied（且改名有自己的 perm）', () async {
      const id = 'p2';
      await repo.save(id, const InstanceCapabilities());

      // 只有 `email:send`：删除没权限（denied），改名有（available）。
      await repo.applyPerms(id, UserInfo(permKeys: const <String>['email:send']));

      final caps = await repo.of(id);
      expect(caps.hasAccountDelete, ProbeState.denied);
      expect(caps.hasAccountRename, ProbeState.available);
      // denied 是「有端点但没权限」→ 入口保留、提示联系管理员，不是隐藏。
      expect(caps.accountDeleteEnabled, isFalse);
      expect(caps.accountRenameEnabled, isTrue);
    });

    test('userInfo == null 时不写库（原样保留）', () async {
      const id = 'p3';
      await repo.save(
        id,
        const InstanceCapabilities(
          hasAccountDelete: ProbeState.available,
          hasAccountRename: ProbeState.denied,
          hasSend: ProbeState.available,
        ),
      );

      await repo.applyPerms(id, null);

      // 读回来逐字段比对，而不是只看 `==` —— `of()` 每次都新建对象，
      // 而这里要证的是「库里那几格没被动过」。
      final caps = await repo.of(id);
      expect(caps.hasAccountDelete, ProbeState.available);
      expect(caps.hasAccountRename, ProbeState.denied);
      expect(caps.hasSend, ProbeState.available);
      expect(caps.hasAccountAdd, ProbeState.unknown);
    });

    test('不碰 probedAt（它是「补探」，不是完整探测）', () async {
      const id = 'p4';
      final probedAt = DateTime.utc(2026, 10, 11, 8, 30);
      await repo.save(id, InstanceCapabilities(probedAt: probedAt));

      await repo.applyPerms(
        id,
        UserInfo(permKeys: const <String>['account:delete']),
      );

      // 那一格写上去的话，诊断页会把这一轮当成一次完整探测。
      final caps = await repo.of(id);
      expect(caps.probedAt, probedAt);
      // 权限那几格照常写了 —— 两件事互不影响。
      expect(caps.hasAccountDelete, ProbeState.available);
    });
  });
}

/// `applyWebsiteConfig` 是**纯函数**（只用 `previous` 与 `config`），
/// 但它的宿主类要一个 `AppDatabase`。这一组用例不碰库，用这个桩就够了 ——
/// 它一旦真的被读到就抛，正好把「你以为这个方法需要 db」这种改法当场打红。
class _NoDb implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('applyWebsiteConfig 不该碰数据库');
}
