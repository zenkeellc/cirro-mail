import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/token_store.dart';
import '../../core/theme/instance_colors.dart';
import '../../core/util/url_utils.dart';
import '../models/profile.dart';

/// 实例（「服务器 + 账号」）的增删改查。
///
/// 这是**唯一**可以删 profile 的地方：删实例要同时清本地缓存（dao 的级联）
/// 与密钥库里的 token，两个不同的存储，必须由知道两边存在的一层来协调。
class ProfileRepository {
  ProfileRepository({
    required this.db,
    required this.tokens,
    required this.prefs,
  });

  final AppDatabase db;
  final TokenStore tokens;
  final PrefsStore prefs;

  static const Uuid _uuid = Uuid();

  Stream<List<Profile>> watchAll() => db.profileDao.watchProfiles();

  Future<List<Profile>> all() => db.profileDao.allProfiles();

  Future<Profile?> find(String id) => db.profileDao.findProfile(id);

  /// 新建一个实例（**此时还没登录**）。
  ///
  /// [baseUrl] 会被规范化（补协议、去尾斜杠、补 `/api`），
  /// 这样后续所有请求与 [UrlUtils.ossBase] 的推导都有一致的输入。
  Future<Profile> create({
    required String baseUrl,
    String name = '',
    String serverTitle = '',
    String email = '',
    int? colorIndex,
  }) async {
    final normalized = UrlUtils.normalizeApiBase(baseUrl);
    final existing = await db.profileDao.allProfiles();
    final now = DateTime.now().toUtc();
    final profile = Profile(
      id: _uuid.v4(),
      baseUrl: normalized,
      name: name,
      serverTitle: serverTitle,
      email: email,
      // 新实例排在最后。
      sort: existing.isEmpty
          ? 0
          : existing.map((p) => p.sort).reduce((a, b) => a > b ? a : b) + 1,
      colorIndex:
          colorIndex ?? InstanceColors.nextIndex(existing.map((p) => p.colorIndex)),
      createdAt: now,
      lastActiveAt: now,
      // ossBase 先用「无 r2Domain」的形态填上，探测到 r2Domain 后会覆盖。
      ossBase: UrlUtils.ossBase(userApi: normalized),
    );
    await db.profileDao.upsertProfile(profile);
    return profile;
  }

  /// 只更新用户可改的字段（备注名、色标、排序、协议身份）。
  Future<void> update(
    String id, {
    String? name,
    int? sort,
    int? colorIndex,
    String? serverTitle,
    String? email,
    String? userName,
    int? userId,
    String? ossBase,
    bool? needsLogin,
  }) =>
      db.profileDao.updateProfileFields(
        id,
        name: name,
        sort: sort,
        colorIndex: colorIndex,
        serverTitle: serverTitle,
        email: email,
        userName: userName,
        userId: userId,
        ossBase: ossBase,
        needsLogin: needsLogin,
      );

  /// 修改备注名（设置页用）。
  Future<void> rename(String id, String name) =>
      db.profileDao.updateProfileFields(id, name: name);

  Future<void> setColorIndex(String id, int colorIndex) =>
      db.profileDao.updateProfileFields(id, colorIndex: colorIndex);

  /// 保存实例配置（`baseUrl` 变了会清掉该实例的 token ——
  /// A 实例签发的 token 在 B 实例毫无意义）。
  Future<void> updateBaseUrl(String id, String baseUrl) async {
    final normalized = UrlUtils.normalizeApiBase(baseUrl);
    final current = await db.profileDao.findProfile(id);
    if (current == null) return;
    if (current.baseUrl == normalized) return;

    await tokens.delete(id);
    await db.profileDao.upsertProfile(
      Profile(
        id: current.id,
        baseUrl: normalized,
        name: current.name,
        serverTitle: current.serverTitle,
        email: current.email,
        userName: current.userName,
        // 换了服务器，之前的 userId 不再有效。
        userId: 0,
        ossBase: UrlUtils.ossBase(userApi: normalized),
        sort: current.sort,
        colorIndex: current.colorIndex,
        needsLogin: true,
        createdAt: current.createdAt,
        lastActiveAt: current.lastActiveAt,
      ),
    );
  }

  /// 登录成功后把服务端认到的身份写回。
  Future<void> markLoggedIn(
    String id, {
    required int userId,
    required String email,
    required String userName,
    String? serverTitle,
    String? ossBase,
  }) =>
      db.profileDao.updateProfileFields(
        id,
        userId: userId,
        email: email,
        userName: userName,
        serverTitle: serverTitle,
        ossBase: ossBase,
        needsLogin: false,
        lastActiveAt: DateTime.now().toUtc(),
      );

  /// 401 后置「需要重新登录」。**不删 token** —— 用户可能只是被别的设备挤掉，
  /// 重新登录即可；删掉反而丢了「上次是谁」的信息。
  Future<void> markNeedsLogin(String id, {bool needsLogin = true}) =>
      db.profileDao.updateProfileFields(id, needsLogin: needsLogin);

  Future<void> touch(String id) => db.profileDao
      .updateProfileFields(id, lastActiveAt: DateTime.now().toUtc());

  Future<void> setLastSyncAt(String id, DateTime at) =>
      db.profileDao.updateProfileFields(id, lastSyncAt: at);

  /// 删实例：本地缓存级联 + token + 当前选中项。
  Future<void> delete(String id) async {
    final wasActive = prefs.activeProfileId == id;
    await db.profileDao.deleteProfileCascade(id);
    await tokens.delete(id);
    if (wasActive) {
      final rest = await db.profileDao.allProfiles();
      await prefs.setActiveProfileId(rest.isEmpty ? null : rest.first.id);
    }
  }

  /// 退出登录但**保留服务器**（用户还想换个账号登回来）。
  ///
  /// 服务端 `DELETE /logout` 只移除**当前**这一个 token（同账号其他设备不受影响），
  /// 所以这里要显式调一次；调用失败（例如 token 早就无效了）不阻断本地清理。
  Future<void> signOut(String id, {bool wipeCache = true}) async {
    await tokens.delete(id);
    if (wipeCache) {
      // 只清数据、保留 profile 行 —— 服务器地址与备注名还有价值。
      await db.profileDao.clearProfileData(id);
    }
    await markNeedsLogin(id);
  }

  /// 切换当前实例。
  Future<void> setActive(String id) async {
    await prefs.setActiveProfileId(id);
    await touch(id);
  }
}