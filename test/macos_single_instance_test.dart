import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **为什么读文本**：`analysis_options.yaml` 把 `macos/**` 排除了，这些原生文件
/// 不进 `flutter analyze`、也不在 widget 树里，跑不了任何行为测试。而这套东西
/// 漏掉一半的后果是**静默的** —— 多出来的进程不报错，只是抢同一份 SQLite、各
/// 登记一份 FCM token、同一封信弹两遍通知。所以「钉住那几行还在」比什么都不钉
/// 强得多。这里钉的每一条都对应一个**实测过的**失效场景，见各 test 的括号。
///
/// 真实行为验证只能靠真机（`TODO.md` 里记了一条），本文件只是防退化。
/// 下面几条「**没有** xxx」的断言都先在**去注释**的副本上找 —— 这几个文件的
/// 注释里专门写着「不要用 xxx、所以用了 yyy」，不剥注释的话钉子会咬到自己的
/// 说明文字（这坑第一版就踩了）。
void main() {
  late String plist;
  late String appDelegate;
  late String singleInstance;
  late String pbxproj;
  late String mainMenuXib;

  /// 剥掉 `//` 行注释与 `/* … */` 块注释，只留代码。
  String withoutLineComments(String source) => source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  /// 剥掉 `<!-- … -->`，只留 plist 的键值。
  String withoutXmlComments(String source) =>
      source.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  setUpAll(() {
    plist = withoutXmlComments(File('macos/Runner/Info.plist').readAsStringSync());
    appDelegate =
        withoutLineComments(File('macos/Runner/AppDelegate.swift').readAsStringSync());
    singleInstance = withoutLineComments(
      File('macos/Runner/SingleInstance.swift').readAsStringSync(),
    );
    pbxproj =
        File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    mainMenuXib =
        File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
  });

  group('LaunchServices 那条路（点 Dock / Finder 双击 / open / open -n）', () {
    test('Info.plist 有 LSMultipleInstancesProhibited（没有它就 open -n 直接多开一个进程）', () {
      expect(plist, contains('<key>LSMultipleInstancesProhibited</key>'));
      // 键和值挨着，中间只有一个换行 + 缩进 —— 值被挪走或改成 false 都要拦住。
      expect(
        plist,
        contains(
          '<key>LSMultipleInstancesProhibited</key>\n\t<true/>',
        ),
      );
    });

    test('**没有** LSUIElement（它会连 Dock 图标一起收走，而点 Dock 是叫回窗口的既有路径）', () {
      expect(plist, isNot(contains('LSUIElement')));
    });
  });

  group('直接 exec 二进制那条路（flutter run 就是这么起的，plist 管不着）', () {
    test('SingleInstance.swift 用 flock 抢锁（不用 NSDistributedLock / 具名内核对象）', () {
      expect(singleInstance, contains('flock('));
      expect(singleInstance, contains('LOCK_EX'));
      expect(singleInstance, contains('LOCK_NB'));
    });

    test('锁文件在 Application Support 下（不是 /tmp —— 那个会跨用户互相挡）', () {
      expect(singleInstance, contains('Library/Application Support/'));
      expect(singleInstance, isNot(contains('"/tmp')));
    });

    test('AppDelegate 开头有守卫，且失败分支会退出（不退出 = 第二份照样活着）', () {
      expect(appDelegate, contains('SingleInstance.acquireAndWakeIfSecond()'));
      expect(appDelegate, contains('guard'));
      expect(appDelegate, contains('exit('));
    });

    test('守卫在 showMainWindow() 之前（放在后面第二份会先闪一下窗口再退出）', () {
      final guardAt =
          appDelegate.indexOf('SingleInstance.acquireAndWakeIfSecond()');
      // 末尾那次「放首屏」的调用，取守卫之后的第一个 showMainWindow()。
      final showAt = appDelegate.indexOf('showMainWindow()', guardAt);
      expect(guardAt, greaterThanOrEqualTo(0));
      expect(showAt, greaterThan(guardAt));
    });
  });

  group('唤醒对面（关窗之后 App 仍是「前台那个」，activate 不产生任何回调）', () {
    test('投递用 CFNotificationCenterPostNotification（NSDistributedNotificationCenter 会被沙箱静默拦掉）', () {
      expect(singleInstance, contains('CFNotificationCenterPostNotification'));
      expect(singleInstance, contains('CFNotificationCenterGetDistributedCenter'));
      expect(
        singleInstance,
        isNot(contains('NSDistributedNotificationCenter')),
      );
    });

    test('AppDelegate 挂了观察者收这条通知（只观察不需要 entitlement）', () {
      expect(appDelegate, contains('DistributedNotificationCenter.default()'));
      expect(appDelegate, contains('SingleInstance.showWindowNotification'));
    });

    test('发送方与接收方共用同一个通知名常量（各写一份字符串迟早漂）', () {
      expect(singleInstance, contains('com.zenkee.mailapp.show-window'));
      expect(appDelegate, isNot(contains('com.zenkee.mailapp.show-window')));
    });

    test('唤醒还走了 NSRunningApplication.activate 这条主路（对面不在前台时只有它管用）', () {
      expect(singleInstance, contains('NSRunningApplication.runningApplications'));
      expect(singleInstance, contains('activateAllWindows'));
    });
  });

  group('工程登记与首屏时机', () {
    test('SingleInstance.swift 在 Sources 编译段里（漏登记 = Swift 侧根本编不到）', () {
      final sources = pbxproj.substring(
        pbxproj.indexOf('/* Begin PBXSourcesBuildPhase section */'),
        pbxproj.indexOf('/* End PBXSourcesBuildPhase section */'),
      );
      expect(sources, contains('SingleInstance.swift in Sources'));
    });

    test('MainMenu.xib 的窗口是 visibleAtLaunch="NO"（否则 nib 比守卫早约 100ms 先上屏）', () {
      expect(mainMenuXib, contains('visibleAtLaunch="NO"'));
      // 别只钉字符串：那个窗口还得是主窗口那一个。
      final windowAt = mainMenuXib.indexOf('<window ');
      expect(windowAt, greaterThanOrEqualTo(0));
      final line = mainMenuXib.substring(
        windowAt,
        mainMenuXib.indexOf('>', windowAt),
      );
      expect(line, contains('MainFlutterWindow'));
      expect(line, contains('visibleAtLaunch="NO"'));
    });
  });
}
