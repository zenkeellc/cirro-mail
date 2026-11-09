import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/db/daos/local_dao.dart';

/// 一次「待写入」的草稿快照。
///
/// 值对象：字段全相等就算同一份内容 —— 保存器的去重、串行合并都建在它上面。
///
/// 为什么单独一层而不是直接拿 `ComposeState`：保存要在**页面销毁之后**还能
/// 完成最后一次落盘（见 [ComposeDraftSaver.dispose]），那时 provider 可能已经
/// 没了，拿不到 state；这一份是页面在还活着时拍下来的。
@immutable
class ComposeDraftSnapshot {
  const ComposeDraftSnapshot({
    this.accountEmail = '',
    this.recipientsJson = '',
    this.subject = '',
    this.content = '',
    this.attachmentPaths = const <String>[],
  });

  /// 发件邮箱（草稿行上的 `account_email`）。
  final String accountEmail;

  /// 已确认收件人的编码（`encodeRecipientAddresses` 的输出）。
  final String recipientsJson;

  final String subject;

  /// 正文 Delta JSON。**可能是数 MB**（内联图片是 base64 嵌在里面的）。
  final String content;

  final List<String> attachmentPaths;

  bool get isEmpty =>
      accountEmail.isEmpty &&
      recipientsJson.isEmpty &&
      subject.trim().isEmpty &&
      content.trim().isEmpty &&
      attachmentPaths.isEmpty;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ComposeDraftSnapshot &&
        other.accountEmail == accountEmail &&
        other.recipientsJson == recipientsJson &&
        other.subject == subject &&
        other.content == content &&
        listEquals(other.attachmentPaths, attachmentPaths);
  }

  @override
  int get hashCode => Object.hash(
        accountEmail,
        recipientsJson,
        subject,
        // 正文可能有数 MB，把它整个塞进 `Object.hash` 会让每次「判等」变成一次
        // 全量哈希 —— 而判等本来就只在两串不同时才需要扫。用长度 + 首尾各一小段
        // 做哈希，碰撞的后果只是多走一次字段比较（`==` 里仍逐字段精确比），
        // 不会写错内容。
        content.length,
        _contentEdges(content),
        Object.hashAll(attachmentPaths),
      );

  static String _contentEdges(String text) {
    const edge = 64;
    if (text.length <= edge * 2) return text;
    return text.substring(0, edge) + text.substring(text.length - edge);
  }

  ComposeDraftSnapshot copyWith({
    String? accountEmail,
    String? recipientsJson,
    String? subject,
    String? content,
    List<String>? attachmentPaths,
  }) =>
      ComposeDraftSnapshot(
        accountEmail: accountEmail ?? this.accountEmail,
        recipientsJson: recipientsJson ?? this.recipientsJson,
        subject: subject ?? this.subject,
        content: content ?? this.content,
        attachmentPaths: attachmentPaths ?? this.attachmentPaths,
      );

  @override
  String toString() => 'ComposeDraftSnapshot(subject: "$subject", '
      'recipients: $recipientsJson, body: ${content.length} chars, '
      'attachments: ${attachmentPaths.length})';
}

/// 撰写页草稿的**唯一写入口**：防写风暴 + 防复活。
///
/// ## 为什么需要它
///
/// 1. **写风暴**：正文是 Delta JSON，内联图片以 `data:image/...;base64,...`
///    嵌在正文里（单张上限 5 MB）。一行的 `content` 可达数 MB —— 每敲一个字
///    写一次库，就是反复重写这几 MB。
/// 2. **复活**：页面关闭、发送成功、放弃草稿之后，防抖里的那一次迟到保存
///    绝不能把已删的草稿再写回来。
///
/// ## 规则（与 spec 一一对应）
///
/// - **trailing 防抖**：每次变化重置 [debounce]；停手才写，连续打字期间 0 次。
/// - **上限兜底**：[maxWait] 内必落一次（一直不停手也不会永远不落盘）。
/// - **指纹去重**：与上次落盘/待落盘的一致就丢弃；光标、提示这类 state 变化
///   根本不会走到这里（页面只把「内容字段」拍成快照）。
/// - **按列增量**：只把真的变了的列交给 DAO，改主题不会重写正文。
/// - **串行合并**：同一时刻最多一个 in-flight 写；写的过程中来的快照只保留
///   最新一份，写完再写一次 —— 中间态不落库。
/// - **UPDATE-only**：行被删之后写到的行数是 0，保存器直接进入「已死」态，
///   绝不 INSERT 复活（见 `LocalDao.updateDraftFields`）。
///
/// 它是个**普通类**，不持有 `Ref`：页面 `dispose()` 之后那次收尾落盘照样能
/// 跑完（DAO 是启动时就拿到的）。
class ComposeDraftSaver {
  ComposeDraftSaver({
    required this.dao,
    required this.draftId,
    this.debounce = kComposeDraftDebounce,
    this.maxWait = kComposeDraftMaxWait,
  });

