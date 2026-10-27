// `hide TimeoutException`：`dart:async` 也有一个 `TimeoutException`，
// 而这里要判的是我们自己的那个（`app_exception.dart`，dio 的超时被映射过去）。
// 不 hide 的话 `e is TimeoutException` 会是一个歧义引用，编译不过。
import 'dart:async' hide TimeoutException;
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../core/db/database.dart';
import '../../core/db/mappers.dart' show decodeAttachmentPaths;
import '../../core/error/app_exception.dart';
import '../../core/storage/local_file.dart';
import '../../data/models/enums.dart';
import '../../data/models/send_payload.dart';
import '../../data/models/send_quota.dart';
import '../../data/repositories/send_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import 'compose_draft.dart';
import 'compose_html.dart';
import 'compose_sender.dart';
import 'compose_text.dart';
import 'editor/image_insert.dart';
import 'html/delta_to_email_html.dart';
import 'html/document_codec.dart';

/// 写邮件页的状态。
///
/// 字段全在这里、动作全在 [ComposeController]：屏幕只做渲染与转发，
/// 这样「点发送之后到底发生了什么」只有一个地方需要读。
class ComposeState {
  const ComposeState({
    required this.args,
    required this.l10n,
    this.profileId = '',
    this.profileName = '',
    this.sender,
    this.senderGroups = const <SenderGroup>[],
    this.recipients = const <String>[],
    this.recipientInput = '',
    this.subject = '',
    this.body = '',
    this.bodyRevision = 0,
    this.attachments = const <SendAttachment>[],
    this.draftId,
    this.busy = false,
    this.progress,
    this.problems = const <String>[],
    this.notice,
    this.noticeIsError = false,
    this.quota = SendQuota.unknown,
    this.recipientSuggestions = const <({String address, String name})>[],
    this.dirty = false,
  });

  final ComposeArgs args;

  /// 本地化实例。由 `build()` 从 `l10nProvider` 取 —— 控制器要拼文案，
  /// 屏幕只负责显示。
  final AppLocalizations l10n;

  final String profileId;

  /// 实例显示名（标题栏）。
  final String profileName;

  /// 这一封信**实际**走哪台实例：选了发件人就跟着发件人走，还没选（或一个
  /// 邮箱都没有）时退回**进来时那台**。
  ///
  /// 控制器里所有「发信侧」的动作都读它，不读 [profileId]。后者的含义已经收窄成
  /// 「**进来时**那台实例」：它既是还没定发件人时的兜底值，也是 `_entryGroup`
  /// 定位入口那一组的键。
  String get sendProfileId => sender?.profile.id ?? profileId;

  /// 发件人：**实例 + 邮箱**（见 [SenderOption]）。null = 一个可用邮箱都没有。
  final SenderOption? sender;

  /// 可选的发件人，按实例分组（屏幕从 `composeSendersProvider` 递进来）。
  final List<SenderGroup> senderGroups;

  /// 已确认的收件人。
  final List<String> recipients;

  /// 收件人输入框里**还没提交**的那半截文字。
  final String recipientInput;

  final String subject;

  /// 正文（一份 Delta JSON）。
  ///
  /// 由页面在编辑器变化**防抖之后**回写（`ComposeScreen._pushBody`）——
  /// 每个字符回写一次的话，带一张 5 MB 图的正文每敲一个字要 base64 编码
  /// 一次 7 MB 的字符串（25 ms）。
  final String body;

  /// 正文**换过一次初值**的计数。
  ///
  /// 「编辑器从 `state.body` 取正文」这件事不能只做一次：草稿是**异步**
  /// 读出来的（[ComposeController.build] 只能排一个 `scheduleMicrotask`），
  /// 而屏幕的第一帧 `build()` 跑在它前面 —— 那一次 `state.body` 还是预填值
  /// （空写信页就是 `''`）。所以要有一个信号告诉屏幕「现在这一份正文是权威
  /// 的，去把它装进编辑器」。
  ///
  /// 为什么用**单调递增的计数**而不是一个 `bool`：连续开两条草稿时，两次
  /// 装载的对象是**两个不同的屏幕实例**（各自一份 `_bodyRevision`），一个
  /// bool 第二次也是 `true`，第二次装载会被吃掉 —— 计数则每次都变。
  ///
  /// 方向的约定：这里是「**上次装的初值是哪一版**」，屏幕那边是「**装到第
  /// 几版了**」。第一帧两者正好相等（`0`），于是不需要装。用户自己打字时
  /// `_pushBody` 把屏幕的版次**原样**回传过来，两边继续相等 —— 一次多余的
  /// 装载就不会发生。`_restoreDraft` / `_finishCompose` 换初值时把它 +1，
  /// 两边不等，屏幕便去装一次。
  final int bodyRevision;

  final List<SendAttachment> attachments;

  final int? draftId;

  final bool busy;

  /// 发送进度 0–1；null = 进度不可知（body 还在组装）。
  final double? progress;

  /// 上一次发送的失败原因。**一次给全**，与服务端
  /// `SendValidationException.reasons` 同一口径：一条一条试最烦人。
  final List<String> problems;

  /// 一次性提示（「已发送」「已放进发件箱」）。屏幕弹完调 `consumeNotice`。
  final String? notice;

  /// [notice] 是不是一条坏消息（决定 SnackBar 的颜色）。
  final bool noticeIsError;

  final SendQuota quota;

  final List<({String address, String name})> recipientSuggestions;

  /// 内容被改过没有（决定退出时要不要问「放弃修改？」）。
  final bool dirty;

  /// 有效的收件人 = 已确认的 + 输入框里还没回车的。
  List<String> get effectiveRecipients {
    final all = <String>[...recipients, ...splitAddresses(recipientInput)];
    final unique = <String>[];
    for (final address in all) {
      if (!unique.any((e) => e.toLowerCase() == address.toLowerCase())) {
        unique.add(address);
      }
    }
    return unique;
  }

  String get previewSubject =>
      subject.trim().isEmpty ? l10n.noSubject : subject.trim();

  /// 附件总量（字节）。
  int get attachmentBytes =>
      attachments.fold<int>(0, (sum, a) => sum + a.size);

  /// 正文里的内联图张数。
  ///
  /// 从 Delta 上数，不在 HTML 串上跑正则：Delta 里是
  /// `{"image":"data:image/png;base64,…"}`（**冒号**分隔），
  /// 而原来那个 `src\s*=\s*["']data:image` 找的是 HTML 的**等号** ——
  /// 换成 Delta 之后它会安静地恒返回 0，而 `SendValidationError.tooManyInlineImages`
  /// 也就跟着永不触发。
  int get inlineImageCount => ImageInsert.countInlineImages(_deltaOf(body));

