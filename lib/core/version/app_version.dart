import 'package:flutter/foundation.dart';

/// 「当前运行的是哪个版本」—— 显示、比较、传给更新检查的**唯一**值对象。
///
/// ## 版本号有两个来源，优先级固定
///
/// 1. **构建期注入**（`--dart-define`，见 `tool/version.dart`）：版本名取最近的
///    git tag，build 号 = git 提交数。官方构建（CI / `.release` 脚本 / 包装脚本）
///    走这条路 —— build 号随每次提交单调递增，不需要人手工改 pubspec。
/// 2. **运行时 `PackageInfo`**：直接 `flutter run`、或者没走包装脚本的构建只有
///    这一份（pubspec 的 `0.1.0+1`）。
///
/// 两者都没有时是 [AppVersion.unknown]：界面显示占位符，更新检查不做判断。
@immutable
class AppVersion {
  const AppVersion({
    required this.name,
    this.buildNumber = 0,
    this.commit = '',
    this.builtAt,
    this.channel = 'public',
  });

  /// 什么都不知道的版本。`name` 为空即「未知」。
  static const AppVersion unknown = AppVersion(name: '');

  /// 版本名，例如 `0.1.0`。可能带语义化的预发布标识（`0.1.0-beta.1`），但
  /// **不会带渠道标记** —— tag 上的 `-pro.N` 在 `tool/version.dart` 那一步就
  /// 去掉了（见 `stripChannelMarker`），渠道是单独一项（[channel]）。
  final String name;

  /// 构建号：官方构建里是 `git rev-list --count HEAD`。0 = 不知道。
  final int buildNumber;

  /// 构建产物对应的 git 提交（短 sha）。空串 = 不知道。
  final String commit;

  /// 构建时间（UTC）。null = 不知道。
  final DateTime? builtAt;

  /// 更新渠道：`public`（开源版）/ `pro`（商业版）。构建期注入，默认 public。
  final String channel;

  bool get isKnown => name.isNotEmpty;

  /// 界面上的版本串：`0.1.0+131`；没有 build 号时只有版本名。
  String get display => buildNumber > 0 ? '$name+$buildNumber' : name;

  /// 版本名里的主体版本（`1.2.3` 那段）。解析不出来时返回 [name] 原样。
  String get coreName {
    final parsed = _ParsedVersion.tryParse(name);
    return parsed == null ? name : parsed.coreString;
  }

  /// 比较两个版本：先比主体版本 / 预发布标识（semver 规则），再比 build 号。
  ///
  /// 返回值与 `Comparable` 一致：负数 = 自己更旧，0 = 一样，正数 = 自己更新。
  /// 版本名认不出来时退回字符串比较 —— **不抛**：更新检查宁可给一个保守的
  /// 结论，也不该因为服务端写了个奇怪的版本名就把整条路打挂。
  int compareTo(AppVersion other) {
    final byName = compareVersionNames(name, other.name);
    if (byName != 0) return byName;
    return buildNumber.compareTo(other.buildNumber);
  }

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.name == name &&
      other.buildNumber == buildNumber &&
      other.commit == commit &&
      other.builtAt == builtAt &&
      other.channel == channel;

  @override
  int get hashCode =>
      Object.hash(name, buildNumber, commit, builtAt, channel);

  @override
  String toString() => 'AppVersion($display, commit=$commit, '
      'builtAt=$builtAt, channel=$channel)';
}

/// 只按版本名比较（不含 build 号），供清单/关于页复用。
int compareVersionNames(String a, String b) {
  final x = _ParsedVersion.tryParse(a);
  final y = _ParsedVersion.tryParse(b);
  if (x == null || y == null) return a.compareTo(b).sign;
  return x.compareTo(y).sign;
}

/// semver 的最小解析器：只解析到「比较需要」的粒度。
///
/// 支持的形状：`1`、`1.2`、`1.2.3`、`1.2.3-pre.1`、`v1.2.3`、`1.2.3+build.7`。
/// 解析不了的（`some-branch-name`）交给调用方退回字符串比较。
class _ParsedVersion {
  const _ParsedVersion(this.core, this.pre);

  /// 三段主体版本，缺位补 0。
  final List<int> core;

  /// 预发布标识（`-pre.1` 那一截）。空列表 = 正式版。
  final List<String> pre;

  String get coreString => core.join('.');

  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?'
    r'(?:-([0-9A-Za-z.-]+))?'
    r'(?:\+[0-9A-Za-z.-]+)?$',
  );

  static _ParsedVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    final core = <int>[
      int.parse(match.group(1)!),
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    ];
    final preRaw = match.group(4);
    final pre = (preRaw == null || preRaw.isEmpty)
        ? const <String>[]
        : preRaw.split('.');
    return _ParsedVersion(core, pre);
  }

  int compareTo(_ParsedVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = core[i].compareTo(other.core[i]);
      if (result != 0) return result;
    }
    // semver §11：有预发布标识的版本 < 同主体版本的正式版。
    if (pre.isEmpty && other.pre.isEmpty) return 0;
    if (pre.isEmpty) return 1;
    if (other.pre.isEmpty) return -1;
    final common = pre.length < other.pre.length ? pre.length : other.pre.length;
    for (var i = 0; i < common; i++) {
      final result = _compareIdentifier(pre[i], other.pre[i]);
      if (result != 0) return result;
    }
    // 前缀相同时，标识少的那个更低（`1.0.0-alpha` < `1.0.0-alpha.1`）。
    return pre.length.compareTo(other.pre.length);
  }

  static int _compareIdentifier(String a, String b) {
    final x = int.tryParse(a);
    final y = int.tryParse(b);
    if (x != null && y != null) return x.compareTo(y);
    // 数字标识 < 字母标识（semver §11.4.3）。
    if (x != null) return -1;
    if (y != null) return 1;
    return a.compareTo(b).sign;
  }
}
