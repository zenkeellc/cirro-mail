import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/attachment_cache.dart';

/// 附件落盘前的文件名净化。
///
/// 这一组测试的第一条是**安全**测试，不是格式测试：`filename` 是服务端
/// （也就是邮件发送方）给的值，`../../../../etc/passwd` 这种名字如果直接
/// 拼进路径，就是把写文件的位置交给了对方。
///
/// 后面几条来自真实邮件里见过的名字：Windows 保留名、超长、纯点、
/// control 字符、URL 编码残留 —— 它们不会泄漏什么，但会让「下载成功」
/// 变成「文件不知道去哪了」。
void main() {
  group('目录穿越', () {
    test('POSIX 相对路径只取最后一段', () {
      expect(AttachmentCache.sanitize('../../../../etc/passwd'), 'passwd');
      expect(AttachmentCache.sanitize('a/b/c.png'), 'c.png');
      expect(AttachmentCache.sanitize('/etc/shadow'), 'shadow');
    });

    test('Windows 反斜杠同样是分隔符', () {
      expect(AttachmentCache.sanitize(r'..\..\windows\system32\cmd.exe'),
          'cmd.exe');
      expect(AttachmentCache.sanitize(r'C:\Users\me\.ssh\id_rsa'), 'id_rsa');
    });

    test('只剩点或斜杠的名字退化成固定名，而不是空串', () {
      expect(AttachmentCache.sanitize('..'), 'attachment');
      expect(AttachmentCache.sanitize('///'), 'attachment');
      expect(AttachmentCache.sanitize('...'), 'attachment');
      expect(AttachmentCache.sanitize('   '), 'attachment');
      expect(AttachmentCache.sanitize(''), 'attachment');
    });
  });

  group('平台兼容', () {
    test('Windows 保留名加前缀（CON.png 在 Windows 上会写失败）', () {
      expect(AttachmentCache.sanitize('CON'), '_CON');
      expect(AttachmentCache.sanitize('nul.txt'), '_nul.txt');
      expect(AttachmentCache.sanitize('COM1.pdf'), '_COM1.pdf');
      // 只是开头相同、不是保留名的，不要误伤。
      expect(AttachmentCache.sanitize('CONTRACT.pdf'), 'CONTRACT.pdf');
    });

    test('Windows 非法字符换成下划线', () {
      expect(AttachmentCache.sanitize('a<b>c:d"e|f?g*h.txt'), 'a_b_c_d_e_f_g_h.txt');
    });

    test('首尾的点与空格去掉（Windows 会静默丢掉，导致文件名对不上）', () {
      expect(AttachmentCache.sanitize('  报告.pdf  '), '报告.pdf');
      expect(AttachmentCache.sanitize('.hidden.txt'), 'hidden.txt');
    });

    test('控制字符被剥掉', () {
      expect(AttachmentCache.sanitize('a\u0000b\u001fc.txt'), 'abc.txt');
    });
  });

  group('长度与扩展名', () {
    test('超长名字按 UTF-8 字节截断并保住扩展名', () {
      // 中文一个字符 3 字节：200 个字符 = 600 字节，必须被截。
      final long = '${'中' * 200}.pdf';
      final safe = AttachmentCache.sanitize(long);
      expect(safe.endsWith('.pdf'), isTrue);
      expect(safe.runes.length, lessThan(200));
      // 截断后仍要是合法文件名（不能只剩半截）。
      expect(safe, isNotEmpty);
    });

    test('扩展名识别', () {
      expect(AttachmentCache.extensionOf('a.PDF'), '.pdf');
      expect(AttachmentCache.extensionOf('a.tar.gz'), '.gz');
      expect(AttachmentCache.extensionOf('noext'), '');
      expect(AttachmentCache.extensionOf('trailing.'), '');
    });
  });

  group('URL 编码残留', () {
    test('带空格的编码名字会被解码（很多客户端这么发）', () {
      expect(AttachmentCache.sanitize('%E6%8A%A5%E5%91%8A.pdf'), '报告.pdf');
      expect(AttachmentCache.sanitize('my%20file.pdf'), 'my file.pdf');
    });

    test('含空格的普通名字不会被误当成编码（解码会把 % 吃掉）', () {
      expect(AttachmentCache.sanitize('100% 完成.pdf'), '100% 完成.pdf');
    });

    test('编不出来（畸形 %）就保持原样，不该抛异常', () {
      expect(AttachmentCache.sanitize('a%ZZb.pdf'), 'a%ZZb.pdf');
      expect(AttachmentCache.sanitize('%'), '%');
    });
  });
}
