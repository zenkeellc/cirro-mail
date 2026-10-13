import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **为什么读文本**：`analysis_options.yaml` 把 `android/**` 排除了，manifest
/// 不进 `flutter analyze`、也不在 widget 树里，跑不了任何行为测试。而这颗雷
/// 的表现是**静默失败**（通知永远不弹、日志里什么都没有），所以「钉住那几行
/// 文字还在」比「什么都不钉」强得多。
void main() {
  late String manifest;

  setUpAll(() {
    manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  });

  test('RECEIVE_BOOT_COMPLETED 在（没有它重启后排期全丢）', () {
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
  });

  test('USE_EXACT_ALARM 在（应用自己声明，不需要运行时申请）', () {
    expect(manifest, contains('android.permission.USE_EXACT_ALARM'));
  });

  test('**没有** SCHEDULE_EXACT_ALARM（两条同时声明会被 Play 判成滥用）', () {
    expect(manifest, isNot(contains('android.permission.SCHEDULE_EXACT_ALARM')));
  });

  test('两条 receiver 都在（接收排期 + 开机后重建排期）', () {
    expect(
      manifest,
      contains(
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver',
      ),
    );
    expect(
      manifest,
      contains(
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver',
      ),
    );
  });

  test('BootReceiver 的 intent-filter 认 BOOT_COMPLETED 与 MY_PACKAGE_REPLACED', () {
    expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
    expect(manifest, contains('android.intent.action.MY_PACKAGE_REPLACED'));
    // HTC 那个变体：插件 README 的四条 action 里的第四条，漏了它某些国产 ROM
    // 快速开机后就收不到广播、排期照样丢。
    expect(manifest, contains('com.htc.intent.action.QUICKBOOT_POWERON'));
  });

  test('权限写在 <application> 之前（写在里面 Android 不认）', () {
    final permission = manifest.indexOf('RECEIVE_BOOT_COMPLETED');
    final application = manifest.indexOf('<application');
    expect(permission, greaterThanOrEqualTo(0));
    expect(permission, lessThan(application));
  });

  test('两条 receiver 写在 <application> 之内', () {
    final open = manifest.indexOf('<application');
    final close = manifest.indexOf('</application>');
    final receiver = manifest.indexOf('ScheduledNotificationReceiver');
    expect(receiver, greaterThan(open));
    expect(receiver, lessThan(close));
  });
}
