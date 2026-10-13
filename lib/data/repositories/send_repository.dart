import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/config/app_defaults.dart';
import '../../core/db/database.dart';
import '../../core/error/app_exception.dart';
import '../../core/util/diag_log.dart';
import '../../features/compose/stream_body_builder.dart';
import '../../instance/runtime_registry.dart';
import '../models/enums.dart';
import '../models/mail_row.dart';
import '../models/send_payload.dart';
import 'email_repository.dart';
import 'profile_repository.dart';

/// 一条 outbox 记录这一轮的结果。
///
/// 三态而不是 `bool`：`flush` 要在「这条完了，看下一条」与
/// 「停手，后面的先别发」之间做选择，而这个区别正是「会不会重复投递」
/// 的分界线（见 [SendRepository._retryable]）。
enum _SendOutcome {
  /// 发出去了。
  sent,

  /// 这条已经判死（`status = failed`），不再占着队首。
  dead,

  /// 暂时失败，可能已经送达或网络还没好 —— 停下来。
  retryLater,

  /// 另一个发送正在进行，这条没被处理。
  blocked,
}

/// 发信。
///
/// ## 三条贯穿全文件的规矩
///
/// 1. **先校验，再入队**（[SendPayload.validate]）。服务端的
///    「≤10 附件 / ≤10 内嵌图」检查发生在**插库之后**（约束 13），
///    不先拦就会在那个用户的发件箱里留下一条永远发不出去的
///    `SAVING` 脏行 —— 用户看得见、删得掉、但每次都以为是 App 的错。
///
/// 2. **附件走流式 body**（[StreamBodyBuilder]）。`/email/send` 只收
///    base64 JSON，没有通用上传端点（约束 14），所以「附件不走 JSON」
///    在不改后端的前提下做不到；能做的是**不把 base64 在内存里爆开**。
///
/// 3. **一个实例同时只发一封**（[_inFlight]）。服务的发信配额通常是按
///    时间窗算的，并发几封一起撞上去只会一起失败；而且串行才能让
///    outbox 的「下一封」语义成立。
///
/// ## 重试的分类（这一条最容易写错）
///
/// `/email/send` **没有幂等键**。所以：
/// - **确定没发出去**（连不上、401、文件还在本地）→ 可以安全重试；
/// - **可能已经发出去了**（超时、连接中途断开）→ **不自动重试**，
///   标成 `failed` 让用户在发件箱里自己决定。自动重试会真的重复投递 ——
///   这是用户最不能接受的失败方式；
/// - **业务拒绝 / 本地校验不过 / 草稿坏了** → 永久失败，重试没有意义。
///
/// 判死的记录**不再占着队首**（见 [flush]），否则一封「附件被用户删了」
/// 的旧信会把整个发件箱永久堵死。
class SendRepository {
  SendRepository({
    required this.db,
    required this.registry,
    required this.profiles,
    required this.emails,
  });

  final AppDatabase db;
  final RuntimeRegistry registry;
  final ProfileRepository profiles;
  final EmailRepository emails;

  /// 每个实例同时只有一个在途发送。
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// 入队一封待发邮件，返回 outbox 行 id。
  ///
  /// 只存**附件路径**，不存 base64 —— 附件可能在 outbox 里躺几天，
  /// 存 base64 会让本地库凭空膨胀几十 MB。
  ///
  /// [attempts] 见 [SendRepository.enqueueUnknownResult]。
  /// [scheduledAt] 见 [enqueueScheduled]。
  Future<int> enqueue(
    SendPayload payload, {
    required String profileId,
    int attempts = 0,
    DateTime? scheduledAt,
  }) {
    // 服务端不支持的字段在这里就该断掉，而不是等它回一句看不懂的错。
    assert(
      !payload.sendEmail.contains(','),
      'sendEmail 是单个发件地址，不能是列表',
    );
    return db.localDao.enqueue(
      profileId: profileId,
      payloadJson: encodePayload(payload),
      attempts: attempts,
      scheduledAt: scheduledAt,
    );
  }

