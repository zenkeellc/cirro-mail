import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/util/attachment_mime.dart';
import 'package:mail_app/data/models/mail_attachment.dart';

/// 一个只填判定要用到的字段的附件。
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

void main() {
  group('声明值优先', () {
    test('服务端给了明确类型就用它', () {
      expect(
        AttachmentMime.of(_att('a.bin', mimeType: 'application/pdf')),
        'application/pdf',
      );
    });

    test('但没有扩展名时，声明值也认', () {
      expect(
        AttachmentMime.of(_att('noext', mimeType: 'image/png')),
        'image/png',
      );
    });

    test('窄字段名 + 明确声明，不吃扩展名那一层', () {
      // `.csv` 的扩展名规则只影响 kind，不改 mime。
      expect(
        AttachmentMime.of(_att('a.csv', mimeType: 'text/tab-separated-values')),
        'text/tab-separated-values',
      );
    });
  });

  group('octet-stream 必须被扩展名覆盖', () {
    // 这两条是这次改动的**核心理由**：S3/KV 后端的下载头永远是
    // `application/octet-stream`，只看声明值的话，图片会显示成通用文件。
    test('声明的 octet-stream 被 .png 覆盖', () {
      expect(
        AttachmentMime.of(_att('photo.png', mimeType: 'application/octet-stream')),
        'image/png',
      );
    });

    test('binary/octet-stream 同理', () {
      expect(
        AttachmentMime.of(_att('doc.pdf', mimeType: 'binary/octet-stream')),
        'application/pdf',
      );
    });

    test('声明为空串也走扩展名', () {
      expect(AttachmentMime.of(_att('a.txt', mimeType: '')), 'text/plain');
    });

    test('没有声明、没有扩展名 → 通用兜底', () {
      expect(
        AttachmentMime.of(_att('README')),
        'application/octet-stream',
      );
    });
  });

  group('package:mime 认不出来的那几个（补丁表）', () {
    // `mime` 2.1.0 的 `extensionToMedia` 里确实没有 docx / pptx / yaml / yml。
    test('docx', () {
      expect(
        AttachmentMime.of(_att('合同.docx')),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    });

    test('pptx', () {
      expect(
        AttachmentMime.of(_att('deck.pptx')),
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
    });

    test('yaml / yml', () {
      expect(AttachmentMime.of(_att('ci.yml')), 'text/yaml');
      expect(AttachmentMime.of(_att('ci.yaml')), 'text/yaml');
    });

    test('补丁表没有把已经有的一起重写（xlsx 走 package:mime）', () {
      expect(
        AttachmentMime.of(_att('book.xlsx')),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    });
  });

  group('kindOf：扩展名在少数冲突上胜出', () {
    test('text/plain 的 .csv 仍是 csv（否则表格渲染不出来）', () {
      expect(
        AttachmentMime.kindOf('text/plain', filename: 'data.csv'),
        AttachmentKind.csv,
      );
    });

    test('octet-stream 的 .csv 仍是 csv', () {
      expect(
        AttachmentMime.kindOf('application/octet-stream', filename: 'data.csv'),
        AttachmentKind.csv,
      );
    });

    test('.tsv 与 .csv 同类', () {
      expect(
        AttachmentMime.kindOf('application/octet-stream', filename: 'a.tsv'),
        AttachmentKind.csv,
      );
    });

    test('.md 是 markdown 而不是普通文本', () {
      expect(
        AttachmentMime.kindOf('text/plain', filename: 'README.md'),
        AttachmentKind.markdown,
      );
    });

    test('没有扩展名时才轮到 mime 说话', () {
      expect(
        AttachmentMime.kindOf('text/csv', filename: 'noext'),
        AttachmentKind.csv,
      );
      expect(
        AttachmentMime.kindOf('text/plain', filename: 'noext'),
        AttachmentKind.text,
      );
    });
  });

  group('kindOf：mime 主类型', () {
    test('图片 / PDF / 音视频', () {
      expect(AttachmentMime.kindOf('image/webp'), AttachmentKind.image);
      expect(AttachmentMime.kindOf('application/pdf'), AttachmentKind.pdf);
      expect(AttachmentMime.kindOf('audio/mpeg'), AttachmentKind.audio);
      expect(AttachmentMime.kindOf('video/mp4'), AttachmentKind.video);
    });

    test('带参数的 mime 要去掉参数段', () {
      expect(
        AttachmentMime.kindOf('text/plain; charset=gbk'),
        AttachmentKind.text,
      );
      expect(
        AttachmentMime.kindOf('IMAGE/PNG'),
        AttachmentKind.image,
      );
    });

    test('application/ogg 归音频', () {
      expect(AttachmentMime.kindOf('application/ogg'), AttachmentKind.audio);
    });

    test('office 三件套的 mime 落到对应 kind（扩展名缺失时）', () {
      expect(
        AttachmentMime.kindOf(
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        AttachmentKind.docx,
      );
      expect(
        AttachmentMime.kindOf(
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        AttachmentKind.xlsx,
      );
      expect(
        AttachmentMime.kindOf(
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        ),
        AttachmentKind.pptx,
      );
    });
  });

  group('kindOf：其余分类', () {
    test('代码 / 配置类当文本看', () {
      for (final mime in <String>[
        'application/json',
        'application/xml',
        'application/rtf',
        'message/rfc822',
      ]) {
        expect(AttachmentMime.kindOf(mime), AttachmentKind.text, reason: mime);
      }
    });

    test('zip / gz / 老版 office 二进制都不是可预览文档', () {
      expect(AttachmentMime.kindOf('application/zip'), AttachmentKind.archive);
      expect(
        AttachmentMime.kindOf('application/msword'),
        AttachmentKind.other,
      );
      expect(
        AttachmentMime.kindOf('application/vnd.ms-excel'),
        AttachmentKind.other,
      );
    });

    test('不认识的一律 other', () {
      expect(
        AttachmentMime.kindOf('application/x-msdownload'),
        AttachmentKind.other,
      );
      expect(AttachmentMime.kindOf(''), AttachmentKind.other);
    });
  });

  group('体积上限', () {
    test('超过 20MB 的文档不提供预览', () {
      expect(
        AttachmentMime.previewable(
          kind: AttachmentKind.text,
          size: 20 * 1024 * 1024 + 1,
        ),
        isFalse,
      );
      expect(
        AttachmentMime.previewable(
          kind: AttachmentKind.text,
          size: 20 * 1024 * 1024,
        ),
        isTrue,
      );
    });

    test('zip 与未知类型本来就不提供预览，与体积无关', () {
      for (final kind in <AttachmentKind>[
        AttachmentKind.archive,
        AttachmentKind.other,
      ]) {
        expect(
          AttachmentMime.previewable(kind: kind, size: 1),
          isFalse,
          reason: '$kind',
        );
      }
    });

    test('size 为 0（服务端没给）不算超限', () {
      expect(
        AttachmentMime.previewable(kind: AttachmentKind.pdf, size: 0),
        isTrue,
      );
    });
  });

  group('kindFor / of 组合', () {
    test('octet-stream + .png → image', () {
      expect(
        AttachmentMime.kindFor(
          _att('photo.png', mimeType: 'application/octet-stream'),
        ),
        AttachmentKind.image,
      );
    });

    test('没有 filename 时用 displayName 的兜底名 —— 不该抛', () {
      expect(
        AttachmentMime.kindFor(const MailAttachment(attId: 7)),
        AttachmentKind.other,
      );
    });
  });
}