  /// 正文 Delta 的 op 列表。解析不出来时给空表 —— 这个数只用于提示，
  /// 拿一个「解析失败」去炸掉整个写邮件页不值当。
  static List<dynamic> _deltaOf(String body) {
    if (body.trim().isEmpty) return const <dynamic>[];
    try {
      final decoded = jsonDecode(body);
      return decoded is List ? decoded : const <dynamic>[];
    } catch (_) {
      return const <dynamic>[];
    }
  }

  /// 现在**为什么**不能发；null = 可以发。
  ///
  /// 做成 getter 而不是 state 里的一个字段：判断依据全部来自 [sender] 与
  /// [quota]，再存一份就成了第三个真相源，迟早会和前两个打架。
  String? get sendDisabledReason {
    // 与发件人那一行同一口径（`sender_picker.dart` 也这么分）：候选整个空 =
    // 所有实例都发不了；候选非空却选不出 = 入口实例这台拿不到发件地址。两处若
    // 各说各的，同一时刻页面上会同时出现两句不一样的红字。
    if (sender == null) {
      return senderGroups.isEmpty
          ? l10n.composeNoMailbox
          : l10n.composeSenderUnavailable;
    }
    // 配额还没探测到时**不拦** —— 显示一个猜出来的「已用完」比放行更糟，
    // 真正的拒绝交给服务端（403 会带着它自己的文案回来）。
    if (!quota.known) return null;
    if (!quota.allowed) return l10n.composeQuotaBanned;
    if (quota.exhausted) return l10n.composeQuotaExhausted;
    return null;
  }

  bool get canSendNow => !busy && sendDisabledReason == null;

  ComposeState copyWith({
    AppLocalizations? l10n,
    String? profileName,
    SenderOption? sender,
    bool clearSender = false,
    List<SenderGroup>? senderGroups,
    List<String>? recipients,
    String? recipientInput,
    String? subject,
    String? body,
    int? bodyRevision,
    List<SendAttachment>? attachments,
    int? draftId,
    bool? busy,
    double? progress,
    List<String>? problems,
    String? notice,
    bool clearNotice = false,
    bool? noticeIsError,
    SendQuota? quota,
    List<({String address, String name})>? recipientSuggestions,
    bool? dirty,
  }) =>
      ComposeState(
        args: args,
        l10n: l10n ?? this.l10n,
        profileId: profileId,
        profileName: profileName ?? this.profileName,
        sender: clearSender ? null : (sender ?? this.sender),
        senderGroups: senderGroups ?? this.senderGroups,
        recipients: recipients ?? this.recipients,
        recipientInput: recipientInput ?? this.recipientInput,
        subject: subject ?? this.subject,
        body: body ?? this.body,
        bodyRevision: bodyRevision ?? this.bodyRevision,
        attachments: attachments ?? this.attachments,
        // 传 0 表示「草稿已经没了」。必须有这一条，因为 `copyWith` 里 null
        // 的语义是「不改」，而删掉草稿之后必须真的把 id 清掉 —— 留着一个
        // 已经不存在的 id，下一轮保存会 update 到 0 行，新写的内容静默丢失。
        draftId: draftId == 0 ? null : (draftId ?? this.draftId),
        busy: busy ?? this.busy,
        progress: progress,
        problems: problems ?? this.problems,
        notice: clearNotice ? null : (notice ?? this.notice),
        noticeIsError: noticeIsError ?? this.noticeIsError,
        quota: quota ?? this.quota,
        recipientSuggestions: recipientSuggestions ?? this.recipientSuggestions,
        dirty: dirty ?? this.dirty,
      );
}

/// 写邮件页的状态与动作。
///
/// 几条刻意的设计：
///
/// 1. **`build()` 只读一次快照，不 watch 流**。watch `mailboxesProvider`
///    这类流的话，后台每同步一次就会重算 provider，而重算会把 `state`
///    整个换回初始值 —— 用户正在打的字会被抹掉。所以可选的发件邮箱由
///    **屏幕** watch（它只影响渲染），选中的那一个存在这里。
/// 2. **正文的真相是 Delta JSON**（`state.body`），发信时才由
///    [DeltaToEmailHtml] 导出成邮件安全 HTML。曾经这里是纯文本、HTML 由
///    [ComposeHtml] 派生 —— 换成 Delta 之后引用块才能对用户可见可编辑
///    （spec §3.6），而「HTML 为真相」那条路在可编辑控件上一直走不通。
///    正文为空与否**在 Delta 上判**（`DocumentCodec.isEmptyDelta`）：
///    导出的 HTML 对空文档永远不是空串（`<p …><br></p>`），拿它当判据
///    会让 `SendValidationError.emptyContent` 永不触发。
/// 3. **本地预校验必须在发之前**：服务端的「≤10 附件 / ≤10 内嵌图」检查
///    发生在**插库之后**（计划约束 13），超限会留一条脏 `SAVING` 行。
/// 4. **失败之后的出路按「能不能确定没送达」分**
///    （见 [SendRepository.isRetryable]）：
///    - 确定没送达（连不上、未登录、校验没过）→ 内容存进本地草稿；
///      其中网络类的再排进发件箱自动重试；
///    - **不确定**（超时、响应不是 cloud-mail 信封）→ 只存草稿，并把这条
///      记成 `unknown` 状态的发件箱条目 + **明确告诉用户**「服务端可能
///      已经收到了」。这条最容易写错：`/email/send` 没有幂等键，
///      静默重试就是重复投递。
class ComposeController extends Notifier<ComposeState> {
  ComposeController(this.args);

  final ComposeArgs args;

  /// **进来时**那台实例（`build()` 里定下来，之后不再变）。
  ///
  /// 用途只剩两处：找草稿（草稿是按入口实例存的）、以及还没定发件人时的兜底。
  /// 发信侧要一律读 [_sendProfileId]。
  String _entryProfileId = '';

  /// 发信侧实例：跟着发件人走。
  String get _sendProfileId => state.sender?.profile.id ?? _entryProfileId;

  /// 这封信还该不该带 `args.mail` 那条线程（见 `buildPayload` 里的注释）。
  ///
  /// `state.sender != null` 那一句**不能删**：发件人还没定下来时
  /// `sendProfileId` 会退回入口实例，看着像是「还在入口实例上」，可这时
  /// `state.sender` 是空的，带 `emailId` 就是拿一个还没确认的身份去挂线程。
  bool get _useReplyThread =>
      (args.mode == ComposeMode.reply || args.mode == ComposeMode.replyAll) &&
      _entryProfileId.isNotEmpty &&
      state.sender != null &&
      state.sendProfileId == _entryProfileId;

  bool _restored = false;

