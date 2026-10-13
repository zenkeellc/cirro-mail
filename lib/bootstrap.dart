import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/db/database.dart';
import 'core/storage/prefs_store.dart';
import 'core/storage/token_store.dart';
import 'providers/core_providers.dart';

/// 启动流程：把三样**只能异步建、且必须全局唯一**的东西建好塞进 `BootstrapData`。
///
/// 为什么不在 provider 里 `await`：
/// - drift 的库同一时刻只能有一个连接，不能由 provider 反复打开；
/// - 密钥库（`flutter_secure_storage`）走平台通道，首帧之后才建会让
///   「冷启动恢复登录态」和第一轮同步抢时序；
/// - 这些失败**不能让 App 崩在 `main` 里**（黑屏），要落到可重试的启动失败页。
///
/// 建库失败不抛出去，而是把异常塞进 `BootstrapData.bootstrapError` ——
/// `router.dart` 的 `redirect` 会据此把用户送回 `StartupFailureScreen`。
/// 密钥库与偏好设置的失败可以降级（见下），不拦路。
Future<BootstrapData> bootstrap() async {
  AppDatabase? db;
  TokenStore? tokens;
  PrefsStore? prefs;
  Object? error;

  try {
    db = AppDatabase();
    // 首次打开会跑 migration 建表；这一步失败几乎都是库文件损坏/无写权限，
    // 属于必须让用户看见的错误，所以就让它抛。
    await db.customSelect('SELECT 1').get();
  } catch (e, st) {
    error = _describe('本地数据库打不开', e, st);
    db = null;
  }

  // 构造 `TokenStore` 不打平台通道，密钥库真出问题会在第一次 read/write 时
  // 以 `PlatformException` 的形式出现 —— `TokenStore` 自己会降级为「仅内存」
  // 并置 `isDegraded`（设置页与启动失败页据此提示用户）。这里不需要 try。
  tokens = TokenStore();

  try {
    prefs = await PrefsStore.open();
  } catch (e, st) {
    // SharedPreferences 起不来（极少见）时给一份**内存实例**兜住：设置不落盘，
    // 但用户至少能读信。这个失败**不**置 bootstrapError —— 没有它 App 也能用，
    // 没必要把用户挡在启动失败页外面。
    debugPrint('偏好设置打不开，本次运行不落盘：$e\n$st');
    prefs = PrefsStore(await SharedPreferences.getInstance());
  }

  return BootstrapData(
    // 库没建起来时给一个「已经坏了」的占位实例，好让 UI 还能构造出来并显示错误。
    // 这里**不**去碰它的查询 —— `isHealthy == false` 时路由会拦住所有页面。
    db: db ?? AppDatabase(),
    tokens: tokens,
    prefs: prefs,
    bootstrapError: error,
  );
}

Object _describe(String what, Object error, StackTrace stackTrace) =>
    BootstrapFailure(what: what, cause: error, stackTrace: stackTrace);

/// 启动失败的原因（带上它在哪一步挂的）。
///
/// 带上 `stackTrace` 是因为启动失败几乎无法复现 —— 用户唯一能提供的就是
/// 启动失败页上那段文字，堆栈在里面才有诊断价值。
class BootstrapFailure implements Exception {
  const BootstrapFailure({
    required this.what,
    required this.cause,
    this.stackTrace,
  });

  final String what;
  final Object cause;
  final StackTrace? stackTrace;

  @override
  String toString() => '$what：$cause';
}
