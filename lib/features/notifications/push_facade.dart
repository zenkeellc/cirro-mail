import 'package:cirro_mail_ext/cirro_mail_ext.dart';

import '../../core/error/app_exception.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/token_store.dart';
import '../settings/push_pages.dart';
import 'push_service.dart';
import 'relay_client.dart';

/// [PushFacade] 的核心实现：把 [PushService] / [PrefsStore] / [TokenStore]
/// 这三样收成一个**扩展只认它**的门面。
///
/// ## 为什么要多这一层
///
/// 扩展（商业版）要画「设置 → 后台推送」的替身 UI，需要「拨开关 / 登记 /
/// 退订 / 查状态」这几件事。让它直接依赖 `PushService` 会把核心的实现细节
/// （prefs 键、钥匙串 key、FCM 分层）变成公开 API 的一部分 —— 那正是
/// `cirro_mail_ext` 存在的理由：**扩展只认接缝，核心随便改**。
///
/// ## 每个方法都不抛
///
/// 与 [PushService] 同一条纪律，只是把 `PushSyncResult` 折成
/// [PushActionResult]。唯一的例外是 [status]：它拉 `/devices` 失败时按
/// 「一个都没登记」显示（那是状态不是动作，没有「失败」可言）。
class PushFacadeImpl implements PushFacade {
  const PushFacadeImpl({
    required this._push,
    required this._prefs,
    required this._tokens,
  });

  final PushService _push;
  final PrefsStore _prefs;
  final TokenStore _tokens;

  @override
  bool get enabled => _push.enabled;

  @override
  Future<PushStatus> status() async {
    await _push.refreshManagedConfig();
    var mailboxes = const <String>[];
    try {
      mailboxes = await _push.remoteMailboxes();
    } on PushSubscriptionRequiredException {
      // 订阅失效在这里**不往上抛**：状态面板要能画出来（「中转端不认这份
      // 订阅」正是它要显示的东西）—— 由扩展按自己的订阅状态决定退回手填
      // 向导，而不是让一次状态查询把整页变成异常页。
    } on AppException {
      // 拉不到就按「一个都没登记」显示，理由同 `remoteMailboxes` 的注释。
    }
    return PushStatus(
      available: _push.available,
      hasFirebaseConfig: _push.hasFirebaseConfig,
      configured: _push.isConfigured,
      deviceIdValid: _push.deviceIdValid,
      deviceId: _push.deviceId,
      mailboxes: mailboxes,
    );
  }

  @override
  Future<PushActionResult> setEnabled(bool value) async {
    if (!value) {
      // 关掉就顺手退订：留着注册在中转端，用户下次开之前会继续收到推送 ——
      // 「我明明关了」是最容易被当成 bug 的一种状态。与自带向导同一口径。
      await _prefs.setPushEnabled(false);
      return _result(await _push.unsubscribe());
    }
    await _prefs.setPushEnabled(true);
    return _result(await _push.syncAll(reason: '托管推送开关'));
  }

  @override
  Future<PushActionResult> register() async =>
      _result(await _push.syncAll(reason: '托管推送手动登记'));

  @override
  Future<PushActionResult> unregister() async => _result(await _push.unsubscribe());

  @override
  Future<PushActionResult> checkChain() async {
    await _push.refreshManagedConfig();
    final url = _push.relayUrl;
    if (url.trim().isEmpty) {
      return const PushActionResult(ok: false, message: '还没有可用的中转地址');
    }
    try {
      final health = await _push.checkRelay(url);
      // 地址顺手送过去，让中转端比一下路径 —— 「配对码对、地址少个尾巴」是
      // 最常见的一种手滑（与自带向导第 ⑥ 页同一条往返）。
      final verify = await _push.verifyWebhook();
      final chain = PushChainCheck(
        relayReachable: true,
        fcmConfigured: health.fcmConfigured,
        codeOk: verify.codeOk,
        urlOk: verify.urlOk,
        lastEventAt: verify.lastEventAt,
        message: _chainMessage(health: health, verify: verify),
      );
      return PushActionResult(
        // 判据与自带向导**共用同一个纯函数**（`chainCheckPassed`）：两处各写
        // 一遍迟早会漂，而漂了的结果是「向导说通了、面板说没通」。
        ok: chainCheckPassed(
          codeOk: chain.codeOk,
          secretOk: verify.secretOk,
          urlOk: chain.urlOk,
          fcmConfigured: chain.fcmConfigured,
        ),
        message: chain.message,
        chain: chain,
      );
    } on PushSubscriptionRequiredException catch (e) {
      return PushActionResult(
        ok: false,
        message: e.userMessage,
        subscriptionRequired: true,
      );
    } on AppException catch (e) {
      return PushActionResult(ok: false, message: e.userMessage);
    }
  }

  @override
  Future<void> clearManualConfig() async {
    final instanceId = _prefs.pushInstanceId;
    await _prefs.clearPushConfig();
    if (instanceId.isNotEmpty) await _tokens.deletePushToken(instanceId);
  }

  /// 把 [PushSyncResult] 折成扩展认的那一种结果。
  static PushActionResult _result(PushSyncResult result) => PushActionResult(
        ok: result.ok,
        message: result.message,
        subscriptionRequired: result.subscriptionRequired,
      );

  /// 把三件事实折成一句人话（扩展要现成可显示的文案，不该自己解析字段）。
  ///
  /// 四个修法完全不同，所以**逐项报**：中转连不上要去查地址、没配 FCM 要
  /// 找部署者、配对码不对要重新取、地址路径不对要改实例后台。
  static String _chainMessage({
    required RelayHealth health,
    required RelayVerifyResult verify,
  }) {
    final problems = <String>[
      if (!health.fcmConfigured) '中转端没有配 FCM 服务账号（推送发不出去）',
      if (verify.credentialOk == false) '设备配对码不对',
      if (verify.urlOk == false) 'webhook 地址路径不对',
    ];
    if (problems.isEmpty) {
      final at = verify.lastEventAt ?? '';
      if (at.isEmpty) {
        return '链路检查通过：中转可达、凭证与地址都对。'
            '中转端还没收到过 webhook —— 确认实例后台里已经填好并开启了推送';
      }
      return '链路检查通过：中转可达、凭证与地址都对。最近一次收到 webhook：$at';
    }
    return '链路检查未通过：${problems.join('；')}';
  }
}