  @override
  ComposeState build() {
    final l10n = ref.read(l10nProvider);
    final profileId = args.resolveProfileId(ref.read(currentProfileIdProvider));
    _entryProfileId = profileId;

    final profile =
        profileId.isEmpty ? null : ref.read(profileByIdProvider(profileId));
    final groups = ref.read(composeSendersProvider);

    final draft = ComposeDraftFactory.of(
      args,
      ossBase: ref.read(ossBaseProvider(_entryProfileId)),
      wroteLabel: l10n.wrote,
    );

    // 草稿与配额都要读库/打网络，推迟到帧后 —— `build()` 里不能 await。
    scheduleMicrotask(() => unawaited(_restoreDraft()));
    scheduleMicrotask(() => unawaited(refreshQuota()));
    // 先预取一遍「不带 query」的最近联系人：用户点进收件人框时（还没敲字）
    // 下拉里就该有东西可点。只在第一次 `setRecipientInput` 时查的话，
    // 空输入框永远不会弹建议 —— 那正是「自动提示」最该出现的时刻。
    scheduleMicrotask(() => unawaited(_refreshSuggestions('')));

    // 发件人先定下来：`replyAll` 的预填收件人要用它再滤一遍「自己」。
    final sender = _initialSender(_entryGroup(groups));

    return ComposeState(
      args: args,
      l10n: l10n,
      profileId: profileId,
      profileName: profile?.displayName ?? '',
      sender: sender,
      senderGroups: groups,
      // 「全部回复」的收件人预填按**这一封投递到的邮箱**去掉了自己；这里按
      // **实际发件邮箱**再滤一次：用户可能在同一个实例里换个邮箱回这封信，
      // 那个地址在原 Cc 里 —— 不滤就会给自己发一份。
      recipients: args.mode == ComposeMode.replyAll
          ? _withoutAddress(draft.recipients, sender?.email)
          : draft.recipients,
      subject: draft.subject,
      // 回复 / 转发时正文的初值就是引用块（spec §3.6：它对用户可见可编辑）。
      // 普通写信时 `draft.quoted` 是空串 —— 页面会用 `DocumentCodec.empty()`
      // 兜底，因为空串不是合法的 Delta（`Document.fromJson` 建不出来）。
      body: draft.quoted,
    );
  }

  /// 从 [recipients] 里去掉 [address]（忽略大小写）。地址为空时原样返回。
  static List<String> _withoutAddress(List<String> recipients, String? address) {
    final own = (address ?? '').trim().toLowerCase();
    if (own.isEmpty) return recipients;
    final kept =
        recipients.where((e) => e.toLowerCase() != own).toList(growable: false);
    return kept.length == recipients.length ? recipients : kept;
  }

  /// 默认发件人。
  ///
  /// 优先用调用方指定的那个（用户是从某个邮箱的收件箱点「写邮件」进来的），
  /// 找不到才落到这一组的第一个 —— 猜错邮箱会让用户用错身份发信，比多一次
  /// 查找值得。
  ///
  /// **只在入口实例这一组里找**：`args.accountId` 是路由上带来的「从这台实例
  /// 的哪个邮箱进来」，拿它去别的实例里按 `accountId` 匹配会命中一个毫不相干
  /// 的邮箱（`accountId` 只在实例内有意义）。
  SenderOption? _initialSender(SenderGroup? group) {
    if (group == null || group.mailboxes.isEmpty) return null;
    final options = group.options;
    final wanted = args.accountId;
    if (wanted > 0) {
      for (final option in options) {
        if (option.mailbox.accountId == wanted) return option;
      }
    }
    return options.first;
  }

  /// 入口实例那一组（`_initialSender` 的取数口）。
  ///
  /// 入口实例不在候选里时返回 null（发不了信、或者它的邮箱都是
  /// `accountId <= 0`）—— 那时 `sender` 为 null，与「这台实例一个可用邮箱
  /// 都没有」是同一件事，界面上的红字也说得清。
  SenderGroup? _entryGroup(List<SenderGroup> groups) {
    for (final group in groups) {
      if (group.profile.id == _entryProfileId) return group;
    }
    return null;
  }

  // ------------------------------------------------------------- 初始化

  /// 恢复这个实例的草稿。**有草稿就用草稿盖掉预填** —— 用户之前敲的东西
  /// 比我们猜的预填内容重要（回复一封写了一半退出去，回来时应该看到自己
  /// 写的那半封，而不是一个干净的引用块）。
  /// 从草稿箱接着写。
  ///
  /// **只有从草稿箱点进来（[ComposeArgs.hasDraftHint]）才会恢复**。
  /// 早先的写法是「取这个实例最近的一条草稿」，那让「点写邮件」变成一件
  /// 不可预测的事 —— 用户可能突然看到几天前写了一半的内容盖在自己的
  /// 回复预填上面，而且没有任何提示。既然是「没写完的东西」，
  /// 就该由用户在草稿箱里明确地把它打开。
  ///
  /// 从草稿箱进来时用户指的是**具体某一条**：退化成「最近的那条」会让
  /// 他点了第 3 条却打开了第 1 条。
  Future<void> _restoreDraft() async {
    if (_restored || _entryProfileId.isEmpty || !args.hasDraftHint) return;
    _restored = true;
    try {
      final draft = await ref
          .read(databaseProvider)
          .localDao
          .findDraft(args.draftId);
      if (draft == null || !ref.mounted) return;
      state = state.copyWith(
        draftId: draft.id,
        recipients: decodeRecipientAddresses(draft.recipientsJson),
        subject: draft.subject,
        body: draft.content,
        // 这是一次**换初值**：屏幕得把编辑器里的文档换成这一份（见
        // `ComposeState.bodyRevision`）。少了这一句，草稿正文就永远进不了
        // 编辑器 —— 用户看到空白页，随手敲一个字再退出还会把原正文覆盖掉。
        bodyRevision: state.bodyRevision + 1,
        attachments: _attachmentsFromPaths(
          decodeAttachmentPaths(draft.attachmentPathsJson),
        ),
        // 草稿内容就是「已经改过的东西」，退出时该问一次要不要留。
        dirty: true,
      );
    } catch (_) {
      // 草稿读不出来不该拦住写信 —— 从预填内容开始。
    }
  }

  /// 拉一次 `loginUserInfo` 算配额。
  ///
  /// 刻意**不做本地缓存**：`sendCount` 是服务端 `email` 表的计数，
  /// 其他设备与网页版发的信也算在内，缓存在本地只会给出一个越来越不准的
  /// 数字。代价是每次打开写邮件页多一次请求，换来「配额是真的」。
  Future<void> refreshQuota() async {
    if (_sendProfileId.isEmpty) return;
    final runtime = ref.read(runtimeProvider(_sendProfileId));
    if (runtime == null || runtime.isDisposed || !runtime.hasToken) return;
    try {
      final user = await runtime.myApi.loginUserInfo();
      if (!ref.mounted) return;
      state = state.copyWith(quota: SendQuota.fromUserInfo(user));
    } on AppException {
      // 配额拿不到就什么都不说（保持 `SendQuota.unknown`）——
      // 显示一个猜出来的「不限量」比不显示更糟。
      if (ref.mounted) state = state.copyWith(quota: SendQuota.unknown);
    }
  }