  /// 排进发送队列，[delay] 之后才真的发出去（写邮件页的默认路径）。
  ///
  /// 这就是「发送后还能反悔」：`/email/send` **没有定时发送**，所以延迟只能
  /// 在客户端做 —— 到点之前这封信只是本地的一行，`nextPending` 挑不到它，
  /// 一个字节都不会发出去；用户点「取消」就是删掉这一行。
  ///
  /// 延迟为 0 时不要走这里 —— 那是「立即发送」，语义上不该经过队列
  /// （失败要当场告诉用户，而不是悄悄排进发件箱）。
  Future<int> enqueueScheduled(
    SendPayload payload, {
    required String profileId,
    required Duration delay,
  }) =>
      enqueue(
        payload,
        profileId: profileId,
        scheduledAt: DateTime.now().toUtc().add(delay),
      );

  /// 用户在队列面板点「立即发出」：清掉计划时间，然后马上发一次。
  ///
  /// 与 [retry] 的区别只在**入参的来源**：这条是「还没发过、只是在等」，
  /// 所以 `attempts` 保持 0，成功删行、失败按常规分类。
  Future<bool> sendDueNow(int outboxId) async {
    final entry = await db.localDao.findById(outboxId);
    if (entry == null) return false;
    if (entry.status != 'pending') return retry(outboxId);
    await db.localDao.clearScheduledAt(outboxId);
    final fresh = await db.localDao.findById(outboxId);
    if (fresh == null) return false;
    return await _sendEntry(fresh) == _SendOutcome.sent;
  }

  /// 队列里还排着几封**没到点**的（列表底部微标签用）。
  ///
  /// 与 [attentionCount] 口径不同：那个数的是「发件箱里有几封要留意」（含判死与
  /// 结果不明的），这个数的是「排队等着发几封」。见 `LocalDao.scheduledCount`。
  Future<int> scheduledCount() => db.localDao.scheduledCount();

  /// 队列里最近一次的发送时刻（微标签上的倒计时）。
  Future<DateTime?> nextScheduledAt() => db.localDao.nextScheduledAt();

  /// 记一条「发出去了，但不知道到没到」的信（超时、连接中途断开）。
  ///
  /// 与 [enqueue] 的区别有两处，缺一不可：
  /// - `status = 'unknown'` —— `LocalDao.nextPending` 挑不到它，
  ///   `flush` 永远不会碰它；
  /// - `attempts = 1` —— 它**其实已经试过一次了**。万一 App 在记完这条之后
  ///   立刻被杀，启动时的 `resetStuckSending` 也不会误判它是「还没试过」。
  ///
  /// [reason] 是给用户看的那句话（`local_dao` 里的默认文案太笼统，
  /// 调用方知道具体是超时还是响应看不懂）。
  Future<int> enqueueUnknownResult(
    SendPayload payload, {
    required String profileId,
    required String reason,
  }) async {
    final id = await db.localDao.enqueue(
      profileId: profileId,
      payloadJson: encodePayload(payload),
      status: 'unknown',
      attempts: 1,
    );
    // `enqueue` 只写状态，原因要单独记一笔 —— 发件箱列表要显示它。
    await db.localDao.recordLastError(id, reason);
    return id;
  }

