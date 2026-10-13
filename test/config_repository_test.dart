import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/models/website_config.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/config_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `ConfigRepository.fetch` 的**返回时机**。
///
/// 这一组测试来自一个真实的线上症状：登录前的「测试连接」永远转圈，
/// 而事后从运行时里读出来的事实是 —— 网络请求早就 200 回来了，
/// `_cache` 里已经有完整配置、`_fetchedAt` 也有值，只是那个 `await` 一直没有下文。
///
/// 根因就在这个文件被测的地方：`_load` 把「同步能力表」这种**纯副作用**
/// 的本地库读写放在了 `return config` 之前并且 `await` 掉了。于是
/// 「drift 后台 isolate 忙 / 库被另一个 isolate 占着」这类与本次请求无关的
/// 毛病，会变成调用方**永远等不到**返回，UI 上就是一个转不完的圈 ——
/// 而且没有任何异常冒出来，日志上连一行错误都没有。
///
/// 所以这里钉住的不是「能力表有没有写成功」（那是 [`_syncCapabilities`]
/// 自己的事，失败只记日志），而是**配置能不能在能力表出问题时照样按时返回**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness harness;

  setUp(() async {
    harness = await _Harness.create();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('正常情况：拿到配置，并把站点标题同步进能力表', () async {
    harness.respond(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{
        'title': 'UMail',
        // `send == 1` 才是「服务端关掉了发信」，0 是开放 —— 语义与字段名直觉相反。
        'send': 1,
        'register': 1,
        'r2Domain': null,
        'domainList': <String>['example.net'],
        'autoRefresh': 0,
      },
    });

    final config = await harness.fetch();

    expect(config.title, 'UMail');

    // 能力表是**异步**同步的（不阻塞 `fetch`），但它终究要落下去。
    final caps = await harness.waitForCapabilities();
    expect(caps.serverTitle, 'UMail');
    expect(caps.sendDisabledByConfig, isTrue);
    expect(caps.r2Domain, isNull);
  });

  test('能力表写入挂住 → `fetch` 照样在超时前返回（这是「一直转圈」的根因）', () async {
    harness.respond(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{'title': 'Stuck', 'send': 1, 'register': 1},
    });
    // 模拟库被另一个 isolate 占着写锁：写能力表的那一步永远不完成。
    harness.freezeCapabilityWrite();

    final started = Stopwatch()..start();
    final config = await harness.fetch().timeout(const Duration(seconds: 2));
    started.stop();

    expect(config.title, 'Stuck');
    expect(
      started.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: '能力表是副作用，不该出现在 fetch 的关键路径上',
    );

    harness.releaseCapabilityWrite();
  });

  test('能力表写入抛错 → 配置照样返回，异常不冒泡给调用方', () async {
    harness.respond(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{'title': 'Fine', 'send': 1, 'register': 1},
    });
    harness.failCapabilityWrite();

    final config = await harness.fetch().timeout(const Duration(seconds: 2));
    expect(config.title, 'Fine');
    // 让那句被吞掉的异常跑完，确认它真的不会变成 unhandled error。
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('并发调用合成一次请求（`_inFlight` 去重仍然有效）', () async {
    harness.respond(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{'title': 'Once', 'send': 1, 'register': 1},
    });

    final results = await Future.wait(<Future<Object>>[
      harness.fetch(),
      harness.fetch(),
      harness.fetch(),
    ]);

    expect(results.map((c) => (c as dynamic).title), everyElement('Once'));
    expect(
      harness.adapter.requested.length,
      1,
      reason: '同一个实例的并发 fetch 只该打一次网络',
    );
  });

  test('forget 之后，能力表里那行也要没（临时探针不该在库里留记录）', () async {
    harness.respond(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{'title': 'Probe', 'send': 1, 'register': 1},
    });

    await harness.fetch();
    await harness.waitForCapabilities();

    await harness.capabilities.forget(harness.profileId);

    expect(
      await harness.db.profileDao.loadCapabilities(harness.profileId),
      isNull,
      reason: '只清内存缓存会在库里留下一个永远不会有人认领的实例条目',
    );
  });
}