  // --------------------------------------------------------------- 编辑

  /// 屏幕把实时的候选递进来（见类注释第 1 条）。
  ///
  /// **「选中那个还在不在」必须连 `profileId` 一起比**：改造前只比
  /// `accountId`，而跨实例之后 A 的 `#3` 与 B 的 `#3` 会被当成同一个邮箱 ——
  /// 那会让「B 下线了」被误判成「选中的还在」，于是选中项指向一个已经不存在的
  /// 实例。
  void syncSenderGroups(List<SenderGroup> groups) {
    if (_sameGroups(groups, state.senderGroups)) return;
    final keep = state.sender;
    state = state.copyWith(
      senderGroups: groups,
      sender: _resolveSender(keep, groups),
      clearSender: groups.isEmpty,
    );
  }

  /// 保住原来那个（还在候选里时），否则落到**入口实例那一组的第一个**，
  /// 连入口实例都不在候选里（发不了信）才退到整体的第一个。
  ///
  /// **兜底必须和 `build()` 里那次同一个口径**（都经 [_initialSender] /
  /// [_entryGroup]）。`build()` 读 `composeSendersProvider` 时它的两条上游
  /// （profiles / mailboxes）还是空的，所以 `sender` 第一帧只能是 null ——
  /// 真正定下身份的是屏幕随后的 `ref.listen` 递进来这次同步。若这里图省事写
  /// `groups.first`，冷启动时默认发件人会落到**按 `sort` 排第一的实例**上，
  /// 而用户可能正站在第二个实例上：那是拿另一个账号的身份发信（回复模式下
  /// 还会因为 `_useReplyThread` 判定「换了实例」而把线程丢掉）。旧实现吃的是
  /// 入口实例自己的邮箱表，`candidates.first` 天然就是入口实例的，所以这一条
  /// 是跨实例改造里才会浮出来的回归。
  ///
  /// **返回新列表里那个对象，不是传进来的 `keep`**：`SenderOption` 的 `==`
  /// 刻意不看 `mailbox.name`（见 [SenderOption]），所以「邮箱改了显示名、
  /// 一次同步把新候选递进来」时 `keep == option` 成立而**两份的 `name` 不同**。
  /// 返回 `keep` 的话触发行会一直显示旧名字，直到用户重新选一次。
  SenderOption? _resolveSender(
    SenderOption? keep,
    List<SenderGroup> groups,
  ) {
    if (groups.isEmpty) return null;
    if (keep != null) {
      for (final option in groups.first.options) {
        if (option == keep) return option;
      }
      for (final group in groups.skip(1)) {
        for (final option in group.options) {
          if (option == keep) return option;
        }
      }
    }
    // 复用 build() 那条兜底（它也带着 `args.accountId` 这个邮箱提示）。
    return _initialSender(_entryGroup(groups)) ??
        (groups.first.options.isEmpty ? null : groups.first.options.first);
  }