  final LocalDao dao;

  /// 草稿行 id。`<= 0` 表示这一页没有可写的行（测试里直接用
  /// `ComposeScreen`、或不走路由的旧路径）—— 保存器整体不工作。
  final int draftId;

  /// 停手后等多久落盘。
  final Duration debounce;

  /// 从第一次有未落盘变化算起，最长等多久必须写一次。
  final Duration maxWait;

  ComposeDraftSnapshot? _pending;
  ComposeDraftSnapshot? _saved;
  Timer? _timer;
  DateTime? _firstPendingAt;
  Future<void>? _writing;

  /// 页面已经明确结束（关闭/放弃/发送成功）：拒绝一切新快照。
  bool _closed = false;

  /// 行已经被删（或确定删了）：拒绝一切写。
  bool _dead = false;

  int _writeCount = 0;
  int _skippedCount = 0;

  bool get isEnabled => draftId > 0;

  /// 实际写库次数（测试用）。
  @visibleForTesting
  int get writeCount => _writeCount;

  /// 因「内容没变」被丢弃的次数（测试用）。
  @visibleForTesting
  int get skippedCount => _skippedCount;

  bool get isDead => _dead;

  /// 首次装载的基线：页面刚把「已经存在的那份内容」装进编辑器时调用。
  ///
  /// 不设基线的话，打开一封几 MB 的草稿、一个字没改、切走 —— 会先整行重写
  /// 一遍。基线只在**从没落过盘**时才生效，之后任何一次真实写都会覆盖它。
  void markSaved(ComposeDraftSnapshot snapshot) {
    if (_closed || _dead || _saved != null || _pending != null) return;
    _saved = snapshot;
  }

  /// 记一次「内容变成这样了」。防抖后写；自动与待写/已写的去重。
  void schedule(ComposeDraftSnapshot snapshot) {
    if (!isEnabled || _closed || _dead) return;
    final previous = _pending ?? _saved;
    if (previous == snapshot) {
      _skippedCount++;
      return;
    }
    _pending = snapshot;
    _firstPendingAt ??= DateTime.now();
    _timer?.cancel();
    final overdue = _firstPendingAt != null &&
        DateTime.now().difference(_firstPendingAt!) >= maxWait;
    _timer = Timer(overdue ? Duration.zero : debounce, () {
      unawaited(flush());
    });
  }

