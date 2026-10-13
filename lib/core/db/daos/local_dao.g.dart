// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_dao.dart';

// ignore_for_file: type=lint
mixin _$LocalDaoMixin on DatabaseAccessor<AppDatabase> {
  $OutboxEntriesTable get outboxEntries => attachedDatabase.outboxEntries;
  $DraftsTable get drafts => attachedDatabase.drafts;
  $RecipientsHistoryTable get recipientsHistory =>
      attachedDatabase.recipientsHistory;
  LocalDaoManager get managers => LocalDaoManager(this);
}

class LocalDaoManager {
  final _$LocalDaoMixin _db;
  LocalDaoManager(this._db);
  $$OutboxEntriesTableTableManager get outboxEntries =>
      $$OutboxEntriesTableTableManager(_db.attachedDatabase, _db.outboxEntries);
  $$DraftsTableTableManager get drafts =>
      $$DraftsTableTableManager(_db.attachedDatabase, _db.drafts);
  $$RecipientsHistoryTableTableManager get recipientsHistory =>
      $$RecipientsHistoryTableTableManager(
        _db.attachedDatabase,
        _db.recipientsHistory,
      );
}