  /// 两组候选是不是同一批 —— 判据是「列表里有没有**要重画的东西**变了」。
  ///
  /// 比 `profileId + accountId + email + name`：比 [SenderOption] 的身份判据
  /// **多一个 `name`**。两者刻意不是一个口径：
  /// - `SenderOption.==` 答的是「是不是同一个发件人」，故意不看 `name`，
  ///   这样邮箱改个显示名不会把用户选好的发件人弹掉；
  /// - 这里答的是「要不要把这一批候选取下来重画」，**必须**含 `name`，
  ///   否则改了名而其余不变时 `syncSenderGroups` 会提前返回，
  ///   `state.senderGroups` 一直是旧名字 —— 触发行永远显示改名前的名字。
  static bool _sameGroups(List<SenderGroup> a, List<SenderGroup> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].profile.id != b[i].profile.id) return false;
      final left = a[i].mailboxes;
      final right = b[i].mailboxes;
      if (left.length != right.length) return false;
      for (var j = 0; j < left.length; j++) {
        if (left[j].accountId != right[j].accountId ||
            left[j].email != right[j].email ||
            left[j].name != right[j].name) {
          return false;
        }
      }
    }
    return true;
  }

  /// 换一个发件人。
  ///
  /// 换了**实例**（不只是换同一台实例里的另一个邮箱）时，有两件事必须跟着走，
  /// 否则界面会自相矛盾：
  ///
  /// - **配额**：`loginUserInfo.sendCount` 是服务端按**用户**算的，
  ///   换了一台实例就是换了一个用户，不重问的话页脚显示的是上一个用户的余量；
  /// - **收件人补全**：本地的 `recipients_history` 是按 `profileId` 分区的，
  ///   不重查的话建议条里全是另一台实例上的联系人。
  ///
  /// 两件事**刻意不做**：
  /// - 不清空正文与收件人 —— 用户可能已经打了半封信，切发件人只是换身份；
  /// - 不改 `draftId` —— 同一条草稿换实例之后归属就地更新（[_saveDraft] 写的
  ///   是 [_sendProfileId]），草稿箱里仍是一条。
  void setSender(SenderOption option) {
    final switchedInstance = state.sendProfileId != option.profile.id;
    // `refreshQuota()` / `_refreshSuggestions()` 都在第一个 `await` 之前**同步**
    // 读 `_sendProfileId`（→ `state.sender`）：这一句必须排在它们前面，
    // 否则拉到的是旧实例的配额与收件人历史。
    state = state.copyWith(sender: option, dirty: true);
    if (!switchedInstance) return;
    unawaited(refreshQuota());
    unawaited(_refreshSuggestions(state.recipientInput));
  }

  void setRecipients(List<String> recipients) =>
      state = state.copyWith(recipients: recipients, dirty: true);

  void setRecipientInput(String value) {
    state = state.copyWith(recipientInput: value, dirty: true);
    unawaited(_refreshSuggestions(value));
  }

  /// 把输入框里那一截提交成收件人（回车、逗号、失焦时调）。
  ///
  /// 返回**没能收下的那几个** —— 形如地址但被判为不合法的输入不该安静地
  /// 消失，用户会以为自己写上了。
  List<String> commitRecipientInput() {
    final parts = splitAddresses(state.recipientInput);
    if (parts.isEmpty) return const <String>[];
    final rejected = parts.where((e) => !looksLikeEmail(e)).toList();
    final accepted = parts.where(looksLikeEmail).toList();
    state = state.copyWith(
      recipients: <String>[...state.recipients, ...accepted],
      recipientInput: '',
      dirty: true,
    );
    return rejected;
  }

  void removeRecipient(String address) => state = state.copyWith(
        recipients:
            state.recipients.where((e) => e != address).toList(growable: false),
        dirty: true,
      );

  /// 追加**一个**收件人（点建议条、回车补全）。
  ///
  /// 与 [setRecipients] 的差别是它读的是**当前** state 而不是调用方手里那份
  /// 快照：补全那个回调夹在「输入框里的半截刚被收下」与「列表重建」之间，
  /// 拼快照会把刚收下的那个地址丢掉。
  ///
  /// 去重（忽略大小写）：同一个地址点两次是很容易发生的，重复的 chip 除了
  /// 碍眼还会让服务端收到两条一样的收件人。
  void addRecipient(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;
    final exists = state.recipients.any(
      (e) => e.toLowerCase() == trimmed.toLowerCase(),
    );
    if (exists) return;
    state = state.copyWith(
      recipients: <String>[...state.recipients, trimmed],
      dirty: true,
    );
  }

  /// 一次追加多个收件人（建议条多选、粘贴拆分）。去重规则同 [addRecipient]。
  ///
  /// 一个都没加进去时**不写 state**：那会白白通知一遍整棵树重建
  /// （收件人一多，`build` 里那几个 `Wrap` 不便宜）。
  void addRecipients(Iterable<String> addresses) {
    final next = <String>[...state.recipients];
    final seen = next.map((e) => e.toLowerCase()).toSet();
    var changed = false;
    for (final raw in addresses) {
      final address = raw.trim();
      if (address.isEmpty) continue;
      if (!seen.add(address.toLowerCase())) continue;
      next.add(address);
      changed = true;
    }
    if (!changed) return;
    state = state.copyWith(recipients: next, dirty: true);
  }

  /// 一次移除多个收件人（chip 多选后的删除 / 剪切）。
  ///
  /// 判据忽略大小写：chip 上是原样地址，而用户选中的那几个是从 state 里拿的，
  /// 两边大小写未必一致（比如从历史里补全进来的 `A@x.com`）。
  void removeRecipients(Iterable<String> addresses) {
    final drop = addresses
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (drop.isEmpty) return;
    final next = state.recipients
        .where((e) => !drop.contains(e.toLowerCase()))
        .toList(growable: false);
    if (next.length == state.recipients.length) return;
    state = state.copyWith(recipients: next, dirty: true);
  }

  /// 补全查询的**代号**。每次发起自增，回来时对不上就丢弃。
  ///
  /// 为什么必须有：`suggestRecipients` 是一次异步 DB 查询，而打字是**每个
  /// 字符一次** `setRecipientInput`。用户连敲三下时三个查询同时在飞，谁先
  /// 回来不确定 —— 慢的那一个（旧 query 的结果）后到，就会把「zhang」的
  /// 建议盖成「z」的结果：界面上高亮着一条与输入框无关的地址，回车一按就
  /// 收下错的人。本地 SQLite 快得看不出来，但慢设备 / 大量历史时是真的。
  int _suggestEpoch = 0;

  Future<void> _refreshSuggestions(String query) async {
    if (_sendProfileId.isEmpty) return;
    final epoch = ++_suggestEpoch;
    try {
      final rows = await ref
          .read(databaseProvider)
          .localDao
          .suggestRecipients(_sendProfileId, query: query.trim(), limit: 8);
      if (!ref.mounted || epoch != _suggestEpoch) return;
      state = state.copyWith(
        recipientSuggestions: rows
            .map((r) => (address: r.address, name: r.name))
            .toList(growable: false),
      );
    } catch (_) {
      // 补全拿不到不是错误。
    }
  }

  void setSubject(String value) =>
      state = state.copyWith(subject: value, dirty: true);

  /// 编辑器回写正文。
  ///
  /// [bodyRevision] 与正文**同一次 `set`** 一起给：`_pushBody` 拿它把「上次
  /// 初值是哪一版」追平，这样屏幕不会把这次自回写误当成 state 换了初值而把
  /// 文档再装回编辑器（详见 `ComposeState.bodyRevision`）。分两次 `set` 也对，
  /// 但那会多出一次整屏重建 —— 编辑器那棵子树不便宜。
  ///
  /// [markDirty] 为假时不置 `dirty`：**装载初值那一趟回写**走的就是这一支
  /// （页面把 `state.body` 本身装进编辑器，编辑器随后通知、防抖回写）。
  /// 那不是用户写的字，不该让「打开一封回复、一个字没动就退出」也留下一份
  /// 草稿 —— 见 `ComposeScreen._adoptingBody`。其余回写一律默认置脏。
  void setBody(String value, {int? bodyRevision, bool markDirty = true}) =>
      state = state.copyWith(
        body: value,
        // `copyWith` 里 null 的语义就是「不改」—— 不传就保持原样。
        bodyRevision: bodyRevision,
        // 假值也要传下去（`copyWith` 传不了「不动」与「置假」的区别，所以
        // 这里用 `??` 而不是直接透传）。
        dirty: markDirty ? true : state.dirty,
      );

  void addAttachments(List<SendAttachment> incoming) {
    if (incoming.isEmpty) return;
    state = state.copyWith(
      attachments: <SendAttachment>[...state.attachments, ...incoming],
      dirty: true,
      problems: const <String>[],
    );
    _reportLimits();
  }

  void removeAttachment(SendAttachment attachment) {
    state = state.copyWith(
      attachments: state.attachments
          .where((a) => a.path != attachment.path)
          .toList(growable: false),
      dirty: true,
      problems: const <String>[],
    );
  }

  /// 提示已经展示过（屏幕弹完 SnackBar 后调用）。
  void consumeNotice() {
    if (state.notice == null) return;
    state = state.copyWith(clearNotice: true);
  }

  void clearProblems() {
    if (state.problems.isEmpty) return;
    state = state.copyWith(problems: const <String>[]);
  }

  // --------------------------------------------------------------- 发送

  /// 「发送」。**不抛异常** —— 写邮件页不该因为一次发送失败而红屏。
  ///
  /// 回来后 `state.notice` 与 `state.problems` 必有其一被填上。
  ///
  /// 延迟设置不为 0 时走**入队**（[AppDefaults.sendDelayDefault]）：信先落进
  /// 发件箱，到点才由发件箱时钟发出去，这段时间里用户可以取消。延迟为 0
  /// 时就是纯粹的直接发送，失败当场告诉用户（见 [sendImmediately]）。
  Future<void> send() async {
    if (!state.canSendNow) return;

    final payload = buildPayload();

    // 服务端的同款检查在这里先做一遍（约束 13）。
    final errors = payload.validate(
      maxAttachmentCount: _maxAttachments,
      maxInlineImages: _maxInlineImages,
      maxTotalBytes: _maxTotalBytes,
    );
    if (errors.isNotEmpty) {
      state = state.copyWith(
        problems: errors.map(_describe).toList(growable: false),
      );
      return;
    }

    // 附件在写信的过程中被清掉了（系统清 Caches、用户在缓存管理页删过）。
    // **必须在这一步发现**：让 `FileSystemException` 冒到发送链路里会被
    // 归成「网络类、可重试」，于是每次同步都白跑一趟，而问题永远不会自己好。
    for (final attachment in state.attachments) {
      if (!LocalFile.exists(attachment.path)) {
        state = state.copyWith(
          problems: <String>[
            state.l10n.sendAttachmentMissing(attachment.filename),
          ],
        );
        return;
      }
    }

    final delay = ref.read(sendDelayProvider);
    if (delay > Duration.zero) {
      await _queue(payload, delay);
      return;
    }
    await _sendDirect(payload);
  }

  /// 忽略延迟设置，立刻发出去（AppBar 上那个闪电按钮）。
  ///
  /// 与 [send] 的区别只有一处：**不看设置里的延迟**。校验与失败处理完全
  /// 复用 [send] 那一套 —— 用户点「立即发送」不代表他愿意越过
  /// 「附件超过 10 个」这类硬限制。
  Future<void> sendImmediately() async {
    if (!state.canSendNow) return;

    final payload = buildPayload();
    final errors = payload.validate(
      maxAttachmentCount: _maxAttachments,
      maxInlineImages: _maxInlineImages,
      maxTotalBytes: _maxTotalBytes,
    );
    if (errors.isNotEmpty) {
      state = state.copyWith(
        problems: errors.map(_describe).toList(growable: false),
      );
      return;
    }
    for (final attachment in state.attachments) {
      if (!LocalFile.exists(attachment.path)) {
        state = state.copyWith(
          problems: <String>[
            state.l10n.sendAttachmentMissing(attachment.filename),
          ],
        );
        return;
      }
    }

    await _sendDirect(payload);
  }

  /// 排进发送队列：不碰网络，落库即成功（需求六的「后悔窗口」）。
  ///
  /// **入队成功后不再走 [_afterFailure]** —— 两条路互斥。一封信既进了
  /// 队列又被当成「发送失败要重试」的话，它会被投递两次。
  Future<void> _queue(SendPayload payload, Duration delay) async {
    state = state.copyWith(
      busy: true,
      progress: null,
      problems: const <String>[],
      clearNotice: true,
      noticeIsError: false,
    );
    try {
      await ref.read(sendRepositoryProvider).enqueueScheduled(
            payload,
            profileId: _sendProfileId,
            delay: delay,
          );
    } catch (e) {
      // 落库都失败（本地库满了 / 被锁住）—— 内容还在编辑器里，
      // 让它留在原地比清空后什么都不说好得多。
      if (!ref.mounted) return;
      state = state.copyWith(
        busy: false,
        problems: <String>[state.l10n.sendQueuedFailed],
        noticeIsError: true,
      );
      return;
    }
    if (!ref.mounted) return;
    await _afterQueued(payload, delay);
  }

  /// 直发（延迟为 0，或用户点了「立即发送」）。
  Future<void> _sendDirect(SendPayload payload) async {
    state = state.copyWith(
      busy: true,
      progress: null,
      problems: const <String>[],
      clearNotice: true,
      noticeIsError: false,
    );

    try {
      await ref.read(sendRepositoryProvider).sendNow(
            payload,
            profileId: _sendProfileId,
            onSendProgress: (sent, total) {
              if (!ref.mounted || total <= 0) return;
              state = state.copyWith(progress: sent / total);
            },
          );
      if (!ref.mounted) return;
      await _finishCompose(state.l10n.sendSuccess, payload);
    } on AppException catch (e) {
      if (!ref.mounted) return;
      await _afterFailure(e, payload);
    } catch (e) {
      // 未知异常：与「超时」同类 —— 无法断定服务端有没有收到。
      if (!ref.mounted) return;
      await _afterFailure(ServerException(message: e.toString()), payload);
    }
  }

  /// 入队成功之后的收尾。与 [send] 成功那条路**只差一句提示**。
  Future<void> _afterQueued(SendPayload payload, Duration delay) async {
    final minutes = (delay.inSeconds / 60).ceil();
    await _finishCompose(state.l10n.queuedNotice(minutes), payload);
  }

  /// 发送成功 / 入队成功之后的收尾。
  ///
  /// 顺序刻意如此：**先记历史、再删草稿**。反过来的话，删草稿失败会让
  /// 整段收尾中断，而用户看到的是「已发送」—— 一次静默的数据不一致。
  Future<void> _finishCompose(String notice, SendPayload payload) async {
    try {
      final dao = ref.read(databaseProvider).localDao;
      await dao.recordRecipients(
        _sendProfileId,
        payload.recipients
            .map((a) => (address: a, name: ''))
            .toList(growable: false),
      );
      unawaited(dao.pruneRecipients(_sendProfileId));
    } catch (_) {
      // 补全历史丢了不影响这封信。
    }

    final id = state.draftId;
    if (id != null) {
      try {
        await ref.read(databaseProvider).localDao.deleteDraft(id);
      } catch (_) {
        // 同上。
      }
    }

    if (!ref.mounted) return;
    state = state.copyWith(
      busy: false,
      progress: null,
      // 0 = 真的把 draftId 清掉（见 `copyWith` 里那条注释）。
      draftId: 0,
      dirty: false,
      problems: const <String>[],
      notice: notice,
      noticeIsError: false,
      recipients: const <String>[],
      recipientInput: '',
      subject: '',
      body: '',
      // 同 `_restoreDraft`：这也是一次换初值。**空正文那一支是提前返回的**
      // （见 `_adoptInitialBody`：`replaceText(0, 0, 空 Delta)` 会往空文档里
      // 再插一个换行，把占位提示顶掉），所以编辑器里的旧正文**不会**被这一版
      // 清掉 —— 这是有意的：这一条通常是关页面前的最后一次 `set`，留着旧正文
      // 反而不会闪一下空白页。版次照样要 +1，好让下一位读者（比如失败后
      // 又出现的那一帧）不至于把它当成「state 换了初值」而重复装载。
      bodyRevision: state.bodyRevision + 1,
      attachments: const <SendAttachment>[],
    );
    unawaited(refreshQuota());
  }

  /// 发送失败之后的出路。见类注释第 4 条。
  Future<void> _afterFailure(AppException e, SendPayload payload) async {
    final l10n = state.l10n;
    final reasons = e is SendValidationException
        ? e.reasons
        : <String>[_describeException(e)];

    // 内容先落草稿 —— 无论后面怎么走，用户打的东西不能丢。
    // 草稿 id 已经在 `_saveDraft` 里写进 `state.draftId` 了，这里不再取用。
    await _saveDraft();

    final retryable = SendRepository.isRetryable(e);
    final uncertain = !retryable && _isUncertain(e);
    var notice = reasons.join('；');

    try {
      if (uncertain) {
        // 记一条 `unknown` 的发件箱条目：`flush` 挑不到它（只挑 `pending`），
        // 但用户能在发件箱里看见「有这么一封信，状态不明」。
        await ref.read(sendRepositoryProvider).enqueueUnknownResult(
              payload,
              profileId: _sendProfileId,
              reason: reasons.join('；'),
            );
        notice = '$notice\n${l10n.sendUnknownResult}';
      } else if (retryable) {
        await ref
            .read(sendRepositoryProvider)
            .enqueue(payload, profileId: _sendProfileId);
        notice = '$notice\n${l10n.sendQueuedRetry}';
      } else {
        // 信本身不合规 / 被业务拒绝（配额、权限）：入队重发一万次也一样，
        // 让用户改完自己再点一次。
        notice = '$notice\n${l10n.composeFailedStayHint}';
      }
    } on AppException {
      // 入队都失败（本地库问题）—— 草稿还在，至少不会丢内容。
    }

    if (!ref.mounted) return;
    state = state.copyWith(
      busy: false,
      progress: null,
      problems: reasons,
      notice: notice,
      noticeIsError: true,
    );
  }

  /// 「可能已经送达」的那两类失败。
  ///
  /// 只有它们算「不确定」，其余都是明确的「没送出去」（连不上、被拒、
  /// 校验没过），可以安全地走自动重试或让用户改完再发。
  bool _isUncertain(AppException e) =>
      e is TimeoutException || e is ServerException;

  // --------------------------------------------------------------- 草稿

  /// 存一次草稿，返回草稿 id（存不下时返回当前 id）。
  ///
  /// **落库之后把 id 回写进 `state.draftId`**：这个流程可能被连着调用不止一次
  /// （换发件人之后再退出就是一次新的保存；重复保存本身也该是幂等的），
  /// 而不回写的话第二次的 `existing` 仍是 null，`saveDraft(id: null)` 会
  /// **再 insert 一行** —— 同一封信在草稿箱里变成两条。回写之后第二次走的是
  /// update，归属就地更新、仍然只有一条。
  ///
  /// **回写要看 `ref.mounted`**：`await` 之后这个 autoDispose 的 notifier 可能
  /// 已经没了，那时仍旧把 id 交给调用方，但绝不能再去碰 `state`。
  Future<int?> _saveDraft() async {
    if (_sendProfileId.isEmpty || !state.dirty) return state.draftId;
    try {
      final existing = state.draftId;
      final id = await ref.read(databaseProvider).localDao.saveDraft(
            id: (existing != null && existing > 0) ? existing : null,
            profileId: _sendProfileId,
            accountEmail: state.sender?.email ?? '',
            recipientsJson:
                encodeRecipientAddresses(state.effectiveRecipients),
            subject: state.subject,
            content: state.body,
            attachmentPaths:
                state.attachments.map((a) => a.path).toList(growable: false),
          );
      if (ref.mounted) state = state.copyWith(draftId: id);
      return id;
    } catch (_) {
      return state.draftId;
    }
  }

  /// 离开写邮件页时调用。
  ///
  /// **空信不存**：点开写邮件又退出去很常见，为此在草稿箱里留一条空记录
  /// 只会让草稿列表变成垃圾场。判断用的是「有没有真的写过东西」而不是
  /// `dirty` —— 回复时的预填内容会让 `dirty` 在用户一个字都没敲时就为 true。
  ///
  /// 正文那一项必须走 [DocumentCodec.isEmptyDelta]，**不能**用
  /// `body.trim().isNotEmpty`：`body` 现在是 Delta JSON，一个「什么都没有」
  /// 的文档编码出来是 `[{"insert":"\n"}]`，`trim()` 之后非空 —— 于是在空白
  /// 写信页上**打一个字再删掉**，退出时就会存出一条空草稿。
  /// （`body` 还是纯文本时，那种情况是空串，判据才成立 —— 这是正文改形状时
  /// 漏掉的一处。回复/转发那一条不受影响：它们的主题带了 `Re:` 前缀，
  /// 本来就过得了第二项。）
  Future<void> saveDraftOnExit() async {
    if (!state.dirty) return;
    final wroteSomething = !DocumentCodec.isEmptyDelta(state.body) ||
        state.subject.trim().isNotEmpty ||
        state.effectiveRecipients.isNotEmpty ||
        state.attachments.isNotEmpty;
    if (!wroteSomething) return;
    await _saveDraft();
  }

  /// 用户点「放弃草稿」。
  Future<void> discardDraft() async {
    final id = state.draftId;
    if (id == null || id <= 0) return;
    await ref.read(databaseProvider).localDao.deleteDraft(id);
    if (ref.mounted) state = state.copyWith(draftId: 0, dirty: false);
  }

  // --------------------------------------------------------------- 组装

  /// 组装成 `/email/send` 的报文。
  ///
  /// `content` 是正文 Delta 导出的邮件安全 HTML；`text` 是它的纯文本形式 ——
  /// 服务端只认 HTML，但 `text` 会出现在列表摘要与检索里，两者都要对。
  ///
  /// **空正文这里给空串，不给导出器的那对 `<p><br></p>`**。正文的真相换成
  /// Delta 之后，一个「什么都没有」的文档导出来是
  /// `<p style="margin:0 0 12px 0"><br></p>` —— `trim()` 之后**永远不为空**，
  /// 于是 [SendPayload.validate] 里那条 `content.trim().isEmpty` 再也触发不了，
  /// **空正文的信能直接发出去**（`_maybePreflight` 里还写着「空正文交给它报错」）。
  /// 换成纯文本那会儿这里由 `ComposeHtml.fromPlainText` 天然给空串，改成 Delta
  /// 时漏了这一步。判据一律走 [DocumentCodec.isEmptyDelta]，它认得「只有换行」
  /// 与「只有空白」；**嵌入不算空**（一封只有一张图的信是能发的）。
  SendPayload buildPayload() {
    final content = DocumentCodec.isEmptyDelta(state.body)
        ? ''
        : DeltaToEmailHtml.convert(_decodeBody());

    return SendPayload(
      accountId: state.sender?.mailbox.accountId ?? 0,
      sendEmail: state.sender?.email ?? '',
      name: state.sender?.name ?? '',
      recipients: state.effectiveRecipients,
      subject: state.subject.trim(),
      text: PlainText.fromHtml(content),
      content: content,
      sendKind: switch (args.mode) {
        ComposeMode.blank => SendKind.normal,
        // 「全部回复」在服务端眼里就是一次 reply：`sendType` 决定线程头
        // （`In-Reply-To` / `References`），而收件人多几个不影响这件事。
        ComposeMode.reply || ComposeMode.replyAll => SendKind.reply,
        ComposeMode.forward => SendKind.forward,
      },
      // 服务端只在 `sendType == 'reply'` 时拿它取 messageId（`selectById`），
      // 而那个查询**不按 userId 过滤**（`email-service.js` 的 `selectById`
      // 只过滤 `isDel`）。从实例 A 回复、却把发件人换成实例 B 的邮箱时，
      // B 上那个 `emailId`（可能是别人的信、也可能不存在）会被拿来当
      // `messageId` 写进 `In-Reply-To` / `References` —— **不报错**，只是
      // 线程挂到了一封不相干的信上。换了实例就不带它。
      replyToEmailId: _useReplyThread ? (args.mail?.emailId ?? 0) : 0,
      attachments: state.attachments,
    );
  }

  /// 正文的 Delta（`state.body` 存的那个字符串）。
  ///
  /// **解析不出来时退回空文档，绝不抛出去** —— 与 [ComposeState._deltaOf] 同
  /// 一条口径。`state.body` 的初值可能是**旧草稿的纯文本**（`_restoreDraft`
  /// 直接搬 `draft.content`，而 [DocumentCodec] 的契约明说旧草稿是纯文本），
  /// 而回写那份 Delta 要等编辑器 250 ms 的防抖烧完。这中间任何一次
  /// [buildPayload]（比如加附件触发的 [_reportLimits]）都会走到这儿 ——
  /// 让它抛 `FormatException` 等于「打开一条旧草稿、加个附件，写邮件页红了」。
  List<dynamic> _decodeBody() {
    final raw = state.body;
    if (raw.trim().isEmpty) {
      return jsonDecode(DocumentCodec.emptyDelta) as List<dynamic>;
    }
    try {
      final decoded = jsonDecode(raw);
      // 形状不对（不是 op 列表）也退回空文档：导出一个空正文，
      // 比让导出器去吃一个字符串强。
      return decoded is List ? decoded : const <dynamic>[];
    } on FormatException {
      return const <dynamic>[];
    }
  }

  // --------------------------------------------------------------- 辅助

  /// 服务端的硬限制。与 `SendRepository._check` 用同一组值。
  static const int _maxAttachments = 10;
  static const int _maxInlineImages = 10;
  static const int _maxTotalBytes = 20 * 1024 * 1024;

  /// 加附件时先单独报一次「太多 / 太大」，不必等用户点发送。
  void _reportLimits() {
    final payload = buildPayload();
    final errors = payload.validate(
      maxAttachmentCount: _maxAttachments,
      maxInlineImages: _maxInlineImages,
      maxTotalBytes: _maxTotalBytes,
    );
    if (!ref.mounted) return;
    state = state.copyWith(
      problems: errors.map(_describe).toList(growable: false),
    );
  }

  /// 把 `SendValidationError` 翻成本地化文案。
  ///
  /// `SendValidationError.message` 是中文，只在日志与诊断里用；
  /// 界面上一律走这里，否则英文界面会冒出中文。
  String _describe(SendValidationError error) => switch (error) {
        SendValidationError.sender => state.l10n.composeSenderUnavailable,
        SendValidationError.noRecipient => state.l10n.composeNoRecipient,
        SendValidationError.badRecipient => state.l10n.composeBadRecipient(
            _firstBadRecipient(),
          ),
        SendValidationError.emptyContent => state.l10n.composeEmptyBody,
        SendValidationError.tooManyAttachments =>
          state.l10n.composeTooManyAttachments(_maxAttachments),
        SendValidationError.tooManyInlineImages =>
          state.l10n.composeTooManyInline(_maxInlineImages),
        SendValidationError.tooLarge =>
          state.l10n.composeTooLarge(_formatBytes(_maxTotalBytes)),
      };

  /// 第一个不合格的收件人（`badRecipient` 那句文案要把它指名道姓写出来，
  /// 否则用户不知道是哪一个写错了）。
  ///
  /// **判空的也要挑出来**：`SendPayload.validate` 会先 `trim` 再过滤空串，
  /// 所以一个 `"   "` 在它眼里是「没有收件人」，而 `looksLikeEmail` 眼里
  /// 是「格式不对」——两边给出不同的结论时，这里要能显示出一个东西。
  String _firstBadRecipient() {
    for (final address in state.effectiveRecipients) {
      if (!looksLikeEmail(address)) return address;
    }
    return '';
  }

  /// 异常 → 一句给用户看的话。
  ///
  /// `userMessage` 已经是按 `accept-language` 本地化过的服务端文案
  /// （或我们自己的兜底），只有「登录失效」这一条要换成本地化的提示 ——
  /// 服务端那句 `sessionExpired` 未必与 App 用的是同一种语言。
  String _describeException(AppException e) => e is AuthExpiredException
      ? state.l10n.sessionExpired
      : e.userMessage;

  /// 附件路径 → `SendAttachment`（大小与类型从磁盘现问）。
  ///
  /// 文件不在了就跳过：草稿里留着一个死路径，发的时候会在本地校验里变成
  /// 一条「附件已不在本地」的报错，不如现在就别带进来。
  static List<SendAttachment> _attachmentsFromPaths(List<String> paths) {
    final result = <SendAttachment>[];
    for (final path in paths) {
      if (!LocalFile.exists(path)) continue;
      result.add(
        SendAttachment(
          path: path,
          filename: _basename(path),
          size: LocalFile.length(path),
          mimeType: lookupMimeType(path) ?? 'application/octet-stream',
        ),
      );
    }
    return result;
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(RegExp(r'[/\\]'));
    return index >= 0 ? path.substring(index + 1) : path;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }
}