// ---------------------------------------------------------------- 测试环境

class _Harness {
  _Harness._({
    required this.db,
    required this.profileId,
    required this.repo,
    required this.registry,
    required this.capabilities,
    required this.adapter,
    required this.profile,
    required this._authEvents,
  });

  static Future<_Harness> create() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final authEvents = AuthEvents();
    final adapter = _FakeAdapter();

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      // 必须走 `DioFactory.build` 再换适配器：直接 `Dio(...)` 就没有
      // `EnvelopeInterceptor`，「信封拆包」这一步不存在，拿到的是
      // `{code,data}` 整包而不是 `data` —— 测试会以「字段全是默认值」的
      // 形式失败，看起来像解析有问题，其实只是夹具少挂了一层。
      buildApiDio: (profile) => DioFactory.build(
        userApi: profile.baseUrl,
        profileId: profile.id,
        authEvents: authEvents,
        readToken: () => null,
        readLanguage: () => 'zh',
      )..httpClientAdapter = adapter,
    );

    final profile = await profiles.create(baseUrl: 'https://mail.example.net');
    registry.ensure(profile);

    final capabilities = _GatedCapabilityRepository(db);
    return _Harness._(
      db: db,
      profileId: profile.id,
      profile: profile,
      repo: ConfigRepository(registry: registry, capabilities: capabilities),
      registry: registry,
      capabilities: capabilities,
      adapter: adapter,
      authEvents: authEvents,
    );
  }

  final AppDatabase db;
  final String profileId;
  final Profile profile;
  final ConfigRepository repo;
  final RuntimeRegistry registry;
  final _GatedCapabilityRepository capabilities;
  final _FakeAdapter adapter;
  final AuthEvents _authEvents;

  Future<WebsiteConfig> fetch() => repo.fetch(
        profile,
        force: true,
        allowStaleOnError: false,
      );

  /// 能力表的写入是**异步**的（不阻塞 `fetch`），等它自然落库。
  Future<InstanceCapabilities> waitForCapabilities() async {
    for (var i = 0; i < 40; i++) {
      final caps = await db.profileDao.loadCapabilities(profileId);
      if (caps != null) return caps;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('能力表一直没有落库');
  }

  void freezeCapabilityWrite() => capabilities.freezeWrite();
  void releaseCapabilityWrite() => capabilities.releaseWrite();
  void failCapabilityWrite() => capabilities.failWrite();

  void respond(Object body) => adapter.respondJson(body);

  Future<void> dispose() async {
    capabilities.releaseWrite();
    await registry.dispose();
    await _authEvents.dispose();
    await db.close();
  }
}

/// 把 `saveCapabilities` 卡住/弄挂的能力仓库 —— 只覆盖这两个异常情形，
/// 其余（`of` / `applyWebsiteConfig`）走真实实现。
class _GatedCapabilityRepository extends CapabilityRepository {
  _GatedCapabilityRepository(super.db);

  Completer<void>? _gate;
  bool _shouldFail = false;

  void freezeWrite() => _gate = Completer<void>();

  void releaseWrite() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void failWrite() {
    _shouldFail = true;
    releaseWrite();
  }

  @override
  Future<void> save(String profileId, InstanceCapabilities caps) async {
    if (_shouldFail) {
      _shouldFail = false;
      throw StateError('模拟能力表写入失败');
    }
    final gate = _gate;
    if (gate != null) await gate.future;
    return super.save(profileId, caps);
  }
}

/// 只回答最后一个请求，够这一组测试用（都是 GET /setting/websiteConfig）。
class _FakeAdapter implements HttpClientAdapter {
  final List<String> requested = <String>[];
  Object _body = const <String, Object?>{'code': 200, 'data': <String, Object?>{}};

  void respondJson(Object body) => _body = body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    return ResponseBody.fromString(
      jsonEncode(_body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
