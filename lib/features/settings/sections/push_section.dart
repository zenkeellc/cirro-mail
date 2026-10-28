import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/error/app_exception.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/notification_providers.dart';
import '../../notifications/push_service.dart';
import '../../notifications/relay_client.dart';
import '../push_pages.dart';
import '../push_widgets.dart';

/// 设置 → 后台推送的正文 —— **七页的分步向导**（没有自己的 `Scaffold`）。
///
/// ## 为什么是一块而不是七张页面
///
/// 七步之间是**依赖顺序**（先有值才能开开关、开了才能登记、登记了才谈得上
/// 自检），不是七条并列的路径。做成七个路由，用户就得自己记住「上一步是
/// 哪个地址」，而系统返回键会把他弹回设置页首页而不是上一步。所以这里是
/// **一块内容 + 内部翻页**。
///
/// 页码与判据都在 [push_pages.dart]（纯逻辑、可单测）；这里只负责画。
///
/// ## 两种形态
///
/// - **窄屏**：它占着设置那一支 Navigator 的一页（`SettingsScreen` 推上来的），
///   [onExit] 退回分类列表。这时系统返回键在第 ② 页之后表示「上一步」。
/// - **宽屏**：内嵌进设置页右栏（[onExit] 为 null）。**不套 `PopScope`**、
///   末页不画「完成」—— 左右两栏都在屏幕上，分类栏就是出口。
///
/// ## 三件互相独立的事
///
/// [PushService] 的注释里有一份同样的分层，第 ① 页就是它的可视化：这个
/// 平台有没有 FCM、三条值填全没有、这台设备在中转端登记上没有。缺任何
/// 一件，「App 不在时收不到提醒」都会发生 —— 而用户在界面上看不出是哪
/// 一件，所以它们**同时**显示，而不是只在出错时弹一句。
class PushSection extends ConsumerStatefulWidget {
  const PushSection({super.key, this.onExit});

  /// 「完成」按钮落地的动作。null = 内嵌形态（宽屏右栏），末页不画那颗按钮。
  final VoidCallback? onExit;

  @override
  ConsumerState<PushSection> createState() => _PushSectionState();
}

class _PushSectionState extends ConsumerState<PushSection> {
  final TextEditingController _relay = TextEditingController();
  final TextEditingController _instanceId = TextEditingController();
  final TextEditingController _code = TextEditingController();

  /// 部署者的管理口令。
  ///
  /// **只活在这个 State 里**：不写 prefs、不进 `TokenStore`、不记日志，
  /// `dispose` 即随控制器一起释放。它只在「一键开通」那一次请求里作为
  /// `Authorization: Bearer` 头出现。
  final TextEditingController _adminToken = TextEditingController();

  /// 设备号是**只读**的。
  ///
  /// 它必须带 `<实例位>-` 前缀，而且那个前缀是 `PushService` 的内部不变量
  /// （见它 `configure` 的注释，以及线上实测过的那次 401）。给用户一个能
  /// 编辑的输入框，等于把「维护这个不变量」外包给用户 —— 而它本来就没有
  /// 任何需要用户决定的成分。
  String _deviceId = '';

  /// 现在停在第几页（[PushPage] 的 `index`）。
  int _page = 0;

  bool _loaded = false;
  bool _busy = false;
  bool _enabled = false;
  bool _checking = false;

  /// 正在登记（第 ④ 页那个主按钮的转圈）。
  ///
  /// 与 [_busy] 分开：那个是「现在别点任何东西」，这个是「这一个动作在飞」
  /// —— 按钮上要转的圈只能是后者，否则用户点第 ⑤ 页的复制也会看到第 ④ 页
  /// 的按钮在转。
  ///
  /// 与 [_unregistering] 也分开：两个钮在同一页上，共用一个标志的话无论点
  /// 哪个都是**两个按钮一起转**，看起来像点了两下。禁用由 [_busy] 管，所以
  /// 分开之后不会出现「这个在飞、那个还能点」。
  bool _registering = false;

  /// 正在退订（第 ④ 页底部那个次按钮的转圈）。
  bool _unregistering = false;

  /// 正在从 `/devices` 拉「中转端记着哪些邮箱」。
  bool _refreshing = false;

  /// 首启自动登记只做一次（见 [_maybeAutoRegister]）。
  bool _autoRegistered = false;

  /// 一条一次性回执 [+ 它的序号]。
  ///
  /// 序号是给 [_drainMessage] 去重用的：光看文案去不掉「同一句话连说两遍」
  /// （连点两次复制、连着自动登记两轮），而那种情况下用户其实该看到两次。
  String? _message;
  bool _messageIsError = false;
  int _messageSeq = 0;

  /// 已经被弹成 SnackBar 的那条回执的序号。
  int _lastDrainedSeq = 0;

  /// 把回执弹成 SnackBar 用的 messenger。
  ///
  /// **在第一帧画完之后抓一次、之后不再通过 `context` 找** —— 设 `_message`
  /// 的地方多半在一个 await 之后（自动登记、刷新、检查），那时
  /// `ScaffoldMessenger.of(context)` 要么得再判一次 mounted，要么在
  /// dispose 之后直接抛（`BuildContext.findAncestorStateOfType`）。
  /// `Messenger` 挂在 `MaterialApp.router` 上，这一页没了它还在，比
  /// context 活得久。
  ScaffoldMessengerState? _messenger;

  RelayHealth? _health;

  /// [_health] 是拿**哪个地址**问出来的。
  ///
  /// 单独记一份是因为 `RelayHealth` 里没有地址：用户在地址框里改了域名再点
  /// 检查时，这两次请求的结果会交错落进 `_health`，于是「中转连不上」可能
  /// 被算成「FCM 没配」而给出一个绿勾（见 [_chainVerified]）。
  String _healthUrl = '';

  List<String> _remoteMailboxes = const <String>[];

  /// 自检结论 + 它当初是拿哪一份输入问出来的。
  ///
  /// 存下输入是为了**作废**：用户改完实例位再点检查，上一次的结论必须消失，
  /// 否则「配对码不对」会一直挂在那儿，看起来像是新一次的结果。
  RelayVerifyResult? _verify;
  String _verifyInputs = '';

  /// 第 ⑤ / ⑥ 两页那两份**跨会话**的见证值（存钥匙串，见 `TokenStore`）。
  ///
  /// 两份都是同一份 JSON（见 [_witnessValue]），其中 `fp` 是确认那一刻
  /// [_inputsFingerprint] 的值：
  /// - [_webhookWitness] —— 用户勾了「我已经在实例后台填好了」；
  /// - [_chainWitness] —— 上一次链路检查**通过**了。
  ///
  /// 存指纹而不是 bool：用户确认的是**当时那三条值**，改了任何一条（哪怕
  /// 只是把地址末尾的斜杠补上）那份确认就该作废，否则「我以为配好了、
  /// 其实填的是上一个实例位」这种错会一直显示成已完成。
  String _webhookWitness = '';
  String _chainWitness = '';

  /// 钥匙串里那两个见证值的 key（见 [TokenStore.readPushStepWitness]）。
  static const String _kWebhookStep = 'webhook';
  static const String _kChainStep = 'chain';

  /// 从钥匙串读回来的**设备配对码**（不是 webhook secret）。
  ///
  /// 拆分之后它是 App 自己的凭证，只用于「这台设备在这个实例位上算不算
  /// 登记过」。显示区里**不再**把它当成实例后台要填的密钥露出来。
  String _pairingCode = '';

  /// 「一键开通」在**本次会话里**真的拿回来的 `webhookSecret`。
  ///
  /// 它**只活在内存里**：不写 prefs、不进 `TokenStore`、不记日志。中转端
  /// 落库之后连管理员也读不回来，所以这是用户唯一一次能看到它的机会 ——
  /// 页面会把「只显示这一次」明说出来，让用户当场复制到实例后台。离开
  /// 这一页（State 销毁）就没了，只能去中转端轮换一个新的。
  String _sessionWebhookSecret = '';

