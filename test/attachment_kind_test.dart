import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/features/attachment/attachment_kind.dart';

MailAttachment _att(
  String filename, {
  String? mimeType,
  int size = 1024,
}) =>
    MailAttachment(
      attId: 1,
      filename: filename,
      mimeType: mimeType,
      size: size,
    );

/// 每个平台都过一遍。`flutter test` 的默认平台是 android，所以显式传
/// [TargetPlatform]，不依赖 `defaultTargetPlatform`。
const _platforms = <TargetPlatform>[
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
];

/// 「这五类在这五个平台上都行」—— 写一次，省得五行重复。
const _everywhere = <String>[
  'notes.txt',
  'data.csv',
  'README.md',
  'report.docx',
  'book.xlsx',
  'deck.pptx',
  'voice.m4a',
];

void main() {
  group('iconOf：看得到扩展名才分得清', () {
    // 这一组的重点在于：**光有 octet-stream 是不够的**。
    // 服务端在 S3/KV 后端上只会给这个值，图标必须靠文件名兜底。
    test('octet-stream 的 .png 是图片图标，不是通用文件图标', () {
      final icon = iconOf(
        _att('photo.png', mimeType: 'application/octet-stream'),
      );
      expect(icon, Icons.image_outlined);
      expect(icon, isNot(Icons.insert_drive_file_outlined));
    });

    test('octet-stream 的 .zip 与 .png 不是同一个图标', () {
      final zip = iconOf(
        _att('backup.zip', mimeType: 'application/octet-stream'),
      );
      final png = iconOf(
        _att('photo.png', mimeType: 'application/octet-stream'),
      );
      expect(zip, Icons.folder_zip_outlined);
      expect(zip, isNot(png));
    });

    test('pdf / docx / xlsx / pptx / 音频 / 视频 各有各的图标', () {
      final src = <String, IconData>{
        'a.pdf': Icons.picture_as_pdf_outlined,
        'a.docx': Icons.description_outlined,
        'a.xlsx': Icons.table_chart_outlined,
        'a.pptx': Icons.slideshow_outlined,
        'a.mp3': Icons.audiotrack_outlined,
        'a.mp4': Icons.movie_outlined,
      };
      for (final entry in src.entries) {
        expect(iconOf(_att(entry.key)), entry.value, reason: entry.key);
      }
      // 六个图标两两不同 —— 否则「各有各的」是假的。
      expect(src.values.toSet().length, src.length);
    });

    test('csv 与 xlsx 共用一个表格图标', () {
      expect(iconOf(_att('a.csv')), iconOf(_att('a.xlsx')));
    });

    test('文本与 markdown 共用一个文章图标', () {
      expect(iconOf(_att('a.txt')), iconOf(_att('a.md')));
    });
  });

  group('ViewerSupport.supports：平台矩阵', () {
    test('文本 / CSV / markdown / 图片 / Office 三件套 / 音频：五平台都行', () {
      for (final platform in _platforms) {
        for (final name in _everywhere) {
          final kind = AttachmentMime.kindOf(
            AttachmentMime.of(_att(name)),
            filename: name,
          );
          expect(
            ViewerSupport.supports(kind, platform),
            isTrue,
            reason: '$name @ $platform',
          );
        }
      }
    });

    test('图片五平台都行', () {
      for (final platform in _platforms) {
        expect(
          ViewerSupport.supports(AttachmentKind.image, platform),
          isTrue,
          reason: '$platform',
        );
      }
    });

    test('PDF 只有 Linux 不行（pdfx 没有 linux 实现）', () {
      for (final platform in _platforms) {
        expect(
          ViewerSupport.supports(AttachmentKind.pdf, platform),
          platform != TargetPlatform.linux,
          reason: '$platform',
        );
      }
    });

    test('视频只有 android / iOS / macOS 行', () {
      for (final platform in _platforms) {
        expect(
          ViewerSupport.supports(AttachmentKind.video, platform),
          platform == TargetPlatform.android ||
              platform == TargetPlatform.iOS ||
              platform == TargetPlatform.macOS,
          reason: '$platform',
        );
      }
    });

    test('压缩包与未知类型哪个平台都不提供预览', () {
      for (final platform in _platforms) {
        for (final kind in <AttachmentKind>[
          AttachmentKind.archive,
          AttachmentKind.other,
        ]) {
          expect(
            ViewerSupport.supports(kind, platform),
            isFalse,
            reason: '$kind @ $platform',
          );
        }
      }
    });
  });

  group('previewableOn：类型 / 体积 / 平台三道都得过', () {
    test('普通文本到处都能预览', () {
      for (final platform in _platforms) {
        expect(
          previewableOn(_att('notes.txt'), platform: platform),
          isTrue,
          reason: '$platform',
        );
      }
    });

    test('mp4 在 windows / linux 上不能预览，在 macOS 上能', () {
      expect(
        previewableOn(_att('clip.mp4'), platform: TargetPlatform.windows),
        isFalse,
      );
      expect(
        previewableOn(_att('clip.mp4'), platform: TargetPlatform.linux),
        isFalse,
      );
      expect(
        previewableOn(_att('clip.mp4'), platform: TargetPlatform.macOS),
        isTrue,
      );
    });

    test('PDF 在 Linux 上不能预览 —— 不是「点了失败」而是那一行不出现', () {
      expect(
        previewableOn(_att('a.pdf'), platform: TargetPlatform.linux),
        isFalse,
      );
      expect(
        previewableOn(_att('a.pdf'), platform: TargetPlatform.macOS),
        isTrue,
      );
    });

    test('超过 20MB 的 docx 一律不能预览（与平台无关）', () {
      final huge = _att('big.docx', size: 20 * 1024 * 1024 + 1);
      for (final platform in _platforms) {
        expect(previewableOn(huge, platform: platform), isFalse);
      }
    });

    test('octet-stream + .png 的附件在 macOS 上仍能预览（走扩展名兜底）', () {
      // bug B/D 的验收：只看 mimeType 的话这里会判成「不能预览」。
      expect(
        previewableOn(
          _att('photo.png', mimeType: 'application/octet-stream'),
          platform: TargetPlatform.macOS,
        ),
        isTrue,
      );
    });

    test('zip 不能预览', () {
      expect(previewableOn(_att('a.zip'), platform: TargetPlatform.macOS), isFalse);
    });
  });

  group('formatAttachmentSize', () {
    test('分档', () {
      expect(formatAttachmentSize(0), '');
      expect(formatAttachmentSize(512), '512 B');
      expect(formatAttachmentSize(2048), '2 KB');
      expect(formatAttachmentSize(1536 * 1024), '1.5 MB');
      expect(formatAttachmentSize(2 * 1024 * 1024 * 1024), '2.00 GB');
    });
  });
}