  /// 立即发一封（不入队）。UI 的「发送」按钮走这条；
  /// 断开网络 / 进程被杀之后的重发走 outbox。
  ///
  /// 抛异常表示**确定没发出去**（调用方可以安全入队重试）。
  /// 返回服务端创建的邮件行。
  Future<List<MailRow>> sendNow(
    SendPayload payload, {
    required String profileId,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    _check(payload);

    final profile = await profiles.find(profileId);
    if (profile == null) {
      throw const NetworkException(detail: '实例不存在');
    }
    final runtime = registry.peek(profileId);
    if (runtime == null || runtime.isDisposed) {
      throw const NetworkException(detail: '实例未就绪');
    }

    final body = StreamBodyBuilder.build(
      payload,
      openFile: (attachment) => File(attachment.path).openRead(),
    );
    final length = StreamBodyBuilder.contentLength(payload);

    final rows = await runtime.emailApi.sendStream(
      body,
      contentLength: length,
      profileId: profileId,
      mailboxEmail: payload.sendEmail,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );

    // 服务端返回的是**刚创建的邮件行**（status=1 已发 / 2 送达）。
    // 直接落库，发件箱里立刻就能看到，不必等下一轮轮询。
    //
    // **这一步失败不能往上抛。** `/email/send` 没有幂等键，而 `_sendEntry`
    // 把「抛出来的异常」一律当作「不知道送达没有」或「可重试」—— 信已经
    // 发出去了，却因为本地写库失败被退回 `pending`，下一轮 flush 就会**重复投递**。
    // 落库只是让「已发送」立刻显示出来，缺了它下一轮收信也会把这一行补回来。
    if (rows.isNotEmpty) {
      try {
        await emails.persistSendResult(profileId, rows);
      } catch (e) {
        DiagLog.log('SendRepository', '已发送落库失败（信已发出，忽略）：$e');
      }
    }
    return rows;
  }

  /// 把 outbox 里待发的信按顺序发出去。某个实例失败不会影响其他实例。
  ///
  /// 返回本轮成功发出的封数。**不抛异常** —— 失败都落在 outbox 的状态里，
  /// 由发件箱页面展示。
  Future<int> flush({Iterable<String>? profileIds}) async {
    final ids = profileIds?.toList(growable: false) ??
        (await profiles.all()).map((p) => p.id).toList(growable: false);

    var sent = 0;
    for (final profileId in ids) {
      // 串行：一个实例一封发完再发下一封（见类注释第 3 条）。
      while (true) {
        // 每次都重新取一次「现在」：一轮 flush 可能跑好几分钟（大附件），
        // 用同一个快照的话中途到点的信要等到下一轮才会被挑中。
        final entry = await db.localDao.nextPending(profileId);
        if (entry == null) break;

        final outcome = await _sendEntry(entry);
        if (outcome == _SendOutcome.sent) {
          sent++;
          continue;
        }
        if (outcome == _SendOutcome.dead) {
          // **这条已经判死（`status = failed`），不再占着队首** ——
          // 继续看下一条。不这么做的话，一封「附件被删掉了」的旧信会
          // 把整个发件箱永久堵死，后面所有信都发不出去。
          continue;
        }
        // 可能已经送达（超时）/ 网络还没好 / 另一个发送正在跑：停下来，
        // 别把后面的也一起撞上去 —— 服务端多半还是同样的结果，
        // 而超时那类反复重试会重复投递。
        break;
      }
    }
    return sent;
  }

  /// 重发一条 outbox 记录（用户在发件箱里点「重试」）。
  ///
  /// **必须先把状态放回 `pending` 再发**，不能直接拿条目去发：
  /// - 判死的条目是 `failed`，直接发的话 [_sendEntry] 成功删掉它、失败又写回
  ///   `failed`，状态的含义就乱了；
  /// - 「状态不明」的条目带着 `attempts = 1`，重试是想让它真的再试一次，
  ///   重新入队才能让「下一次崩溃时不得自动重发」这条保护继续成立。
  ///
  /// 用户点这个按钮就是一次明确的「我知道可能重复，也要再发一次」，
  /// 所以此处不受自动重试的那套保守规则约束。
  Future<bool> retry(int outboxId) async {
    final entry = await db.localDao.findById(outboxId);
    if (entry == null) return false;
    await db.localDao.requeue(outboxId);
    final fresh = await db.localDao.findById(outboxId);
    if (fresh == null) return false;
    return await _sendEntry(fresh) == _SendOutcome.sent;
  }

  /// 放弃一条 outbox 记录（用户在发件箱里点「删除」）。
  Future<void> discard(int outboxId) => db.localDao.deleteOutboxEntry(outboxId);

  /// 进程启动时把上次异常退出留下的 `sending` 孤儿退回 `pending`。
  ///
  /// 退回而不是直接判失败：绝大多数情况下是进程被系统杀了，请求根本没发出去。
  /// 但**只退一次** —— 反复退回会让「已试过一次」的信无限重试，
  /// 而 `/email/send` 没有幂等保护（`attempts > 0` 的仍会退回，
  /// 这个取舍写在 `local_dao` 的注释里：宁可让用户看到一条「待确认」，
  /// 也不要静默重复投递）。
  Future<int> recoverStuck() => db.localDao.resetStuckSending();

  /// 发件箱里还有多少封没出去（角标用，含 `failed` / `unknown`）。
  Future<int> attentionCount() => db.localDao.attentionCount();

  /// 发件箱页面的数据源（含 `failed` 的条目，见 `LocalDao.watchOutbox`）。
  Stream<List<DbOutboxEntry>> watchOutbox({String? profileId}) =>
      db.localDao.watchOutbox(profileId: profileId);

  // ------------------------------------------------------------ 内部

  Future<_SendOutcome> _sendEntry(DbOutboxEntry entry) async {
    // 同一个实例不允许并发发送。
    final running = _inFlight[entry.profileId];
    if (running != null) {
      await running;
      // 前一个刚发完，重新看一眼这条是否还在（可能已经被处理掉了）。
      final again = await db.localDao.nextPending(entry.profileId);
      if (again == null || again.id != entry.id) return _SendOutcome.blocked;
    }

    final completer = Completer<void>();
    _inFlight[entry.profileId] = completer.future;
    try {
      await db.localDao.markSending(entry.id);

      final payload = decodePayload(entry.payloadJson);
      if (payload == null) {
        await db.localDao.markFailed(entry.id, '草稿已损坏，无法重发', permanent: true);
        return _SendOutcome.dead;
      }

      try {
        _check(payload);
      } on SendValidationException catch (e) {
        // 本地校验不过 = 这条记录本身没救了，重试一万次也一样。
        await db.localDao.markFailed(entry.id, e.describe, permanent: true);
        return _SendOutcome.dead;
      }

      // 附件文件在排队期间被删掉是常事（用户清过缓存、系统清过 Caches）。
      // 让 `FileSystemException` 冒到外面被当成「未知异常」的话，这条记录
      // 会被判成**可重试**，于是每次同步都白跑一趟 —— 判死才对。
      for (final attachment in payload.attachments) {
        if (!await File(attachment.path).exists()) {
          await db.localDao.markFailed(
            entry.id,
            '附件已不在本地：${attachment.filename}',
            permanent: true,
          );
          return _SendOutcome.dead;
        }
      }

      await sendNow(payload, profileId: entry.profileId);
      await db.localDao.markSent(entry.id);
      return _SendOutcome.sent;
    } on AppException catch (e) {
      // `permanent: true` 落在库里是 `failed` 状态 —— 也就是「不会再自动试，
      // 等用户自己决定」。所以这里的判断其实是 [_retryable] 取反。
      final permanent = !_retryable(e);
      await db.localDao.markFailed(
        entry.id,
        _messageOf(e),
        permanent: permanent,
      );
      return permanent ? _SendOutcome.dead : _SendOutcome.retryLater;
    } catch (e) {
      // 未知异常：可能是磁盘、可能是解析。保守当作可重试。
      await db.localDao.markFailed(entry.id, e.toString());
      return _SendOutcome.retryLater;
    } finally {
      _inFlight.remove(entry.profileId);
      completer.complete();
    }
  }

  /// 这次失败之后**还能不能自动重试**。
  ///
  /// 判断依据只有一条：**这次失败是否已经确定「没送达」**。
  /// `/email/send` 没有幂等键，重复投递（对方收到两封一样的信）
  /// 比「多试一次」严重得多。
  ///
  /// - [NetworkException] 可重试：连不上、DNS 失败、连接中途断开 ——
  ///   服务端要的是完整的 JSON body，收不全就直接解析失败，不会建邮件；
  /// - [AuthExpiredException] 可重试：用户重登之后还能发；
  /// - [TimeoutException] **不可重试**：请求可能已经被处理了，
  ///   只是响应没回来；
  /// - [ApiException]（403 配额 / 501 参数）不可重试：重试一万次也一样；
  /// - [ServerException] 不可重试：响应不是 cloud-mail 的信封（被代理改写、
  ///   或中间层返回了 5xx），同样无法断定送达状态。
  ///
  /// 公开是因为**写邮件页要问同一个问题**：发送失败之后是「悄悄入队等重试」
  /// 还是「停下来告诉用户」，用的就是这条判断。两边各写一份的话，
  /// 迟早会出现「UI 说会自动重试、发件箱里却是判死的」这种自相矛盾。
  static bool isRetryable(AppException e) => _retryable(e);

  static bool _retryable(AppException e) => switch (e) {
        AuthExpiredException() => true,
        NetworkException() => true,
        _ => false,
      };

  /// 写进 outbox `last_error` 的那句话。[SendValidationException] 的问题
  /// 在 `describe` 里（`userMessage` 只是「邮件还没准备好发送」这句概括）。
  static String _messageOf(AppException e) =>
      e is SendValidationException ? e.describe : e.userMessage;

  /// 发送前的本地校验。**这一条是硬要求**（服务端在插库之后才检查）。
  ///
  /// 抛 [SendValidationException]（而不是「附件不可用」之类的泛化异常）：
  /// 调用方需要能区分「这封信本身不合规，重试一万次也一样」与
  /// 「网络抖动，重试有用」，前者的处理是**停在原地让用户改**。
  static void _check(SendPayload payload) {
    final errors = payload.validate(
      maxAttachmentCount: AppDefaults.attachmentCountLimit,
      maxInlineImages: AppDefaults.inlineImageCountLimit,
      maxTotalBytes: AppDefaults.attachmentTotalSoftLimit,
    );
    if (errors.isEmpty) return;

    // 全部失败原因一起给，用户一次就能改完 —— 一条一条弹是最烦人的。
    throw SendValidationException(
      errors.map((e) => e.message).toList(growable: false),
    );
  }

  // ------------------------------------------------------------ 序列化

  /// outbox 里存的是 [SendPayload] 的 JSON，**外加每个附件的本地路径**。
  ///
  /// 为什么要多这一步：[SendAttachment.toJson] 是**发给服务端的形状**
  /// （`content` 是 base64，没有 `path`）。直接拿它落库的话，附件路径就丢了 ——
  /// outbox 里躺着的信再发出来时一个附件都不带，而且**没有任何报错**，
  /// 用户只会发现对方没收到附件。所以这里在落库这一侧补上 `path`，
  /// 发往服务端的那条路径（[StreamBodyBuilder]）保持不变。
  static String encodePayload(SendPayload payload) {
    final map = payload.toJson();
    if (payload.attachments.isNotEmpty) {
      map['attachments'] = payload.attachments
          .map((a) => <String, dynamic>{...a.toJson(), 'path': a.path})
          .toList(growable: false);
    }
    return jsonEncode(map);
  }

  /// 解析 outbox 里的草稿。坏数据返回 null 而不是抛 —— 一条坏记录
  /// 不该让整个发件箱打不开。
  static SendPayload? decodePayload(String json) {
    final Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      map = decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }

    final recipients = <String>[];
    final rawTo = map['receiveEmail'];
    if (rawTo is List) {
      for (final item in rawTo) {
        if (item is String && item.isNotEmpty) recipients.add(item);
      }
    }

    final attachments = <SendAttachment>[];
    final rawAtt = map['attachments'];
    if (rawAtt is List) {
      for (final item in rawAtt) {
        if (item is! Map) continue;
        final att = item.cast<String, dynamic>();
        final path = att['path'] ?? att['localPath'];
        if (path is! String || path.isEmpty) continue;
        final size = att['size'];
        attachments.add(
          SendAttachment(
            path: path,
            filename: (att['filename'] as String?) ?? 'attachment',
            size: size is int ? size : 0,
            mimeType: (att['mimeType'] as String?) ??
                (att['contentType'] as String?) ??
                'application/octet-stream',
          ),
        );
      }
    }

    return SendPayload(
      accountId: _int(map['accountId']),
      sendEmail: (map['sendEmail'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      subject: (map['subject'] as String?) ?? '',
      text: (map['text'] as String?) ?? '',
      content: (map['content'] as String?) ?? '',
      recipients: recipients,
      sendKind: SendKind.fromWire(map['sendType'] as String?),
      replyToEmailId: _int(map['emailId']),
      attachments: attachments,
    );
  }

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    if (value is num) return value.toInt();
    return 0;
  }
}
