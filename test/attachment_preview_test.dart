import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/features/attachment/attachment_preview.dart';
import 'package:mail_app/features/attachment/viewers/audio_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/csv_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/docx_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/local_image_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/pdf_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/pptx_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/text_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/video_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/xlsx_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

MailAttachment _att(String filename, {int size = 1024, String? mimeType}) =>
    MailAttachment(attId: 1, filename: filename, mimeType: mimeType, size: size);

/// 每个平台都过一遍。`flutter test` 的默认平台是 android，所以显式传
/// [TargetPlatform]（同 `attachment_kind_test.dart`）。
const _platforms = <TargetPlatform>[
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
];

/// 跑测试的这台机器有没有 PDF 渲染后端。
///
/// **不能拿 [defaultTargetPlatform] 判**：`flutter test` 会把运行时的值
/// 按住成 android（`_platform_io.dart` 里那句 `FLUTTER_TEST` 断言）。所以
/// 问到的是「像不像 android」，而不是「是不是 linux」。
bool get _hostSupportsPdf => !Platform.isLinux;

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: child,
    );

void main() {
  group('canPreview：第三道拦在「有没有 viewer」上', () {
    test('已经有 viewer 的类型在各自能跑的平台上都能预览', () {
      const files = <String>[
        'notes.txt',
        'data.csv',
        'README.md',
        'report.docx',
        'book.xlsx',
        'deck.pptx',
        'voice.m4a',
        'photo.png',
        'a.pdf',
      ];
      for (final name in files) {
        for (final platform in _platforms) {
          // PDF 在 Linux 上没有后端，这一条由 `ViewerSupport.pdf` 判 ——
          // 见另外那个测试文件，这里只排掉它。
          if (name.endsWith('.pdf') && platform == TargetPlatform.linux) {
            continue;
          }
          expect(
            canPreview(_att(name), platform: platform),
            isTrue,
            reason: '$name @ $platform',
          );
        }
      }
    });

    test('压缩包与未知类型没有 viewer，所以不给「预览」', () {
      for (final platform in _platforms) {
        expect(canPreview(_att('a.zip'), platform: platform), isFalse);
        expect(canPreview(_att('a.doc'), platform: platform), isFalse);
        expect(canPreview(_att('blob.bin'), platform: platform), isFalse);
      }
    });

    test('视频只在 macOS / iOS / Android 上有预览', () {
      expect(
        canPreview(_att('clip.mp4'), platform: TargetPlatform.macOS),
        isTrue,
      );
      expect(
        canPreview(_att('clip.mp4'), platform: TargetPlatform.windows),
        isFalse,
      );
      expect(
        canPreview(_att('clip.mp4'), platform: TargetPlatform.linux),
        isFalse,
      );
    });

    test('超限的附件不管 viewer 有没有都判 false', () {
      expect(
        canPreview(
          _att('big.xlsx', size: 20 * 1024 * 1024 + 1),
          platform: TargetPlatform.macOS,
        ),
        isFalse,
      );
    });
  });

  group('分发器落到正确的页面', () {
    /// 推一次预览，然后断言栈顶出现的是 [T]。
    ///
    /// 不读 `route.builder` 的返回值（那要自己造 element），直接看页面树上
    /// 有没有那个 widget。**每个用例结束前要把推上去的那一页弹回来** ——
    /// 同一个用例里第二次 `pumpWidget` 会复用同一个 `Navigator`，上一次推的
    /// 页面还盖在上面，底下的按钮点不着（`tap` 会警告「hit test 不到」，
    /// 于是什么也没发生）。
    Future<void> expectLands<T extends Widget>(
      WidgetTester tester,
      String filename,
    ) async {
      await tester.pumpWidget(_host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => openAttachmentPreview(
              Navigator.of(context),
              path: '/nonexistent/definitely/not/here',
              title: filename,
              attachment: _att(filename),
            ),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      // 目标页面读盘会失败并给出「文件不在了」—— 我们只关心**落在哪一页**。
      // 用 `pump` 推进几帧就够（`pumpAndSettle` 会卡在等待期内那个无限动画上）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(T), findsOneWidget, reason: filename);

      // 收尾：弹回去，给同一用例里的下一次推页腾出位置。
      // `NavigatorState.pop` 返回 void —— 不 await。返回动画要**走完**，
      // 否则退场中的那一页还盖在上面，下一次 `tap` 打在它身上（hit test
      // 不到底下的按钮，于是什么也不发生）。这里不能用 `pumpAndSettle`：
      // 被推上去的页面里有个转圈动画永远不停。
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    testWidgets('文本 / Markdown 走同一个 viewer', (tester) async {
      await expectLands<TextViewerScreen>(tester, 'notes.txt');
      await expectLands<TextViewerScreen>(tester, 'README.md');
    });

    testWidgets('CSV / docx / xlsx / pptx 各就各位', (tester) async {
      await expectLands<CsvViewerScreen>(tester, 'data.csv');
      await expectLands<DocxViewerScreen>(tester, 'r.docx');
      await expectLands<XlsxViewerScreen>(tester, 'b.xlsx');
      await expectLands<PptxViewerScreen>(tester, 'd.pptx');
    });

    testWidgets(
      '图片 / PDF / 音频 / 视频各就各位',
      (tester) async {
        await expectLands<LocalImageViewerScreen>(tester, 'p.png');
        await expectLands<PdfViewerScreen>(tester, 'a.pdf');
        await expectLands<AudioViewerScreen>(tester, 'v.m4a');
        await expectLands<VideoViewerScreen>(tester, 'c.mp4');
      },
      // 这一条与上面那组 `canPreview` 不同：它真的 push 页面进去，于是
      // `pdfx` 会走一遍 `assertHasPdfSupport()` —— 那里读的是**真平台**，
      // 不是上面那个恒为 android 的 `defaultTargetPlatform`。Linux 上
      // `pdfx` 没有渲染后端（它的平台表里就没有 linux），于是
      // `PdfDocument.openFile` 抛 `PlatformNotSupportedException`，CI 的
      // ubuntu 跑必红；而 `ViewerSupport.pdf` 早就判了 Linux 不支持，真机
      // 上这一页在那平台上根本走不到。所以这里如实跳过，而不是去断言一个
      // 到达不了的落点。`skip` 只要 bool —— 理由写在注释里。
      skip: !_hostSupportsPdf,
    );

    testWidgets('octet-stream 的 .png 也落到图片页（扩展名兜底那一半）', (tester) async {
      await tester.pumpWidget(_host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => openAttachmentPreview(
              Navigator.of(context),
              path: '/nonexistent/definitely/not/here',
              title: 'photo.png',
              attachment: _att(
                'photo.png',
                mimeType: 'application/octet-stream',
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(LocalImageViewerScreen), findsOneWidget);
    });
  });
}