/// 写邮件页的 provider。
///
/// `isAutoDispose: true` 是**必须的** —— 写完一封信、退出页面之后，
/// 这份状态（含用户敲的正文、附件列表）不该在内存里留着。
/// 代价是「切到后台再回来」如果页面被回收就会重建，所以离开页面时的
/// 草稿落盘（`ComposeController.saveDraftOnExit`）是这条链路的必需环节，
/// 不是可选项。
///
/// 用 family 而不是「一个全局的当前编辑状态」：多实例下用户可能同时开着
/// 两个写邮件页（给实例 A 回信、给实例 B 转发），共用一份状态会互相覆盖。
///
/// 这里**不写 `NotifierProviderFamily<...>` 的类型注解**：那个类只在
/// `flutter_riverpod/misc.dart` 里导出（主入口 `flutter_riverpod.dart`
/// 的 `show` 列表里没有它），写全名就得为一个纯注解多一条 import。
/// 类型由初始化式推出来，一样是静态的。
final composeControllerProvider =
    NotifierProvider.family<ComposeController, ComposeState, ComposeArgs>(
  ComposeController.new,
  name: 'composeController',
  isAutoDispose: true,
);

/// 草稿箱的数据源（`null` = 全部实例）。
///
/// 与 `outboxProvider` 一样不做实例过滤：草稿是**本机**的东西，
/// 用户打开草稿箱想看的是「我在这台设备上还有哪些没写完的信」。
final draftsProvider = StreamProvider.family<List<DbDraft>, String?>(
  (ref, profileId) =>
      ref.watch(databaseProvider).localDao.watchDrafts(profileId: profileId),
  name: 'drafts',
);