  /// [_sessionWebhookSecret] 属于**哪一个实例位**。
  ///
  /// 用户在一键开通之后可能又去改了实例位 / 换了中转位，那份 secret 就
  /// 不属于新的那一个了 —— 继续显示只会让他把上一个位的密钥填进新位的
  /// 实例后台。所以 [_save] 里拿实例位一比，对不上就整份作废。
  String _webhookSecretSlot = '';

  /// 第 ⑤ 页那一句二元问题：这个实例是不是用户自己在管。
  ///
  /// 只决定一句文案与要不要显示「复制转达文案」，**不影响任何行为** ——
  /// 两条值在两种答案下都照常显示。`null` 表示还没答。
  bool? _isAdmin;

  @override
  void initState() {
    super.initState();
    // prefs 是同步的，但配对码在密钥库里（异步），所以统一走一次 load。
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 第一帧之后再抓 messenger：`initState` 那一刻这一层还没挂上去，
    // 而 `ScaffoldMessenger.of` 此时会抛。
    if (_messenger == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _messenger = ScaffoldMessenger.maybeOf(context);
      });
    }
  }

  @override
  void dispose() {
    _relay.dispose();
    _instanceId.dispose();
    _code.dispose();
    _adminToken.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final push = ref.read(pushServiceProvider);
    _relay.text = push.relayUrl;
    _instanceId.text = push.instanceId;
    _code.text = await _pairingCodeOrEmpty();
    // 到这里 `initState` 已经跑完了，可以安全地取 `context` 上的翻译。
    if (!mounted) return;
    await _prefillFromBuild(push, AppLocalizations.of(context));
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _enabled = push.enabled;
      _pairingCode = _code.text.trim();
      // 第 ⑤ 页那句「是你在管吗」的答案也一起读回来 —— 它是个只问一次就
      // 该记住的分岔，以前每次进来都回到「两个都没选中」。
      _isAdmin = ref.read(prefsStoreProvider).pushIsAdmin;
    });
    // 顺序要紧：`ensureDeviceId()` 必须排在 `_refreshRemote()` 前面 ——
    // 后者会拿设备号去问 `/devices`，旧值是个裸 UUID 时会问出一份空
    // 列表（看起来像「一条都没登记」）。
    await _syncDeviceId();
    // 见证值必须在刷新之前读回来：`_refreshRemote()` 会同时更新
    // `_remoteMailboxes`（进度条上「登记」那一页的判据）与第 ⑤ 页要显示的
    // 事件时间，而 `_maybeAutoRegister()` 又拿刚拉回来的那份列表决定要不
    // 要自动登记一次。
    await _loadWitnesses();
    // 进页面这一次是**静默**的：用户什么都没点，不该弹「已刷新…」。
    await _refreshRemote(silent: true);
    await _maybeAutoRegister();
  }

  /// 把钥匙串里那两份「这一步我做过了」的见证值读回来。
  ///
  /// 两份都是 [_witnessValue] 那种 JSON（含输入指纹），按**当前实例位**
  /// 读 —— 换了实例位就自然读不到旧位的确认（key 里带着 `slot`）。
  Future<void> _loadWitnesses() async {
    final slot = _instanceId.text.trim();
    final tokens = ref.read(tokenStoreProvider);
    final chain = await tokens.readPushStepWitness(slot, _kChainStep);
    final webhook = await tokens.readPushStepWitness(slot, _kWebhookStep);
    if (!mounted) return;
    setState(() {
      _chainWitness = chain ?? '';
      _webhookWitness = webhook ?? '';
    });
  }

  /// 写下一份见证值：登不进 / 清不掉都只是「下次进来还得再确认一次」，
  /// 不该把当前这次操作弄失败。
  Future<void> _saveWitness(String step, String value) async {
    final slot = _instanceId.text.trim();
    if (slot.isEmpty) return;
    await ref.read(tokenStoreProvider).writePushStepWitness(slot, step, value);
  }

  /// 见证值的字面值。
  ///
  /// 存的是**一份 JSON，而不是几个字段用 `|` 拼起来的字符串** —— 输入指纹
  /// 本身就是用 `|` 拼的（见 [_inputsFingerprint]），再拿 `|` 当外层分隔
  /// 符，「哪一段是时间」立刻变成一个解析题，而且第一刀正好切在指纹中间：
  /// `_witnessFingerprint` 只会拿到地址那一段，永远等不上完整指纹，于是
  /// 用户勾了、确认了、再进来**还是**「未完成」。
  ///
  /// 三个字段：
  /// - `fp` —— 记下这份确认时的输入指纹（对不上就整份作废）；
  /// - `at` —— 那一刻本身（第 ⑥ 页会把它显示成「上次是什么时候过的」）；
  /// - `event` —— 那一刻中转端记着的「最近一次真的收到 webhook」的时间，
  ///   空串表示当时还没有过。它是第 ⑤ 页在用户没勾那个框时**唯一**的客观
  ///   证据，所以要跟着一起存下来，不能只留在内存的 `_verify` 里。
  String _witnessValue({String evidence = ''}) => jsonEncode(<String, String>{
        'fp': _inputsFingerprint(),
        'at': DateTime.now().toIso8601String(),
        'event': evidence,
      });

  /// 拆一份见证值。解不出来（旧版本存的 `|` 格式、被手工改过）就回空表 ——
  /// 对上层来说就是「这份确认不作数」，正好是要的降级：让他再确认一次，
  /// 而不是拿一份读不懂的东西当真。
  static Map<String, String> _witnessFields(String witness) {
    if (witness.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(witness);
      if (decoded is! Map) return const <String, String>{};
      return decoded.map(
        (key, value) => MapEntry('$key', value?.toString() ?? ''),
      );
    } on FormatException {
      return const <String, String>{};
    }
  }

  /// 这份见证值还作不作数 —— 它记的那份输入跟现在输入框里的一致才算。
  bool _witnessValid(String witness) {
    final fields = _witnessFields(witness);
    return (fields['fp'] ?? '').isNotEmpty &&
        fields['fp'] == _inputsFingerprint();
  }

  /// 见证值里记的那个时间（`_verify` 也带着同一份，见 [_chainCheck]）。
  ///
  /// 单独留一份是因为 `verifyWebhook` 只在**这一次检查**里跑过；重新进页面
  /// 时只有钥匙串里那份见过时间，而「上次是什么时候过的」正是这一条最有
  /// 用的信息。
  static String _witnessStampOf(String witness) =>
      _witnessFields(witness)['at'] ?? '';

  /// 见证值里记的「中转端最近一次收到 webhook」。
  String? get _rememberedEvent {
    if (!_witnessValid(_chainWitness)) return null;
    final event = _witnessEvidenceOf(_chainWitness);
    return event.isEmpty ? null : event;
  }

  static String _witnessEvidenceOf(String witness) =>
      _witnessFields(witness)['event'] ?? '';

  /// 把设备号修成带实例位前缀的形状，并把结果读到 [_deviceId] 里显示。
  ///
  /// 之所以不在这里现生成、而是交给 `PushService`：那儿是所有网络路径
  /// （含启动时的登记）共用的那一处，见 `PushService.ensureDeviceId`。
  Future<void> _syncDeviceId() async {
    final value = await ref.read(pushServiceProvider).ensureDeviceId();
    if (!mounted) return;
    setState(() => _deviceId = value);
  }

  /// 用构建期注入的默认值补空字段（部署者拿自己的包时 `--dart-define` 进来的）。
  ///
  /// 三条的落点**刻意不同**：
  /// - 中转地址、实例位 → 存 prefs（它们不是秘密，设置页本来就明文显示）；
  /// - 设备配对码 → 只存 `TokenStore`，**不写 prefs**：它虽然是可公开的
  ///   App 侧凭证，但仍是「这个实例位上这台设备」的身份，不该躺在无加密的
  ///   配置里。构建期注入的 `PUSH_PAIRING_CODE` 语义就是它（见
  ///   `AppDefaults.pushPairingCode`），webhookSecret **不从这里进来**。
  ///
  /// 只在字段**为空**时补：默认值是用来省掉首次配置的，用户手填过的值
  /// （哪怕跟默认值不一样）绝不能被构建期的常量盖掉。
  Future<void> _prefillFromBuild(PushService push, AppLocalizations l10n) async {
    final prefs = ref.read(prefsStoreProvider);
    var applied = false;
    if (_relay.text.trim().isEmpty && AppDefaults.pushRelayUrl.isNotEmpty) {
      _relay.text = AppDefaults.pushRelayUrl;
      await prefs.setPushRelayUrl(AppDefaults.pushRelayUrl);
      applied = true;
    }
    if (_instanceId.text.trim().isEmpty && AppDefaults.pushInstanceId.isNotEmpty) {
      _instanceId.text = AppDefaults.pushInstanceId;
      await prefs.setPushInstanceId(AppDefaults.pushInstanceId);
      applied = true;
    }
    if (_code.text.trim().isEmpty && AppDefaults.pushPairingCode.isNotEmpty) {
      _code.text = AppDefaults.pushPairingCode;
      // 存进**刚落盘的实例位**，不是构建期的常量：只注入了
      // `PUSH_PAIRING_CODE` 而没注入 `PUSH_INSTANCE_ID` 时，后者是空串，
      // 配对码会被写到一个空 key 下 —— 读的时候永远读不回来。
      await ref
          .read(tokenStoreProvider)
          .writePushToken(_instanceId.text.trim(), AppDefaults.pushPairingCode);
      applied = true;
    }
    if (applied) {
      // 直接写字段而不是 `_setMessage`：那时 `_loaded` 还是 false，
      // `setState` 会在下面那次统一调用里发生。
      _message = l10n.pushBuiltInApplied;
      _messageIsError = false;
    }
  }

  /// 首次配置完自动登记一次。
  ///
  /// 用户在别处（一键开通 / dart-define）已经拿到配对码，进来这一页时
  /// 「配置好了但一个邮箱都没登记」是唯一的中间态 —— 那时候他其实什么都
  /// 不用改，却得自己找到「登记」按钮点一下，否则推送根本不来。
  ///
  /// 只登记一次（[_autoRegistered]），失败静默：这是个便利，不是关键路径，
  /// 失败时页面上本来就有状态条与「登记」按钮兜着。
  ///
  /// 它在进入向导时就跑，**不等用户走到第 ④ 页** —— 走到那页再跑的话，
  /// 那个中间态会一直挂到用户恰好点开那一页为止。
  Future<void> _maybeAutoRegister() async {
    if (_autoRegistered) return;
    final push = ref.read(pushServiceProvider);
    if (!push.isConfigured || !push.enabled) return;
    if (await ref.read(tokenStoreProvider).readPushToken(push.instanceId) == null) {
      return;
    }
    // 用刚拉回来的那份列表判断，不再打一次请求。
    if (_remoteMailboxes.isNotEmpty) return;
    _autoRegistered = true;
    final result = await push.syncAll(reason: '首次配置自动登记');
    if (!mounted) return;
    _setMessage(result.message, error: !result.ok);
    await _refreshRemote(silent: true);
  }

  /// 总开关。**先存配置再开** —— 用户很可能改完地址直接拨开关，
  /// 那时候输入框里的值还没落盘，不先存就会拿旧配置去登记。
  Future<void> _toggle(bool next) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final prefs = ref.read(prefsStoreProvider);
      final push = ref.read(pushServiceProvider);
      if (next) {
        await _save();
        await prefs.setPushEnabled(true);
        if (!mounted) return;
        setState(() => _enabled = true);

        final result = await push.syncAll(reason: '开启');
        if (!mounted) return;
        _setMessage(result.message, error: !result.ok);
      } else {
        await prefs.setPushEnabled(false);
        if (!mounted) return;
        setState(() => _enabled = false);

        // 关掉就顺手退订：留着注册在中转端，用户下次开之前不该继续
        // 收到推送（否则「我明明关了」就成了 bug）。
        final result = await push.unsubscribe();
        if (!mounted) return;
        _setMessage(result.message, error: !result.ok);
      }
      await _refreshRemote(silent: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _pairingCodeOrEmpty() async {
    final push = ref.read(pushServiceProvider);
    if (!push.isConfigured) return '';
    return await ref.read(tokenStoreProvider).readPushToken(push.instanceId) ?? '';
  }

  /// `/devices` 拉回来那份列表，写进 [_remoteMailboxes]。
  ///
  /// `silent` 用于进入页面时的自动刷新：那时用户什么都没点，不该突然弹一条
  /// 「已刷新：中转端记着 3 个邮箱」的回执。**手动点刷新一定要回执** ——
  /// 那个按钮以前按下去没有任何可见反应，用户只能怀疑是不是坏了。
  Future<void> _refreshRemote({bool silent = false}) async {
    final l10n = AppLocalizations.of(context);
    if (!silent) {
      setState(() {
        _busy = true;
        _refreshing = true;
        _message = null;
      });
    }
    try {
      final list = await ref.read(pushServiceProvider).remoteMailboxes();
      if (!mounted) return;
      setState(() => _remoteMailboxes = list);
      if (!silent) {
        _setMessage(
          list.isEmpty
              ? l10n.pushRefreshedEmpty
              : l10n.pushRefreshed(list.length),
          error: false,
        );
      }
    } on AppException catch (e) {
      // 以前这里把异常一路吞进「一份空列表」里，于是「中转连不上」和
      // 「一个邮箱都没登记」在界面上长得一模一样。
      if (mounted && !silent) _setMessage(e.userMessage, error: true);
    } finally {
      if (mounted && !silent) {
        setState(() {
          _busy = false;
          _refreshing = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final push = ref.read(pushServiceProvider);
    await push.configure(
      relayUrl: _relay.text,
      instanceId: _instanceId.text,
      pairingCode: _code.text,
    );
    // 设备号可能刚刚因为换了实例位被重掷（`configure` 内部做的），
    // 显示区要跟上，否则用户看到的是上一个实例位的前缀。
    await _syncDeviceId();
    if (!mounted) return;
    // 用户可能刚改过配对码/实例位 —— 显示区与自检结论都得跟着变，
    // 否则「复制」出去的是上一次的密钥。
    setState(() {
      _pairingCode = _code.text.trim();
      // 本次会话拿到的 webhookSecret 是**某个实例位**的。实例位改了它就
      // 作废 —— 继续显示只会把上一个位的密钥填进新位。
      if (_sessionWebhookSecret.isNotEmpty &&
          _webhookSecretSlot != _instanceId.text.trim()) {
        _sessionWebhookSecret = '';
        _webhookSecretSlot = '';
      }
      _verify = null;
      _verifyInputs = '';
    });
  }

  /// 部署者一键开通：在中转端现开一个实例位，把 id 与两个凭证一起拿回来。
  ///
  /// 这是「配对码从哪来」这个问题的**唯一一个真正的自动答案**（另一个是
  /// 构建期 `--dart-define` 注入）。拆分之后两个值的落点不同：
  ///
  /// - `deviceCode`（设备配对码）→ 立刻落进 `TokenStore`（见 [_save]），
  ///   它就是输入框里那个「配对码」；
  /// - `webhookSecret` → **只留在内存**（[_sessionWebhookSecret]），这一页
  ///   显示 / 可复制一次，不落盘。它权限更大（能伪造 webhook），不该躺在
  ///   这台设备上。
  Future<void> _provision() async {
    final token = _adminToken.text.trim();
    if (token.isEmpty) {
      _setMessage(AppLocalizations.of(context).pushAdminTokenNeeded, error: true);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final client = RelayClient(baseUrl: _relay.text);
      if (!client.isConfigured) {
        _setMessage(AppLocalizations.of(context).serverAddressRequired, error: true);
        return;
      }
      final inst = await client.createInstance(
        adminToken: token,
        // 备注名只影响部署者在中转端列表里看到的那一行。用 App 名字而不是
        // 设备号：一个部署者多半会开好几个位，`a1b2c3…` 这种名字对不上
        // 「哪个是我的平板」。
        name: AppLocalizations.of(context).appTitle,
      );
      if (!mounted) return;
      _instanceId.text = inst.instanceId;
      _code.text = inst.deviceCode;
      // 立刻落盘 + 刷新显示区：设备配对码以后还要用来注册 / 读事件，
      // 留在输入框里而没落库的话，用户一去不返就得到中转端轮换一次。
      await _save();
      if (!mounted) return;
      final hasDeviceCode = inst.deviceCode.isNotEmpty;
      setState(() {
        _pairingCode = inst.deviceCode;
        // webhookSecret 只进内存。为空（老中转端）时也不假装拿到了。
        _sessionWebhookSecret = inst.webhookSecret;
        // 记下它属于哪个位：上面那次 `_save` 已经可能把旧的清掉了。
        _webhookSecretSlot = inst.instanceId;
        _verify = null;
        _verifyInputs = '';
      });
      // `deviceCode` 为空只可能是「中转端比这个 App 还老」—— 它的管理面
      // 还不回这个字段。新 App 不能把 webhookSecret 回落成配对码存起来
      // （那是拆分之前的行为），所以这里只能如实说：位开出来了、webhook
      // 密钥也拿到了，但设备配对码得手动填（或先把中转端升级）。
      _setMessage(
        hasDeviceCode
            ? AppLocalizations.of(context).pushAutoProvisionDone
            : AppLocalizations.of(context).pushAutoProvisionNoDeviceCode,
        error: !hasDeviceCode,
      );
    } on AppException catch (e) {
      if (!mounted) return;
      _setMessage(e.userMessage, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 第 ⑥ 页唯一的动作：一次问清整条链路。
  ///
  /// 先 `_save()` 是为了让用户「改完输入框直接点检查」也能生效 ——
  /// 和总开关那边的处理一样，输入框里的值必须先落盘才作数。
  ///
  /// 中转连不上就直接停：`verifyWebhook` 走的是同一个 host，再问一次只
  /// 会拿到同一句错误，两句一样的报错是噪音。
  Future<void> _chainCheck() async {
    // 先取好翻译：下面 `_save()` 之后 `context` 就跨了 async gap，
    // 而在那之后再 `of(context)` 就得先 `mounted` 判一次 —— 直接拿
    // 现成的那份更省事，也不会随 `_message` 一起被重建掉。
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _checking = true;
      _message = null;
    });
    try {
      await _save();
      final inputs = _inputsFingerprint();
      final url = _relay.text.trim();
      if (url.isEmpty) {
        _setMessage(l10n.serverAddressRequired, error: true);
        return;
      }
      final push = ref.read(pushServiceProvider);
      final health = await push.checkRelay(url);
      if (!mounted) return;
      setState(() {
        _health = health;
        // 记下这份健康检查是拿**哪个地址**问出来的：用户在地址框里改了域名
        // 再点检查（或者加载时那次与手动那次交错）时，`_health` 可能属于上
        // 一个地址，于是「中转连不上」会被算成「FCM 没配」而给一个绿勾。
        _healthUrl = url;
      });
      // 顺带把用户填的地址一起送过去，让中转端比一下路径 ——
      // 「配对码对但地址少了个尾巴」是最常见的一种手滑。
      final result = await push.verifyWebhook(webhookUrl: _webhookUrlPreview());
      if (!mounted) return;
      setState(() {
        _verify = result;
        _verifyInputs = inputs;
      });
      // 结论通过就把这份「上一次是好的」记进钥匙串 —— 用户报的那条
      // 「第六步检查过了，再进来还是未完成」正是因为以前只有内存里的
      // `_verify` 算数，退出这一页就没了。不通过就把它**清掉**，让重新
      // 检查真的能翻盘；失败本身不写见证值（当场显示就够了，记下来只会
      // 在下次进来时给一个他其实已经处理过的红叉）。
      //
      // 判据与 [_chainVerified] 共用 `chainCheckPassed`：一处存见证值、
      // 一处打勾，两处必须是同一个答案（拆分之后凭证那项优先取 `codeOk`，
      // 见契约 §4.4）。
      final ok = chainCheckPassed(
        codeOk: result.codeOk,
        secretOk: result.secretOk,
        urlOk: result.urlOk,
        fcmConfigured: health.fcmConfigured,
      );
      // 一起把「中转端当时记着的最近一次事件」写进去：用户下次进来只看
      // 第 ⑤ 页时，那是唯一一条不靠自述的证据（见 [instanceStepDone]）。
      final witness = ok ? _witnessValue(evidence: result.lastEventAt ?? '') : '';
      setState(() => _chainWitness = witness);
      await _saveWitness(_kChainStep, witness);
    } on AppException catch (e) {
      if (!mounted) return;
      _setMessage(e.userMessage, error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _checking = false;
        });
      }
    }
  }

  /// 当前输入框里那几条值的指纹，用来判断上一次检查结论还有没有效。
  String _inputsFingerprint() =>
      '${_relay.text.trim()}|${_instanceId.text.trim()}|${_code.text.trim()}';

  /// 应该填进实例后台的完整地址。
  ///
  /// 用**用户自己填的中转地址**拼，而不是等中转端回一个 origin：中转端
  /// 看到的是「边缘那一跳」（本地开发时是 localhost、绑了自定义域之后
  /// 可能是 worker.dev 子域），而用户在实例后台里该填的是**他自己配的
  /// 那个地址**。检查返回的 `webhookUrl` 只作为兜底。
  String _webhookUrlPreview() {
    final base = _relay.text.trim().replaceAll(RegExp(r'/+$'), '');
    final slot = _instanceId.text.trim();
    final fallback = _verify?.webhookUrl ?? '';
    if (base.isEmpty || slot.isEmpty) return fallback;
    // 用户可能已经粘了完整地址（带 /<slot>/webhook），那就别重复拼。
    if (base.endsWith('/$slot/webhook')) return base;
    return '$base/$slot/webhook';
  }

  Future<void> _copy(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    _setMessage(AppLocalizations.of(context).pushCopied, error: false);
  }

  /// 把第 ⑤ 页那两条值拼成一段现成的话，给「不是我在管」的人直接转发。
  ///
  /// 分两版，因为 webhookSecret 现在**只在本次会话一键开通拿回来时**才在
  /// App 里出现：
  /// - 手上有 secret → 老文案，地址 + 密钥一起给；
  /// - 手上没有 → 只给地址，并说明密钥要另外向**中转位的创建者**要。把
  ///   「去要一个 secret」这一步说清楚，比让收信的人对着半句话猜要好。
  Future<void> _copyRelayMessage() async {
    final l10n = AppLocalizations.of(context);
    final url = _webhookUrlPreview();
    final secret = _sessionWebhookSecret;
    await _copy(
      secret.isEmpty
          ? l10n.pushPageWebhookRelayMessageNoSecret(url)
          : l10n.pushPageWebhookRelayMessage(url, secret),
    );
  }

  Future<void> _register() async {
    setState(() {
      _busy = true;
      _registering = true;
      _message = null;
    });
    try {
      await _save();
      // 这句话是第 ④ 页那句「第一次点登记时系统会问通知权限」的兑现处。
      // FCM 自己那条 `requestPermission` 只管 Apple 那侧与（新版插件才有的）
      // Android 13+；本地通知插件这条才是 **POST_NOTIFICATIONS** 的正主。
      // 两个都可能已经问过，插件里都对同一个 Future 做了缓存，重复调无副作用。
      await ref.read(notificationServiceProvider).ensurePermission();
      if (!mounted) return;
      final result = await ref.read(pushServiceProvider).syncAll(reason: '手动');
      if (!mounted) return;
      _setMessage(result.message, error: !result.ok);
      await _refreshRemote(silent: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _registering = false;
        });
      }
    }
  }

  Future<void> _unregister() async {
    setState(() {
      _busy = true;
      _unregistering = true;
      _message = null;
    });
    try {
      await _save();
      final result = await ref.read(pushServiceProvider).unsubscribe();
      if (!mounted) return;
      _setMessage(result.message, error: !result.ok);
      await _refreshRemote(silent: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _unregistering = false;
        });
      }
    }
  }

  /// 第 ① 页那个「重新检查状态」。
  ///
  /// `_load()` 本身要能在进入页面时静默跑（那时 `_loaded` 还是 false，
  /// 页面在转圈），所以「转圈 + 回执」这两件事由这里补 —— 手动点的时候
  /// 用户需要知道它在飞、也需要知道飞完看到了什么。
  Future<void> _recheck() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _refreshing = true;
      _message = null;
    });
    try {
      await _load();
      if (!mounted) return;
      _setMessage(
        _remoteMailboxes.isEmpty
            ? l10n.pushRefreshedEmpty
            : l10n.pushRefreshed(_remoteMailboxes.length),
        error: false,
      );
    } on AppException catch (e) {
      if (mounted) _setMessage(e.userMessage, error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _refreshing = false;
        });
      }
    }
  }

  /// 记下一条一次性回执。它**不在页面里长住** —— 见 [_drainMessage]。
  void _setMessage(String message, {required bool error}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = error;
      _messageSeq++;
    });
  }

  /// 一条一次性回执 → **SnackBar**（用完即走的 toast）。
  ///
  /// ## 为什么不再是一条常驻的 PushNotice
  ///
  /// 以前这里是页面底部的一条 `PushNotice`，而它在 `_navBar` 上方、
  /// `IndexedStack` 之外 —— 于是**横跨全部七页**：登记完邮箱之后那句话会
  /// 一直挂在下面，翻到第 ⑤ 页还在，看起来像一条「当前状态」而不是「刚才
  /// 那一下的回执」。要判断「到底登记上没有」，正确的落点是第 ① 页那三行
  /// 与第 ④ 页的邮箱列表 —— 它们才是一直在刷新的事实。所以这里改成
  /// toast：说一次就走，哪个页面都不留痕。
  ///
  /// ## 为什么推迟到帧结束
  ///
  /// `showSnackBar` 内部会 `setState`，在 `build` 期间调用会撞上
  /// 「setState() called during build」的断言 —— 而有一条路径恰好在
  /// build 期间就有待消费的回执：`_prefillFromBuild` 是在 `_load` 的那次
  /// `setState` 里带着 `_message` 一起落下的。
  ///
  /// 去重用 [_messageSeq] 而不是文案本身：同一句话连说两遍（连点两次
  /// 「复制」）也该各弹一次。
  void _drainMessage(BuildContext context) {
    final message = _message;
    if (message == null || _messageSeq == _lastDrainedSeq) return;
    _lastDrainedSeq = _messageSeq;
    final error = _messageIsError;
    // 优先用第一帧抓下来的那个；兜底再看一次 context（`build` 里
    // `ScaffoldMessenger.of(context)` 是安全的，它在上面几层）。
    final messenger = _messenger ?? ScaffoldMessenger.maybeOf(context);
    _messenger = messenger;
    // 颜色要在这一帧里读出来：post-frame 里这个 `context` 可能已经失效。
    final errorColor = Theme.of(context).colorScheme.error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? errorColor : null,
          // 报错要留够读完的时间（它们通常还带着「该去改哪一处」）。
          duration: Duration(seconds: error ? 6 : 3),
        ),
      );
    });
  }

  // ------------------------------------------------------------ 向导状态

  /// 喂给 [pageDone] 的那几件本机事实。
  PushFacts get _facts {
    final push = ref.read(pushServiceProvider);
    final slot = _instanceId.text.trim();
    return PushFacts(
      available: push.available,
      hasFirebaseConfig: push.hasFirebaseConfig,
      relayUrl: _relay.text.trim(),
      instanceId: slot,
      hasPairingCode: _code.text.trim().isNotEmpty,
      deviceIdValid: PushService.deviceIdMatchesInstance(_deviceId, slot),
      enabled: _enabled,
      enrolledMailboxes: _remoteMailboxes.length,
      instanceConfirmed: _witnessValid(_webhookWitness),
      // 中转端「最近一次真的收到 webhook」的时间。本次会话问过就用问出来
      // 的那个，没问过就退回上次存下的那份 —— 不然用户配好了、中转端也确
      // 实收到过信，只是这次没点「检查」，第 ⑤ 页照样显示成没做。
      chainEventAt: _verify?.lastEventAt ?? _rememberedEvent,
    );
  }

  /// 第 ⑥ 页「检查过了吗、过了吗」。
  ///
  /// 四个条件缺一不可：**这次真的问过**（有结论、且输入没被改过）、
  /// **凭证与地址都对**、**中转端有 FCM 服务账号**（没有它，前面全对也
  /// 投不出去）、以及**那次问的是一个能用的中转地址**。
  ///
  /// 凭证那一项的判断放在 [chainCheckPassed] 里（纯函数、可单测）：
  /// App 送的是设备配对码，所以看 `codeOk`；老的 `secretOk` 只在更老的
  /// 中转端上出现，两者取先有的那个。
  ///
  /// 最后一条是补上的一个真 bug：`_health` 曾经可能属于**上一个**地址
  /// （用户在地址框里改了域名再点检查，或者加载时那次检查与手动检查交错），
  /// 于是「中转连不上」会被算成「FCM 没配」而给一个绿勾。现在记下那份
  /// 健康检查是拿哪个地址问出来的，地址一变就作废。
  ///
  /// 返回 `null` 表示「还没得出过有效结论」—— 页面上显示「待你自己确认」
  /// 而不是红叉。**从钥匙串里读回来的那份上次结论不参与这里**：它只用来
  /// 决定进度条上那个勾要不要打（见 [_chainDone]），因为「上次通过」和
  /// 「这一次通过」在页面上要说的话不一样。
  bool? get _chainVerified {
    final result = _verify;
    if (result == null || _verifyInputs != _inputsFingerprint()) return null;
    if (!chainCheckPassed(
      codeOk: result.codeOk,
      secretOk: result.secretOk,
      urlOk: result.urlOk,
      fcmConfigured: _health?.fcmConfigured ?? false,
    )) {
      return false;
    }
    if (_healthUrl != _relay.text.trim()) return false;
    return true;
  }

  /// 进度条上第 ⑥ 页那个勾：本次会话的有效结论，**或者**上次会话存下来的
  /// 那份通过记录（输入没改过才算）。
  ///
  /// 这正是用户报的「第六步检查链路都成功了，再次进来还是显示未完成的
  /// 原因」—— 以前只有内存里的 `_verify` 算数，重启一次就没了。
  bool? get _chainDone {
    final live = _chainVerified;
    if (live != null) return live;
    // 存下来的是「通过」，没有「失败」的见证值 —— 失败让他当场看到就够了，
    // 记下来只会在下次进来时给一个他其实已经处理过的红叉。
    if (_witnessValid(_chainWitness)) return true;
    return null;
  }

  /// 跳页。第 ① 页那三行状态与底部那两个钮都走这里。
  void _goTo(int page) {
    if (page < 0 || page >= pushPageCount || page == _page) return;
    setState(() => _page = page);
  }

  /// 第 ① 页那三行状态各自该跳去哪一页。
  void _goToPage(PushPage page) => _goTo(pageIndexOf(page));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    // 回执统一在这里消费一次：七页里任何一页触发的动作，toast 都从同一个
    // 出口弹出，且**不在任何一页上留下常驻的东西**。
    _drainMessage(context);

    final body = Column(
      children: <Widget>[
        _progress(l10n),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(
            index: _page,
            children: <Widget>[
              for (final page in PushPage.values) _pageBody(page, l10n),
            ],
          ),
        ),
        _navBar(l10n),
      ],
    );

    // 内嵌形态（宽屏右栏）：**不套 `PopScope`**。那个 `PopScope` 拦的是
    // 「系统返回键 = 上一步」，而它只在窄屏成立 —— 窄屏下这一块占着整个
    // 分支的 Navigator 页，返回键该表示「退出这一页」。宽屏下它挂在设置页
    // 内部，返回键姓「设置」不姓「推送」，套上去只会把设置页的退出也吃成
    // 「上一步」。
    if (widget.onExit == null) return body;

    return PopScope(
      // 不在第一页时，系统返回键解释成「上一步」而不是「离开这一页」。
      // 只拦**手势/返回键**：末页那个「完成」（走 [onExit]）照旧直接生效
      // —— 否则「完成」会被这里解释成「上一步」，点不动。
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goTo(_page - 1);
      },
      child: body,
    );
  }

  // ------------------------------------------------------------ 骨架

  /// 顶部的进度：七个圆点（做过的打勾）+ 一句「第 N 步 / 共 7 步」。
  ///
  /// 圆点不只是装饰：它同时回答了「还有几步不用管」——做过的那几步会带 ✓。
  Widget _progress(AppLocalizations l10n) {
    final facts = _facts;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.pushPageStepOf(_page + 1, pushPageCount),
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (final page in PushPage.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _dot(
                    done: pageDone(
                          page,
                          facts,
                          // 第 ⑥ 页用 [_chainDone] 而不是 [_chainVerified]：
                          // 后者是「**这一次**问过且通过」，前者还认上次会话
                          // 存下来的那份通过记录 —— 圆点回答的是「这一步做过
                          // 没有」，不该因为重启一次就把勾抹掉。
                          chainVerified: page == PushPage.check
                              ? _chainDone
                              : _chainVerified,
                        ) ==
                        true,
                    current: pageIndexOf(page) == _page,
                  ),

                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot({required bool done, required bool current}) {
    final scheme = Theme.of(context).colorScheme;
    final size = current ? 16.0 : 10.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? scheme.primary
            : current
                ? scheme.primary
                : scheme.surfaceContainerHighest,
      ),
      child: done
          ? Icon(Icons.check, size: size * 0.7, color: scheme.onPrimary)
          : null,
    );
  }

  /// 底部的两个导航钮。
  ///
  /// **主动作不在这里** —— 它长在每一页的正文里。把「保存」「登记」这类
  /// 动作和「上一步 / 下一步」并排放，正是改造之前「六个按钮长得一样」的
  /// 根源：用户分不清哪个是做事、哪个是走路。
  Widget _navBar(AppLocalizations l10n) {
    final last = _page == pushPageCount - 1;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: <Widget>[
            TextButton.icon(
              onPressed: _page == 0 ? null : () => _goTo(_page - 1),
              icon: const Icon(Icons.chevron_left),
              label: Text(l10n.pushPageBack),
            ),
            const Spacer(),
            if (last)
              // 内嵌形态（`onExit == null`）**不画**「完成」：宽屏下左右两栏
              // 都在屏幕上，没有可退的地方，分类栏就是出口（左边的「上一步」
              // 照旧可用）。窄屏下它走 `onExit` 退回分类列表 —— 用回调而不是
              // `Navigator.pop()`，因为这一块在内嵌形态下根本不是一页路由，
              // `pop()` 会把设置页自己弹掉。
              if (widget.onExit != null)
                FilledButton.icon(
                  onPressed: widget.onExit,
                  icon: const Icon(Icons.check),
                  label: Text(l10n.pushPageDone),
                )
            else
              FilledButton.icon(
                onPressed: () => _goTo(_page + 1),
                icon: const Icon(Icons.chevron_right),
                label: Text(l10n.pushPageNext),
              ),
          ],
        ),
      ),
    );
  }

  /// 一页的正文。每页都自带滚动 —— `IndexedStack` 会把七页全建出来，
  /// 各自的滚动位置因此也各自留着。
  Widget _pageBody(PushPage page, AppLocalizations l10n) => switch (page) {
        PushPage.status => _statusPage(l10n),
        PushPage.threeValues => _valuesPage(l10n),
        PushPage.enable => _enablePage(l10n),
        PushPage.register => _enrollPage(l10n),
        PushPage.instance => _instancePage(l10n),
        PushPage.check => _checkPage(l10n),
        PushPage.limits => _notesPage(l10n),
      };

  /// 页首那三行：标题、一句「这一页干什么」。
  Widget _header(String title, String body, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(body, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
      ],
    );
  }

  /// 一页的主动作：一句说明 + 一个按钮（或开关）。页面里唯一的实心钮。
  Widget _action({required Widget child, String? hint}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        child,
        if (hint != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(hint, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ ① 状态

  Widget _statusPage(AppLocalizations l10n) {
    final push = ref.watch(pushServiceProvider);
    final theme = Theme.of(context);
    final configured = push.isConfigured;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageStatusTitle, l10n.pushPageStatusBody, l10n),

        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            push.available ? Icons.phone_android : Icons.phonelink_off,
            color: push.available ? theme.colorScheme.primary : theme.colorScheme.error,
          ),
          title: Text(l10n.pushPageStatusPlatform),
          subtitle: Text(
            !push.available
                ? l10n.pushUnsupported
                : push.hasFirebaseConfig
                    ? l10n.pushPageStatusOk
                    : l10n.pushNoFirebaseConfig,
          ),
          // 平台是这份构建天生的属性，没有可去的一页。
          trailing: push.available && push.hasFirebaseConfig
              ? const Icon(Icons.check, size: 18)
              : null,
        ),

        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            configured ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: configured ? theme.colorScheme.primary : theme.colorScheme.outline,
          ),
          title: Text(l10n.pushPageStatusConfigured),
          subtitle: Text(configured ? l10n.pushPageStatusOk : _missingValues(l10n)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _goToPage(PushPage.threeValues),
        ),

        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            _remoteMailboxes.isNotEmpty
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            color: _remoteMailboxes.isNotEmpty
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          title: Text(l10n.pushRegistrations),
          subtitle: Text(
            _remoteMailboxes.isEmpty
                ? l10n.pushRegistrationsEmpty
                : l10n.pushPageStatusRegisteredCount(_remoteMailboxes.length),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _goToPage(PushPage.register),
        ),

        const SizedBox(height: 8),

        // 开关关着是「三行全绿但一条推送都没有」的常见成因，所以单独提，
        // 并给一个直达第 ③ 页的钮 —— 用户不必自己数到第三页。
        if (!_enabled) ...<Widget>[
          PushNotice(
            icon: Icons.pause_circle_outline,
            text: l10n.pushPageStatusOff,
            tone: PushTone.warn,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: FilledButton.tonal(
                onPressed: () => _goToPage(PushPage.enable),
                child: Text(l10n.pushPageStatusGo),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],

        if (_remoteMailboxes.isNotEmpty) ...<Widget>[
          const Divider(),
          for (final mailbox in _remoteMailboxes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.mail_outline, size: 18),
              title: Text(mailbox),
            ),
        ],

        const Divider(),
        Text(l10n.pushHint, style: theme.textTheme.bodySmall),

        // 设备号从这里露出来。它**默认是收起的**，因为绝大多数用户一辈子
        // 不需要知道它有值 —— 但又不能不给：它是排查「为什么这台设备收不到」
        // 时唯一能拿去和中转端对质的东西。
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.tune),
          title: Text(l10n.pushAdvanced),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(l10n.pushDeviceIdHint, style: theme.textTheme.bodySmall),
            ),
            PushCopyRow(
              label: l10n.pushDeviceId,
              value: _deviceId,
              emptyHint: l10n.pushNotConfigured,
              copyLabel: l10n.pushCopy,
              onCopy: _copy,
            ),
          ],
        ),

        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            // 这个钮要重跑整个 `_load()`：读钥匙串、修设备号、问一次
            // `/devices` 三趟异步。真机上有时要好几秒 —— 期间必须让用户
            // 看见它在飞，否则「点了没反应」只会被再点一遍。
            onPressed: _busy ? null : _recheck,
            icon: _refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(
              _refreshing ? l10n.pushChecking : l10n.pushPageRecheck,
            ),
          ),
        ),
      ],
    );
  }

  /// 三条值里缺了哪几条 —— 只说缺的那些，齐了就没人调这个。
  String _missingValues(AppLocalizations l10n) {
    final missing = <String>[
      if (_relay.text.trim().isEmpty) l10n.pushRelayUrl,
      if (_instanceId.text.trim().isEmpty) l10n.pushInstanceId,
      if (_code.text.trim().isEmpty) l10n.pushPairingCode,
    ];
    return missing.join(' · ');
  }

  // ------------------------------------------------------------ ② 三条值

  Widget _valuesPage(AppLocalizations l10n) {
    final push = ref.watch(pushServiceProvider);
    final theme = Theme.of(context);
    final locked = !push.available || _busy;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageValuesTitle, l10n.pushPageValuesBody, l10n),

        TextField(
          controller: _relay,
          enabled: !locked,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: l10n.pushRelayUrl,
            helperText: l10n.pushRelayUrlHint,
            prefixIcon: const Icon(Icons.cloud_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _instanceId,
          enabled: !locked,
          decoration: InputDecoration(
            labelText: l10n.pushInstanceId,
            helperText: l10n.pushInstanceIdHint,
            prefixIcon: const Icon(Icons.tag),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          enabled: !locked,
          decoration: InputDecoration(
            labelText: l10n.pushPairingCode,
            helperText: l10n.pushPairingCodeHint,
            prefixIcon: const Icon(Icons.key_outlined),
          ),
        ),

        const SizedBox(height: 20),
        _action(
          child: FilledButton.icon(
            onPressed: locked
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      await _save();
                      if (!mounted) return;
                      _setMessage(l10n.pushPageValuesSaved, error: false);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.pushPageValuesSave),
          ),
          hint: l10n.pushPageValuesKeep,
        ),

        const SizedBox(height: 16),

        // 这一段存在的唯一理由是：配对码**没有地方能查**。它是中转位创建
        // 时回显一次就再也读不回来的值（两边后端都读不回），所以用户看到
        // 「配对码」这个输入框时，正确的反应是「我去哪找」——而不是
        // 「我忘了」。这一段就是那个答案。
        //
        // 默认收起：只有部署者用得到，展开它是一次显式选择，不需要它的
        // 人看不到那个口令框。
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.auto_awesome),
          title: Text(l10n.pushPageValuesProvision),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.pushAutoProvisionHint,
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextField(
              controller: _adminToken,
              enabled: !locked,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.pushAdminToken,
                helperText: l10n.pushAdminTokenHint,
                prefixIcon: const Icon(Icons.admin_panel_settings_outlined),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: locked ? null : _provision,
                icon: const Icon(Icons.auto_awesome),
                label: Text(l10n.pushAutoProvision),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ ③ 开关

  Widget _enablePage(AppLocalizations l10n) {
    final push = ref.watch(pushServiceProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageEnableTitle, l10n.pushPageEnableBody, l10n),

        // 这一页唯一的东西，就是这一个开关。它大、它显眼、它没有邻居。
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(l10n.pushEnable),
            subtitle: Text(l10n.pushEnabledHint),
            value: _enabled,
            onChanged: _busy || !push.available ? null : _toggle,
          ),
        ),

        const SizedBox(height: 12),
        Text(l10n.pushPageEnableOff, style: theme.textTheme.bodySmall),

        if (!push.available) ...<Widget>[
          const SizedBox(height: 16),
          PushNotice(
            icon: Icons.phonelink_off,
            text: l10n.pushUnsupported,
            tone: PushTone.warn,
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ ④ 登记

  Widget _enrollPage(AppLocalizations l10n) {
    final push = ref.watch(pushServiceProvider);
    final theme = Theme.of(context);
    final ready = push.isConfigured && _enabled && push.available;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageEnrollTitle, l10n.pushPageEnrollBody, l10n),

        _action(
          child: FilledButton.icon(
            onPressed: !ready || _busy ? null : _register,
            // 登记要真的连一趟中转端（还要先问一次通知权限），在真机上
            // 往往是好几秒 —— 没有转圈的话用户只会以为按钮坏了，然后
            // 反复点。文案也跟着换成「登记中…」：光转圈不说在做什么，
            // 同样会让人怀疑卡住了。
            icon: _registering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(_registering ? l10n.pushRegistering : l10n.pushRegister),
          ),
          hint: ready ? null : l10n.pushPageEnrollBlocked,
        ),

        const SizedBox(height: 8),
        Text(l10n.pushPageEnrollPermission, style: theme.textTheme.bodySmall),

        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices_outlined),
          title: Text(l10n.pushRegistrations),
          subtitle: Text(
            _remoteMailboxes.isEmpty
                ? l10n.pushRegistrationsEmpty
                : l10n.pushPageStatusRegisteredCount(_remoteMailboxes.length),
          ),
          trailing: IconButton(
            // 刷新要给两样东西：**转圈**（正在飞）和**回执**（飞到哪了）。
            // 只有转圈的话，用户还是不知道「刷新出来的这份是不是我要的」
            // 或者「到底刷成功了没有」——那正是这个按钮最初的问题。
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: _refreshing ? l10n.pushRefreshing : l10n.refresh,
            onPressed: _busy || !push.isConfigured ? null : _refreshRemote,
          ),
        ),
        if (_remoteMailboxes.isNotEmpty)
          for (final mailbox in _remoteMailboxes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.mail_outline, size: 18),
              title: Text(mailbox),
            ),

        const Divider(),
        _action(
          child: TextButton.icon(
            onPressed: _busy || !push.isConfigured ? null : _unregister,
            icon: _unregistering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.notifications_off_outlined),
            label: Text(
              _unregistering ? l10n.pushUnregistering : l10n.pushUnregister,
            ),
          ),
          hint: l10n.pushPageEnrollUnsubHint,
        ),
      ],
    );
  }

  // ------------------------------------------------------------ ⑤ 实例后台

  /// 勾上 / 取消「我已在实例后台填好了」（第 ⑤ 页那一步的完成开关）。
  ///
  /// 勾上是**按当前这几条值**记一份见证（钥匙串，见 `TokenStore`）；取消就
  /// 删掉。所以改地址或配对码之后它会自己变回没勾 —— 那种情况下确实得回到
  /// 实例后台重新填一遍。
  ///
  /// `_verify` 不动：那个勾与「链路检查」各自独立（一个是「我填了」，一个是
  /// 「填对了、而且真通了」），不该互相清掉。
  Future<void> _setWebhookConfirmed(bool value) async {
    final witness = value ? _witnessValue() : '';
    setState(() => _webhookWitness = witness);
    await _saveWitness(_kWebhookStep, witness);
  }

  /// 「这个实例是你在管吗」—— 存 prefs。
  ///
  /// 它只决定要不要显示「复制转达文案」，但**它是个从没答过就永远问一遍的
  /// 问题**：以前那两个 chips 每次进来都是「都没选中」，看起来像用户从没
  /// 回答过。
  Future<void> _setAdminAnswer(bool value) async {
    setState(() => _isAdmin = value);
    await ref.read(prefsStoreProvider).setPushIsAdmin(value);
  }

  Widget _instancePage(AppLocalizations l10n) {
    final theme = Theme.of(context);
    // App 这一侧三条值齐没齐（地址 / 实例位 / **设备配对码**）。它们齐了才
    // 谈得上「去实例后台填 webhook」—— 地址和密钥都是从这条链路来的。
    final configured = _pairingCode.isNotEmpty;
    final hasAddress = _webhookUrlPreview().isNotEmpty;
    // 本次会话「一键开通」真的拿回来的 webhookSecret（只在内存里，见
    // [_sessionWebhookSecret]）。为空就一律不显示 —— 它由中转位的创建者
    // 保管，不再拿 App 里的设备配对码冒充。
    final sessionSecret = _sessionWebhookSecret;
    // 这一页 App **验证不了**（事情发生在另一个网站上），所以「做完了」的
    // 主判据是用户自己那个勾；中转端真的收到过 webhook 是唯一一个客观证据。
    final confirmed = _witnessValid(_webhookWitness);
    // 本次会话问过就用问出来的那个，没问过就用上次存下的那个 —— 只认内存
    // 的话，用户「配好了、收过信了、只是这次没点检查」再进来，这一页仍然
    // 只会说「待你自己确认」。
    final evidence = _verify?.lastEventAt ?? _rememberedEvent ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageWebhookTitle, l10n.pushPageWebhookBody, l10n),

        // 取代了原先的四选一身份选择器：真正影响这一页的只有**一件事**
        // ——「这个实例是不是你在管」，它决定要不要给你一段能直接转发的话。
        // 两条值在两种答案下都照常显示，所以这不是一个岔路口。
        //
        // 这个答案**会记住**（存 prefs）：它只是个分岔，但用户答过一次就是
        // 答过了 —— 以前每次进来都是两个都没选中的 chips，看起来像从没答过。
        Text(l10n.pushPageWebhookAdminAsk, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: Text(l10n.pushPageWebhookAdminYes),
              selected: _isAdmin == true,
              onSelected: (_) => _setAdminAnswer(true),
            ),
            ChoiceChip(
              label: Text(l10n.pushPageWebhookAdminNo),
              selected: _isAdmin == false,
              onSelected: (_) => _setAdminAnswer(false),
            ),
          ],
        ),

        if (_isAdmin == false) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            l10n.pushPageWebhookAdminOtherHint,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              // 转达文案只要求「地址拼得出来」—— 密钥那半句按手上有没有
              // secret 分两版（见 [_copyRelayMessage]），没有地址才禁用。
              onPressed: hasAddress ? _copyRelayMessage : null,
              icon: const Icon(Icons.forward_to_inbox_outlined),
              label: Text(l10n.pushPageWebhookRelayCopy),
            ),
          ),
        ],

        const SizedBox(height: 20),
        Text(l10n.pushWebhookHint, style: theme.textTheme.bodySmall),
        PushCopyRow(
          label: l10n.pushWebhookUrl,
          value: _webhookUrlPreview(),
          emptyHint: l10n.pushNotConfigured,
          copyLabel: l10n.pushCopy,
          onCopy: _copy,
        ),
        // 拆分之后 App 里的「配对码」是**设备配对码**，跟实例后台要填的
        // webhookSecret 是两个凭证（见 docs/push-setup.md）：
        // 前者可以公开、只用来注册设备；后者权限大得多，只有中转位创建者
        // 才有。所以这一栏只有**本次会话一键开通真的拿回了它**时才显示值，
        // 其余情况一律显示「由创建者保管」那句 —— 绝不拿配对码冒充。
        PushCopyRow(
          label: l10n.pushWebhookSecret,
          value: sessionSecret,
          emptyHint: l10n.pushWebhookSecretCustodian,
          copyLabel: l10n.pushCopy,
          onCopy: _copy,
          obscure: true,
        ),

        if (sessionSecret.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          // 只在这个会话里存在：用户不复制走、也不填进实例后台的话，
          // 离开这一页就再也读不到了（只能去中转端轮换一个）。
          PushNotice(
            icon: Icons.timer_outlined,
            text: l10n.pushWebhookSecretOnce,
            tone: PushTone.warn,
          ),
        ],

        if (!configured) ...<Widget>[
          const SizedBox(height: 8),
          // 还没配好三条值 —— 这一页恰恰是唯一需要地址与密钥的一页，
          // 得说清该回哪去。
          PushNotice(
            icon: Icons.key_off_outlined,
            text: l10n.pushNeedLoginFirst,
            tone: PushTone.info,
          ),
        ],

        const Divider(height: 24),

        // 「我填过了」那个勾 —— 它就是这一步的**完成开关**。
        // 不勾的话这一页会一直显示成没做（App 看不到另一个网站上的事），
        // 而那正是用户报的那个问题：明明已经在实例后台配好了，再进来还是
        // 「该步骤没有执行」。
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: confirmed,
          onChanged: configured
              ? (value) => _setWebhookConfirmed(value ?? false)
              : null,
          title: Text(l10n.pushPageWebhookConfirm),
        ),

        // 三句话互斥，说的都是「现在到底算不算做完了」：
        // 勾了 → 已确认；没勾但中转端真收到过 → 客观上通了；都不是 → 说明
        // 为什么得自己点一下。
        if (confirmed)
          PushNotice(
            icon: Icons.check_circle_outline,
            text: l10n.pushPageWebhookConfirmed,
            tone: PushTone.ok,
          )
        else if (evidence.isNotEmpty)
          PushNotice(
            icon: Icons.verified_outlined,
            text: l10n.pushPageWebhookEvidence(formatRelayTime(evidence)),
            tone: PushTone.ok,
          )
        else
          PushNotice(
            icon: Icons.help_outline,
            text: l10n.pushPageWebhookUnconfirmed,
            tone: PushTone.info,
          ),

        const SizedBox(height: 8),
        PushNotice(
          icon: Icons.info_outline,
          text: l10n.pushPageWebhookStatus0,
          tone: PushTone.info,
        ),
      ],
    );
  }

  // ------------------------------------------------------------ ⑥ 检查

  Widget _checkPage(AppLocalizations l10n) {
    final verified = _verify != null && _verifyInputs == _inputsFingerprint();
    // 本次没问过、但上次会话存下的那份通过记录还在（值也没改过）。
    final remembered = !verified && _witnessValid(_chainWitness);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageCheckTitle, l10n.pushPageCheckBody, l10n),

        // 这一页也只有一件事要做。「测试连接」与「自检」原来分成两个钮，
        // 用户得先猜哪个先点、再猜哪个的失败更严重 —— 它们问的其实是同
        // 一条链路上相邻的两段。
        _action(
          child: FilledButton.icon(
            onPressed: _busy || !ref.watch(pushServiceProvider).isConfigured
                ? null
                : _chainCheck,
            // 检查要连打两趟中转端（`/health` 与 `/verify-webhook`），
            // 秒级；转圈之外文案也换成「自检中…」，免得用户以为没点着。
            icon: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_outlined),
            label: Text(_checking ? l10n.pushChecking : l10n.pushPageCheckAction),
          ),
          hint: ref.watch(pushServiceProvider).isConfigured
              ? null
              : l10n.pushNeedLoginFirst,
        ),

        const SizedBox(height: 16),

        if (verified)
          PushSelfCheckResult(result: _verify!, l10n: l10n, health: _health),
        if (remembered)
          // 上次那一次是通过的，而且这几条值一个字都没改。旧代码只认内存里
          // 的结论，于是「检查链路都成功了，再进来还是未完成」—— 那句结论
          // 现在留在钥匙串里了，这里把它说出来（连同它是什么时候过的），
          // 进度条上那个勾也算数。
          PushNotice(
            icon: Icons.check_circle_outline,
            text: l10n.pushPageCheckRememberedAt(
              formatRelayTime(_witnessStampOf(_chainWitness)),
            ),
            tone: PushTone.ok,
          ),
        if (!verified && !remembered && _verify != null)
          // 输入改过之后旧的结论就作废了（指纹对不上）。明说一句，比让人
          // 对着一个说不清的空白猜要好 —— 那正是以前「配对码不对一直挂着」
          // 的反面：现在是「结论过期了」，两句话指的事不一样。
          PushNotice(
            icon: Icons.history_outlined,
            text: l10n.pushPageCheckStale,
            tone: PushTone.info,
          ),
        if (!verified && !remembered && _verify == null)
          // 从没检查过 —— 也明说一句。以前这一页在没结论时是完全空白的，
          // 用户看不出「是没查过」还是「查了但没画出结果」。
          PushNotice(
            icon: Icons.help_outline,
            text: l10n.pushPageCheckNever,
            tone: PushTone.info,
          ),
      ],
    );
  }

  // ------------------------------------------------------------ ⑦ 说明

  Widget _notesPage(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _header(l10n.pushPageNotesTitle, l10n.pushPageNotesBody, l10n),

        Text(l10n.pushLimits, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final line in <String>[
          l10n.pushLimit1,
          l10n.pushLimit2,
          l10n.pushLimit3,
          l10n.pushLimit4,
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('· '),
                Expanded(child: Text(line, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),

        const Divider(),
        Text(l10n.pushPageNotesTurnOff, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(l10n.pushPageNotesTurnOffBody, style: theme.textTheme.bodySmall),

        const SizedBox(height: 16),
        Text(l10n.pushPageNotesSwitchSlot, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(l10n.pushPageNotesSwitchSlotBody, style: theme.textTheme.bodySmall),

        const Divider(),
        // 从零搭一套的完整命令（建实例 / 建 Firebase / 部署中转）**不再
        // 内嵌在 App 里**：那是仓库作者自己的事，而且命令会随版本漂。
        // 留在文档里，App 只说它在哪。
        Text(l10n.pushPageDocsHint, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