  /// 立刻落盘（取消防抖）。切页、发送前、关闭前调用。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!isEnabled || _dead) return;
    // 等还在飞的那一次写完再收尾（它内部会继续 drain 新快照）。
    final inFlight = _writing;
    if (inFlight != null) {
      await inFlight;
    }
    if (_dead || _pending == null) return;
    final future = _drain();
    _writing = future;
    try {
      await future;
    } finally {
      if (identical(_writing, future)) _writing = null;
    }
  }

  /// 页面被销毁（不代表关闭草稿）：把最后一份内容尽量落下去。
  ///
  /// [finalSnapshot] 是页面在销毁前用**还活着的编辑器**拍的最后一份
  /// （比 `state.body` 新，最近 250 ms 的防抖可能还没烧完）；不给就用待写的
  /// 那一份。
  ///
  /// 不 `await` —— `dispose()` 里不能等。写是普通 Future，页面没了照样跑完。
  void dispose([ComposeDraftSnapshot? finalSnapshot]) {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (!isEnabled || _dead) return;
    final snapshot = finalSnapshot ?? _pending;
    if (snapshot == null) return;
    _pending = null;
    unawaited(_write(snapshot));
  }

  /// 页面/草稿已经结束（关闭、放弃、发送成功）：丢弃所有待写内容。
  ///
  /// 与 [dispose] 的区别：那个是「页面没了但内容要留」，这个是「内容不该
  /// 再出现在库里」。发送成功后由页面调用，防止收尾的 pop 又写回一条。
  void abandon() {
    _closed = true;
    _dead = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _firstPendingAt = null;
  }

  /// 把当前所有待写快照写到库里。串行合并：中间态不落库。
  Future<void> _drain() async {
    var failures = 0;
    while (!_dead) {
      final snapshot = _pending;
      if (snapshot == null) {
        _firstPendingAt = null;
        return;
      }
      _pending = null;
      final changed = _changedColumns(_saved, snapshot);
      if (changed == null) {
        // 内容其实没变（基线与当前快照一致）：记下基线，不写库。
        _saved = snapshot;
        _skippedCount++;
        continue;
      }
      try {
        final rows = await dao.updateDraftFields(
          draftId,
          accountEmail: changed.accountEmail,
          recipientsJson: changed.recipientsJson,
          subject: changed.subject,
          content: changed.content,
          attachmentPaths: changed.attachmentPaths,
        );
        _writeCount++;
        if (rows == 0) {
          // 行已经被删除：发送成功 / 放弃 / 空页关闭。**绝不能**再插回去。
          _dead = true;
          _pending = null;
          return;
        }
        _saved = snapshot;
        failures = 0;
      } catch (_) {
        // 本地库写失败（磁盘满、锁超时）不该把内容吞掉：放回待写，再试一次。
        // 第二次还失败就放弃 —— 无限重试只会把每次翻页都拖成卡顿。
        if (failures >= 1) {
          _pending = null;
          return;
        }
        failures++;
        _pending = snapshot;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// 立刻写一份（`dispose` 收尾用：不经过 `_pending` 的合并流程）。
  Future<void> _write(ComposeDraftSnapshot snapshot) async {
    if (_dead) return;
    final changed = _changedColumns(_saved, snapshot);
    if (changed == null) return;
    try {
      final rows = await dao.updateDraftFields(
        draftId,
        accountEmail: changed.accountEmail,
        recipientsJson: changed.recipientsJson,
        subject: changed.subject,
        content: changed.content,
        attachmentPaths: changed.attachmentPaths,
      );
      _writeCount++;
      if (rows == 0) {
        _dead = true;
        return;
      }
      _saved = snapshot;
    } catch (_) {
      // 收尾这一次失败就到这里：崩溃/关窗路径上没人能补救，日志由 DAO 那层
      // 自己决定要不要记（这里静默，不往 UI 弹东西）。
    }
  }

  static DraftColumnPatch? _changedColumns(
    ComposeDraftSnapshot? previous,
    ComposeDraftSnapshot next,
  ) =>
      changedDraftColumns(previous, next);
}

/// 两份快照的差异 → **只带真的变了的列**；null = 完全一样。
///
/// 单独一个纯函数（而不是塞在保存器私有方法里）是为了把「改主题不该重写
/// 正文」这条规矩钉成可单测的断言 —— 它是防写放大的核心，靠翻代码看不出来。
///
/// null 字段 = 这一列没变（DAO 侧落成 `Value.absent()`，SQL 里不会出现）。
DraftColumnPatch? changedDraftColumns(
  ComposeDraftSnapshot? previous,
  ComposeDraftSnapshot next,
) {
  if (previous == null) {
    return DraftColumnPatch(
      accountEmail: next.accountEmail,
      recipientsJson: next.recipientsJson,
      subject: next.subject,
      content: next.content,
      attachmentPaths: next.attachmentPaths,
    );
  }
  if (previous == next) return null;
  return DraftColumnPatch(
    accountEmail:
        previous.accountEmail == next.accountEmail ? null : next.accountEmail,
    recipientsJson: previous.recipientsJson == next.recipientsJson
        ? null
        : next.recipientsJson,
    subject: previous.subject == next.subject ? null : next.subject,
    content: previous.content == next.content ? null : next.content,
    attachmentPaths: listEquals(previous.attachmentPaths, next.attachmentPaths)
        ? null
        : next.attachmentPaths,
  );
}

/// [changedDraftColumns] 的结果：null 字段 = 这一列没变（DAO 侧 `Value.absent()`）。
class DraftColumnPatch {
  const DraftColumnPatch({
    this.accountEmail,
    this.recipientsJson,
    this.subject,
    this.content,
    this.attachmentPaths,
  });

  final String? accountEmail;
  final String? recipientsJson;
  final String? subject;
  final String? content;
  final List<String>? attachmentPaths;
}

/// 防抖时长。公开成常量而不是写在构造默认值里：测试要断言「1.5s 才写」，
/// 别处也可能想复用同一个数。
const Duration kComposeDraftDebounce = Duration(milliseconds: 1500);

/// 头部 `maxWait` 的默认值。
const Duration kComposeDraftMaxWait = Duration(seconds: 30);
