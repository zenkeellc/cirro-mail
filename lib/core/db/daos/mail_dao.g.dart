// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'mail_dao.dart';

// ignore_for_file: type=lint
mixin _$MailDaoMixin on DatabaseAccessor<AppDatabase> {
  $MailsTable get mails => attachedDatabase.mails;
  $AttachmentsTable get attachments => attachedDatabase.attachments;
  $SyncStatesTable get syncStates => attachedDatabase.syncStates;
  MailDaoManager get managers => MailDaoManager(this);
}

class MailDaoManager {
  final _$MailDaoMixin _db;
  MailDaoManager(this._db);
  $$MailsTableTableManager get mails =>
      $$MailsTableTableManager(_db.attachedDatabase, _db.mails);
  $$AttachmentsTableTableManager get attachments =>
      $$AttachmentsTableTableManager(_db.attachedDatabase, _db.attachments);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db.attachedDatabase, _db.syncStates);
}
