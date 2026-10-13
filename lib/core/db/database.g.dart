// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ProfilesTable extends Profiles
    with TableInfo<$ProfilesTable, DbProfile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseUrlMeta = const VerificationMeta(
    'baseUrl',
  );
  @override
  late final GeneratedColumn<String> baseUrl = GeneratedColumn<String>(
    'base_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
    'email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverTitleMeta = const VerificationMeta(
    'serverTitle',
  );
  @override
  late final GeneratedColumn<String> serverTitle = GeneratedColumn<String>(
    'server_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _userNameMeta = const VerificationMeta(
    'userName',
  );
  @override
  late final GeneratedColumn<String> userName = GeneratedColumn<String>(
    'user_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ossBaseMeta = const VerificationMeta(
    'ossBase',
  );
  @override
  late final GeneratedColumn<String> ossBase = GeneratedColumn<String>(
    'oss_base',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _colorIndexMeta = const VerificationMeta(
    'colorIndex',
  );
  @override
  late final GeneratedColumn<int> colorIndex = GeneratedColumn<int>(
    'color_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _needsLoginMeta = const VerificationMeta(
    'needsLogin',
  );
  @override
  late final GeneratedColumn<bool> needsLogin = GeneratedColumn<bool>(
    'needs_login',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("needs_login" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lastSyncAtMeta = const VerificationMeta(
    'lastSyncAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastSyncAt = GeneratedColumn<DateTime>(
    'last_sync_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastActiveAtMeta = const VerificationMeta(
    'lastActiveAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastActiveAt = GeneratedColumn<DateTime>(
    'last_active_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    baseUrl,
    name,
    email,
    serverTitle,
    userName,
    userId,
    ossBase,
    sort,
    colorIndex,
    needsLogin,
    lastSyncAt,
    createdAt,
    lastActiveAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbProfile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('base_url')) {
      context.handle(
        _baseUrlMeta,
        baseUrl.isAcceptableOrUnknown(data['base_url']!, _baseUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_baseUrlMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('email')) {
      context.handle(
        _emailMeta,
        email.isAcceptableOrUnknown(data['email']!, _emailMeta),
      );
    }
    if (data.containsKey('server_title')) {
      context.handle(
        _serverTitleMeta,
        serverTitle.isAcceptableOrUnknown(
          data['server_title']!,
          _serverTitleMeta,
        ),
      );
    }
    if (data.containsKey('user_name')) {
      context.handle(
        _userNameMeta,
        userName.isAcceptableOrUnknown(data['user_name']!, _userNameMeta),
      );
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    }
    if (data.containsKey('oss_base')) {
      context.handle(
        _ossBaseMeta,
        ossBase.isAcceptableOrUnknown(data['oss_base']!, _ossBaseMeta),
      );
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('color_index')) {
      context.handle(
        _colorIndexMeta,
        colorIndex.isAcceptableOrUnknown(data['color_index']!, _colorIndexMeta),
      );
    }
    if (data.containsKey('needs_login')) {
      context.handle(
        _needsLoginMeta,
        needsLogin.isAcceptableOrUnknown(data['needs_login']!, _needsLoginMeta),
      );
    }
    if (data.containsKey('last_sync_at')) {
      context.handle(
        _lastSyncAtMeta,
        lastSyncAt.isAcceptableOrUnknown(
          data['last_sync_at']!,
          _lastSyncAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('last_active_at')) {
      context.handle(
        _lastActiveAtMeta,
        lastActiveAt.isAcceptableOrUnknown(
          data['last_active_at']!,
          _lastActiveAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbProfile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbProfile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      baseUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_url'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      email: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}email'],
      )!,
      serverTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_title'],
      )!,
      userName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_name'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      ossBase: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}oss_base'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      colorIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_index'],
      )!,
      needsLogin: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}needs_login'],
      )!,
      lastSyncAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_sync_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      ),
      lastActiveAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_active_at'],
      ),
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class DbProfile extends DataClass implements Insertable<DbProfile> {
  /// UUID，也是 secure storage 的 key 后缀。
  final String id;
  final String baseUrl;
  final String name;
  final String email;
  final String serverTitle;
  final String userName;
  final int userId;
  final String ossBase;
  final int sort;
  final int colorIndex;

  /// token 被判 401 后置位。该实例的同步循环停下，但不影响其他实例。
  final bool needsLogin;
  final DateTime? lastSyncAt;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;
  const DbProfile({
    required this.id,
    required this.baseUrl,
    required this.name,
    required this.email,
    required this.serverTitle,
    required this.userName,
    required this.userId,
    required this.ossBase,
    required this.sort,
    required this.colorIndex,
    required this.needsLogin,
    this.lastSyncAt,
    this.createdAt,
    this.lastActiveAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['base_url'] = Variable<String>(baseUrl);
    map['name'] = Variable<String>(name);
    map['email'] = Variable<String>(email);
    map['server_title'] = Variable<String>(serverTitle);
    map['user_name'] = Variable<String>(userName);
    map['user_id'] = Variable<int>(userId);
    map['oss_base'] = Variable<String>(ossBase);
    map['sort'] = Variable<int>(sort);
    map['color_index'] = Variable<int>(colorIndex);
    map['needs_login'] = Variable<bool>(needsLogin);
    if (!nullToAbsent || lastSyncAt != null) {
      map['last_sync_at'] = Variable<DateTime>(lastSyncAt);
    }
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    if (!nullToAbsent || lastActiveAt != null) {
      map['last_active_at'] = Variable<DateTime>(lastActiveAt);
    }
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(
      id: Value(id),
      baseUrl: Value(baseUrl),
      name: Value(name),
      email: Value(email),
      serverTitle: Value(serverTitle),
      userName: Value(userName),
      userId: Value(userId),
      ossBase: Value(ossBase),
      sort: Value(sort),
      colorIndex: Value(colorIndex),
      needsLogin: Value(needsLogin),
      lastSyncAt: lastSyncAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncAt),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
      lastActiveAt: lastActiveAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastActiveAt),
    );
  }

  factory DbProfile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbProfile(
      id: serializer.fromJson<String>(json['id']),
      baseUrl: serializer.fromJson<String>(json['baseUrl']),
      name: serializer.fromJson<String>(json['name']),
      email: serializer.fromJson<String>(json['email']),
      serverTitle: serializer.fromJson<String>(json['serverTitle']),
      userName: serializer.fromJson<String>(json['userName']),
      userId: serializer.fromJson<int>(json['userId']),
      ossBase: serializer.fromJson<String>(json['ossBase']),
      sort: serializer.fromJson<int>(json['sort']),
      colorIndex: serializer.fromJson<int>(json['colorIndex']),
      needsLogin: serializer.fromJson<bool>(json['needsLogin']),
      lastSyncAt: serializer.fromJson<DateTime?>(json['lastSyncAt']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
      lastActiveAt: serializer.fromJson<DateTime?>(json['lastActiveAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'baseUrl': serializer.toJson<String>(baseUrl),
      'name': serializer.toJson<String>(name),
      'email': serializer.toJson<String>(email),
      'serverTitle': serializer.toJson<String>(serverTitle),
      'userName': serializer.toJson<String>(userName),
      'userId': serializer.toJson<int>(userId),
      'ossBase': serializer.toJson<String>(ossBase),
      'sort': serializer.toJson<int>(sort),
      'colorIndex': serializer.toJson<int>(colorIndex),
      'needsLogin': serializer.toJson<bool>(needsLogin),
      'lastSyncAt': serializer.toJson<DateTime?>(lastSyncAt),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
      'lastActiveAt': serializer.toJson<DateTime?>(lastActiveAt),
    };
  }

  DbProfile copyWith({
    String? id,
    String? baseUrl,
    String? name,
    String? email,
    String? serverTitle,
    String? userName,
    int? userId,
    String? ossBase,
    int? sort,
    int? colorIndex,
    bool? needsLogin,
    Value<DateTime?> lastSyncAt = const Value.absent(),
    Value<DateTime?> createdAt = const Value.absent(),
    Value<DateTime?> lastActiveAt = const Value.absent(),
  }) => DbProfile(
    id: id ?? this.id,
    baseUrl: baseUrl ?? this.baseUrl,
    name: name ?? this.name,
    email: email ?? this.email,
    serverTitle: serverTitle ?? this.serverTitle,
    userName: userName ?? this.userName,
    userId: userId ?? this.userId,
    ossBase: ossBase ?? this.ossBase,
    sort: sort ?? this.sort,
    colorIndex: colorIndex ?? this.colorIndex,
    needsLogin: needsLogin ?? this.needsLogin,
    lastSyncAt: lastSyncAt.present ? lastSyncAt.value : this.lastSyncAt,
    createdAt: createdAt.present ? createdAt.value : this.createdAt,
    lastActiveAt: lastActiveAt.present ? lastActiveAt.value : this.lastActiveAt,
  );
  DbProfile copyWithCompanion(ProfilesCompanion data) {
    return DbProfile(
      id: data.id.present ? data.id.value : this.id,
      baseUrl: data.baseUrl.present ? data.baseUrl.value : this.baseUrl,
      name: data.name.present ? data.name.value : this.name,
      email: data.email.present ? data.email.value : this.email,
      serverTitle: data.serverTitle.present
          ? data.serverTitle.value
          : this.serverTitle,
      userName: data.userName.present ? data.userName.value : this.userName,
      userId: data.userId.present ? data.userId.value : this.userId,
      ossBase: data.ossBase.present ? data.ossBase.value : this.ossBase,
      sort: data.sort.present ? data.sort.value : this.sort,
      colorIndex: data.colorIndex.present
          ? data.colorIndex.value
          : this.colorIndex,
      needsLogin: data.needsLogin.present
          ? data.needsLogin.value
          : this.needsLogin,
      lastSyncAt: data.lastSyncAt.present
          ? data.lastSyncAt.value
          : this.lastSyncAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastActiveAt: data.lastActiveAt.present
          ? data.lastActiveAt.value
          : this.lastActiveAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbProfile(')
          ..write('id: $id, ')
          ..write('baseUrl: $baseUrl, ')
          ..write('name: $name, ')
          ..write('email: $email, ')
          ..write('serverTitle: $serverTitle, ')
          ..write('userName: $userName, ')
          ..write('userId: $userId, ')
          ..write('ossBase: $ossBase, ')
          ..write('sort: $sort, ')
          ..write('colorIndex: $colorIndex, ')
          ..write('needsLogin: $needsLogin, ')
          ..write('lastSyncAt: $lastSyncAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastActiveAt: $lastActiveAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    baseUrl,
    name,
    email,
    serverTitle,
    userName,
    userId,
    ossBase,
    sort,
    colorIndex,
    needsLogin,
    lastSyncAt,
    createdAt,
    lastActiveAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbProfile &&
          other.id == this.id &&
          other.baseUrl == this.baseUrl &&
          other.name == this.name &&
          other.email == this.email &&
          other.serverTitle == this.serverTitle &&
          other.userName == this.userName &&
          other.userId == this.userId &&
          other.ossBase == this.ossBase &&
          other.sort == this.sort &&
          other.colorIndex == this.colorIndex &&
          other.needsLogin == this.needsLogin &&
          other.lastSyncAt == this.lastSyncAt &&
          other.createdAt == this.createdAt &&
          other.lastActiveAt == this.lastActiveAt);
}

class ProfilesCompanion extends UpdateCompanion<DbProfile> {
  final Value<String> id;
  final Value<String> baseUrl;
  final Value<String> name;
  final Value<String> email;
  final Value<String> serverTitle;
  final Value<String> userName;
  final Value<int> userId;
  final Value<String> ossBase;
  final Value<int> sort;
  final Value<int> colorIndex;
  final Value<bool> needsLogin;
  final Value<DateTime?> lastSyncAt;
  final Value<DateTime?> createdAt;
  final Value<DateTime?> lastActiveAt;
  final Value<int> rowid;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.baseUrl = const Value.absent(),
    this.name = const Value.absent(),
    this.email = const Value.absent(),
    this.serverTitle = const Value.absent(),
    this.userName = const Value.absent(),
    this.userId = const Value.absent(),
    this.ossBase = const Value.absent(),
    this.sort = const Value.absent(),
    this.colorIndex = const Value.absent(),
    this.needsLogin = const Value.absent(),
    this.lastSyncAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastActiveAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfilesCompanion.insert({
    required String id,
    required String baseUrl,
    this.name = const Value.absent(),
    this.email = const Value.absent(),
    this.serverTitle = const Value.absent(),
    this.userName = const Value.absent(),
    this.userId = const Value.absent(),
    this.ossBase = const Value.absent(),
    this.sort = const Value.absent(),
    this.colorIndex = const Value.absent(),
    this.needsLogin = const Value.absent(),
    this.lastSyncAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastActiveAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       baseUrl = Value(baseUrl);
  static Insertable<DbProfile> custom({
    Expression<String>? id,
    Expression<String>? baseUrl,
    Expression<String>? name,
    Expression<String>? email,
    Expression<String>? serverTitle,
    Expression<String>? userName,
    Expression<int>? userId,
    Expression<String>? ossBase,
    Expression<int>? sort,
    Expression<int>? colorIndex,
    Expression<bool>? needsLogin,
    Expression<DateTime>? lastSyncAt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? lastActiveAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (baseUrl != null) 'base_url': baseUrl,
      if (name != null) 'name': name,
      if (email != null) 'email': email,
      if (serverTitle != null) 'server_title': serverTitle,
      if (userName != null) 'user_name': userName,
      if (userId != null) 'user_id': userId,
      if (ossBase != null) 'oss_base': ossBase,
      if (sort != null) 'sort': sort,
      if (colorIndex != null) 'color_index': colorIndex,
      if (needsLogin != null) 'needs_login': needsLogin,
      if (lastSyncAt != null) 'last_sync_at': lastSyncAt,
      if (createdAt != null) 'created_at': createdAt,
      if (lastActiveAt != null) 'last_active_at': lastActiveAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfilesCompanion copyWith({
    Value<String>? id,
    Value<String>? baseUrl,
    Value<String>? name,
    Value<String>? email,
    Value<String>? serverTitle,
    Value<String>? userName,
    Value<int>? userId,
    Value<String>? ossBase,
    Value<int>? sort,
    Value<int>? colorIndex,
    Value<bool>? needsLogin,
    Value<DateTime?>? lastSyncAt,
    Value<DateTime?>? createdAt,
    Value<DateTime?>? lastActiveAt,
    Value<int>? rowid,
  }) {
    return ProfilesCompanion(
      id: id ?? this.id,
      baseUrl: baseUrl ?? this.baseUrl,
      name: name ?? this.name,
      email: email ?? this.email,
      serverTitle: serverTitle ?? this.serverTitle,
      userName: userName ?? this.userName,
      userId: userId ?? this.userId,
      ossBase: ossBase ?? this.ossBase,
      sort: sort ?? this.sort,
      colorIndex: colorIndex ?? this.colorIndex,
      needsLogin: needsLogin ?? this.needsLogin,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      createdAt: createdAt ?? this.createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (baseUrl.present) {
      map['base_url'] = Variable<String>(baseUrl.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (serverTitle.present) {
      map['server_title'] = Variable<String>(serverTitle.value);
    }
    if (userName.present) {
      map['user_name'] = Variable<String>(userName.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (ossBase.present) {
      map['oss_base'] = Variable<String>(ossBase.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (colorIndex.present) {
      map['color_index'] = Variable<int>(colorIndex.value);
    }
    if (needsLogin.present) {
      map['needs_login'] = Variable<bool>(needsLogin.value);
    }
    if (lastSyncAt.present) {
      map['last_sync_at'] = Variable<DateTime>(lastSyncAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastActiveAt.present) {
      map['last_active_at'] = Variable<DateTime>(lastActiveAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('baseUrl: $baseUrl, ')
          ..write('name: $name, ')
          ..write('email: $email, ')
          ..write('serverTitle: $serverTitle, ')
          ..write('userName: $userName, ')
          ..write('userId: $userId, ')
          ..write('ossBase: $ossBase, ')
          ..write('sort: $sort, ')
          ..write('colorIndex: $colorIndex, ')
          ..write('needsLogin: $needsLogin, ')
          ..write('lastSyncAt: $lastSyncAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastActiveAt: $lastActiveAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CapabilitiesTable extends Capabilities
    with TableInfo<$CapabilitiesTable, DbCapability> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CapabilitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _probedAtMeta = const VerificationMeta(
    'probedAt',
  );
  @override
  late final GeneratedColumn<DateTime> probedAt = GeneratedColumn<DateTime>(
    'probed_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [profileId, payload, probedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'capabilities';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbCapability> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('probed_at')) {
      context.handle(
        _probedAtMeta,
        probedAt.isAcceptableOrUnknown(data['probed_at']!, _probedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId};
  @override
  DbCapability map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbCapability(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      probedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}probed_at'],
      ),
    );
  }

  @override
  $CapabilitiesTable createAlias(String alias) {
    return $CapabilitiesTable(attachedDatabase, alias);
  }
}

class DbCapability extends DataClass implements Insertable<DbCapability> {
  final String profileId;
  final String payload;
  final DateTime? probedAt;
  const DbCapability({
    required this.profileId,
    required this.payload,
    this.probedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['payload'] = Variable<String>(payload);
    if (!nullToAbsent || probedAt != null) {
      map['probed_at'] = Variable<DateTime>(probedAt);
    }
    return map;
  }

  CapabilitiesCompanion toCompanion(bool nullToAbsent) {
    return CapabilitiesCompanion(
      profileId: Value(profileId),
      payload: Value(payload),
      probedAt: probedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(probedAt),
    );
  }

  factory DbCapability.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbCapability(
      profileId: serializer.fromJson<String>(json['profileId']),
      payload: serializer.fromJson<String>(json['payload']),
      probedAt: serializer.fromJson<DateTime?>(json['probedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'payload': serializer.toJson<String>(payload),
      'probedAt': serializer.toJson<DateTime?>(probedAt),
    };
  }

  DbCapability copyWith({
    String? profileId,
    String? payload,
    Value<DateTime?> probedAt = const Value.absent(),
  }) => DbCapability(
    profileId: profileId ?? this.profileId,
    payload: payload ?? this.payload,
    probedAt: probedAt.present ? probedAt.value : this.probedAt,
  );
  DbCapability copyWithCompanion(CapabilitiesCompanion data) {
    return DbCapability(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      payload: data.payload.present ? data.payload.value : this.payload,
      probedAt: data.probedAt.present ? data.probedAt.value : this.probedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbCapability(')
          ..write('profileId: $profileId, ')
          ..write('payload: $payload, ')
          ..write('probedAt: $probedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(profileId, payload, probedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbCapability &&
          other.profileId == this.profileId &&
          other.payload == this.payload &&
          other.probedAt == this.probedAt);
}

class CapabilitiesCompanion extends UpdateCompanion<DbCapability> {
  final Value<String> profileId;
  final Value<String> payload;
  final Value<DateTime?> probedAt;
  final Value<int> rowid;
  const CapabilitiesCompanion({
    this.profileId = const Value.absent(),
    this.payload = const Value.absent(),
    this.probedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CapabilitiesCompanion.insert({
    required String profileId,
    required String payload,
    this.probedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       payload = Value(payload);
  static Insertable<DbCapability> custom({
    Expression<String>? profileId,
    Expression<String>? payload,
    Expression<DateTime>? probedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (payload != null) 'payload': payload,
      if (probedAt != null) 'probed_at': probedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CapabilitiesCompanion copyWith({
    Value<String>? profileId,
    Value<String>? payload,
    Value<DateTime?>? probedAt,
    Value<int>? rowid,
  }) {
    return CapabilitiesCompanion(
      profileId: profileId ?? this.profileId,
      payload: payload ?? this.payload,
      probedAt: probedAt ?? this.probedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (probedAt.present) {
      map['probed_at'] = Variable<DateTime>(probedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CapabilitiesCompanion(')
          ..write('profileId: $profileId, ')
          ..write('payload: $payload, ')
          ..write('probedAt: $probedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MailboxesTable extends Mailboxes
    with TableInfo<$MailboxesTable, DbMailbox> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MailboxesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
    'email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _allReceiveMeta = const VerificationMeta(
    'allReceive',
  );
  @override
  late final GeneratedColumn<int> allReceive = GeneratedColumn<int>(
    'all_receive',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _latestEmailTimeMeta = const VerificationMeta(
    'latestEmailTime',
  );
  @override
  late final GeneratedColumn<String> latestEmailTime = GeneratedColumn<String>(
    'latest_email_time',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  @override
  late final GeneratedColumn<DateTime> syncedAt = GeneratedColumn<DateTime>(
    'synced_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    accountId,
    email,
    name,
    status,
    allReceive,
    sort,
    latestEmailTime,
    syncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mailboxes';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbMailbox> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('email')) {
      context.handle(
        _emailMeta,
        email.isAcceptableOrUnknown(data['email']!, _emailMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('all_receive')) {
      context.handle(
        _allReceiveMeta,
        allReceive.isAcceptableOrUnknown(data['all_receive']!, _allReceiveMeta),
      );
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('latest_email_time')) {
      context.handle(
        _latestEmailTimeMeta,
        latestEmailTime.isAcceptableOrUnknown(
          data['latest_email_time']!,
          _latestEmailTimeMeta,
        ),
      );
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, accountId};
  @override
  DbMailbox map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbMailbox(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      email: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}email'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}status'],
      )!,
      allReceive: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}all_receive'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      latestEmailTime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}latest_email_time'],
      ),
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}synced_at'],
      ),
    );
  }

  @override
  $MailboxesTable createAlias(String alias) {
    return $MailboxesTable(attachedDatabase, alias);
  }
}

class DbMailbox extends DataClass implements Insertable<DbMailbox> {
  final String profileId;
  final int accountId;
  final String email;
  final String name;
  final int status;

  /// 1 = 接收该用户所有邮箱的邮件。服务端的 `setAllReceive` 是**切换语义**
  /// （开一个会清掉其他），客户端要单邮箱开启或用合并视图代替。
  final int allReceive;
  final int sort;

  /// 服务端给的是时间字符串，原样保留（只用于「最近活跃」展示）。
  final String? latestEmailTime;
  final DateTime? syncedAt;
  const DbMailbox({
    required this.profileId,
    required this.accountId,
    required this.email,
    required this.name,
    required this.status,
    required this.allReceive,
    required this.sort,
    this.latestEmailTime,
    this.syncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['account_id'] = Variable<int>(accountId);
    map['email'] = Variable<String>(email);
    map['name'] = Variable<String>(name);
    map['status'] = Variable<int>(status);
    map['all_receive'] = Variable<int>(allReceive);
    map['sort'] = Variable<int>(sort);
    if (!nullToAbsent || latestEmailTime != null) {
      map['latest_email_time'] = Variable<String>(latestEmailTime);
    }
    if (!nullToAbsent || syncedAt != null) {
      map['synced_at'] = Variable<DateTime>(syncedAt);
    }
    return map;
  }

  MailboxesCompanion toCompanion(bool nullToAbsent) {
    return MailboxesCompanion(
      profileId: Value(profileId),
      accountId: Value(accountId),
      email: Value(email),
      name: Value(name),
      status: Value(status),
      allReceive: Value(allReceive),
      sort: Value(sort),
      latestEmailTime: latestEmailTime == null && nullToAbsent
          ? const Value.absent()
          : Value(latestEmailTime),
      syncedAt: syncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedAt),
    );
  }

  factory DbMailbox.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbMailbox(
      profileId: serializer.fromJson<String>(json['profileId']),
      accountId: serializer.fromJson<int>(json['accountId']),
      email: serializer.fromJson<String>(json['email']),
      name: serializer.fromJson<String>(json['name']),
      status: serializer.fromJson<int>(json['status']),
      allReceive: serializer.fromJson<int>(json['allReceive']),
      sort: serializer.fromJson<int>(json['sort']),
      latestEmailTime: serializer.fromJson<String?>(json['latestEmailTime']),
      syncedAt: serializer.fromJson<DateTime?>(json['syncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'accountId': serializer.toJson<int>(accountId),
      'email': serializer.toJson<String>(email),
      'name': serializer.toJson<String>(name),
      'status': serializer.toJson<int>(status),
      'allReceive': serializer.toJson<int>(allReceive),
      'sort': serializer.toJson<int>(sort),
      'latestEmailTime': serializer.toJson<String?>(latestEmailTime),
      'syncedAt': serializer.toJson<DateTime?>(syncedAt),
    };
  }

  DbMailbox copyWith({
    String? profileId,
    int? accountId,
    String? email,
    String? name,
    int? status,
    int? allReceive,
    int? sort,
    Value<String?> latestEmailTime = const Value.absent(),
    Value<DateTime?> syncedAt = const Value.absent(),
  }) => DbMailbox(
    profileId: profileId ?? this.profileId,
    accountId: accountId ?? this.accountId,
    email: email ?? this.email,
    name: name ?? this.name,
    status: status ?? this.status,
    allReceive: allReceive ?? this.allReceive,
    sort: sort ?? this.sort,
    latestEmailTime: latestEmailTime.present
        ? latestEmailTime.value
        : this.latestEmailTime,
    syncedAt: syncedAt.present ? syncedAt.value : this.syncedAt,
  );
  DbMailbox copyWithCompanion(MailboxesCompanion data) {
    return DbMailbox(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      email: data.email.present ? data.email.value : this.email,
      name: data.name.present ? data.name.value : this.name,
      status: data.status.present ? data.status.value : this.status,
      allReceive: data.allReceive.present
          ? data.allReceive.value
          : this.allReceive,
      sort: data.sort.present ? data.sort.value : this.sort,
      latestEmailTime: data.latestEmailTime.present
          ? data.latestEmailTime.value
          : this.latestEmailTime,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbMailbox(')
          ..write('profileId: $profileId, ')
          ..write('accountId: $accountId, ')
          ..write('email: $email, ')
          ..write('name: $name, ')
          ..write('status: $status, ')
          ..write('allReceive: $allReceive, ')
          ..write('sort: $sort, ')
          ..write('latestEmailTime: $latestEmailTime, ')
          ..write('syncedAt: $syncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    profileId,
    accountId,
    email,
    name,
    status,
    allReceive,
    sort,
    latestEmailTime,
    syncedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbMailbox &&
          other.profileId == this.profileId &&
          other.accountId == this.accountId &&
          other.email == this.email &&
          other.name == this.name &&
          other.status == this.status &&
          other.allReceive == this.allReceive &&
          other.sort == this.sort &&
          other.latestEmailTime == this.latestEmailTime &&
          other.syncedAt == this.syncedAt);
}

class MailboxesCompanion extends UpdateCompanion<DbMailbox> {
  final Value<String> profileId;
  final Value<int> accountId;
  final Value<String> email;
  final Value<String> name;
  final Value<int> status;
  final Value<int> allReceive;
  final Value<int> sort;
  final Value<String?> latestEmailTime;
  final Value<DateTime?> syncedAt;
  final Value<int> rowid;
  const MailboxesCompanion({
    this.profileId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.email = const Value.absent(),
    this.name = const Value.absent(),
    this.status = const Value.absent(),
    this.allReceive = const Value.absent(),
    this.sort = const Value.absent(),
    this.latestEmailTime = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MailboxesCompanion.insert({
    required String profileId,
    required int accountId,
    this.email = const Value.absent(),
    this.name = const Value.absent(),
    this.status = const Value.absent(),
    this.allReceive = const Value.absent(),
    this.sort = const Value.absent(),
    this.latestEmailTime = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       accountId = Value(accountId);
  static Insertable<DbMailbox> custom({
    Expression<String>? profileId,
    Expression<int>? accountId,
    Expression<String>? email,
    Expression<String>? name,
    Expression<int>? status,
    Expression<int>? allReceive,
    Expression<int>? sort,
    Expression<String>? latestEmailTime,
    Expression<DateTime>? syncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (accountId != null) 'account_id': accountId,
      if (email != null) 'email': email,
      if (name != null) 'name': name,
      if (status != null) 'status': status,
      if (allReceive != null) 'all_receive': allReceive,
      if (sort != null) 'sort': sort,
      if (latestEmailTime != null) 'latest_email_time': latestEmailTime,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MailboxesCompanion copyWith({
    Value<String>? profileId,
    Value<int>? accountId,
    Value<String>? email,
    Value<String>? name,
    Value<int>? status,
    Value<int>? allReceive,
    Value<int>? sort,
    Value<String?>? latestEmailTime,
    Value<DateTime?>? syncedAt,
    Value<int>? rowid,
  }) {
    return MailboxesCompanion(
      profileId: profileId ?? this.profileId,
      accountId: accountId ?? this.accountId,
      email: email ?? this.email,
      name: name ?? this.name,
      status: status ?? this.status,
      allReceive: allReceive ?? this.allReceive,
      sort: sort ?? this.sort,
      latestEmailTime: latestEmailTime ?? this.latestEmailTime,
      syncedAt: syncedAt ?? this.syncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (allReceive.present) {
      map['all_receive'] = Variable<int>(allReceive.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (latestEmailTime.present) {
      map['latest_email_time'] = Variable<String>(latestEmailTime.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<DateTime>(syncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MailboxesCompanion(')
          ..write('profileId: $profileId, ')
          ..write('accountId: $accountId, ')
          ..write('email: $email, ')
          ..write('name: $name, ')
          ..write('status: $status, ')
          ..write('allReceive: $allReceive, ')
          ..write('sort: $sort, ')
          ..write('latestEmailTime: $latestEmailTime, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MailsTable extends Mails with TableInfo<$MailsTable, DbMail> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MailsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emailIdMeta = const VerificationMeta(
    'emailId',
  );
  @override
  late final GeneratedColumn<int> emailId = GeneratedColumn<int>(
    'email_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _mailboxEmailMeta = const VerificationMeta(
    'mailboxEmail',
  );
  @override
  late final GeneratedColumn<String> mailboxEmail = GeneratedColumn<String>(
    'mailbox_email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sendEmailMeta = const VerificationMeta(
    'sendEmail',
  );
  @override
  late final GeneratedColumn<String> sendEmail = GeneratedColumn<String>(
    'send_email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _toEmailMeta = const VerificationMeta(
    'toEmail',
  );
  @override
  late final GeneratedColumn<String> toEmail = GeneratedColumn<String>(
    'to_email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _toNameMeta = const VerificationMeta('toName');
  @override
  late final GeneratedColumn<String> toName = GeneratedColumn<String>(
    'to_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _recipientJsonMeta = const VerificationMeta(
    'recipientJson',
  );
  @override
  late final GeneratedColumn<String> recipientJson = GeneratedColumn<String>(
    'recipient_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _ccJsonMeta = const VerificationMeta('ccJson');
  @override
  late final GeneratedColumn<String> ccJson = GeneratedColumn<String>(
    'cc_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _bccJsonMeta = const VerificationMeta(
    'bccJson',
  );
  @override
  late final GeneratedColumn<String> bccJson = GeneratedColumn<String>(
    'bcc_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _messageMeta = const VerificationMeta(
    'message',
  );
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
    'message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _unreadMeta = const VerificationMeta('unread');
  @override
  late final GeneratedColumn<int> unread = GeneratedColumn<int>(
    'unread',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isStarMeta = const VerificationMeta('isStar');
  @override
  late final GeneratedColumn<int> isStar = GeneratedColumn<int>(
    'is_star',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _starKnownMeta = const VerificationMeta(
    'starKnown',
  );
  @override
  late final GeneratedColumn<bool> starKnown = GeneratedColumn<bool>(
    'star_known',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("star_known" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDelMeta = const VerificationMeta('isDel');
  @override
  late final GeneratedColumn<int> isDel = GeneratedColumn<int>(
    'is_del',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bodyTextMeta = const VerificationMeta(
    'bodyText',
  );
  @override
  late final GeneratedColumn<String> bodyText = GeneratedColumn<String>(
    'body_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _inReplyToMeta = const VerificationMeta(
    'inReplyTo',
  );
  @override
  late final GeneratedColumn<String> inReplyTo = GeneratedColumn<String>(
    'in_reply_to',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _relationMeta = const VerificationMeta(
    'relation',
  );
  @override
  late final GeneratedColumn<String> relation = GeneratedColumn<String>(
    'relation',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resendEmailIdMeta = const VerificationMeta(
    'resendEmailId',
  );
  @override
  late final GeneratedColumn<String> resendEmailId = GeneratedColumn<String>(
    'resend_email_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createTimeMeta = const VerificationMeta(
    'createTime',
  );
  @override
  late final GeneratedColumn<DateTime> createTime = GeneratedColumn<DateTime>(
    'create_time',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hasFullBodyMeta = const VerificationMeta(
    'hasFullBody',
  );
  @override
  late final GeneratedColumn<bool> hasFullBody = GeneratedColumn<bool>(
    'has_full_body',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_full_body" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<DateTime> cachedAt = GeneratedColumn<DateTime>(
    'cached_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    emailId,
    accountId,
    mailboxEmail,
    type,
    status,
    sendEmail,
    name,
    subject,
    code,
    toEmail,
    toName,
    recipientJson,
    ccJson,
    bccJson,
    message,
    unread,
    isStar,
    starKnown,
    isDel,
    content,
    bodyText,
    inReplyTo,
    relation,
    messageId,
    resendEmailId,
    createTime,
    hasFullBody,
    cachedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mails';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbMail> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('email_id')) {
      context.handle(
        _emailIdMeta,
        emailId.isAcceptableOrUnknown(data['email_id']!, _emailIdMeta),
      );
    } else if (isInserting) {
      context.missing(_emailIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('mailbox_email')) {
      context.handle(
        _mailboxEmailMeta,
        mailboxEmail.isAcceptableOrUnknown(
          data['mailbox_email']!,
          _mailboxEmailMeta,
        ),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('send_email')) {
      context.handle(
        _sendEmailMeta,
        sendEmail.isAcceptableOrUnknown(data['send_email']!, _sendEmailMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    }
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    }
    if (data.containsKey('to_email')) {
      context.handle(
        _toEmailMeta,
        toEmail.isAcceptableOrUnknown(data['to_email']!, _toEmailMeta),
      );
    }
    if (data.containsKey('to_name')) {
      context.handle(
        _toNameMeta,
        toName.isAcceptableOrUnknown(data['to_name']!, _toNameMeta),
      );
    }
    if (data.containsKey('recipient_json')) {
      context.handle(
        _recipientJsonMeta,
        recipientJson.isAcceptableOrUnknown(
          data['recipient_json']!,
          _recipientJsonMeta,
        ),
      );
    }
    if (data.containsKey('cc_json')) {
      context.handle(
        _ccJsonMeta,
        ccJson.isAcceptableOrUnknown(data['cc_json']!, _ccJsonMeta),
      );
    }
    if (data.containsKey('bcc_json')) {
      context.handle(
        _bccJsonMeta,
        bccJson.isAcceptableOrUnknown(data['bcc_json']!, _bccJsonMeta),
      );
    }
    if (data.containsKey('message')) {
      context.handle(
        _messageMeta,
        message.isAcceptableOrUnknown(data['message']!, _messageMeta),
      );
    }
    if (data.containsKey('unread')) {
      context.handle(
        _unreadMeta,
        unread.isAcceptableOrUnknown(data['unread']!, _unreadMeta),
      );
    }
    if (data.containsKey('is_star')) {
      context.handle(
        _isStarMeta,
        isStar.isAcceptableOrUnknown(data['is_star']!, _isStarMeta),
      );
    }
    if (data.containsKey('star_known')) {
      context.handle(
        _starKnownMeta,
        starKnown.isAcceptableOrUnknown(data['star_known']!, _starKnownMeta),
      );
    }
    if (data.containsKey('is_del')) {
      context.handle(
        _isDelMeta,
        isDel.isAcceptableOrUnknown(data['is_del']!, _isDelMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('body_text')) {
      context.handle(
        _bodyTextMeta,
        bodyText.isAcceptableOrUnknown(data['body_text']!, _bodyTextMeta),
      );
    }
    if (data.containsKey('in_reply_to')) {
      context.handle(
        _inReplyToMeta,
        inReplyTo.isAcceptableOrUnknown(data['in_reply_to']!, _inReplyToMeta),
      );
    }
    if (data.containsKey('relation')) {
      context.handle(
        _relationMeta,
        relation.isAcceptableOrUnknown(data['relation']!, _relationMeta),
      );
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    }
    if (data.containsKey('resend_email_id')) {
      context.handle(
        _resendEmailIdMeta,
        resendEmailId.isAcceptableOrUnknown(
          data['resend_email_id']!,
          _resendEmailIdMeta,
        ),
      );
    }
    if (data.containsKey('create_time')) {
      context.handle(
        _createTimeMeta,
        createTime.isAcceptableOrUnknown(data['create_time']!, _createTimeMeta),
      );
    }
    if (data.containsKey('has_full_body')) {
      context.handle(
        _hasFullBodyMeta,
        hasFullBody.isAcceptableOrUnknown(
          data['has_full_body']!,
          _hasFullBodyMeta,
        ),
      );
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, emailId};
  @override
  DbMail map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbMail(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      emailId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}email_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      mailboxEmail: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mailbox_email'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}status'],
      )!,
      sendEmail: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}send_email'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      )!,
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      toEmail: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_email'],
      )!,
      toName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_name'],
      )!,
      recipientJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recipient_json'],
      )!,
      ccJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cc_json'],
      )!,
      bccJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bcc_json'],
      )!,
      message: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message'],
      ),
      unread: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread'],
      )!,
      isStar: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_star'],
      )!,
      starKnown: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}star_known'],
      )!,
      isDel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_del'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      ),
      bodyText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body_text'],
      ),
      inReplyTo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}in_reply_to'],
      ),
      relation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relation'],
      ),
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      ),
      resendEmailId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resend_email_id'],
      ),
      createTime: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}create_time'],
      ),
      hasFullBody: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_full_body'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cached_at'],
      ),
    );
  }

  @override
  $MailsTable createAlias(String alias) {
    return $MailsTable(attachedDatabase, alias);
  }
}

class DbMail extends DataClass implements Insertable<DbMail> {
  final String profileId;
  final int emailId;

  /// 这封邮件归属的邮箱（`email.accountId`）。
  final int accountId;

  /// 该邮件被投递到的邮箱地址，聚合视图与通知深链要用（列表接口不返回，
  /// 由本地根据 accountId 补上）。
  final String mailboxEmail;

  /// 0 收件 / 1 发件。
  final int type;
  final int status;
  final String sendEmail;
  final String name;
  final String subject;
  final String code;
  final String toEmail;
  final String toName;

  /// 收件人/抄送/密送：**原样保存服务端的 JSON 字符串**，
  /// 解析交给 `Recipient.listFromJson`，这样坏数据不会污染库里其他行。
  final String recipientJson;
  final String ccJson;
  final String bccJson;

  /// 退信/失败原因（可能是 JSON 字符串也可能是纯文本）。
  final String? message;

  /// **0 = 未读，1 = 已读**（与字段名直觉相反）。
  final int unread;
  final int isStar;

  /// 服务端这一行**是否带了 `isStar`**。
  ///
  /// `/email/list` 会 join `star` 表给出 `isStar`，但 `/email/latest` 走的是
  /// `emailBriefColumns`，**没有这个字段**。分不清「缺失」和「值 0」的话，
  /// 轮询一次就会把用户标好的星标全抹掉。
  final bool starKnown;
  final int isDel;
  final String? content;

  /// 纯文本正文。**不叫 `text`** —— 那是 drift `Table` 上的列构造器方法名，
  /// 撞名会让整张表里所有 `text()` 调用都解析到本字段上。
  final String? bodyText;
  final String? inReplyTo;
  final String? relation;
  final String? messageId;
  final String? resendEmailId;
  final DateTime? createTime;

  /// 是否已拿到完整正文。false 表示这是摘要行，进详情页要先补拉 `full=1`。
  final bool hasFullBody;

  /// 本地写入时间（用于缓存淘汰与「同步中」判断）。
  final DateTime? cachedAt;
  const DbMail({
    required this.profileId,
    required this.emailId,
    required this.accountId,
    required this.mailboxEmail,
    required this.type,
    required this.status,
    required this.sendEmail,
    required this.name,
    required this.subject,
    required this.code,
    required this.toEmail,
    required this.toName,
    required this.recipientJson,
    required this.ccJson,
    required this.bccJson,
    this.message,
    required this.unread,
    required this.isStar,
    required this.starKnown,
    required this.isDel,
    this.content,
    this.bodyText,
    this.inReplyTo,
    this.relation,
    this.messageId,
    this.resendEmailId,
    this.createTime,
    required this.hasFullBody,
    this.cachedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['email_id'] = Variable<int>(emailId);
    map['account_id'] = Variable<int>(accountId);
    map['mailbox_email'] = Variable<String>(mailboxEmail);
    map['type'] = Variable<int>(type);
    map['status'] = Variable<int>(status);
    map['send_email'] = Variable<String>(sendEmail);
    map['name'] = Variable<String>(name);
    map['subject'] = Variable<String>(subject);
    map['code'] = Variable<String>(code);
    map['to_email'] = Variable<String>(toEmail);
    map['to_name'] = Variable<String>(toName);
    map['recipient_json'] = Variable<String>(recipientJson);
    map['cc_json'] = Variable<String>(ccJson);
    map['bcc_json'] = Variable<String>(bccJson);
    if (!nullToAbsent || message != null) {
      map['message'] = Variable<String>(message);
    }
    map['unread'] = Variable<int>(unread);
    map['is_star'] = Variable<int>(isStar);
    map['star_known'] = Variable<bool>(starKnown);
    map['is_del'] = Variable<int>(isDel);
    if (!nullToAbsent || content != null) {
      map['content'] = Variable<String>(content);
    }
    if (!nullToAbsent || bodyText != null) {
      map['body_text'] = Variable<String>(bodyText);
    }
    if (!nullToAbsent || inReplyTo != null) {
      map['in_reply_to'] = Variable<String>(inReplyTo);
    }
    if (!nullToAbsent || relation != null) {
      map['relation'] = Variable<String>(relation);
    }
    if (!nullToAbsent || messageId != null) {
      map['message_id'] = Variable<String>(messageId);
    }
    if (!nullToAbsent || resendEmailId != null) {
      map['resend_email_id'] = Variable<String>(resendEmailId);
    }
    if (!nullToAbsent || createTime != null) {
      map['create_time'] = Variable<DateTime>(createTime);
    }
    map['has_full_body'] = Variable<bool>(hasFullBody);
    if (!nullToAbsent || cachedAt != null) {
      map['cached_at'] = Variable<DateTime>(cachedAt);
    }
    return map;
  }

  MailsCompanion toCompanion(bool nullToAbsent) {
    return MailsCompanion(
      profileId: Value(profileId),
      emailId: Value(emailId),
      accountId: Value(accountId),
      mailboxEmail: Value(mailboxEmail),
      type: Value(type),
      status: Value(status),
      sendEmail: Value(sendEmail),
      name: Value(name),
      subject: Value(subject),
      code: Value(code),
      toEmail: Value(toEmail),
      toName: Value(toName),
      recipientJson: Value(recipientJson),
      ccJson: Value(ccJson),
      bccJson: Value(bccJson),
      message: message == null && nullToAbsent
          ? const Value.absent()
          : Value(message),
      unread: Value(unread),
      isStar: Value(isStar),
      starKnown: Value(starKnown),
      isDel: Value(isDel),
      content: content == null && nullToAbsent
          ? const Value.absent()
          : Value(content),
      bodyText: bodyText == null && nullToAbsent
          ? const Value.absent()
          : Value(bodyText),
      inReplyTo: inReplyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(inReplyTo),
      relation: relation == null && nullToAbsent
          ? const Value.absent()
          : Value(relation),
      messageId: messageId == null && nullToAbsent
          ? const Value.absent()
          : Value(messageId),
      resendEmailId: resendEmailId == null && nullToAbsent
          ? const Value.absent()
          : Value(resendEmailId),
      createTime: createTime == null && nullToAbsent
          ? const Value.absent()
          : Value(createTime),
      hasFullBody: Value(hasFullBody),
      cachedAt: cachedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(cachedAt),
    );
  }

  factory DbMail.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbMail(
      profileId: serializer.fromJson<String>(json['profileId']),
      emailId: serializer.fromJson<int>(json['emailId']),
      accountId: serializer.fromJson<int>(json['accountId']),
      mailboxEmail: serializer.fromJson<String>(json['mailboxEmail']),
      type: serializer.fromJson<int>(json['type']),
      status: serializer.fromJson<int>(json['status']),
      sendEmail: serializer.fromJson<String>(json['sendEmail']),
      name: serializer.fromJson<String>(json['name']),
      subject: serializer.fromJson<String>(json['subject']),
      code: serializer.fromJson<String>(json['code']),
      toEmail: serializer.fromJson<String>(json['toEmail']),
      toName: serializer.fromJson<String>(json['toName']),
      recipientJson: serializer.fromJson<String>(json['recipientJson']),
      ccJson: serializer.fromJson<String>(json['ccJson']),
      bccJson: serializer.fromJson<String>(json['bccJson']),
      message: serializer.fromJson<String?>(json['message']),
      unread: serializer.fromJson<int>(json['unread']),
      isStar: serializer.fromJson<int>(json['isStar']),
      starKnown: serializer.fromJson<bool>(json['starKnown']),
      isDel: serializer.fromJson<int>(json['isDel']),
      content: serializer.fromJson<String?>(json['content']),
      bodyText: serializer.fromJson<String?>(json['bodyText']),
      inReplyTo: serializer.fromJson<String?>(json['inReplyTo']),
      relation: serializer.fromJson<String?>(json['relation']),
      messageId: serializer.fromJson<String?>(json['messageId']),
      resendEmailId: serializer.fromJson<String?>(json['resendEmailId']),
      createTime: serializer.fromJson<DateTime?>(json['createTime']),
      hasFullBody: serializer.fromJson<bool>(json['hasFullBody']),
      cachedAt: serializer.fromJson<DateTime?>(json['cachedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'emailId': serializer.toJson<int>(emailId),
      'accountId': serializer.toJson<int>(accountId),
      'mailboxEmail': serializer.toJson<String>(mailboxEmail),
      'type': serializer.toJson<int>(type),
      'status': serializer.toJson<int>(status),
      'sendEmail': serializer.toJson<String>(sendEmail),
      'name': serializer.toJson<String>(name),
      'subject': serializer.toJson<String>(subject),
      'code': serializer.toJson<String>(code),
      'toEmail': serializer.toJson<String>(toEmail),
      'toName': serializer.toJson<String>(toName),
      'recipientJson': serializer.toJson<String>(recipientJson),
      'ccJson': serializer.toJson<String>(ccJson),
      'bccJson': serializer.toJson<String>(bccJson),
      'message': serializer.toJson<String?>(message),
      'unread': serializer.toJson<int>(unread),
      'isStar': serializer.toJson<int>(isStar),
      'starKnown': serializer.toJson<bool>(starKnown),
      'isDel': serializer.toJson<int>(isDel),
      'content': serializer.toJson<String?>(content),
      'bodyText': serializer.toJson<String?>(bodyText),
      'inReplyTo': serializer.toJson<String?>(inReplyTo),
      'relation': serializer.toJson<String?>(relation),
      'messageId': serializer.toJson<String?>(messageId),
      'resendEmailId': serializer.toJson<String?>(resendEmailId),
      'createTime': serializer.toJson<DateTime?>(createTime),
      'hasFullBody': serializer.toJson<bool>(hasFullBody),
      'cachedAt': serializer.toJson<DateTime?>(cachedAt),
    };
  }

  DbMail copyWith({
    String? profileId,
    int? emailId,
    int? accountId,
    String? mailboxEmail,
    int? type,
    int? status,
    String? sendEmail,
    String? name,
    String? subject,
    String? code,
    String? toEmail,
    String? toName,
    String? recipientJson,
    String? ccJson,
    String? bccJson,
    Value<String?> message = const Value.absent(),
    int? unread,
    int? isStar,
    bool? starKnown,
    int? isDel,
    Value<String?> content = const Value.absent(),
    Value<String?> bodyText = const Value.absent(),
    Value<String?> inReplyTo = const Value.absent(),
    Value<String?> relation = const Value.absent(),
    Value<String?> messageId = const Value.absent(),
    Value<String?> resendEmailId = const Value.absent(),
    Value<DateTime?> createTime = const Value.absent(),
    bool? hasFullBody,
    Value<DateTime?> cachedAt = const Value.absent(),
  }) => DbMail(
    profileId: profileId ?? this.profileId,
    emailId: emailId ?? this.emailId,
    accountId: accountId ?? this.accountId,
    mailboxEmail: mailboxEmail ?? this.mailboxEmail,
    type: type ?? this.type,
    status: status ?? this.status,
    sendEmail: sendEmail ?? this.sendEmail,
    name: name ?? this.name,
    subject: subject ?? this.subject,
    code: code ?? this.code,
    toEmail: toEmail ?? this.toEmail,
    toName: toName ?? this.toName,
    recipientJson: recipientJson ?? this.recipientJson,
    ccJson: ccJson ?? this.ccJson,
    bccJson: bccJson ?? this.bccJson,
    message: message.present ? message.value : this.message,
    unread: unread ?? this.unread,
    isStar: isStar ?? this.isStar,
    starKnown: starKnown ?? this.starKnown,
    isDel: isDel ?? this.isDel,
    content: content.present ? content.value : this.content,
    bodyText: bodyText.present ? bodyText.value : this.bodyText,
    inReplyTo: inReplyTo.present ? inReplyTo.value : this.inReplyTo,
    relation: relation.present ? relation.value : this.relation,
    messageId: messageId.present ? messageId.value : this.messageId,
    resendEmailId: resendEmailId.present
        ? resendEmailId.value
        : this.resendEmailId,
    createTime: createTime.present ? createTime.value : this.createTime,
    hasFullBody: hasFullBody ?? this.hasFullBody,
    cachedAt: cachedAt.present ? cachedAt.value : this.cachedAt,
  );
  DbMail copyWithCompanion(MailsCompanion data) {
    return DbMail(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      emailId: data.emailId.present ? data.emailId.value : this.emailId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      mailboxEmail: data.mailboxEmail.present
          ? data.mailboxEmail.value
          : this.mailboxEmail,
      type: data.type.present ? data.type.value : this.type,
      status: data.status.present ? data.status.value : this.status,
      sendEmail: data.sendEmail.present ? data.sendEmail.value : this.sendEmail,
      name: data.name.present ? data.name.value : this.name,
      subject: data.subject.present ? data.subject.value : this.subject,
      code: data.code.present ? data.code.value : this.code,
      toEmail: data.toEmail.present ? data.toEmail.value : this.toEmail,
      toName: data.toName.present ? data.toName.value : this.toName,
      recipientJson: data.recipientJson.present
          ? data.recipientJson.value
          : this.recipientJson,
      ccJson: data.ccJson.present ? data.ccJson.value : this.ccJson,
      bccJson: data.bccJson.present ? data.bccJson.value : this.bccJson,
      message: data.message.present ? data.message.value : this.message,
      unread: data.unread.present ? data.unread.value : this.unread,
      isStar: data.isStar.present ? data.isStar.value : this.isStar,
      starKnown: data.starKnown.present ? data.starKnown.value : this.starKnown,
      isDel: data.isDel.present ? data.isDel.value : this.isDel,
      content: data.content.present ? data.content.value : this.content,
      bodyText: data.bodyText.present ? data.bodyText.value : this.bodyText,
      inReplyTo: data.inReplyTo.present ? data.inReplyTo.value : this.inReplyTo,
      relation: data.relation.present ? data.relation.value : this.relation,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      resendEmailId: data.resendEmailId.present
          ? data.resendEmailId.value
          : this.resendEmailId,
      createTime: data.createTime.present
          ? data.createTime.value
          : this.createTime,
      hasFullBody: data.hasFullBody.present
          ? data.hasFullBody.value
          : this.hasFullBody,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbMail(')
          ..write('profileId: $profileId, ')
          ..write('emailId: $emailId, ')
          ..write('accountId: $accountId, ')
          ..write('mailboxEmail: $mailboxEmail, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('sendEmail: $sendEmail, ')
          ..write('name: $name, ')
          ..write('subject: $subject, ')
          ..write('code: $code, ')
          ..write('toEmail: $toEmail, ')
          ..write('toName: $toName, ')
          ..write('recipientJson: $recipientJson, ')
          ..write('ccJson: $ccJson, ')
          ..write('bccJson: $bccJson, ')
          ..write('message: $message, ')
          ..write('unread: $unread, ')
          ..write('isStar: $isStar, ')
          ..write('starKnown: $starKnown, ')
          ..write('isDel: $isDel, ')
          ..write('content: $content, ')
          ..write('bodyText: $bodyText, ')
          ..write('inReplyTo: $inReplyTo, ')
          ..write('relation: $relation, ')
          ..write('messageId: $messageId, ')
          ..write('resendEmailId: $resendEmailId, ')
          ..write('createTime: $createTime, ')
          ..write('hasFullBody: $hasFullBody, ')
          ..write('cachedAt: $cachedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    profileId,
    emailId,
    accountId,
    mailboxEmail,
    type,
    status,
    sendEmail,
    name,
    subject,
    code,
    toEmail,
    toName,
    recipientJson,
    ccJson,
    bccJson,
    message,
    unread,
    isStar,
    starKnown,
    isDel,
    content,
    bodyText,
    inReplyTo,
    relation,
    messageId,
    resendEmailId,
    createTime,
    hasFullBody,
    cachedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbMail &&
          other.profileId == this.profileId &&
          other.emailId == this.emailId &&
          other.accountId == this.accountId &&
          other.mailboxEmail == this.mailboxEmail &&
          other.type == this.type &&
          other.status == this.status &&
          other.sendEmail == this.sendEmail &&
          other.name == this.name &&
          other.subject == this.subject &&
          other.code == this.code &&
          other.toEmail == this.toEmail &&
          other.toName == this.toName &&
          other.recipientJson == this.recipientJson &&
          other.ccJson == this.ccJson &&
          other.bccJson == this.bccJson &&
          other.message == this.message &&
          other.unread == this.unread &&
          other.isStar == this.isStar &&
          other.starKnown == this.starKnown &&
          other.isDel == this.isDel &&
          other.content == this.content &&
          other.bodyText == this.bodyText &&
          other.inReplyTo == this.inReplyTo &&
          other.relation == this.relation &&
          other.messageId == this.messageId &&
          other.resendEmailId == this.resendEmailId &&
          other.createTime == this.createTime &&
          other.hasFullBody == this.hasFullBody &&
          other.cachedAt == this.cachedAt);
}

class MailsCompanion extends UpdateCompanion<DbMail> {
  final Value<String> profileId;
  final Value<int> emailId;
  final Value<int> accountId;
  final Value<String> mailboxEmail;
  final Value<int> type;
  final Value<int> status;
  final Value<String> sendEmail;
  final Value<String> name;
  final Value<String> subject;
  final Value<String> code;
  final Value<String> toEmail;
  final Value<String> toName;
  final Value<String> recipientJson;
  final Value<String> ccJson;
  final Value<String> bccJson;
  final Value<String?> message;
  final Value<int> unread;
  final Value<int> isStar;
  final Value<bool> starKnown;
  final Value<int> isDel;
  final Value<String?> content;
  final Value<String?> bodyText;
  final Value<String?> inReplyTo;
  final Value<String?> relation;
  final Value<String?> messageId;
  final Value<String?> resendEmailId;
  final Value<DateTime?> createTime;
  final Value<bool> hasFullBody;
  final Value<DateTime?> cachedAt;
  final Value<int> rowid;
  const MailsCompanion({
    this.profileId = const Value.absent(),
    this.emailId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.mailboxEmail = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.sendEmail = const Value.absent(),
    this.name = const Value.absent(),
    this.subject = const Value.absent(),
    this.code = const Value.absent(),
    this.toEmail = const Value.absent(),
    this.toName = const Value.absent(),
    this.recipientJson = const Value.absent(),
    this.ccJson = const Value.absent(),
    this.bccJson = const Value.absent(),
    this.message = const Value.absent(),
    this.unread = const Value.absent(),
    this.isStar = const Value.absent(),
    this.starKnown = const Value.absent(),
    this.isDel = const Value.absent(),
    this.content = const Value.absent(),
    this.bodyText = const Value.absent(),
    this.inReplyTo = const Value.absent(),
    this.relation = const Value.absent(),
    this.messageId = const Value.absent(),
    this.resendEmailId = const Value.absent(),
    this.createTime = const Value.absent(),
    this.hasFullBody = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MailsCompanion.insert({
    required String profileId,
    required int emailId,
    this.accountId = const Value.absent(),
    this.mailboxEmail = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.sendEmail = const Value.absent(),
    this.name = const Value.absent(),
    this.subject = const Value.absent(),
    this.code = const Value.absent(),
    this.toEmail = const Value.absent(),
    this.toName = const Value.absent(),
    this.recipientJson = const Value.absent(),
    this.ccJson = const Value.absent(),
    this.bccJson = const Value.absent(),
    this.message = const Value.absent(),
    this.unread = const Value.absent(),
    this.isStar = const Value.absent(),
    this.starKnown = const Value.absent(),
    this.isDel = const Value.absent(),
    this.content = const Value.absent(),
    this.bodyText = const Value.absent(),
    this.inReplyTo = const Value.absent(),
    this.relation = const Value.absent(),
    this.messageId = const Value.absent(),
    this.resendEmailId = const Value.absent(),
    this.createTime = const Value.absent(),
    this.hasFullBody = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       emailId = Value(emailId);
  static Insertable<DbMail> custom({
    Expression<String>? profileId,
    Expression<int>? emailId,
    Expression<int>? accountId,
    Expression<String>? mailboxEmail,
    Expression<int>? type,
    Expression<int>? status,
    Expression<String>? sendEmail,
    Expression<String>? name,
    Expression<String>? subject,
    Expression<String>? code,
    Expression<String>? toEmail,
    Expression<String>? toName,
    Expression<String>? recipientJson,
    Expression<String>? ccJson,
    Expression<String>? bccJson,
    Expression<String>? message,
    Expression<int>? unread,
    Expression<int>? isStar,
    Expression<bool>? starKnown,
    Expression<int>? isDel,
    Expression<String>? content,
    Expression<String>? bodyText,
    Expression<String>? inReplyTo,
    Expression<String>? relation,
    Expression<String>? messageId,
    Expression<String>? resendEmailId,
    Expression<DateTime>? createTime,
    Expression<bool>? hasFullBody,
    Expression<DateTime>? cachedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (emailId != null) 'email_id': emailId,
      if (accountId != null) 'account_id': accountId,
      if (mailboxEmail != null) 'mailbox_email': mailboxEmail,
      if (type != null) 'type': type,
      if (status != null) 'status': status,
      if (sendEmail != null) 'send_email': sendEmail,
      if (name != null) 'name': name,
      if (subject != null) 'subject': subject,
      if (code != null) 'code': code,
      if (toEmail != null) 'to_email': toEmail,
      if (toName != null) 'to_name': toName,
      if (recipientJson != null) 'recipient_json': recipientJson,
      if (ccJson != null) 'cc_json': ccJson,
      if (bccJson != null) 'bcc_json': bccJson,
      if (message != null) 'message': message,
      if (unread != null) 'unread': unread,
      if (isStar != null) 'is_star': isStar,
      if (starKnown != null) 'star_known': starKnown,
      if (isDel != null) 'is_del': isDel,
      if (content != null) 'content': content,
      if (bodyText != null) 'body_text': bodyText,
      if (inReplyTo != null) 'in_reply_to': inReplyTo,
      if (relation != null) 'relation': relation,
      if (messageId != null) 'message_id': messageId,
      if (resendEmailId != null) 'resend_email_id': resendEmailId,
      if (createTime != null) 'create_time': createTime,
      if (hasFullBody != null) 'has_full_body': hasFullBody,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MailsCompanion copyWith({
    Value<String>? profileId,
    Value<int>? emailId,
    Value<int>? accountId,
    Value<String>? mailboxEmail,
    Value<int>? type,
    Value<int>? status,
    Value<String>? sendEmail,
    Value<String>? name,
    Value<String>? subject,
    Value<String>? code,
    Value<String>? toEmail,
    Value<String>? toName,
    Value<String>? recipientJson,
    Value<String>? ccJson,
    Value<String>? bccJson,
    Value<String?>? message,
    Value<int>? unread,
    Value<int>? isStar,
    Value<bool>? starKnown,
    Value<int>? isDel,
    Value<String?>? content,
    Value<String?>? bodyText,
    Value<String?>? inReplyTo,
    Value<String?>? relation,
    Value<String?>? messageId,
    Value<String?>? resendEmailId,
    Value<DateTime?>? createTime,
    Value<bool>? hasFullBody,
    Value<DateTime?>? cachedAt,
    Value<int>? rowid,
  }) {
    return MailsCompanion(
      profileId: profileId ?? this.profileId,
      emailId: emailId ?? this.emailId,
      accountId: accountId ?? this.accountId,
      mailboxEmail: mailboxEmail ?? this.mailboxEmail,
      type: type ?? this.type,
      status: status ?? this.status,
      sendEmail: sendEmail ?? this.sendEmail,
      name: name ?? this.name,
      subject: subject ?? this.subject,
      code: code ?? this.code,
      toEmail: toEmail ?? this.toEmail,
      toName: toName ?? this.toName,
      recipientJson: recipientJson ?? this.recipientJson,
      ccJson: ccJson ?? this.ccJson,
      bccJson: bccJson ?? this.bccJson,
      message: message ?? this.message,
      unread: unread ?? this.unread,
      isStar: isStar ?? this.isStar,
      starKnown: starKnown ?? this.starKnown,
      isDel: isDel ?? this.isDel,
      content: content ?? this.content,
      bodyText: bodyText ?? this.bodyText,
      inReplyTo: inReplyTo ?? this.inReplyTo,
      relation: relation ?? this.relation,
      messageId: messageId ?? this.messageId,
      resendEmailId: resendEmailId ?? this.resendEmailId,
      createTime: createTime ?? this.createTime,
      hasFullBody: hasFullBody ?? this.hasFullBody,
      cachedAt: cachedAt ?? this.cachedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (emailId.present) {
      map['email_id'] = Variable<int>(emailId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (mailboxEmail.present) {
      map['mailbox_email'] = Variable<String>(mailboxEmail.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (sendEmail.present) {
      map['send_email'] = Variable<String>(sendEmail.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (toEmail.present) {
      map['to_email'] = Variable<String>(toEmail.value);
    }
    if (toName.present) {
      map['to_name'] = Variable<String>(toName.value);
    }
    if (recipientJson.present) {
      map['recipient_json'] = Variable<String>(recipientJson.value);
    }
    if (ccJson.present) {
      map['cc_json'] = Variable<String>(ccJson.value);
    }
    if (bccJson.present) {
      map['bcc_json'] = Variable<String>(bccJson.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (unread.present) {
      map['unread'] = Variable<int>(unread.value);
    }
    if (isStar.present) {
      map['is_star'] = Variable<int>(isStar.value);
    }
    if (starKnown.present) {
      map['star_known'] = Variable<bool>(starKnown.value);
    }
    if (isDel.present) {
      map['is_del'] = Variable<int>(isDel.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (bodyText.present) {
      map['body_text'] = Variable<String>(bodyText.value);
    }
    if (inReplyTo.present) {
      map['in_reply_to'] = Variable<String>(inReplyTo.value);
    }
    if (relation.present) {
      map['relation'] = Variable<String>(relation.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (resendEmailId.present) {
      map['resend_email_id'] = Variable<String>(resendEmailId.value);
    }
    if (createTime.present) {
      map['create_time'] = Variable<DateTime>(createTime.value);
    }
    if (hasFullBody.present) {
      map['has_full_body'] = Variable<bool>(hasFullBody.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<DateTime>(cachedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MailsCompanion(')
          ..write('profileId: $profileId, ')
          ..write('emailId: $emailId, ')
          ..write('accountId: $accountId, ')
          ..write('mailboxEmail: $mailboxEmail, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('sendEmail: $sendEmail, ')
          ..write('name: $name, ')
          ..write('subject: $subject, ')
          ..write('code: $code, ')
          ..write('toEmail: $toEmail, ')
          ..write('toName: $toName, ')
          ..write('recipientJson: $recipientJson, ')
          ..write('ccJson: $ccJson, ')
          ..write('bccJson: $bccJson, ')
          ..write('message: $message, ')
          ..write('unread: $unread, ')
          ..write('isStar: $isStar, ')
          ..write('starKnown: $starKnown, ')
          ..write('isDel: $isDel, ')
          ..write('content: $content, ')
          ..write('bodyText: $bodyText, ')
          ..write('inReplyTo: $inReplyTo, ')
          ..write('relation: $relation, ')
          ..write('messageId: $messageId, ')
          ..write('resendEmailId: $resendEmailId, ')
          ..write('createTime: $createTime, ')
          ..write('hasFullBody: $hasFullBody, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttachmentsTable extends Attachments
    with TableInfo<$AttachmentsTable, DbAttachment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attIdMeta = const VerificationMeta('attId');
  @override
  late final GeneratedColumn<int> attId = GeneratedColumn<int>(
    'att_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emailIdMeta = const VerificationMeta(
    'emailId',
  );
  @override
  late final GeneratedColumn<int> emailId = GeneratedColumn<int>(
    'email_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _filenameMeta = const VerificationMeta(
    'filename',
  );
  @override
  late final GeneratedColumn<String> filename = GeneratedColumn<String>(
    'filename',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _mimeTypeMeta = const VerificationMeta(
    'mimeType',
  );
  @override
  late final GeneratedColumn<String> mimeType = GeneratedColumn<String>(
    'mime_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _contentIdMeta = const VerificationMeta(
    'contentId',
  );
  @override
  late final GeneratedColumn<String> contentId = GeneratedColumn<String>(
    'content_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _downloadedAtMeta = const VerificationMeta(
    'downloadedAt',
  );
  @override
  late final GeneratedColumn<DateTime> downloadedAt = GeneratedColumn<DateTime>(
    'downloaded_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    attId,
    emailId,
    key,
    filename,
    mimeType,
    size,
    type,
    contentId,
    localPath,
    downloadedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attachments';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbAttachment> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('att_id')) {
      context.handle(
        _attIdMeta,
        attId.isAcceptableOrUnknown(data['att_id']!, _attIdMeta),
      );
    } else if (isInserting) {
      context.missing(_attIdMeta);
    }
    if (data.containsKey('email_id')) {
      context.handle(
        _emailIdMeta,
        emailId.isAcceptableOrUnknown(data['email_id']!, _emailIdMeta),
      );
    }
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    }
    if (data.containsKey('filename')) {
      context.handle(
        _filenameMeta,
        filename.isAcceptableOrUnknown(data['filename']!, _filenameMeta),
      );
    }
    if (data.containsKey('mime_type')) {
      context.handle(
        _mimeTypeMeta,
        mimeType.isAcceptableOrUnknown(data['mime_type']!, _mimeTypeMeta),
      );
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('content_id')) {
      context.handle(
        _contentIdMeta,
        contentId.isAcceptableOrUnknown(data['content_id']!, _contentIdMeta),
      );
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('downloaded_at')) {
      context.handle(
        _downloadedAtMeta,
        downloadedAt.isAcceptableOrUnknown(
          data['downloaded_at']!,
          _downloadedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, attId};
  @override
  DbAttachment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbAttachment(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      attId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}att_id'],
      )!,
      emailId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}email_id'],
      )!,
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      filename: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}filename'],
      )!,
      mimeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime_type'],
      ),
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      contentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_id'],
      ),
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      downloadedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}downloaded_at'],
      ),
    );
  }

  @override
  $AttachmentsTable createAlias(String alias) {
    return $AttachmentsTable(attachedDatabase, alias);
  }
}

class DbAttachment extends DataClass implements Insertable<DbAttachment> {
  final String profileId;
  final int attId;
  final int emailId;
  final String key;
  final String filename;
  final String? mimeType;
  final int size;
  final int type;
  final String? contentId;

  /// 本地已下载路径（绝对路径）。未下载为 null。
  final String? localPath;
  final DateTime? downloadedAt;
  const DbAttachment({
    required this.profileId,
    required this.attId,
    required this.emailId,
    required this.key,
    required this.filename,
    this.mimeType,
    required this.size,
    required this.type,
    this.contentId,
    this.localPath,
    this.downloadedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['att_id'] = Variable<int>(attId);
    map['email_id'] = Variable<int>(emailId);
    map['key'] = Variable<String>(key);
    map['filename'] = Variable<String>(filename);
    if (!nullToAbsent || mimeType != null) {
      map['mime_type'] = Variable<String>(mimeType);
    }
    map['size'] = Variable<int>(size);
    map['type'] = Variable<int>(type);
    if (!nullToAbsent || contentId != null) {
      map['content_id'] = Variable<String>(contentId);
    }
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    if (!nullToAbsent || downloadedAt != null) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt);
    }
    return map;
  }

  AttachmentsCompanion toCompanion(bool nullToAbsent) {
    return AttachmentsCompanion(
      profileId: Value(profileId),
      attId: Value(attId),
      emailId: Value(emailId),
      key: Value(key),
      filename: Value(filename),
      mimeType: mimeType == null && nullToAbsent
          ? const Value.absent()
          : Value(mimeType),
      size: Value(size),
      type: Value(type),
      contentId: contentId == null && nullToAbsent
          ? const Value.absent()
          : Value(contentId),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      downloadedAt: downloadedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(downloadedAt),
    );
  }

  factory DbAttachment.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbAttachment(
      profileId: serializer.fromJson<String>(json['profileId']),
      attId: serializer.fromJson<int>(json['attId']),
      emailId: serializer.fromJson<int>(json['emailId']),
      key: serializer.fromJson<String>(json['key']),
      filename: serializer.fromJson<String>(json['filename']),
      mimeType: serializer.fromJson<String?>(json['mimeType']),
      size: serializer.fromJson<int>(json['size']),
      type: serializer.fromJson<int>(json['type']),
      contentId: serializer.fromJson<String?>(json['contentId']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      downloadedAt: serializer.fromJson<DateTime?>(json['downloadedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'attId': serializer.toJson<int>(attId),
      'emailId': serializer.toJson<int>(emailId),
      'key': serializer.toJson<String>(key),
      'filename': serializer.toJson<String>(filename),
      'mimeType': serializer.toJson<String?>(mimeType),
      'size': serializer.toJson<int>(size),
      'type': serializer.toJson<int>(type),
      'contentId': serializer.toJson<String?>(contentId),
      'localPath': serializer.toJson<String?>(localPath),
      'downloadedAt': serializer.toJson<DateTime?>(downloadedAt),
    };
  }

  DbAttachment copyWith({
    String? profileId,
    int? attId,
    int? emailId,
    String? key,
    String? filename,
    Value<String?> mimeType = const Value.absent(),
    int? size,
    int? type,
    Value<String?> contentId = const Value.absent(),
    Value<String?> localPath = const Value.absent(),
    Value<DateTime?> downloadedAt = const Value.absent(),
  }) => DbAttachment(
    profileId: profileId ?? this.profileId,
    attId: attId ?? this.attId,
    emailId: emailId ?? this.emailId,
    key: key ?? this.key,
    filename: filename ?? this.filename,
    mimeType: mimeType.present ? mimeType.value : this.mimeType,
    size: size ?? this.size,
    type: type ?? this.type,
    contentId: contentId.present ? contentId.value : this.contentId,
    localPath: localPath.present ? localPath.value : this.localPath,
    downloadedAt: downloadedAt.present ? downloadedAt.value : this.downloadedAt,
  );
  DbAttachment copyWithCompanion(AttachmentsCompanion data) {
    return DbAttachment(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      attId: data.attId.present ? data.attId.value : this.attId,
      emailId: data.emailId.present ? data.emailId.value : this.emailId,
      key: data.key.present ? data.key.value : this.key,
      filename: data.filename.present ? data.filename.value : this.filename,
      mimeType: data.mimeType.present ? data.mimeType.value : this.mimeType,
      size: data.size.present ? data.size.value : this.size,
      type: data.type.present ? data.type.value : this.type,
      contentId: data.contentId.present ? data.contentId.value : this.contentId,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      downloadedAt: data.downloadedAt.present
          ? data.downloadedAt.value
          : this.downloadedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbAttachment(')
          ..write('profileId: $profileId, ')
          ..write('attId: $attId, ')
          ..write('emailId: $emailId, ')
          ..write('key: $key, ')
          ..write('filename: $filename, ')
          ..write('mimeType: $mimeType, ')
          ..write('size: $size, ')
          ..write('type: $type, ')
          ..write('contentId: $contentId, ')
          ..write('localPath: $localPath, ')
          ..write('downloadedAt: $downloadedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    profileId,
    attId,
    emailId,
    key,
    filename,
    mimeType,
    size,
    type,
    contentId,
    localPath,
    downloadedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbAttachment &&
          other.profileId == this.profileId &&
          other.attId == this.attId &&
          other.emailId == this.emailId &&
          other.key == this.key &&
          other.filename == this.filename &&
          other.mimeType == this.mimeType &&
          other.size == this.size &&
          other.type == this.type &&
          other.contentId == this.contentId &&
          other.localPath == this.localPath &&
          other.downloadedAt == this.downloadedAt);
}

class AttachmentsCompanion extends UpdateCompanion<DbAttachment> {
  final Value<String> profileId;
  final Value<int> attId;
  final Value<int> emailId;
  final Value<String> key;
  final Value<String> filename;
  final Value<String?> mimeType;
  final Value<int> size;
  final Value<int> type;
  final Value<String?> contentId;
  final Value<String?> localPath;
  final Value<DateTime?> downloadedAt;
  final Value<int> rowid;
  const AttachmentsCompanion({
    this.profileId = const Value.absent(),
    this.attId = const Value.absent(),
    this.emailId = const Value.absent(),
    this.key = const Value.absent(),
    this.filename = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.size = const Value.absent(),
    this.type = const Value.absent(),
    this.contentId = const Value.absent(),
    this.localPath = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttachmentsCompanion.insert({
    required String profileId,
    required int attId,
    this.emailId = const Value.absent(),
    this.key = const Value.absent(),
    this.filename = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.size = const Value.absent(),
    this.type = const Value.absent(),
    this.contentId = const Value.absent(),
    this.localPath = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       attId = Value(attId);
  static Insertable<DbAttachment> custom({
    Expression<String>? profileId,
    Expression<int>? attId,
    Expression<int>? emailId,
    Expression<String>? key,
    Expression<String>? filename,
    Expression<String>? mimeType,
    Expression<int>? size,
    Expression<int>? type,
    Expression<String>? contentId,
    Expression<String>? localPath,
    Expression<DateTime>? downloadedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (attId != null) 'att_id': attId,
      if (emailId != null) 'email_id': emailId,
      if (key != null) 'key': key,
      if (filename != null) 'filename': filename,
      if (mimeType != null) 'mime_type': mimeType,
      if (size != null) 'size': size,
      if (type != null) 'type': type,
      if (contentId != null) 'content_id': contentId,
      if (localPath != null) 'local_path': localPath,
      if (downloadedAt != null) 'downloaded_at': downloadedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttachmentsCompanion copyWith({
    Value<String>? profileId,
    Value<int>? attId,
    Value<int>? emailId,
    Value<String>? key,
    Value<String>? filename,
    Value<String?>? mimeType,
    Value<int>? size,
    Value<int>? type,
    Value<String?>? contentId,
    Value<String?>? localPath,
    Value<DateTime?>? downloadedAt,
    Value<int>? rowid,
  }) {
    return AttachmentsCompanion(
      profileId: profileId ?? this.profileId,
      attId: attId ?? this.attId,
      emailId: emailId ?? this.emailId,
      key: key ?? this.key,
      filename: filename ?? this.filename,
      mimeType: mimeType ?? this.mimeType,
      size: size ?? this.size,
      type: type ?? this.type,
      contentId: contentId ?? this.contentId,
      localPath: localPath ?? this.localPath,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (attId.present) {
      map['att_id'] = Variable<int>(attId.value);
    }
    if (emailId.present) {
      map['email_id'] = Variable<int>(emailId.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (filename.present) {
      map['filename'] = Variable<String>(filename.value);
    }
    if (mimeType.present) {
      map['mime_type'] = Variable<String>(mimeType.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (contentId.present) {
      map['content_id'] = Variable<String>(contentId.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (downloadedAt.present) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentsCompanion(')
          ..write('profileId: $profileId, ')
          ..write('attId: $attId, ')
          ..write('emailId: $emailId, ')
          ..write('key: $key, ')
          ..write('filename: $filename, ')
          ..write('mimeType: $mimeType, ')
          ..write('size: $size, ')
          ..write('type: $type, ')
          ..write('contentId: $contentId, ')
          ..write('localPath: $localPath, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStatesTable extends SyncStates
    with TableInfo<$SyncStatesTable, DbSyncState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  @override
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
    'scope',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorEmailIdMeta = const VerificationMeta(
    'cursorEmailId',
  );
  @override
  late final GeneratedColumn<int> cursorEmailId = GeneratedColumn<int>(
    'cursor_email_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _oldestEmailIdMeta = const VerificationMeta(
    'oldestEmailId',
  );
  @override
  late final GeneratedColumn<int> oldestEmailId = GeneratedColumn<int>(
    'oldest_email_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _remoteTotalMeta = const VerificationMeta(
    'remoteTotal',
  );
  @override
  late final GeneratedColumn<int> remoteTotal = GeneratedColumn<int>(
    'remote_total',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _remoteTotalAtMeta = const VerificationMeta(
    'remoteTotalAt',
  );
  @override
  late final GeneratedColumn<DateTime> remoteTotalAt =
      GeneratedColumn<DateTime>(
        'remote_total_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _backfillDoneMeta = const VerificationMeta(
    'backfillDone',
  );
  @override
  late final GeneratedColumn<bool> backfillDone = GeneratedColumn<bool>(
    'backfill_done',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("backfill_done" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lastSyncAtMeta = const VerificationMeta(
    'lastSyncAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastSyncAt = GeneratedColumn<DateTime>(
    'last_sync_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _failCountMeta = const VerificationMeta(
    'failCount',
  );
  @override
  late final GeneratedColumn<int> failCount = GeneratedColumn<int>(
    'fail_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    scope,
    cursorEmailId,
    oldestEmailId,
    remoteTotal,
    remoteTotalAt,
    backfillDone,
    lastSyncAt,
    failCount,
    lastError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbSyncState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('scope')) {
      context.handle(
        _scopeMeta,
        scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeMeta);
    }
    if (data.containsKey('cursor_email_id')) {
      context.handle(
        _cursorEmailIdMeta,
        cursorEmailId.isAcceptableOrUnknown(
          data['cursor_email_id']!,
          _cursorEmailIdMeta,
        ),
      );
    }
    if (data.containsKey('oldest_email_id')) {
      context.handle(
        _oldestEmailIdMeta,
        oldestEmailId.isAcceptableOrUnknown(
          data['oldest_email_id']!,
          _oldestEmailIdMeta,
        ),
      );
    }
    if (data.containsKey('remote_total')) {
      context.handle(
        _remoteTotalMeta,
        remoteTotal.isAcceptableOrUnknown(
          data['remote_total']!,
          _remoteTotalMeta,
        ),
      );
    }
    if (data.containsKey('remote_total_at')) {
      context.handle(
        _remoteTotalAtMeta,
        remoteTotalAt.isAcceptableOrUnknown(
          data['remote_total_at']!,
          _remoteTotalAtMeta,
        ),
      );
    }
    if (data.containsKey('backfill_done')) {
      context.handle(
        _backfillDoneMeta,
        backfillDone.isAcceptableOrUnknown(
          data['backfill_done']!,
          _backfillDoneMeta,
        ),
      );
    }
    if (data.containsKey('last_sync_at')) {
      context.handle(
        _lastSyncAtMeta,
        lastSyncAt.isAcceptableOrUnknown(
          data['last_sync_at']!,
          _lastSyncAtMeta,
        ),
      );
    }
    if (data.containsKey('fail_count')) {
      context.handle(
        _failCountMeta,
        failCount.isAcceptableOrUnknown(data['fail_count']!, _failCountMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, scope};
  @override
  DbSyncState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbSyncState(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      scope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope'],
      )!,
      cursorEmailId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cursor_email_id'],
      )!,
      oldestEmailId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}oldest_email_id'],
      )!,
      remoteTotal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}remote_total'],
      )!,
      remoteTotalAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}remote_total_at'],
      ),
      backfillDone: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}backfill_done'],
      )!,
      lastSyncAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_sync_at'],
      ),
      failCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}fail_count'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
    );
  }

  @override
  $SyncStatesTable createAlias(String alias) {
    return $SyncStatesTable(attachedDatabase, alias);
  }
}

class DbSyncState extends DataClass implements Insertable<DbSyncState> {
  final String profileId;
  final String scope;

  /// 增量游标：已知的最大 `emailId`。
  final int cursorEmailId;

  /// 已加载到的最小 `emailId`（往上翻页的游标）。
  final int oldestEmailId;

  /// 服务端在这个 scope 下的**精确总数**（`/email/list` 的 `total`）。
  ///
  /// 它是「还有几封没同步」的减数：`total - 本地条数`。服务端的 count 口径
  /// （`userId + type + accountId/allReceive + isDel=NORMAL`）与 [scope] 一一对应，
  /// 所以放在这一行而不是新开一张表。
  ///
  /// **0 表示「还不知道」** —— 只有不带游标的那次 list（冷启动基线 / 翻页）才拿得到
  /// `total`，`/email/latest` 与 `/star/list` 的响应里没有它。用它做减法前先判 0。
  final int remoteTotal;

  /// 上一次拿到 [remoteTotal] 的时刻。null = **还没探过**。
  ///
  /// 为什么「已知」不能只看 [remoteTotal]：那一列的 0 表示「还不知道」，
  /// 于是「真的是个空邮箱」与「还没探过」会撞在同一个值上 —— 表现是空邮箱
  /// 永远显示占位符，而且「要不要探」只能写成 `remoteTotal <= 0`，于是
  /// **每次展开都重探它**，TTL 也没有载体（`lastSyncAt` 是同步引擎的语义，
  /// 不能借）。有了这一列三态才分得开：
  /// `null` = 未知（显示占位符、需要探）；非 null = [remoteTotal] 就是真值
  /// （**0 也是真值**）；TTL = `now - remoteTotalAt`。
  final DateTime? remoteTotalAt;

  /// 更旧的方向是否已经翻到底（`loadOlder` 返回 false 时置位）。
  ///
  /// 落库的理由：这个结论只活在 `MailListController._hasMore` 那个内存字段里的话，
  /// 每次冷启动都会白白多发一次「拉到底才发现没有」的请求。
  final bool backfillDone;
  final DateTime? lastSyncAt;

  /// 连续失败次数（成功后清零）。调度器用它指数退避。
  final int failCount;
  final String? lastError;
  const DbSyncState({
    required this.profileId,
    required this.scope,
    required this.cursorEmailId,
    required this.oldestEmailId,
    required this.remoteTotal,
    this.remoteTotalAt,
    required this.backfillDone,
    this.lastSyncAt,
    required this.failCount,
    this.lastError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['scope'] = Variable<String>(scope);
    map['cursor_email_id'] = Variable<int>(cursorEmailId);
    map['oldest_email_id'] = Variable<int>(oldestEmailId);
    map['remote_total'] = Variable<int>(remoteTotal);
    if (!nullToAbsent || remoteTotalAt != null) {
      map['remote_total_at'] = Variable<DateTime>(remoteTotalAt);
    }
    map['backfill_done'] = Variable<bool>(backfillDone);
    if (!nullToAbsent || lastSyncAt != null) {
      map['last_sync_at'] = Variable<DateTime>(lastSyncAt);
    }
    map['fail_count'] = Variable<int>(failCount);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    return map;
  }

  SyncStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncStatesCompanion(
      profileId: Value(profileId),
      scope: Value(scope),
      cursorEmailId: Value(cursorEmailId),
      oldestEmailId: Value(oldestEmailId),
      remoteTotal: Value(remoteTotal),
      remoteTotalAt: remoteTotalAt == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteTotalAt),
      backfillDone: Value(backfillDone),
      lastSyncAt: lastSyncAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncAt),
      failCount: Value(failCount),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
    );
  }

  factory DbSyncState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbSyncState(
      profileId: serializer.fromJson<String>(json['profileId']),
      scope: serializer.fromJson<String>(json['scope']),
      cursorEmailId: serializer.fromJson<int>(json['cursorEmailId']),
      oldestEmailId: serializer.fromJson<int>(json['oldestEmailId']),
      remoteTotal: serializer.fromJson<int>(json['remoteTotal']),
      remoteTotalAt: serializer.fromJson<DateTime?>(json['remoteTotalAt']),
      backfillDone: serializer.fromJson<bool>(json['backfillDone']),
      lastSyncAt: serializer.fromJson<DateTime?>(json['lastSyncAt']),
      failCount: serializer.fromJson<int>(json['failCount']),
      lastError: serializer.fromJson<String?>(json['lastError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'scope': serializer.toJson<String>(scope),
      'cursorEmailId': serializer.toJson<int>(cursorEmailId),
      'oldestEmailId': serializer.toJson<int>(oldestEmailId),
      'remoteTotal': serializer.toJson<int>(remoteTotal),
      'remoteTotalAt': serializer.toJson<DateTime?>(remoteTotalAt),
      'backfillDone': serializer.toJson<bool>(backfillDone),
      'lastSyncAt': serializer.toJson<DateTime?>(lastSyncAt),
      'failCount': serializer.toJson<int>(failCount),
      'lastError': serializer.toJson<String?>(lastError),
    };
  }

  DbSyncState copyWith({
    String? profileId,
    String? scope,
    int? cursorEmailId,
    int? oldestEmailId,
    int? remoteTotal,
    Value<DateTime?> remoteTotalAt = const Value.absent(),
    bool? backfillDone,
    Value<DateTime?> lastSyncAt = const Value.absent(),
    int? failCount,
    Value<String?> lastError = const Value.absent(),
  }) => DbSyncState(
    profileId: profileId ?? this.profileId,
    scope: scope ?? this.scope,
    cursorEmailId: cursorEmailId ?? this.cursorEmailId,
    oldestEmailId: oldestEmailId ?? this.oldestEmailId,
    remoteTotal: remoteTotal ?? this.remoteTotal,
    remoteTotalAt: remoteTotalAt.present
        ? remoteTotalAt.value
        : this.remoteTotalAt,
    backfillDone: backfillDone ?? this.backfillDone,
    lastSyncAt: lastSyncAt.present ? lastSyncAt.value : this.lastSyncAt,
    failCount: failCount ?? this.failCount,
    lastError: lastError.present ? lastError.value : this.lastError,
  );
  DbSyncState copyWithCompanion(SyncStatesCompanion data) {
    return DbSyncState(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      scope: data.scope.present ? data.scope.value : this.scope,
      cursorEmailId: data.cursorEmailId.present
          ? data.cursorEmailId.value
          : this.cursorEmailId,
      oldestEmailId: data.oldestEmailId.present
          ? data.oldestEmailId.value
          : this.oldestEmailId,
      remoteTotal: data.remoteTotal.present
          ? data.remoteTotal.value
          : this.remoteTotal,
      remoteTotalAt: data.remoteTotalAt.present
          ? data.remoteTotalAt.value
          : this.remoteTotalAt,
      backfillDone: data.backfillDone.present
          ? data.backfillDone.value
          : this.backfillDone,
      lastSyncAt: data.lastSyncAt.present
          ? data.lastSyncAt.value
          : this.lastSyncAt,
      failCount: data.failCount.present ? data.failCount.value : this.failCount,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbSyncState(')
          ..write('profileId: $profileId, ')
          ..write('scope: $scope, ')
          ..write('cursorEmailId: $cursorEmailId, ')
          ..write('oldestEmailId: $oldestEmailId, ')
          ..write('remoteTotal: $remoteTotal, ')
          ..write('remoteTotalAt: $remoteTotalAt, ')
          ..write('backfillDone: $backfillDone, ')
          ..write('lastSyncAt: $lastSyncAt, ')
          ..write('failCount: $failCount, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    profileId,
    scope,
    cursorEmailId,
    oldestEmailId,
    remoteTotal,
    remoteTotalAt,
    backfillDone,
    lastSyncAt,
    failCount,
    lastError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbSyncState &&
          other.profileId == this.profileId &&
          other.scope == this.scope &&
          other.cursorEmailId == this.cursorEmailId &&
          other.oldestEmailId == this.oldestEmailId &&
          other.remoteTotal == this.remoteTotal &&
          other.remoteTotalAt == this.remoteTotalAt &&
          other.backfillDone == this.backfillDone &&
          other.lastSyncAt == this.lastSyncAt &&
          other.failCount == this.failCount &&
          other.lastError == this.lastError);
}

class SyncStatesCompanion extends UpdateCompanion<DbSyncState> {
  final Value<String> profileId;
  final Value<String> scope;
  final Value<int> cursorEmailId;
  final Value<int> oldestEmailId;
  final Value<int> remoteTotal;
  final Value<DateTime?> remoteTotalAt;
  final Value<bool> backfillDone;
  final Value<DateTime?> lastSyncAt;
  final Value<int> failCount;
  final Value<String?> lastError;
  final Value<int> rowid;
  const SyncStatesCompanion({
    this.profileId = const Value.absent(),
    this.scope = const Value.absent(),
    this.cursorEmailId = const Value.absent(),
    this.oldestEmailId = const Value.absent(),
    this.remoteTotal = const Value.absent(),
    this.remoteTotalAt = const Value.absent(),
    this.backfillDone = const Value.absent(),
    this.lastSyncAt = const Value.absent(),
    this.failCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStatesCompanion.insert({
    required String profileId,
    required String scope,
    this.cursorEmailId = const Value.absent(),
    this.oldestEmailId = const Value.absent(),
    this.remoteTotal = const Value.absent(),
    this.remoteTotalAt = const Value.absent(),
    this.backfillDone = const Value.absent(),
    this.lastSyncAt = const Value.absent(),
    this.failCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       scope = Value(scope);
  static Insertable<DbSyncState> custom({
    Expression<String>? profileId,
    Expression<String>? scope,
    Expression<int>? cursorEmailId,
    Expression<int>? oldestEmailId,
    Expression<int>? remoteTotal,
    Expression<DateTime>? remoteTotalAt,
    Expression<bool>? backfillDone,
    Expression<DateTime>? lastSyncAt,
    Expression<int>? failCount,
    Expression<String>? lastError,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (scope != null) 'scope': scope,
      if (cursorEmailId != null) 'cursor_email_id': cursorEmailId,
      if (oldestEmailId != null) 'oldest_email_id': oldestEmailId,
      if (remoteTotal != null) 'remote_total': remoteTotal,
      if (remoteTotalAt != null) 'remote_total_at': remoteTotalAt,
      if (backfillDone != null) 'backfill_done': backfillDone,
      if (lastSyncAt != null) 'last_sync_at': lastSyncAt,
      if (failCount != null) 'fail_count': failCount,
      if (lastError != null) 'last_error': lastError,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStatesCompanion copyWith({
    Value<String>? profileId,
    Value<String>? scope,
    Value<int>? cursorEmailId,
    Value<int>? oldestEmailId,
    Value<int>? remoteTotal,
    Value<DateTime?>? remoteTotalAt,
    Value<bool>? backfillDone,
    Value<DateTime?>? lastSyncAt,
    Value<int>? failCount,
    Value<String?>? lastError,
    Value<int>? rowid,
  }) {
    return SyncStatesCompanion(
      profileId: profileId ?? this.profileId,
      scope: scope ?? this.scope,
      cursorEmailId: cursorEmailId ?? this.cursorEmailId,
      oldestEmailId: oldestEmailId ?? this.oldestEmailId,
      remoteTotal: remoteTotal ?? this.remoteTotal,
      remoteTotalAt: remoteTotalAt ?? this.remoteTotalAt,
      backfillDone: backfillDone ?? this.backfillDone,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      failCount: failCount ?? this.failCount,
      lastError: lastError ?? this.lastError,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (cursorEmailId.present) {
      map['cursor_email_id'] = Variable<int>(cursorEmailId.value);
    }
    if (oldestEmailId.present) {
      map['oldest_email_id'] = Variable<int>(oldestEmailId.value);
    }
    if (remoteTotal.present) {
      map['remote_total'] = Variable<int>(remoteTotal.value);
    }
    if (remoteTotalAt.present) {
      map['remote_total_at'] = Variable<DateTime>(remoteTotalAt.value);
    }
    if (backfillDone.present) {
      map['backfill_done'] = Variable<bool>(backfillDone.value);
    }
    if (lastSyncAt.present) {
      map['last_sync_at'] = Variable<DateTime>(lastSyncAt.value);
    }
    if (failCount.present) {
      map['fail_count'] = Variable<int>(failCount.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStatesCompanion(')
          ..write('profileId: $profileId, ')
          ..write('scope: $scope, ')
          ..write('cursorEmailId: $cursorEmailId, ')
          ..write('oldestEmailId: $oldestEmailId, ')
          ..write('remoteTotal: $remoteTotal, ')
          ..write('remoteTotalAt: $remoteTotalAt, ')
          ..write('backfillDone: $backfillDone, ')
          ..write('lastSyncAt: $lastSyncAt, ')
          ..write('failCount: $failCount, ')
          ..write('lastError: $lastError, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OutboxEntriesTable extends OutboxEntries
    with TableInfo<$OutboxEntriesTable, DbOutboxEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scheduledAtMeta = const VerificationMeta(
    'scheduledAt',
  );
  @override
  late final GeneratedColumn<DateTime> scheduledAt = GeneratedColumn<DateTime>(
    'scheduled_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastAttemptAtMeta = const VerificationMeta(
    'lastAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastAttemptAt =
      GeneratedColumn<DateTime>(
        'last_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileId,
    payloadJson,
    status,
    attempts,
    lastError,
    scheduledAt,
    createdAt,
    lastAttemptAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbOutboxEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('scheduled_at')) {
      context.handle(
        _scheduledAtMeta,
        scheduledAt.isAcceptableOrUnknown(
          data['scheduled_at']!,
          _scheduledAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_attempt_at')) {
      context.handle(
        _lastAttemptAtMeta,
        lastAttemptAt.isAcceptableOrUnknown(
          data['last_attempt_at']!,
          _lastAttemptAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbOutboxEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbOutboxEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      scheduledAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}scheduled_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      lastAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_attempt_at'],
      ),
    );
  }

  @override
  $OutboxEntriesTable createAlias(String alias) {
    return $OutboxEntriesTable(attachedDatabase, alias);
  }
}

class DbOutboxEntry extends DataClass implements Insertable<DbOutboxEntry> {
  final int id;
  final String profileId;

  /// 整封邮件（含附件**路径**，不含 base64 —— base64 发送时才流式读盘）。
  final String payloadJson;

  /// 待发送 / 发送中 / 已发送 / 永久失败。
  final String status;
  final int attempts;
  final String? lastError;

  /// 计划发送时间（UTC）。null = 随时可发。
  ///
  /// 这是「发送后一分钟内还能反悔」的唯一实现方式：`/email/send` **没有定时发送**，
  /// 所以延迟整个在客户端做 —— 到点之前这封信只是本地的一行记录，
  /// `LocalDao.nextDue` 挑不到它，一个字节都不会发出去。取消就是删掉这一行。
  final DateTime? scheduledAt;
  final DateTime createdAt;
  final DateTime? lastAttemptAt;
  const DbOutboxEntry({
    required this.id,
    required this.profileId,
    required this.payloadJson,
    required this.status,
    required this.attempts,
    this.lastError,
    this.scheduledAt,
    required this.createdAt,
    this.lastAttemptAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['profile_id'] = Variable<String>(profileId);
    map['payload_json'] = Variable<String>(payloadJson);
    map['status'] = Variable<String>(status);
    map['attempts'] = Variable<int>(attempts);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    if (!nullToAbsent || scheduledAt != null) {
      map['scheduled_at'] = Variable<DateTime>(scheduledAt);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || lastAttemptAt != null) {
      map['last_attempt_at'] = Variable<DateTime>(lastAttemptAt);
    }
    return map;
  }

  OutboxEntriesCompanion toCompanion(bool nullToAbsent) {
    return OutboxEntriesCompanion(
      id: Value(id),
      profileId: Value(profileId),
      payloadJson: Value(payloadJson),
      status: Value(status),
      attempts: Value(attempts),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      scheduledAt: scheduledAt == null && nullToAbsent
          ? const Value.absent()
          : Value(scheduledAt),
      createdAt: Value(createdAt),
      lastAttemptAt: lastAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastAttemptAt),
    );
  }

  factory DbOutboxEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbOutboxEntry(
      id: serializer.fromJson<int>(json['id']),
      profileId: serializer.fromJson<String>(json['profileId']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      status: serializer.fromJson<String>(json['status']),
      attempts: serializer.fromJson<int>(json['attempts']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      scheduledAt: serializer.fromJson<DateTime?>(json['scheduledAt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      lastAttemptAt: serializer.fromJson<DateTime?>(json['lastAttemptAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileId': serializer.toJson<String>(profileId),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'status': serializer.toJson<String>(status),
      'attempts': serializer.toJson<int>(attempts),
      'lastError': serializer.toJson<String?>(lastError),
      'scheduledAt': serializer.toJson<DateTime?>(scheduledAt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'lastAttemptAt': serializer.toJson<DateTime?>(lastAttemptAt),
    };
  }

  DbOutboxEntry copyWith({
    int? id,
    String? profileId,
    String? payloadJson,
    String? status,
    int? attempts,
    Value<String?> lastError = const Value.absent(),
    Value<DateTime?> scheduledAt = const Value.absent(),
    DateTime? createdAt,
    Value<DateTime?> lastAttemptAt = const Value.absent(),
  }) => DbOutboxEntry(
    id: id ?? this.id,
    profileId: profileId ?? this.profileId,
    payloadJson: payloadJson ?? this.payloadJson,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    lastError: lastError.present ? lastError.value : this.lastError,
    scheduledAt: scheduledAt.present ? scheduledAt.value : this.scheduledAt,
    createdAt: createdAt ?? this.createdAt,
    lastAttemptAt: lastAttemptAt.present
        ? lastAttemptAt.value
        : this.lastAttemptAt,
  );
  DbOutboxEntry copyWithCompanion(OutboxEntriesCompanion data) {
    return DbOutboxEntry(
      id: data.id.present ? data.id.value : this.id,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      status: data.status.present ? data.status.value : this.status,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      scheduledAt: data.scheduledAt.present
          ? data.scheduledAt.value
          : this.scheduledAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastAttemptAt: data.lastAttemptAt.present
          ? data.lastAttemptAt.value
          : this.lastAttemptAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbOutboxEntry(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError, ')
          ..write('scheduledAt: $scheduledAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAttemptAt: $lastAttemptAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileId,
    payloadJson,
    status,
    attempts,
    lastError,
    scheduledAt,
    createdAt,
    lastAttemptAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbOutboxEntry &&
          other.id == this.id &&
          other.profileId == this.profileId &&
          other.payloadJson == this.payloadJson &&
          other.status == this.status &&
          other.attempts == this.attempts &&
          other.lastError == this.lastError &&
          other.scheduledAt == this.scheduledAt &&
          other.createdAt == this.createdAt &&
          other.lastAttemptAt == this.lastAttemptAt);
}

class OutboxEntriesCompanion extends UpdateCompanion<DbOutboxEntry> {
  final Value<int> id;
  final Value<String> profileId;
  final Value<String> payloadJson;
  final Value<String> status;
  final Value<int> attempts;
  final Value<String?> lastError;
  final Value<DateTime?> scheduledAt;
  final Value<DateTime> createdAt;
  final Value<DateTime?> lastAttemptAt;
  const OutboxEntriesCompanion({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
    this.scheduledAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastAttemptAt = const Value.absent(),
  });
  OutboxEntriesCompanion.insert({
    this.id = const Value.absent(),
    required String profileId,
    required String payloadJson,
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
    this.scheduledAt = const Value.absent(),
    required DateTime createdAt,
    this.lastAttemptAt = const Value.absent(),
  }) : profileId = Value(profileId),
       payloadJson = Value(payloadJson),
       createdAt = Value(createdAt);
  static Insertable<DbOutboxEntry> custom({
    Expression<int>? id,
    Expression<String>? profileId,
    Expression<String>? payloadJson,
    Expression<String>? status,
    Expression<int>? attempts,
    Expression<String>? lastError,
    Expression<DateTime>? scheduledAt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? lastAttemptAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileId != null) 'profile_id': profileId,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (status != null) 'status': status,
      if (attempts != null) 'attempts': attempts,
      if (lastError != null) 'last_error': lastError,
      if (scheduledAt != null) 'scheduled_at': scheduledAt,
      if (createdAt != null) 'created_at': createdAt,
      if (lastAttemptAt != null) 'last_attempt_at': lastAttemptAt,
    });
  }

  OutboxEntriesCompanion copyWith({
    Value<int>? id,
    Value<String>? profileId,
    Value<String>? payloadJson,
    Value<String>? status,
    Value<int>? attempts,
    Value<String?>? lastError,
    Value<DateTime?>? scheduledAt,
    Value<DateTime>? createdAt,
    Value<DateTime?>? lastAttemptAt,
  }) {
    return OutboxEntriesCompanion(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      payloadJson: payloadJson ?? this.payloadJson,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      createdAt: createdAt ?? this.createdAt,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (scheduledAt.present) {
      map['scheduled_at'] = Variable<DateTime>(scheduledAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastAttemptAt.present) {
      map['last_attempt_at'] = Variable<DateTime>(lastAttemptAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxEntriesCompanion(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError, ')
          ..write('scheduledAt: $scheduledAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAttemptAt: $lastAttemptAt')
          ..write(')'))
        .toString();
  }
}

class $RecipientsHistoryTable extends RecipientsHistory
    with TableInfo<$RecipientsHistoryTable, DbRecipientHistory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecipientsHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _usedAtMeta = const VerificationMeta('usedAt');
  @override
  late final GeneratedColumn<DateTime> usedAt = GeneratedColumn<DateTime>(
    'used_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _useCountMeta = const VerificationMeta(
    'useCount',
  );
  @override
  late final GeneratedColumn<int> useCount = GeneratedColumn<int>(
    'use_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    address,
    name,
    usedAt,
    useCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recipients_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbRecipientHistory> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('used_at')) {
      context.handle(
        _usedAtMeta,
        usedAt.isAcceptableOrUnknown(data['used_at']!, _usedAtMeta),
      );
    }
    if (data.containsKey('use_count')) {
      context.handle(
        _useCountMeta,
        useCount.isAcceptableOrUnknown(data['use_count']!, _useCountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, address};
  @override
  DbRecipientHistory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbRecipientHistory(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      usedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}used_at'],
      ),
      useCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}use_count'],
      )!,
    );
  }

  @override
  $RecipientsHistoryTable createAlias(String alias) {
    return $RecipientsHistoryTable(attachedDatabase, alias);
  }
}

class DbRecipientHistory extends DataClass
    implements Insertable<DbRecipientHistory> {
  final String profileId;
  final String address;
  final String name;
  final DateTime? usedAt;
  final int useCount;
  const DbRecipientHistory({
    required this.profileId,
    required this.address,
    required this.name,
    this.usedAt,
    required this.useCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['address'] = Variable<String>(address);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || usedAt != null) {
      map['used_at'] = Variable<DateTime>(usedAt);
    }
    map['use_count'] = Variable<int>(useCount);
    return map;
  }

  RecipientsHistoryCompanion toCompanion(bool nullToAbsent) {
    return RecipientsHistoryCompanion(
      profileId: Value(profileId),
      address: Value(address),
      name: Value(name),
      usedAt: usedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(usedAt),
      useCount: Value(useCount),
    );
  }

  factory DbRecipientHistory.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbRecipientHistory(
      profileId: serializer.fromJson<String>(json['profileId']),
      address: serializer.fromJson<String>(json['address']),
      name: serializer.fromJson<String>(json['name']),
      usedAt: serializer.fromJson<DateTime?>(json['usedAt']),
      useCount: serializer.fromJson<int>(json['useCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'address': serializer.toJson<String>(address),
      'name': serializer.toJson<String>(name),
      'usedAt': serializer.toJson<DateTime?>(usedAt),
      'useCount': serializer.toJson<int>(useCount),
    };
  }

  DbRecipientHistory copyWith({
    String? profileId,
    String? address,
    String? name,
    Value<DateTime?> usedAt = const Value.absent(),
    int? useCount,
  }) => DbRecipientHistory(
    profileId: profileId ?? this.profileId,
    address: address ?? this.address,
    name: name ?? this.name,
    usedAt: usedAt.present ? usedAt.value : this.usedAt,
    useCount: useCount ?? this.useCount,
  );
  DbRecipientHistory copyWithCompanion(RecipientsHistoryCompanion data) {
    return DbRecipientHistory(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      address: data.address.present ? data.address.value : this.address,
      name: data.name.present ? data.name.value : this.name,
      usedAt: data.usedAt.present ? data.usedAt.value : this.usedAt,
      useCount: data.useCount.present ? data.useCount.value : this.useCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbRecipientHistory(')
          ..write('profileId: $profileId, ')
          ..write('address: $address, ')
          ..write('name: $name, ')
          ..write('usedAt: $usedAt, ')
          ..write('useCount: $useCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(profileId, address, name, usedAt, useCount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbRecipientHistory &&
          other.profileId == this.profileId &&
          other.address == this.address &&
          other.name == this.name &&
          other.usedAt == this.usedAt &&
          other.useCount == this.useCount);
}

class RecipientsHistoryCompanion extends UpdateCompanion<DbRecipientHistory> {
  final Value<String> profileId;
  final Value<String> address;
  final Value<String> name;
  final Value<DateTime?> usedAt;
  final Value<int> useCount;
  final Value<int> rowid;
  const RecipientsHistoryCompanion({
    this.profileId = const Value.absent(),
    this.address = const Value.absent(),
    this.name = const Value.absent(),
    this.usedAt = const Value.absent(),
    this.useCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecipientsHistoryCompanion.insert({
    required String profileId,
    required String address,
    this.name = const Value.absent(),
    this.usedAt = const Value.absent(),
    this.useCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       address = Value(address);
  static Insertable<DbRecipientHistory> custom({
    Expression<String>? profileId,
    Expression<String>? address,
    Expression<String>? name,
    Expression<DateTime>? usedAt,
    Expression<int>? useCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (address != null) 'address': address,
      if (name != null) 'name': name,
      if (usedAt != null) 'used_at': usedAt,
      if (useCount != null) 'use_count': useCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecipientsHistoryCompanion copyWith({
    Value<String>? profileId,
    Value<String>? address,
    Value<String>? name,
    Value<DateTime?>? usedAt,
    Value<int>? useCount,
    Value<int>? rowid,
  }) {
    return RecipientsHistoryCompanion(
      profileId: profileId ?? this.profileId,
      address: address ?? this.address,
      name: name ?? this.name,
      usedAt: usedAt ?? this.usedAt,
      useCount: useCount ?? this.useCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (usedAt.present) {
      map['used_at'] = Variable<DateTime>(usedAt.value);
    }
    if (useCount.present) {
      map['use_count'] = Variable<int>(useCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecipientsHistoryCompanion(')
          ..write('profileId: $profileId, ')
          ..write('address: $address, ')
          ..write('name: $name, ')
          ..write('usedAt: $usedAt, ')
          ..write('useCount: $useCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DraftsTable extends Drafts with TableInfo<$DraftsTable, DbDraft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountEmailMeta = const VerificationMeta(
    'accountEmail',
  );
  @override
  late final GeneratedColumn<String> accountEmail = GeneratedColumn<String>(
    'account_email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _recipientsJsonMeta = const VerificationMeta(
    'recipientsJson',
  );
  @override
  late final GeneratedColumn<String> recipientsJson = GeneratedColumn<String>(
    'recipients_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _attachmentPathsJsonMeta =
      const VerificationMeta('attachmentPathsJson');
  @override
  late final GeneratedColumn<String> attachmentPathsJson =
      GeneratedColumn<String>(
        'attachment_paths_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileId,
    accountEmail,
    recipientsJson,
    subject,
    content,
    attachmentPathsJson,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbDraft> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('account_email')) {
      context.handle(
        _accountEmailMeta,
        accountEmail.isAcceptableOrUnknown(
          data['account_email']!,
          _accountEmailMeta,
        ),
      );
    }
    if (data.containsKey('recipients_json')) {
      context.handle(
        _recipientsJsonMeta,
        recipientsJson.isAcceptableOrUnknown(
          data['recipients_json']!,
          _recipientsJsonMeta,
        ),
      );
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('attachment_paths_json')) {
      context.handle(
        _attachmentPathsJsonMeta,
        attachmentPathsJson.isAcceptableOrUnknown(
          data['attachment_paths_json']!,
          _attachmentPathsJsonMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbDraft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbDraft(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      accountEmail: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_email'],
      )!,
      recipientsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recipients_json'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      attachmentPathsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attachment_paths_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DraftsTable createAlias(String alias) {
    return $DraftsTable(attachedDatabase, alias);
  }
}

class DbDraft extends DataClass implements Insertable<DbDraft> {
  final int id;
  final String profileId;
  final String accountEmail;
  final String recipientsJson;
  final String subject;
  final String content;

  /// 附件只存路径，不存内容。
  final String attachmentPathsJson;
  final DateTime updatedAt;
  const DbDraft({
    required this.id,
    required this.profileId,
    required this.accountEmail,
    required this.recipientsJson,
    required this.subject,
    required this.content,
    required this.attachmentPathsJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['profile_id'] = Variable<String>(profileId);
    map['account_email'] = Variable<String>(accountEmail);
    map['recipients_json'] = Variable<String>(recipientsJson);
    map['subject'] = Variable<String>(subject);
    map['content'] = Variable<String>(content);
    map['attachment_paths_json'] = Variable<String>(attachmentPathsJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  DraftsCompanion toCompanion(bool nullToAbsent) {
    return DraftsCompanion(
      id: Value(id),
      profileId: Value(profileId),
      accountEmail: Value(accountEmail),
      recipientsJson: Value(recipientsJson),
      subject: Value(subject),
      content: Value(content),
      attachmentPathsJson: Value(attachmentPathsJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory DbDraft.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbDraft(
      id: serializer.fromJson<int>(json['id']),
      profileId: serializer.fromJson<String>(json['profileId']),
      accountEmail: serializer.fromJson<String>(json['accountEmail']),
      recipientsJson: serializer.fromJson<String>(json['recipientsJson']),
      subject: serializer.fromJson<String>(json['subject']),
      content: serializer.fromJson<String>(json['content']),
      attachmentPathsJson: serializer.fromJson<String>(
        json['attachmentPathsJson'],
      ),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileId': serializer.toJson<String>(profileId),
      'accountEmail': serializer.toJson<String>(accountEmail),
      'recipientsJson': serializer.toJson<String>(recipientsJson),
      'subject': serializer.toJson<String>(subject),
      'content': serializer.toJson<String>(content),
      'attachmentPathsJson': serializer.toJson<String>(attachmentPathsJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  DbDraft copyWith({
    int? id,
    String? profileId,
    String? accountEmail,
    String? recipientsJson,
    String? subject,
    String? content,
    String? attachmentPathsJson,
    DateTime? updatedAt,
  }) => DbDraft(
    id: id ?? this.id,
    profileId: profileId ?? this.profileId,
    accountEmail: accountEmail ?? this.accountEmail,
    recipientsJson: recipientsJson ?? this.recipientsJson,
    subject: subject ?? this.subject,
    content: content ?? this.content,
    attachmentPathsJson: attachmentPathsJson ?? this.attachmentPathsJson,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DbDraft copyWithCompanion(DraftsCompanion data) {
    return DbDraft(
      id: data.id.present ? data.id.value : this.id,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      accountEmail: data.accountEmail.present
          ? data.accountEmail.value
          : this.accountEmail,
      recipientsJson: data.recipientsJson.present
          ? data.recipientsJson.value
          : this.recipientsJson,
      subject: data.subject.present ? data.subject.value : this.subject,
      content: data.content.present ? data.content.value : this.content,
      attachmentPathsJson: data.attachmentPathsJson.present
          ? data.attachmentPathsJson.value
          : this.attachmentPathsJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbDraft(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('accountEmail: $accountEmail, ')
          ..write('recipientsJson: $recipientsJson, ')
          ..write('subject: $subject, ')
          ..write('content: $content, ')
          ..write('attachmentPathsJson: $attachmentPathsJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileId,
    accountEmail,
    recipientsJson,
    subject,
    content,
    attachmentPathsJson,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbDraft &&
          other.id == this.id &&
          other.profileId == this.profileId &&
          other.accountEmail == this.accountEmail &&
          other.recipientsJson == this.recipientsJson &&
          other.subject == this.subject &&
          other.content == this.content &&
          other.attachmentPathsJson == this.attachmentPathsJson &&
          other.updatedAt == this.updatedAt);
}

class DraftsCompanion extends UpdateCompanion<DbDraft> {
  final Value<int> id;
  final Value<String> profileId;
  final Value<String> accountEmail;
  final Value<String> recipientsJson;
  final Value<String> subject;
  final Value<String> content;
  final Value<String> attachmentPathsJson;
  final Value<DateTime> updatedAt;
  const DraftsCompanion({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    this.accountEmail = const Value.absent(),
    this.recipientsJson = const Value.absent(),
    this.subject = const Value.absent(),
    this.content = const Value.absent(),
    this.attachmentPathsJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  DraftsCompanion.insert({
    this.id = const Value.absent(),
    required String profileId,
    this.accountEmail = const Value.absent(),
    this.recipientsJson = const Value.absent(),
    this.subject = const Value.absent(),
    this.content = const Value.absent(),
    this.attachmentPathsJson = const Value.absent(),
    required DateTime updatedAt,
  }) : profileId = Value(profileId),
       updatedAt = Value(updatedAt);
  static Insertable<DbDraft> custom({
    Expression<int>? id,
    Expression<String>? profileId,
    Expression<String>? accountEmail,
    Expression<String>? recipientsJson,
    Expression<String>? subject,
    Expression<String>? content,
    Expression<String>? attachmentPathsJson,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileId != null) 'profile_id': profileId,
      if (accountEmail != null) 'account_email': accountEmail,
      if (recipientsJson != null) 'recipients_json': recipientsJson,
      if (subject != null) 'subject': subject,
      if (content != null) 'content': content,
      if (attachmentPathsJson != null)
        'attachment_paths_json': attachmentPathsJson,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  DraftsCompanion copyWith({
    Value<int>? id,
    Value<String>? profileId,
    Value<String>? accountEmail,
    Value<String>? recipientsJson,
    Value<String>? subject,
    Value<String>? content,
    Value<String>? attachmentPathsJson,
    Value<DateTime>? updatedAt,
  }) {
    return DraftsCompanion(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      accountEmail: accountEmail ?? this.accountEmail,
      recipientsJson: recipientsJson ?? this.recipientsJson,
      subject: subject ?? this.subject,
      content: content ?? this.content,
      attachmentPathsJson: attachmentPathsJson ?? this.attachmentPathsJson,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (accountEmail.present) {
      map['account_email'] = Variable<String>(accountEmail.value);
    }
    if (recipientsJson.present) {
      map['recipients_json'] = Variable<String>(recipientsJson.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (attachmentPathsJson.present) {
      map['attachment_paths_json'] = Variable<String>(
        attachmentPathsJson.value,
      );
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DraftsCompanion(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('accountEmail: $accountEmail, ')
          ..write('recipientsJson: $recipientsJson, ')
          ..write('subject: $subject, ')
          ..write('content: $content, ')
          ..write('attachmentPathsJson: $attachmentPathsJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $RemindersTable extends Reminders
    with TableInfo<$RemindersTable, DbReminder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RemindersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emailIdMeta = const VerificationMeta(
    'emailId',
  );
  @override
  late final GeneratedColumn<int> emailId = GeneratedColumn<int>(
    'email_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _senderMeta = const VerificationMeta('sender');
  @override
  late final GeneratedColumn<String> sender = GeneratedColumn<String>(
    'sender',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _remindAtMeta = const VerificationMeta(
    'remindAt',
  );
  @override
  late final GeneratedColumn<DateTime> remindAt = GeneratedColumn<DateTime>(
    'remind_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _firedAtMeta = const VerificationMeta(
    'firedAt',
  );
  @override
  late final GeneratedColumn<DateTime> firedAt = GeneratedColumn<DateTime>(
    'fired_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileId,
    emailId,
    subject,
    sender,
    remindAt,
    createdAt,
    firedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reminders';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbReminder> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('email_id')) {
      context.handle(
        _emailIdMeta,
        emailId.isAcceptableOrUnknown(data['email_id']!, _emailIdMeta),
      );
    } else if (isInserting) {
      context.missing(_emailIdMeta);
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    }
    if (data.containsKey('sender')) {
      context.handle(
        _senderMeta,
        sender.isAcceptableOrUnknown(data['sender']!, _senderMeta),
      );
    }
    if (data.containsKey('remind_at')) {
      context.handle(
        _remindAtMeta,
        remindAt.isAcceptableOrUnknown(data['remind_at']!, _remindAtMeta),
      );
    } else if (isInserting) {
      context.missing(_remindAtMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('fired_at')) {
      context.handle(
        _firedAtMeta,
        firedAt.isAcceptableOrUnknown(data['fired_at']!, _firedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbReminder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbReminder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      emailId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}email_id'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      )!,
      sender: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender'],
      )!,
      remindAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}remind_at'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      firedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}fired_at'],
      ),
    );
  }

  @override
  $RemindersTable createAlias(String alias) {
    return $RemindersTable(attachedDatabase, alias);
  }
}

class DbReminder extends DataClass implements Insertable<DbReminder> {
  final int id;
  final String profileId;
  final int emailId;

  /// 冗余存一份标题与发件人：到点弹通知时那封邮件可能已经被删了，
  /// 而「你让我提醒你的那封信」这个信息只在这张表里。
  final String subject;
  final String sender;

  /// 提醒时间（**UTC**，与 `OutboxEntries.scheduledAt` 同一套约定）。
  final DateTime remindAt;
  final DateTime createdAt;

  /// 已经弹过了（主路径由系统排期弹出，降级路由 ticker 弹）。
  ///
  /// **弹过之后不删行**，只置这个时间戳：「删掉」在弹失败时会把提醒吞掉，
  /// 而用户完全不知道。留一行带 `firedAt` 的，既不会重复弹，也留着
  /// 「这封信我提醒过一次」这个事实。
  final DateTime? firedAt;
  const DbReminder({
    required this.id,
    required this.profileId,
    required this.emailId,
    required this.subject,
    required this.sender,
    required this.remindAt,
    required this.createdAt,
    this.firedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['profile_id'] = Variable<String>(profileId);
    map['email_id'] = Variable<int>(emailId);
    map['subject'] = Variable<String>(subject);
    map['sender'] = Variable<String>(sender);
    map['remind_at'] = Variable<DateTime>(remindAt);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || firedAt != null) {
      map['fired_at'] = Variable<DateTime>(firedAt);
    }
    return map;
  }

  RemindersCompanion toCompanion(bool nullToAbsent) {
    return RemindersCompanion(
      id: Value(id),
      profileId: Value(profileId),
      emailId: Value(emailId),
      subject: Value(subject),
      sender: Value(sender),
      remindAt: Value(remindAt),
      createdAt: Value(createdAt),
      firedAt: firedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(firedAt),
    );
  }

  factory DbReminder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbReminder(
      id: serializer.fromJson<int>(json['id']),
      profileId: serializer.fromJson<String>(json['profileId']),
      emailId: serializer.fromJson<int>(json['emailId']),
      subject: serializer.fromJson<String>(json['subject']),
      sender: serializer.fromJson<String>(json['sender']),
      remindAt: serializer.fromJson<DateTime>(json['remindAt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      firedAt: serializer.fromJson<DateTime?>(json['firedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileId': serializer.toJson<String>(profileId),
      'emailId': serializer.toJson<int>(emailId),
      'subject': serializer.toJson<String>(subject),
      'sender': serializer.toJson<String>(sender),
      'remindAt': serializer.toJson<DateTime>(remindAt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'firedAt': serializer.toJson<DateTime?>(firedAt),
    };
  }

  DbReminder copyWith({
    int? id,
    String? profileId,
    int? emailId,
    String? subject,
    String? sender,
    DateTime? remindAt,
    DateTime? createdAt,
    Value<DateTime?> firedAt = const Value.absent(),
  }) => DbReminder(
    id: id ?? this.id,
    profileId: profileId ?? this.profileId,
    emailId: emailId ?? this.emailId,
    subject: subject ?? this.subject,
    sender: sender ?? this.sender,
    remindAt: remindAt ?? this.remindAt,
    createdAt: createdAt ?? this.createdAt,
    firedAt: firedAt.present ? firedAt.value : this.firedAt,
  );
  DbReminder copyWithCompanion(RemindersCompanion data) {
    return DbReminder(
      id: data.id.present ? data.id.value : this.id,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      emailId: data.emailId.present ? data.emailId.value : this.emailId,
      subject: data.subject.present ? data.subject.value : this.subject,
      sender: data.sender.present ? data.sender.value : this.sender,
      remindAt: data.remindAt.present ? data.remindAt.value : this.remindAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      firedAt: data.firedAt.present ? data.firedAt.value : this.firedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbReminder(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('emailId: $emailId, ')
          ..write('subject: $subject, ')
          ..write('sender: $sender, ')
          ..write('remindAt: $remindAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('firedAt: $firedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileId,
    emailId,
    subject,
    sender,
    remindAt,
    createdAt,
    firedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbReminder &&
          other.id == this.id &&
          other.profileId == this.profileId &&
          other.emailId == this.emailId &&
          other.subject == this.subject &&
          other.sender == this.sender &&
          other.remindAt == this.remindAt &&
          other.createdAt == this.createdAt &&
          other.firedAt == this.firedAt);
}

class RemindersCompanion extends UpdateCompanion<DbReminder> {
  final Value<int> id;
  final Value<String> profileId;
  final Value<int> emailId;
  final Value<String> subject;
  final Value<String> sender;
  final Value<DateTime> remindAt;
  final Value<DateTime> createdAt;
  final Value<DateTime?> firedAt;
  const RemindersCompanion({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    this.emailId = const Value.absent(),
    this.subject = const Value.absent(),
    this.sender = const Value.absent(),
    this.remindAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.firedAt = const Value.absent(),
  });
  RemindersCompanion.insert({
    this.id = const Value.absent(),
    required String profileId,
    required int emailId,
    this.subject = const Value.absent(),
    this.sender = const Value.absent(),
    required DateTime remindAt,
    required DateTime createdAt,
    this.firedAt = const Value.absent(),
  }) : profileId = Value(profileId),
       emailId = Value(emailId),
       remindAt = Value(remindAt),
       createdAt = Value(createdAt);
  static Insertable<DbReminder> custom({
    Expression<int>? id,
    Expression<String>? profileId,
    Expression<int>? emailId,
    Expression<String>? subject,
    Expression<String>? sender,
    Expression<DateTime>? remindAt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? firedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileId != null) 'profile_id': profileId,
      if (emailId != null) 'email_id': emailId,
      if (subject != null) 'subject': subject,
      if (sender != null) 'sender': sender,
      if (remindAt != null) 'remind_at': remindAt,
      if (createdAt != null) 'created_at': createdAt,
      if (firedAt != null) 'fired_at': firedAt,
    });
  }

  RemindersCompanion copyWith({
    Value<int>? id,
    Value<String>? profileId,
    Value<int>? emailId,
    Value<String>? subject,
    Value<String>? sender,
    Value<DateTime>? remindAt,
    Value<DateTime>? createdAt,
    Value<DateTime?>? firedAt,
  }) {
    return RemindersCompanion(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      emailId: emailId ?? this.emailId,
      subject: subject ?? this.subject,
      sender: sender ?? this.sender,
      remindAt: remindAt ?? this.remindAt,
      createdAt: createdAt ?? this.createdAt,
      firedAt: firedAt ?? this.firedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (emailId.present) {
      map['email_id'] = Variable<int>(emailId.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (sender.present) {
      map['sender'] = Variable<String>(sender.value);
    }
    if (remindAt.present) {
      map['remind_at'] = Variable<DateTime>(remindAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (firedAt.present) {
      map['fired_at'] = Variable<DateTime>(firedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RemindersCompanion(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('emailId: $emailId, ')
          ..write('subject: $subject, ')
          ..write('sender: $sender, ')
          ..write('remindAt: $remindAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('firedAt: $firedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $CapabilitiesTable capabilities = $CapabilitiesTable(this);
  late final $MailboxesTable mailboxes = $MailboxesTable(this);
  late final $MailsTable mails = $MailsTable(this);
  late final $AttachmentsTable attachments = $AttachmentsTable(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $OutboxEntriesTable outboxEntries = $OutboxEntriesTable(this);
  late final $RecipientsHistoryTable recipientsHistory =
      $RecipientsHistoryTable(this);
  late final $DraftsTable drafts = $DraftsTable(this);
  late final $RemindersTable reminders = $RemindersTable(this);
  late final ProfileDao profileDao = ProfileDao(this as AppDatabase);
  late final MailDao mailDao = MailDao(this as AppDatabase);
  late final LocalDao localDao = LocalDao(this as AppDatabase);
  late final ReminderDao reminderDao = ReminderDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    profiles,
    capabilities,
    mailboxes,
    mails,
    attachments,
    syncStates,
    outboxEntries,
    recipientsHistory,
    drafts,
    reminders,
  ];
}

typedef $$ProfilesTableCreateCompanionBuilder =
    ProfilesCompanion Function({
      required String id,
      required String baseUrl,
      Value<String> name,
      Value<String> email,
      Value<String> serverTitle,
      Value<String> userName,
      Value<int> userId,
      Value<String> ossBase,
      Value<int> sort,
      Value<int> colorIndex,
      Value<bool> needsLogin,
      Value<DateTime?> lastSyncAt,
      Value<DateTime?> createdAt,
      Value<DateTime?> lastActiveAt,
      Value<int> rowid,
    });
typedef $$ProfilesTableUpdateCompanionBuilder =
    ProfilesCompanion Function({
      Value<String> id,
      Value<String> baseUrl,
      Value<String> name,
      Value<String> email,
      Value<String> serverTitle,
      Value<String> userName,
      Value<int> userId,
      Value<String> ossBase,
      Value<int> sort,
      Value<int> colorIndex,
      Value<bool> needsLogin,
      Value<DateTime?> lastSyncAt,
      Value<DateTime?> createdAt,
      Value<DateTime?> lastActiveAt,
      Value<int> rowid,
    });

class $$ProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseUrl => $composableBuilder(
    column: $table.baseUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverTitle => $composableBuilder(
    column: $table.serverTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userName => $composableBuilder(
    column: $table.userName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ossBase => $composableBuilder(
    column: $table.ossBase,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorIndex => $composableBuilder(
    column: $table.colorIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get needsLogin => $composableBuilder(
    column: $table.needsLogin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastActiveAt => $composableBuilder(
    column: $table.lastActiveAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseUrl => $composableBuilder(
    column: $table.baseUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverTitle => $composableBuilder(
    column: $table.serverTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userName => $composableBuilder(
    column: $table.userName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ossBase => $composableBuilder(
    column: $table.ossBase,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorIndex => $composableBuilder(
    column: $table.colorIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get needsLogin => $composableBuilder(
    column: $table.needsLogin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastActiveAt => $composableBuilder(
    column: $table.lastActiveAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get baseUrl =>
      $composableBuilder(column: $table.baseUrl, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get email =>
      $composableBuilder(column: $table.email, builder: (column) => column);

  GeneratedColumn<String> get serverTitle => $composableBuilder(
    column: $table.serverTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get userName =>
      $composableBuilder(column: $table.userName, builder: (column) => column);

  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get ossBase =>
      $composableBuilder(column: $table.ossBase, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<int> get colorIndex => $composableBuilder(
    column: $table.colorIndex,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get needsLogin => $composableBuilder(
    column: $table.needsLogin,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastActiveAt => $composableBuilder(
    column: $table.lastActiveAt,
    builder: (column) => column,
  );
}

class $$ProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfilesTable,
          DbProfile,
          $$ProfilesTableFilterComposer,
          $$ProfilesTableOrderingComposer,
          $$ProfilesTableAnnotationComposer,
          $$ProfilesTableCreateCompanionBuilder,
          $$ProfilesTableUpdateCompanionBuilder,
          (DbProfile, BaseReferences<_$AppDatabase, $ProfilesTable, DbProfile>),
          DbProfile,
          PrefetchHooks Function()
        > {
  $$ProfilesTableTableManager(_$AppDatabase db, $ProfilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> baseUrl = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> email = const Value.absent(),
                Value<String> serverTitle = const Value.absent(),
                Value<String> userName = const Value.absent(),
                Value<int> userId = const Value.absent(),
                Value<String> ossBase = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> colorIndex = const Value.absent(),
                Value<bool> needsLogin = const Value.absent(),
                Value<DateTime?> lastSyncAt = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<DateTime?> lastActiveAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion(
                id: id,
                baseUrl: baseUrl,
                name: name,
                email: email,
                serverTitle: serverTitle,
                userName: userName,
                userId: userId,
                ossBase: ossBase,
                sort: sort,
                colorIndex: colorIndex,
                needsLogin: needsLogin,
                lastSyncAt: lastSyncAt,
                createdAt: createdAt,
                lastActiveAt: lastActiveAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String baseUrl,
                Value<String> name = const Value.absent(),
                Value<String> email = const Value.absent(),
                Value<String> serverTitle = const Value.absent(),
                Value<String> userName = const Value.absent(),
                Value<int> userId = const Value.absent(),
                Value<String> ossBase = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> colorIndex = const Value.absent(),
                Value<bool> needsLogin = const Value.absent(),
                Value<DateTime?> lastSyncAt = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<DateTime?> lastActiveAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion.insert(
                id: id,
                baseUrl: baseUrl,
                name: name,
                email: email,
                serverTitle: serverTitle,
                userName: userName,
                userId: userId,
                ossBase: ossBase,
                sort: sort,
                colorIndex: colorIndex,
                needsLogin: needsLogin,
                lastSyncAt: lastSyncAt,
                createdAt: createdAt,
                lastActiveAt: lastActiveAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProfilesTable, DbProfile>(table),
                  BaseReferences<_$AppDatabase, $ProfilesTable, DbProfile>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfilesTable,
      DbProfile,
      $$ProfilesTableFilterComposer,
      $$ProfilesTableOrderingComposer,
      $$ProfilesTableAnnotationComposer,
      $$ProfilesTableCreateCompanionBuilder,
      $$ProfilesTableUpdateCompanionBuilder,
      (DbProfile, BaseReferences<_$AppDatabase, $ProfilesTable, DbProfile>),
      DbProfile,
      PrefetchHooks Function()
    >;
typedef $$CapabilitiesTableCreateCompanionBuilder =
    CapabilitiesCompanion Function({
      required String profileId,
      required String payload,
      Value<DateTime?> probedAt,
      Value<int> rowid,
    });
typedef $$CapabilitiesTableUpdateCompanionBuilder =
    CapabilitiesCompanion Function({
      Value<String> profileId,
      Value<String> payload,
      Value<DateTime?> probedAt,
      Value<int> rowid,
    });

class $$CapabilitiesTableFilterComposer
    extends Composer<_$AppDatabase, $CapabilitiesTable> {
  $$CapabilitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get probedAt => $composableBuilder(
    column: $table.probedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CapabilitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $CapabilitiesTable> {
  $$CapabilitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get probedAt => $composableBuilder(
    column: $table.probedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CapabilitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CapabilitiesTable> {
  $$CapabilitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<DateTime> get probedAt =>
      $composableBuilder(column: $table.probedAt, builder: (column) => column);
}

class $$CapabilitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CapabilitiesTable,
          DbCapability,
          $$CapabilitiesTableFilterComposer,
          $$CapabilitiesTableOrderingComposer,
          $$CapabilitiesTableAnnotationComposer,
          $$CapabilitiesTableCreateCompanionBuilder,
          $$CapabilitiesTableUpdateCompanionBuilder,
          (
            DbCapability,
            BaseReferences<_$AppDatabase, $CapabilitiesTable, DbCapability>,
          ),
          DbCapability,
          PrefetchHooks Function()
        > {
  $$CapabilitiesTableTableManager(_$AppDatabase db, $CapabilitiesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CapabilitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CapabilitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CapabilitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<DateTime?> probedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CapabilitiesCompanion(
                profileId: profileId,
                payload: payload,
                probedAt: probedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String payload,
                Value<DateTime?> probedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CapabilitiesCompanion.insert(
                profileId: profileId,
                payload: payload,
                probedAt: probedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CapabilitiesTable, DbCapability>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $CapabilitiesTable,
                    DbCapability
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CapabilitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CapabilitiesTable,
      DbCapability,
      $$CapabilitiesTableFilterComposer,
      $$CapabilitiesTableOrderingComposer,
      $$CapabilitiesTableAnnotationComposer,
      $$CapabilitiesTableCreateCompanionBuilder,
      $$CapabilitiesTableUpdateCompanionBuilder,
      (
        DbCapability,
        BaseReferences<_$AppDatabase, $CapabilitiesTable, DbCapability>,
      ),
      DbCapability,
      PrefetchHooks Function()
    >;
typedef $$MailboxesTableCreateCompanionBuilder =
    MailboxesCompanion Function({
      required String profileId,
      required int accountId,
      Value<String> email,
      Value<String> name,
      Value<int> status,
      Value<int> allReceive,
      Value<int> sort,
      Value<String?> latestEmailTime,
      Value<DateTime?> syncedAt,
      Value<int> rowid,
    });
typedef $$MailboxesTableUpdateCompanionBuilder =
    MailboxesCompanion Function({
      Value<String> profileId,
      Value<int> accountId,
      Value<String> email,
      Value<String> name,
      Value<int> status,
      Value<int> allReceive,
      Value<int> sort,
      Value<String?> latestEmailTime,
      Value<DateTime?> syncedAt,
      Value<int> rowid,
    });

class $$MailboxesTableFilterComposer
    extends Composer<_$AppDatabase, $MailboxesTable> {
  $$MailboxesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get allReceive => $composableBuilder(
    column: $table.allReceive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get latestEmailTime => $composableBuilder(
    column: $table.latestEmailTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MailboxesTableOrderingComposer
    extends Composer<_$AppDatabase, $MailboxesTable> {
  $$MailboxesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get allReceive => $composableBuilder(
    column: $table.allReceive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get latestEmailTime => $composableBuilder(
    column: $table.latestEmailTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MailboxesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MailboxesTable> {
  $$MailboxesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get email =>
      $composableBuilder(column: $table.email, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get allReceive => $composableBuilder(
    column: $table.allReceive,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<String> get latestEmailTime => $composableBuilder(
    column: $table.latestEmailTime,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);
}

class $$MailboxesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MailboxesTable,
          DbMailbox,
          $$MailboxesTableFilterComposer,
          $$MailboxesTableOrderingComposer,
          $$MailboxesTableAnnotationComposer,
          $$MailboxesTableCreateCompanionBuilder,
          $$MailboxesTableUpdateCompanionBuilder,
          (
            DbMailbox,
            BaseReferences<_$AppDatabase, $MailboxesTable, DbMailbox>,
          ),
          DbMailbox,
          PrefetchHooks Function()
        > {
  $$MailboxesTableTableManager(_$AppDatabase db, $MailboxesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MailboxesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MailboxesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MailboxesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> email = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<int> allReceive = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<String?> latestEmailTime = const Value.absent(),
                Value<DateTime?> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MailboxesCompanion(
                profileId: profileId,
                accountId: accountId,
                email: email,
                name: name,
                status: status,
                allReceive: allReceive,
                sort: sort,
                latestEmailTime: latestEmailTime,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required int accountId,
                Value<String> email = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<int> allReceive = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<String?> latestEmailTime = const Value.absent(),
                Value<DateTime?> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MailboxesCompanion.insert(
                profileId: profileId,
                accountId: accountId,
                email: email,
                name: name,
                status: status,
                allReceive: allReceive,
                sort: sort,
                latestEmailTime: latestEmailTime,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MailboxesTable, DbMailbox>(table),
                  BaseReferences<_$AppDatabase, $MailboxesTable, DbMailbox>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MailboxesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MailboxesTable,
      DbMailbox,
      $$MailboxesTableFilterComposer,
      $$MailboxesTableOrderingComposer,
      $$MailboxesTableAnnotationComposer,
      $$MailboxesTableCreateCompanionBuilder,
      $$MailboxesTableUpdateCompanionBuilder,
      (DbMailbox, BaseReferences<_$AppDatabase, $MailboxesTable, DbMailbox>),
      DbMailbox,
      PrefetchHooks Function()
    >;
typedef $$MailsTableCreateCompanionBuilder =
    MailsCompanion Function({
      required String profileId,
      required int emailId,
      Value<int> accountId,
      Value<String> mailboxEmail,
      Value<int> type,
      Value<int> status,
      Value<String> sendEmail,
      Value<String> name,
      Value<String> subject,
      Value<String> code,
      Value<String> toEmail,
      Value<String> toName,
      Value<String> recipientJson,
      Value<String> ccJson,
      Value<String> bccJson,
      Value<String?> message,
      Value<int> unread,
      Value<int> isStar,
      Value<bool> starKnown,
      Value<int> isDel,
      Value<String?> content,
      Value<String?> bodyText,
      Value<String?> inReplyTo,
      Value<String?> relation,
      Value<String?> messageId,
      Value<String?> resendEmailId,
      Value<DateTime?> createTime,
      Value<bool> hasFullBody,
      Value<DateTime?> cachedAt,
      Value<int> rowid,
    });
typedef $$MailsTableUpdateCompanionBuilder =
    MailsCompanion Function({
      Value<String> profileId,
      Value<int> emailId,
      Value<int> accountId,
      Value<String> mailboxEmail,
      Value<int> type,
      Value<int> status,
      Value<String> sendEmail,
      Value<String> name,
      Value<String> subject,
      Value<String> code,
      Value<String> toEmail,
      Value<String> toName,
      Value<String> recipientJson,
      Value<String> ccJson,
      Value<String> bccJson,
      Value<String?> message,
      Value<int> unread,
      Value<int> isStar,
      Value<bool> starKnown,
      Value<int> isDel,
      Value<String?> content,
      Value<String?> bodyText,
      Value<String?> inReplyTo,
      Value<String?> relation,
      Value<String?> messageId,
      Value<String?> resendEmailId,
      Value<DateTime?> createTime,
      Value<bool> hasFullBody,
      Value<DateTime?> cachedAt,
      Value<int> rowid,
    });

class $$MailsTableFilterComposer extends Composer<_$AppDatabase, $MailsTable> {
  $$MailsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mailboxEmail => $composableBuilder(
    column: $table.mailboxEmail,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sendEmail => $composableBuilder(
    column: $table.sendEmail,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toEmail => $composableBuilder(
    column: $table.toEmail,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toName => $composableBuilder(
    column: $table.toName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recipientJson => $composableBuilder(
    column: $table.recipientJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ccJson => $composableBuilder(
    column: $table.ccJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bccJson => $composableBuilder(
    column: $table.bccJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unread => $composableBuilder(
    column: $table.unread,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isStar => $composableBuilder(
    column: $table.isStar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get starKnown => $composableBuilder(
    column: $table.starKnown,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isDel => $composableBuilder(
    column: $table.isDel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bodyText => $composableBuilder(
    column: $table.bodyText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get inReplyTo => $composableBuilder(
    column: $table.inReplyTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relation => $composableBuilder(
    column: $table.relation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resendEmailId => $composableBuilder(
    column: $table.resendEmailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasFullBody => $composableBuilder(
    column: $table.hasFullBody,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MailsTableOrderingComposer
    extends Composer<_$AppDatabase, $MailsTable> {
  $$MailsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mailboxEmail => $composableBuilder(
    column: $table.mailboxEmail,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sendEmail => $composableBuilder(
    column: $table.sendEmail,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toEmail => $composableBuilder(
    column: $table.toEmail,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toName => $composableBuilder(
    column: $table.toName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recipientJson => $composableBuilder(
    column: $table.recipientJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ccJson => $composableBuilder(
    column: $table.ccJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bccJson => $composableBuilder(
    column: $table.bccJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unread => $composableBuilder(
    column: $table.unread,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isStar => $composableBuilder(
    column: $table.isStar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get starKnown => $composableBuilder(
    column: $table.starKnown,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isDel => $composableBuilder(
    column: $table.isDel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bodyText => $composableBuilder(
    column: $table.bodyText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get inReplyTo => $composableBuilder(
    column: $table.inReplyTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relation => $composableBuilder(
    column: $table.relation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resendEmailId => $composableBuilder(
    column: $table.resendEmailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasFullBody => $composableBuilder(
    column: $table.hasFullBody,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MailsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MailsTable> {
  $$MailsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<int> get emailId =>
      $composableBuilder(column: $table.emailId, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get mailboxEmail => $composableBuilder(
    column: $table.mailboxEmail,
    builder: (column) => column,
  );

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get sendEmail =>
      $composableBuilder(column: $table.sendEmail, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get toEmail =>
      $composableBuilder(column: $table.toEmail, builder: (column) => column);

  GeneratedColumn<String> get toName =>
      $composableBuilder(column: $table.toName, builder: (column) => column);

  GeneratedColumn<String> get recipientJson => $composableBuilder(
    column: $table.recipientJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ccJson =>
      $composableBuilder(column: $table.ccJson, builder: (column) => column);

  GeneratedColumn<String> get bccJson =>
      $composableBuilder(column: $table.bccJson, builder: (column) => column);

  GeneratedColumn<String> get message =>
      $composableBuilder(column: $table.message, builder: (column) => column);

  GeneratedColumn<int> get unread =>
      $composableBuilder(column: $table.unread, builder: (column) => column);

  GeneratedColumn<int> get isStar =>
      $composableBuilder(column: $table.isStar, builder: (column) => column);

  GeneratedColumn<bool> get starKnown =>
      $composableBuilder(column: $table.starKnown, builder: (column) => column);

  GeneratedColumn<int> get isDel =>
      $composableBuilder(column: $table.isDel, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get bodyText =>
      $composableBuilder(column: $table.bodyText, builder: (column) => column);

  GeneratedColumn<String> get inReplyTo =>
      $composableBuilder(column: $table.inReplyTo, builder: (column) => column);

  GeneratedColumn<String> get relation =>
      $composableBuilder(column: $table.relation, builder: (column) => column);

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get resendEmailId => $composableBuilder(
    column: $table.resendEmailId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hasFullBody => $composableBuilder(
    column: $table.hasFullBody,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);
}

class $$MailsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MailsTable,
          DbMail,
          $$MailsTableFilterComposer,
          $$MailsTableOrderingComposer,
          $$MailsTableAnnotationComposer,
          $$MailsTableCreateCompanionBuilder,
          $$MailsTableUpdateCompanionBuilder,
          (DbMail, BaseReferences<_$AppDatabase, $MailsTable, DbMail>),
          DbMail,
          PrefetchHooks Function()
        > {
  $$MailsTableTableManager(_$AppDatabase db, $MailsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MailsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MailsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MailsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<int> emailId = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> mailboxEmail = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<String> sendEmail = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String> toEmail = const Value.absent(),
                Value<String> toName = const Value.absent(),
                Value<String> recipientJson = const Value.absent(),
                Value<String> ccJson = const Value.absent(),
                Value<String> bccJson = const Value.absent(),
                Value<String?> message = const Value.absent(),
                Value<int> unread = const Value.absent(),
                Value<int> isStar = const Value.absent(),
                Value<bool> starKnown = const Value.absent(),
                Value<int> isDel = const Value.absent(),
                Value<String?> content = const Value.absent(),
                Value<String?> bodyText = const Value.absent(),
                Value<String?> inReplyTo = const Value.absent(),
                Value<String?> relation = const Value.absent(),
                Value<String?> messageId = const Value.absent(),
                Value<String?> resendEmailId = const Value.absent(),
                Value<DateTime?> createTime = const Value.absent(),
                Value<bool> hasFullBody = const Value.absent(),
                Value<DateTime?> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MailsCompanion(
                profileId: profileId,
                emailId: emailId,
                accountId: accountId,
                mailboxEmail: mailboxEmail,
                type: type,
                status: status,
                sendEmail: sendEmail,
                name: name,
                subject: subject,
                code: code,
                toEmail: toEmail,
                toName: toName,
                recipientJson: recipientJson,
                ccJson: ccJson,
                bccJson: bccJson,
                message: message,
                unread: unread,
                isStar: isStar,
                starKnown: starKnown,
                isDel: isDel,
                content: content,
                bodyText: bodyText,
                inReplyTo: inReplyTo,
                relation: relation,
                messageId: messageId,
                resendEmailId: resendEmailId,
                createTime: createTime,
                hasFullBody: hasFullBody,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required int emailId,
                Value<int> accountId = const Value.absent(),
                Value<String> mailboxEmail = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<String> sendEmail = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String> toEmail = const Value.absent(),
                Value<String> toName = const Value.absent(),
                Value<String> recipientJson = const Value.absent(),
                Value<String> ccJson = const Value.absent(),
                Value<String> bccJson = const Value.absent(),
                Value<String?> message = const Value.absent(),
                Value<int> unread = const Value.absent(),
                Value<int> isStar = const Value.absent(),
                Value<bool> starKnown = const Value.absent(),
                Value<int> isDel = const Value.absent(),
                Value<String?> content = const Value.absent(),
                Value<String?> bodyText = const Value.absent(),
                Value<String?> inReplyTo = const Value.absent(),
                Value<String?> relation = const Value.absent(),
                Value<String?> messageId = const Value.absent(),
                Value<String?> resendEmailId = const Value.absent(),
                Value<DateTime?> createTime = const Value.absent(),
                Value<bool> hasFullBody = const Value.absent(),
                Value<DateTime?> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MailsCompanion.insert(
                profileId: profileId,
                emailId: emailId,
                accountId: accountId,
                mailboxEmail: mailboxEmail,
                type: type,
                status: status,
                sendEmail: sendEmail,
                name: name,
                subject: subject,
                code: code,
                toEmail: toEmail,
                toName: toName,
                recipientJson: recipientJson,
                ccJson: ccJson,
                bccJson: bccJson,
                message: message,
                unread: unread,
                isStar: isStar,
                starKnown: starKnown,
                isDel: isDel,
                content: content,
                bodyText: bodyText,
                inReplyTo: inReplyTo,
                relation: relation,
                messageId: messageId,
                resendEmailId: resendEmailId,
                createTime: createTime,
                hasFullBody: hasFullBody,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MailsTable, DbMail>(table),
                  BaseReferences<_$AppDatabase, $MailsTable, DbMail>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MailsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MailsTable,
      DbMail,
      $$MailsTableFilterComposer,
      $$MailsTableOrderingComposer,
      $$MailsTableAnnotationComposer,
      $$MailsTableCreateCompanionBuilder,
      $$MailsTableUpdateCompanionBuilder,
      (DbMail, BaseReferences<_$AppDatabase, $MailsTable, DbMail>),
      DbMail,
      PrefetchHooks Function()
    >;
typedef $$AttachmentsTableCreateCompanionBuilder =
    AttachmentsCompanion Function({
      required String profileId,
      required int attId,
      Value<int> emailId,
      Value<String> key,
      Value<String> filename,
      Value<String?> mimeType,
      Value<int> size,
      Value<int> type,
      Value<String?> contentId,
      Value<String?> localPath,
      Value<DateTime?> downloadedAt,
      Value<int> rowid,
    });
typedef $$AttachmentsTableUpdateCompanionBuilder =
    AttachmentsCompanion Function({
      Value<String> profileId,
      Value<int> attId,
      Value<int> emailId,
      Value<String> key,
      Value<String> filename,
      Value<String?> mimeType,
      Value<int> size,
      Value<int> type,
      Value<String?> contentId,
      Value<String?> localPath,
      Value<DateTime?> downloadedAt,
      Value<int> rowid,
    });

class $$AttachmentsTableFilterComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attId => $composableBuilder(
    column: $table.attId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filename => $composableBuilder(
    column: $table.filename,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mimeType => $composableBuilder(
    column: $table.mimeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentId => $composableBuilder(
    column: $table.contentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AttachmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attId => $composableBuilder(
    column: $table.attId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filename => $composableBuilder(
    column: $table.filename,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mimeType => $composableBuilder(
    column: $table.mimeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentId => $composableBuilder(
    column: $table.contentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AttachmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<int> get attId =>
      $composableBuilder(column: $table.attId, builder: (column) => column);

  GeneratedColumn<int> get emailId =>
      $composableBuilder(column: $table.emailId, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get filename =>
      $composableBuilder(column: $table.filename, builder: (column) => column);

  GeneratedColumn<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get contentId =>
      $composableBuilder(column: $table.contentId, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => column,
  );
}

class $$AttachmentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AttachmentsTable,
          DbAttachment,
          $$AttachmentsTableFilterComposer,
          $$AttachmentsTableOrderingComposer,
          $$AttachmentsTableAnnotationComposer,
          $$AttachmentsTableCreateCompanionBuilder,
          $$AttachmentsTableUpdateCompanionBuilder,
          (
            DbAttachment,
            BaseReferences<_$AppDatabase, $AttachmentsTable, DbAttachment>,
          ),
          DbAttachment,
          PrefetchHooks Function()
        > {
  $$AttachmentsTableTableManager(_$AppDatabase db, $AttachmentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttachmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AttachmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AttachmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<int> attId = const Value.absent(),
                Value<int> emailId = const Value.absent(),
                Value<String> key = const Value.absent(),
                Value<String> filename = const Value.absent(),
                Value<String?> mimeType = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String?> contentId = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttachmentsCompanion(
                profileId: profileId,
                attId: attId,
                emailId: emailId,
                key: key,
                filename: filename,
                mimeType: mimeType,
                size: size,
                type: type,
                contentId: contentId,
                localPath: localPath,
                downloadedAt: downloadedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required int attId,
                Value<int> emailId = const Value.absent(),
                Value<String> key = const Value.absent(),
                Value<String> filename = const Value.absent(),
                Value<String?> mimeType = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String?> contentId = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttachmentsCompanion.insert(
                profileId: profileId,
                attId: attId,
                emailId: emailId,
                key: key,
                filename: filename,
                mimeType: mimeType,
                size: size,
                type: type,
                contentId: contentId,
                localPath: localPath,
                downloadedAt: downloadedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AttachmentsTable, DbAttachment>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $AttachmentsTable,
                    DbAttachment
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AttachmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AttachmentsTable,
      DbAttachment,
      $$AttachmentsTableFilterComposer,
      $$AttachmentsTableOrderingComposer,
      $$AttachmentsTableAnnotationComposer,
      $$AttachmentsTableCreateCompanionBuilder,
      $$AttachmentsTableUpdateCompanionBuilder,
      (
        DbAttachment,
        BaseReferences<_$AppDatabase, $AttachmentsTable, DbAttachment>,
      ),
      DbAttachment,
      PrefetchHooks Function()
    >;
typedef $$SyncStatesTableCreateCompanionBuilder =
    SyncStatesCompanion Function({
      required String profileId,
      required String scope,
      Value<int> cursorEmailId,
      Value<int> oldestEmailId,
      Value<int> remoteTotal,
      Value<DateTime?> remoteTotalAt,
      Value<bool> backfillDone,
      Value<DateTime?> lastSyncAt,
      Value<int> failCount,
      Value<String?> lastError,
      Value<int> rowid,
    });
typedef $$SyncStatesTableUpdateCompanionBuilder =
    SyncStatesCompanion Function({
      Value<String> profileId,
      Value<String> scope,
      Value<int> cursorEmailId,
      Value<int> oldestEmailId,
      Value<int> remoteTotal,
      Value<DateTime?> remoteTotalAt,
      Value<bool> backfillDone,
      Value<DateTime?> lastSyncAt,
      Value<int> failCount,
      Value<String?> lastError,
      Value<int> rowid,
    });

class $$SyncStatesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cursorEmailId => $composableBuilder(
    column: $table.cursorEmailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get oldestEmailId => $composableBuilder(
    column: $table.oldestEmailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get remoteTotal => $composableBuilder(
    column: $table.remoteTotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get remoteTotalAt => $composableBuilder(
    column: $table.remoteTotalAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get backfillDone => $composableBuilder(
    column: $table.backfillDone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get failCount => $composableBuilder(
    column: $table.failCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cursorEmailId => $composableBuilder(
    column: $table.cursorEmailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get oldestEmailId => $composableBuilder(
    column: $table.oldestEmailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get remoteTotal => $composableBuilder(
    column: $table.remoteTotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get remoteTotalAt => $composableBuilder(
    column: $table.remoteTotalAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get backfillDone => $composableBuilder(
    column: $table.backfillDone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get failCount => $composableBuilder(
    column: $table.failCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get scope =>
      $composableBuilder(column: $table.scope, builder: (column) => column);

  GeneratedColumn<int> get cursorEmailId => $composableBuilder(
    column: $table.cursorEmailId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get oldestEmailId => $composableBuilder(
    column: $table.oldestEmailId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get remoteTotal => $composableBuilder(
    column: $table.remoteTotal,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get remoteTotalAt => $composableBuilder(
    column: $table.remoteTotalAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get backfillDone => $composableBuilder(
    column: $table.backfillDone,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get failCount =>
      $composableBuilder(column: $table.failCount, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);
}

class $$SyncStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncStatesTable,
          DbSyncState,
          $$SyncStatesTableFilterComposer,
          $$SyncStatesTableOrderingComposer,
          $$SyncStatesTableAnnotationComposer,
          $$SyncStatesTableCreateCompanionBuilder,
          $$SyncStatesTableUpdateCompanionBuilder,
          (
            DbSyncState,
            BaseReferences<_$AppDatabase, $SyncStatesTable, DbSyncState>,
          ),
          DbSyncState,
          PrefetchHooks Function()
        > {
  $$SyncStatesTableTableManager(_$AppDatabase db, $SyncStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> scope = const Value.absent(),
                Value<int> cursorEmailId = const Value.absent(),
                Value<int> oldestEmailId = const Value.absent(),
                Value<int> remoteTotal = const Value.absent(),
                Value<DateTime?> remoteTotalAt = const Value.absent(),
                Value<bool> backfillDone = const Value.absent(),
                Value<DateTime?> lastSyncAt = const Value.absent(),
                Value<int> failCount = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStatesCompanion(
                profileId: profileId,
                scope: scope,
                cursorEmailId: cursorEmailId,
                oldestEmailId: oldestEmailId,
                remoteTotal: remoteTotal,
                remoteTotalAt: remoteTotalAt,
                backfillDone: backfillDone,
                lastSyncAt: lastSyncAt,
                failCount: failCount,
                lastError: lastError,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String scope,
                Value<int> cursorEmailId = const Value.absent(),
                Value<int> oldestEmailId = const Value.absent(),
                Value<int> remoteTotal = const Value.absent(),
                Value<DateTime?> remoteTotalAt = const Value.absent(),
                Value<bool> backfillDone = const Value.absent(),
                Value<DateTime?> lastSyncAt = const Value.absent(),
                Value<int> failCount = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStatesCompanion.insert(
                profileId: profileId,
                scope: scope,
                cursorEmailId: cursorEmailId,
                oldestEmailId: oldestEmailId,
                remoteTotal: remoteTotal,
                remoteTotalAt: remoteTotalAt,
                backfillDone: backfillDone,
                lastSyncAt: lastSyncAt,
                failCount: failCount,
                lastError: lastError,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncStatesTable, DbSyncState>(table),
                  BaseReferences<_$AppDatabase, $SyncStatesTable, DbSyncState>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncStatesTable,
      DbSyncState,
      $$SyncStatesTableFilterComposer,
      $$SyncStatesTableOrderingComposer,
      $$SyncStatesTableAnnotationComposer,
      $$SyncStatesTableCreateCompanionBuilder,
      $$SyncStatesTableUpdateCompanionBuilder,
      (
        DbSyncState,
        BaseReferences<_$AppDatabase, $SyncStatesTable, DbSyncState>,
      ),
      DbSyncState,
      PrefetchHooks Function()
    >;
typedef $$OutboxEntriesTableCreateCompanionBuilder =
    OutboxEntriesCompanion Function({
      Value<int> id,
      required String profileId,
      required String payloadJson,
      Value<String> status,
      Value<int> attempts,
      Value<String?> lastError,
      Value<DateTime?> scheduledAt,
      required DateTime createdAt,
      Value<DateTime?> lastAttemptAt,
    });
typedef $$OutboxEntriesTableUpdateCompanionBuilder =
    OutboxEntriesCompanion Function({
      Value<int> id,
      Value<String> profileId,
      Value<String> payloadJson,
      Value<String> status,
      Value<int> attempts,
      Value<String?> lastError,
      Value<DateTime?> scheduledAt,
      Value<DateTime> createdAt,
      Value<DateTime?> lastAttemptAt,
    });

class $$OutboxEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get scheduledAt => $composableBuilder(
    column: $table.scheduledAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastAttemptAt => $composableBuilder(
    column: $table.lastAttemptAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OutboxEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get scheduledAt => $composableBuilder(
    column: $table.scheduledAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastAttemptAt => $composableBuilder(
    column: $table.lastAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OutboxEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<DateTime> get scheduledAt => $composableBuilder(
    column: $table.scheduledAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastAttemptAt => $composableBuilder(
    column: $table.lastAttemptAt,
    builder: (column) => column,
  );
}

class $$OutboxEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OutboxEntriesTable,
          DbOutboxEntry,
          $$OutboxEntriesTableFilterComposer,
          $$OutboxEntriesTableOrderingComposer,
          $$OutboxEntriesTableAnnotationComposer,
          $$OutboxEntriesTableCreateCompanionBuilder,
          $$OutboxEntriesTableUpdateCompanionBuilder,
          (
            DbOutboxEntry,
            BaseReferences<_$AppDatabase, $OutboxEntriesTable, DbOutboxEntry>,
          ),
          DbOutboxEntry,
          PrefetchHooks Function()
        > {
  $$OutboxEntriesTableTableManager(_$AppDatabase db, $OutboxEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<DateTime?> scheduledAt = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> lastAttemptAt = const Value.absent(),
              }) => OutboxEntriesCompanion(
                id: id,
                profileId: profileId,
                payloadJson: payloadJson,
                status: status,
                attempts: attempts,
                lastError: lastError,
                scheduledAt: scheduledAt,
                createdAt: createdAt,
                lastAttemptAt: lastAttemptAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String profileId,
                required String payloadJson,
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<DateTime?> scheduledAt = const Value.absent(),
                required DateTime createdAt,
                Value<DateTime?> lastAttemptAt = const Value.absent(),
              }) => OutboxEntriesCompanion.insert(
                id: id,
                profileId: profileId,
                payloadJson: payloadJson,
                status: status,
                attempts: attempts,
                lastError: lastError,
                scheduledAt: scheduledAt,
                createdAt: createdAt,
                lastAttemptAt: lastAttemptAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$OutboxEntriesTable, DbOutboxEntry>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $OutboxEntriesTable,
                    DbOutboxEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OutboxEntriesTable,
      DbOutboxEntry,
      $$OutboxEntriesTableFilterComposer,
      $$OutboxEntriesTableOrderingComposer,
      $$OutboxEntriesTableAnnotationComposer,
      $$OutboxEntriesTableCreateCompanionBuilder,
      $$OutboxEntriesTableUpdateCompanionBuilder,
      (
        DbOutboxEntry,
        BaseReferences<_$AppDatabase, $OutboxEntriesTable, DbOutboxEntry>,
      ),
      DbOutboxEntry,
      PrefetchHooks Function()
    >;
typedef $$RecipientsHistoryTableCreateCompanionBuilder =
    RecipientsHistoryCompanion Function({
      required String profileId,
      required String address,
      Value<String> name,
      Value<DateTime?> usedAt,
      Value<int> useCount,
      Value<int> rowid,
    });
typedef $$RecipientsHistoryTableUpdateCompanionBuilder =
    RecipientsHistoryCompanion Function({
      Value<String> profileId,
      Value<String> address,
      Value<String> name,
      Value<DateTime?> usedAt,
      Value<int> useCount,
      Value<int> rowid,
    });

class $$RecipientsHistoryTableFilterComposer
    extends Composer<_$AppDatabase, $RecipientsHistoryTable> {
  $$RecipientsHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get usedAt => $composableBuilder(
    column: $table.usedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get useCount => $composableBuilder(
    column: $table.useCount,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecipientsHistoryTableOrderingComposer
    extends Composer<_$AppDatabase, $RecipientsHistoryTable> {
  $$RecipientsHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get usedAt => $composableBuilder(
    column: $table.usedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get useCount => $composableBuilder(
    column: $table.useCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecipientsHistoryTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecipientsHistoryTable> {
  $$RecipientsHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get usedAt =>
      $composableBuilder(column: $table.usedAt, builder: (column) => column);

  GeneratedColumn<int> get useCount =>
      $composableBuilder(column: $table.useCount, builder: (column) => column);
}

class $$RecipientsHistoryTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecipientsHistoryTable,
          DbRecipientHistory,
          $$RecipientsHistoryTableFilterComposer,
          $$RecipientsHistoryTableOrderingComposer,
          $$RecipientsHistoryTableAnnotationComposer,
          $$RecipientsHistoryTableCreateCompanionBuilder,
          $$RecipientsHistoryTableUpdateCompanionBuilder,
          (
            DbRecipientHistory,
            BaseReferences<
              _$AppDatabase,
              $RecipientsHistoryTable,
              DbRecipientHistory
            >,
          ),
          DbRecipientHistory,
          PrefetchHooks Function()
        > {
  $$RecipientsHistoryTableTableManager(
    _$AppDatabase db,
    $RecipientsHistoryTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecipientsHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecipientsHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecipientsHistoryTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> address = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<DateTime?> usedAt = const Value.absent(),
                Value<int> useCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecipientsHistoryCompanion(
                profileId: profileId,
                address: address,
                name: name,
                usedAt: usedAt,
                useCount: useCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String address,
                Value<String> name = const Value.absent(),
                Value<DateTime?> usedAt = const Value.absent(),
                Value<int> useCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecipientsHistoryCompanion.insert(
                profileId: profileId,
                address: address,
                name: name,
                usedAt: usedAt,
                useCount: useCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecipientsHistoryTable, DbRecipientHistory>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $RecipientsHistoryTable,
                    DbRecipientHistory
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecipientsHistoryTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecipientsHistoryTable,
      DbRecipientHistory,
      $$RecipientsHistoryTableFilterComposer,
      $$RecipientsHistoryTableOrderingComposer,
      $$RecipientsHistoryTableAnnotationComposer,
      $$RecipientsHistoryTableCreateCompanionBuilder,
      $$RecipientsHistoryTableUpdateCompanionBuilder,
      (
        DbRecipientHistory,
        BaseReferences<
          _$AppDatabase,
          $RecipientsHistoryTable,
          DbRecipientHistory
        >,
      ),
      DbRecipientHistory,
      PrefetchHooks Function()
    >;
typedef $$DraftsTableCreateCompanionBuilder =
    DraftsCompanion Function({
      Value<int> id,
      required String profileId,
      Value<String> accountEmail,
      Value<String> recipientsJson,
      Value<String> subject,
      Value<String> content,
      Value<String> attachmentPathsJson,
      required DateTime updatedAt,
    });
typedef $$DraftsTableUpdateCompanionBuilder =
    DraftsCompanion Function({
      Value<int> id,
      Value<String> profileId,
      Value<String> accountEmail,
      Value<String> recipientsJson,
      Value<String> subject,
      Value<String> content,
      Value<String> attachmentPathsJson,
      Value<DateTime> updatedAt,
    });

class $$DraftsTableFilterComposer
    extends Composer<_$AppDatabase, $DraftsTable> {
  $$DraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountEmail => $composableBuilder(
    column: $table.accountEmail,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attachmentPathsJson => $composableBuilder(
    column: $table.attachmentPathsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DraftsTableOrderingComposer
    extends Composer<_$AppDatabase, $DraftsTable> {
  $$DraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountEmail => $composableBuilder(
    column: $table.accountEmail,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attachmentPathsJson => $composableBuilder(
    column: $table.attachmentPathsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DraftsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DraftsTable> {
  $$DraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get accountEmail => $composableBuilder(
    column: $table.accountEmail,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get attachmentPathsJson => $composableBuilder(
    column: $table.attachmentPathsJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DraftsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DraftsTable,
          DbDraft,
          $$DraftsTableFilterComposer,
          $$DraftsTableOrderingComposer,
          $$DraftsTableAnnotationComposer,
          $$DraftsTableCreateCompanionBuilder,
          $$DraftsTableUpdateCompanionBuilder,
          (DbDraft, BaseReferences<_$AppDatabase, $DraftsTable, DbDraft>),
          DbDraft,
          PrefetchHooks Function()
        > {
  $$DraftsTableTableManager(_$AppDatabase db, $DraftsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                Value<String> accountEmail = const Value.absent(),
                Value<String> recipientsJson = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> attachmentPathsJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => DraftsCompanion(
                id: id,
                profileId: profileId,
                accountEmail: accountEmail,
                recipientsJson: recipientsJson,
                subject: subject,
                content: content,
                attachmentPathsJson: attachmentPathsJson,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String profileId,
                Value<String> accountEmail = const Value.absent(),
                Value<String> recipientsJson = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> attachmentPathsJson = const Value.absent(),
                required DateTime updatedAt,
              }) => DraftsCompanion.insert(
                id: id,
                profileId: profileId,
                accountEmail: accountEmail,
                recipientsJson: recipientsJson,
                subject: subject,
                content: content,
                attachmentPathsJson: attachmentPathsJson,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DraftsTable, DbDraft>(table),
                  BaseReferences<_$AppDatabase, $DraftsTable, DbDraft>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DraftsTable,
      DbDraft,
      $$DraftsTableFilterComposer,
      $$DraftsTableOrderingComposer,
      $$DraftsTableAnnotationComposer,
      $$DraftsTableCreateCompanionBuilder,
      $$DraftsTableUpdateCompanionBuilder,
      (DbDraft, BaseReferences<_$AppDatabase, $DraftsTable, DbDraft>),
      DbDraft,
      PrefetchHooks Function()
    >;
typedef $$RemindersTableCreateCompanionBuilder =
    RemindersCompanion Function({
      Value<int> id,
      required String profileId,
      required int emailId,
      Value<String> subject,
      Value<String> sender,
      required DateTime remindAt,
      required DateTime createdAt,
      Value<DateTime?> firedAt,
    });
typedef $$RemindersTableUpdateCompanionBuilder =
    RemindersCompanion Function({
      Value<int> id,
      Value<String> profileId,
      Value<int> emailId,
      Value<String> subject,
      Value<String> sender,
      Value<DateTime> remindAt,
      Value<DateTime> createdAt,
      Value<DateTime?> firedAt,
    });

class $$RemindersTableFilterComposer
    extends Composer<_$AppDatabase, $RemindersTable> {
  $$RemindersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sender => $composableBuilder(
    column: $table.sender,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get remindAt => $composableBuilder(
    column: $table.remindAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get firedAt => $composableBuilder(
    column: $table.firedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RemindersTableOrderingComposer
    extends Composer<_$AppDatabase, $RemindersTable> {
  $$RemindersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sender => $composableBuilder(
    column: $table.sender,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get remindAt => $composableBuilder(
    column: $table.remindAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get firedAt => $composableBuilder(
    column: $table.firedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RemindersTableAnnotationComposer
    extends Composer<_$AppDatabase, $RemindersTable> {
  $$RemindersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<int> get emailId =>
      $composableBuilder(column: $table.emailId, builder: (column) => column);

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get sender =>
      $composableBuilder(column: $table.sender, builder: (column) => column);

  GeneratedColumn<DateTime> get remindAt =>
      $composableBuilder(column: $table.remindAt, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get firedAt =>
      $composableBuilder(column: $table.firedAt, builder: (column) => column);
}

class $$RemindersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RemindersTable,
          DbReminder,
          $$RemindersTableFilterComposer,
          $$RemindersTableOrderingComposer,
          $$RemindersTableAnnotationComposer,
          $$RemindersTableCreateCompanionBuilder,
          $$RemindersTableUpdateCompanionBuilder,
          (
            DbReminder,
            BaseReferences<_$AppDatabase, $RemindersTable, DbReminder>,
          ),
          DbReminder,
          PrefetchHooks Function()
        > {
  $$RemindersTableTableManager(_$AppDatabase db, $RemindersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RemindersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RemindersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RemindersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                Value<int> emailId = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> sender = const Value.absent(),
                Value<DateTime> remindAt = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> firedAt = const Value.absent(),
              }) => RemindersCompanion(
                id: id,
                profileId: profileId,
                emailId: emailId,
                subject: subject,
                sender: sender,
                remindAt: remindAt,
                createdAt: createdAt,
                firedAt: firedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String profileId,
                required int emailId,
                Value<String> subject = const Value.absent(),
                Value<String> sender = const Value.absent(),
                required DateTime remindAt,
                required DateTime createdAt,
                Value<DateTime?> firedAt = const Value.absent(),
              }) => RemindersCompanion.insert(
                id: id,
                profileId: profileId,
                emailId: emailId,
                subject: subject,
                sender: sender,
                remindAt: remindAt,
                createdAt: createdAt,
                firedAt: firedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RemindersTable, DbReminder>(table),
                  BaseReferences<_$AppDatabase, $RemindersTable, DbReminder>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RemindersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RemindersTable,
      DbReminder,
      $$RemindersTableFilterComposer,
      $$RemindersTableOrderingComposer,
      $$RemindersTableAnnotationComposer,
      $$RemindersTableCreateCompanionBuilder,
      $$RemindersTableUpdateCompanionBuilder,
      (DbReminder, BaseReferences<_$AppDatabase, $RemindersTable, DbReminder>),
      DbReminder,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$CapabilitiesTableTableManager get capabilities =>
      $$CapabilitiesTableTableManager(_db, _db.capabilities);
  $$MailboxesTableTableManager get mailboxes =>
      $$MailboxesTableTableManager(_db, _db.mailboxes);
  $$MailsTableTableManager get mails =>
      $$MailsTableTableManager(_db, _db.mails);
  $$AttachmentsTableTableManager get attachments =>
      $$AttachmentsTableTableManager(_db, _db.attachments);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$OutboxEntriesTableTableManager get outboxEntries =>
      $$OutboxEntriesTableTableManager(_db, _db.outboxEntries);
  $$RecipientsHistoryTableTableManager get recipientsHistory =>
      $$RecipientsHistoryTableTableManager(_db, _db.recipientsHistory);
  $$DraftsTableTableManager get drafts =>
      $$DraftsTableTableManager(_db, _db.drafts);
  $$RemindersTableTableManager get reminders =>
      $$RemindersTableTableManager(_db, _db.reminders);
}
