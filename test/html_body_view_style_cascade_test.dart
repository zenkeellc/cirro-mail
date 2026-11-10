import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 真实邮件回归：Apple「The new iPad mini is here.」那封。
///
/// 这封邮件为了同时伺候桌面与手机，把**同一份头部内容写了两遍**：
///
/// ```html
/// <td class="m8">
///   <span class="m7"><img alt="Apple" …></span><!-- 手机版 -->
///   <span class="n11"><img alt="Apple" … class="m27"></span><!-- 桌面版 -->
/// </td>
/// ```
///
/// 浏览器靠 `<style>` 里的 `.m7{display:none!important}` 藏掉手机版；我们的
/// 渲染器（`flutter_widget_from_html_core`）不解析 `<style>`，于是**两份都画
/// 出来**，用户看到「Apple Apple」「iPad mini iPad mini」。
///
/// fixture 是从这封真实邮件里原样裁下来的：11 个 `<style>` 块 + 头部那段表格
/// （一个字节没改，只补了外层 `html`/`body` 与承载 `.m8` 的表格）。三张图
/// （Apple logo / iPad mini 字标 / 产品图）在正文里各出现两次，样式表要求只留
/// 桌面那一份。
///
/// 断言走「放行外联资源」这条路（`allowedHosts`），数的是
/// `CachedNetworkImage`：默认拦截时每份都变成 `BlockedImageTile`，而那个占位块
/// 在 61px 高的图上会溢出 1px（**修复前后都有**的既有问题，与本用例无关，见
/// 交付说明），会把这条用例染红、掩盖真正要验的东西。放行后 fwfh 只为**每个
/// 可见的** `<img>` 建一个网络图 widget，数的东西更干净。
///
/// 网络图在 widget 测试里不会真的画完（`path_provider` 的 future 永远不完成），
/// 所以只 `pump` 固定帧、**不 `pumpAndSettle`**（会挂住）。
void main() {
  final html = File(
    'test/fixtures/apple_ipad_mini_dup.html',
  ).readAsStringSync();

  Future<void> pumpBody(WidgetTester tester, String body) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HtmlBodyView(
              html: body,
              ossBase: 'https://mail.example.com/api/oss/',
              shrinkWrap: true,
              allowedHosts: const <String>['www.apple.com'],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  List<String> imageUrls(WidgetTester tester) => tester
      .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
      .map((image) => image.imageUrl)
      .toList();

  testWidgets('样式表藏掉的手机版头部不会重复渲染', (tester) async {
    await pumpBody(tester, html);
    expect(tester.takeException(), isNull);

    final urls = imageUrls(tester);
    final lockups =
        urls.where((url) => url.contains('hero_lockup_2x.jpg')).length;
    final logos = urls
        .where((url) => url.contains('apple_logo_circle_1d1d1f-f5f5f7'))
        .length;

    // 正文里各有两份（手机版 + 桌面版），样式表要求只留一份。
    expect(lockups, 1, reason: '「iPad mini」字标渲染了 $lockups 份，应只有桌面版');
    expect(logos, 1, reason: 'Apple logo 渲染了 $logos 份，应只有桌面版');

    // 藏掉的只是重复的那一份，桌面版必须还在 —— 三张图都在。
    expect(urls.length, 3, reason: '可见图片应正好三张：$urls');
  });

  testWidgets('没有 <style> 的正文不受影响（同样的两份内容照旧都画）', (
    tester,
  ) async {
    // 反证：把样式表摘掉，用例 1 的「只留一份」就不该成立 —— 否则说明
    // 断言数错了东西（比如 fwfh 根本没把第二份建出来）。
    final noStyles = html.replaceAll(
      RegExp(r'<style[^>]*>[\s\S]*?</style\s*>', caseSensitive: false),
      '',
    );
    expect(noStyles, isNot(contains('<style')));

    await pumpBody(tester, noStyles);
    expect(tester.takeException(), isNull);

    final urls = imageUrls(tester);
    expect(
      urls.where((url) => url.contains('hero_lockup_2x.jpg')).length,
      2,
      reason: '没有样式表可依据时，手机版 + 桌面版都该画出来',
    );
  });
}
