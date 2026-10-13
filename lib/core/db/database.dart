import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'daos/local_dao.dart';
import 'daos/mail_dao.dart';
import 'daos/profile_dao.dart';
import 'daos/reminder_dao.dart';
import 'tables.dart';

part 'database.g.dart';

/// 多实例共用的本地库。
///
/// 打开方式：`driftDatabase(name: 'cloud_mail')` —— 由 `drift_flutter` 处理
/// 各平台的原生 SQLite（Android/iOS/macOS 用系统库，Windows/Linux 走
/// `sqlite3` 自带原生资产）。**不要**直接依赖 `sqlite3_flutter_libs`，它已 EOL。
///
/// 所有写操作都走 `profileId`，聚合查询就是「不加 profileId 过滤」的同一张表。
///
/// daos 列在注解里（而不是手写 getter），这样 drift 生成的 `profileDao` /
/// `mailDao` / `localDao` 会随库一起重建，类型不会与表定义漂移。
@DriftDatabase(
  tables: [
    Profiles, Capabilities, Mailboxes, Mails, Attachments, SyncStates,
    OutboxEntries, RecipientsHistory, Drafts, Reminders,
  ],
  daos: [ProfileDao, MailDao, LocalDao, ReminderDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase()
      : super(
          driftDatabase(
            name: _dbName,
            // 开 WAL 的原因只有一个：**这个库会被两个 isolate 同时打开**。
            // 主 isolate（UI）之外，Android 的后台任务隔离环境也会开一份
            // （见 `features/notifications/background_sync_task.dart`）。
            // 默认的 rollback journal 下，两边同时读+写会互锁并抛
            // `database is locked` —— 后台那一轮同步会静默失败，
            // 而用户完全看不到原因。
            //
            // `busy_timeout` 是配套的第二半：WAL 允许「一个写多个读」，
            // 但两个**写**之间仍然要排队。没有这个超时，撞上的那一边会
            // 立刻拿到 SQLITE_BUSY 而不是等对方提交完。
            //
            // 注意 `setup` 是在 drift 自己那个后台 isolate 里执行的
            // （主 isolate 只是连过去），所以这里的代码不会捕获主 isolate 的
            // 任何变量 —— WAL 是**持久属性**，写一次就留在库文件里。
            native: DriftNativeOptions(
              setup: (db) {
                db.execute('PRAGMA journal_mode = WAL');
                db.execute('PRAGMA busy_timeout = 5000');
              },
            ),
          ),
        );

  /// 测试用：注入内存库或自定义执行器。
  AppDatabase.forTesting(super.executor);

  static const String _dbName = 'cloud_mail';

  @override
  int get schemaVersion => 4;   // 3 → 4：sync_states.remote_total_at（侧栏总数 TTL）

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // 聚合时间线的主查询：按时间倒序、跨实例。
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_mails_time '
            'ON mails (create_time DESC, profile_id, email_id DESC)',
          );
          // 单实例 / 单邮箱视图。
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_mails_profile_account '
            'ON mails (profile_id, account_id, email_id DESC)',
          );
          // 未读角标（服务端没有未读计数接口，只能在本地算）。
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_mails_unread '
            'ON mails (profile_id, unread, is_del)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_mails_type '
            'ON mails (profile_id, type, email_id DESC)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_attachments_email '
            'ON attachments (profile_id, email_id)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_attachments_local '
            'ON attachments (local_path)',
          );
        },
        onUpgrade: (m, from, to) async {
          // 逐级 migrate，**不要**用 destructive 迁移抹掉用户本地缓存
          // （草稿、发件箱里没发出去的信都在里面）。
          if (from < 2) {
            // v1 → v2：三处纯 ADD COLUMN，都有默认值，旧行语义不变。
            // - `outbox.scheduled_at`：null = 立刻可发（旧行为）；
            // - `sync_states.remote_total`：0 = 还不知道服务端有多少封；
            // - `sync_states.backfill_done`：false = 更旧的方向还没翻到底。
            //
            // 这段代码会被**两个 isolate** 各跑一次（UI 与 Android 后台任务
            // 共开一个库文件，见类注释）。它们由 SQLite 的 `user_version` 串行化：
            // 谁先拿到写锁谁执行 ALTER，另一个打开时已经看到 `from == to == 2`。
            // 因此这里只能放「快且可重复」的语句 —— 单条 ADD COLUMN 没问题，
            // 但**不要**在这里塞表重写（那会把 5 秒的 busy_timeout 撑爆）。
            await m.addColumn(outboxEntries, outboxEntries.scheduledAt);
            await m.addColumn(syncStates, syncStates.remoteTotal);
            await m.addColumn(syncStates, syncStates.backfillDone);
          }
          if (from < 3) {
            // 只建表。**不加索引、不重写别表** —— 两个 isolate 会各跑一次，
            // 靠 SQLite 的 user_version 串行化，语句必须快且可重复
            // （上面那段注释说的「不要在这里塞表重写」就是这条）。
            await m.createTable(reminders);
          }
          if (from < 4) {
            // `sync_states.remote_total_at`：null = 还没探过这个邮箱的总数，
            // 与 v3 之前的显示完全一致（侧栏右侧只有未读数）。同样是一条
            // **ADD COLUMN**，没有任何回填 —— 两个 isolate 各跑一次也安全。
            await m.addColumn(syncStates, syncStates.remoteTotalAt);
          }
        },
        beforeOpen: (details) async {
          // 外键在本库没用到（跨表引用一律靠 profileId+emailId 手工维护），
          // 但保留开启以免将来加了引用才发现。
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
