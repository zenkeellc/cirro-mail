import 'package:flutter/material.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/editor/snippet_insert.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组钉的是**解码的健壮性**：设置读不出来不该让写信页打不开。
/// 形状抄 `PrefsStore.instanceColors` 那套（`prefs_store.dart:151`）——
/// 「垃圾输入退回默认、绝不抛」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('签名', () {
    test('没存过时是空表', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PrefsStore(await SharedPreferences.getInstance());
      expect(store.signatures, isEmpty);
    });

    test('按发件邮箱各存一份', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PrefsStore(await SharedPreferences.getInstance());
      await store.setSignature('a@b.com', '张三\n公司');
      await store.setSignature('c@d.com', '李四');

      expect(store.signatureFor('a@b.com'), '张三\n公司');
      expect(store.signatureFor('c@d.com'), '李四');
      expect(store.signatureFor('nobody@x.com'), isEmpty,
          reason: '没配过的地址给空串，不是 null —— 调用方不用再判空');
    });

    test('空串 = 删掉这一条，不是存一个空签名', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = PrefsStore(prefs);
      await store.setSignature('a@b.com', '张三');
      await store.setSignature('a@b.com', '');
      expect(store.signatureFor('a@b.com'), isEmpty);
      // **必须断言底层存储，不能只断言 getter** —— `signatures` getter 自己
      // 会把空串那一条过滤掉，所以「存一个 `"a@b.com": ""`」这种实现
      // 也能让 `signatures.containsKey` 那条断言绿（变异实测过：
      // 把 `setSignature` 改成恒写，用例全绿）。
      expect(prefs.getString('cm_signatures'), isNot(contains('a@b.com')),
          reason: '删键 = 存储里真的没有它，不是留着一条空串靠 getter 兜');
    });

    test('存进去的是垃圾也不抛，退回空表', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_signatures': '这不是 JSON',
      });
      final store = PrefsStore(await SharedPreferences.getInstance());
      expect(store.signatures, isEmpty);
    });

    test('值不是字符串时跳过那一条，别的照读', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_signatures': '{"a@b.com": 42, "c@d.com": "李四"}',
      });
      final store = PrefsStore(await SharedPreferences.getInstance());
      expect(store.signatureFor('a@b.com'), isEmpty);
      expect(store.signatureFor('c@d.com'), '李四');
    });
  });

  group('常用语', () {
    test('按发件邮箱各存一组，顺序保留', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PrefsStore(await SharedPreferences.getInstance());
      await store.setPhrases('a@b.com', const <WritingSnippet>[
        WritingSnippet(id: '1', name: '开头的自我介绍', text: '我是…'),
        WritingSnippet(id: '2', name: '约时间', text: '方便的话…'),
      ]);

      final list = store.phrasesFor('a@b.com');
      expect(list.map((s) => s.id), <String>['1', '2']);
      expect(list.first.name, '开头的自我介绍');
      expect(list.first.text, '我是…');
      expect(store.phrasesFor('nobody@x.com'), isEmpty);

      // 第二个地址 —— 只写一个地址的话，「各存一组」没被钉住：
      // 把 `setPhrases` 改成每次清空整表，用例照样全绿（变异实测）。
      await store.setPhrases('c@d.com', const <WritingSnippet>[
        WritingSnippet(id: '9', name: '别的', text: '别的正文'),
      ]);
      expect(store.phrasesFor('a@b.com').length, 2, reason: '写 B 不该动到 A');
      expect(store.phrasesFor('c@d.com').single.id, '9');
    });

    test('空组 = 删掉这个地址', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = PrefsStore(prefs);
      await store.setPhrases('a@b.com', const <WritingSnippet>[
        WritingSnippet(id: '1', name: 'n', text: 't'),
      ]);
      await store.setPhrases('a@b.com', const <WritingSnippet>[]);
      expect(store.phrasesFor('a@b.com'), isEmpty);
      // 同「签名」那条：只断 getter 不够 —— getter 会把空组过滤掉。
      // 必须断底层存储，才能钉住「空组 = 真的删键」。
      expect(prefs.getString('cm_phrases'), isNot(contains('a@b.com')));
    });

    test('存进去的是垃圾也不抛', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_phrases': '[1,2,3]',
      });
      final store = PrefsStore(await SharedPreferences.getInstance());
      expect(store.phrasesFor('a@b.com'), isEmpty);
    });

    test('某一条缺字段时跳过那一条，别的照读', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_phrases':
            '{"a@b.com": [{"id":"1"}, {"id":"2","name":"约时间","text":"方便的话"}]}',
      });
      final store = PrefsStore(await SharedPreferences.getInstance());
      final list = store.phrasesFor('a@b.com');
      expect(list.length, 1);
      expect(list.single.id, '2');
    });

    test('返回的列表一律不可变 —— 缺地址与已有地址行为一致', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PrefsStore(await SharedPreferences.getInstance());
      await store.setPhrases('a@b.com', const <WritingSnippet>[
        WritingSnippet(id: '1', name: 'n', text: 't'),
      ]);

      // 「缺地址」走共享的 `const []`，「已有地址」走 getter 新建的 list。
      // 两支的可变性必须一致，否则同一个调用方行为随「存没存过」而变：
      // `.add()` 在一个地址抛、在另一个地址静默成功且不落盘。
      expect(() => store.phrasesFor('nobody@x.com').add(
            const WritingSnippet(id: 'x', name: 'x', text: 'x'),
          ), throwsUnsupportedError);
      expect(() => store.phrasesFor('a@b.com').add(
            const WritingSnippet(id: 'x', name: 'x', text: 'x'),
          ), throwsUnsupportedError);
    });
  });

  group('WritingSnippet', () {
    const a = WritingSnippet(id: '1', name: '约时间', text: '方便的话…');

    test('== / hashCode：内容相同即相等，不同即不等', () {
      // 故意不用 `const` 构造 aCopy —— const 会被 canonicalize 成同一个实例，
      // 那样 `identical` 也能让下面全绿，== 其实没被钉住。
      final a = WritingSnippet(id: '1', name: '约时间', text: '方便的话…');
      final aCopy = WritingSnippet(id: '1', name: '约时间', text: '方便的话…');
      final b = WritingSnippet(id: '2', name: '别的', text: '别的正文');

      expect(identical(a, aCopy), isFalse,
          reason: '两份是不同实例，才钉得住 == 而不是 identical');
      // Set 同时钉住 == 与 hashCode：相等的两份必须并成 1，不同的留 2。
      expect(<WritingSnippet>{a, aCopy, b}.length, 2);
      expect(<WritingSnippet>{a, aCopy}.length, 1);
      expect(a, aCopy);
      expect(a.hashCode, aCopy.hashCode);
      expect(a, isNot(b));
    });

    test('toJson → fromJson 往返', () {
      final round = WritingSnippet.fromJson(a.toJson());
      expect(round, a);
    });

    test('fromJson：非 Map / 缺字段 / 字段类型不对都给 null，不抛', () {
      expect(WritingSnippet.fromJson(null), isNull);
      expect(WritingSnippet.fromJson('不是 Map'), isNull);
      expect(WritingSnippet.fromJson(<String, dynamic>{}), isNull);
      expect(
        WritingSnippet.fromJson(<String, dynamic>{'id': '1', 'name': 'n'}),
        isNull,
      );
      expect(
        WritingSnippet.fromJson(
          <String, dynamic>{'id': 1, 'name': 'n', 'text': 't'},
        ),
        isNull,
      );
    });
  });

  group('插入到光标处', () {
    test('空文档：整段插进去，光标落在末尾', () {
      final c = q.QuillController(
        document: q.Document()..insert(0, '\n'),
        selection: const TextSelection.collapsed(offset: 0),
      );
      addTearDown(c.dispose);

      insertSnippet(c, '张三\n公司');

      expect(c.document.toPlainText().trim(), '张三\n公司');
      // 光标在文本之后（+1 是收尾那个 `\n`）。
      expect(c.selection.baseOffset, '张三\n公司'.length + 1);
    });

    test('标题行上插入不带残留的块级属性', () {
      final c = q.QuillController(
        document: q.Document.fromJson(<dynamic>[
          {'insert': '标题'},
          {
            'insert': '\n',
            'attributes': <String, dynamic>{'header': 1},
          },
        ]),
        selection: const TextSelection.collapsed(offset: 0),
      );
      addTearDown(c.dispose);

      insertSnippet(c, '签名一\n签名二');

      final ops = c.document.toDelta().toJson();
      final hasHeader = ops.any((op) {
        final attrs = op['attributes'];
        return attrs is Map && attrs['header'] != null;
      });
      expect(hasHeader, isFalse,
          reason: '插入走的清块级那一步没生效 —— 标题属性留在新段落上了');
      expect(c.document.toPlainText(), contains('签名一'));
      expect(c.document.toPlainText(), contains('标题'));
    });

    test('列表行上插入，新段落不是列表项', () {
      final c = q.QuillController(
        document: q.Document.fromJson(<dynamic>[
          {'insert': '一项'},
          {
            'insert': '\n',
            'attributes': <String, dynamic>{'list': 'bullet'},
          },
        ]),
        selection: const TextSelection.collapsed(offset: 0),
      );
      addTearDown(c.dispose);

      insertSnippet(c, '签名');

      final ops = c.document.toDelta().toJson();
      // 初版这里写的是 `ops.toString(), contains('"list":"bullet"')` —— 恒为假：
      // Dart 的 `Map.toString()` 是 `{list: bullet}`，键上根本没有引号。
      // 而且走到 `insertParagraphText` 时，被清的是**「当前行」整行**的块级
      // 属性（不只是新来的段落），所以插入后整篇都不该再剩 `list`。
      // 从 Map 里取属性、断言「一条都不剩」，才是这条用例真正要钉的东西。
      final withList = ops.whereType<Map>().where((op) {
        final attrs = op['attributes'];
        return attrs is Map && attrs['list'] != null;
      });
      // 绕过去直接 `replaceText`（不清块级）时，原来那行的 `list` 会留着，
      // 这条就红 —— 变异实测过。
      expect(withList, isEmpty,
          reason: '插入没走「先清块级属性」那一步，list 留在了原来那行上');
      expect(c.document.toPlainText(), contains('一项'),
          reason: '清的是块级属性，不该把原来那行的文字一起弄没');
      // 新来的那一段**不**继承 list。
      final added = ops.whereType<Map>().where((op) =>
          op['insert'] is String && (op['insert'] as String).contains('签名'));
      expect(added.length, 1);
      expect(added.single['attributes'], isNull);
    });

    /// **光标在行中间时，不能把这一行已经打了的字吃掉。**
    ///
    /// 这条是必须的：`insertParagraphText` 干的是
    /// `replaceText(line.start, line.text.length, '$text\n')` —— 它换掉的是
    /// **整行文字**，不是「光标处插入」。而它眼里的「整行」是 `SlashCommand`
    /// 给的 `line.text`：`getPlainText(0, caret)` 在最后一个 `\n` 处切出来的
    /// 那半段，也就是**光标之前**的文字，`replaceText` 覆盖 `[line.start, caret)`。
    /// 所以修之前，光标停在一行中间点「签名」会静默吞掉**光标之前的字**，
    /// 光标之后的字不在这个范围里、反而活下来。实测（修之前）：
    /// 文档 `好的，我看看。` 光标在 6 → 插完只剩 `张三\n公司\n。\n`，
    /// 「好的，我看」全没了、「。」还在。
    ///
    /// 更常见的一击是**行尾**：点段落末尾落在视觉行尾时，编辑器给的是
    /// `document.length - 1` 这个偏移（quill 的选区夹取，
    /// `quill_controller.dart:477`；本仓库是 flutter_quill 11.6.0），
    /// 而 `insertParagraphText` 拿 `line.text` 取的是「光标之前的整段」——
    /// 修之前，写完一句话点签名，**整句话都没了**。
    test('光标在一行中间：光标前后的字都还在', () {
      final c = q.QuillController(
        document: q.Document.fromJson(<dynamic>[
          {'insert': '你好世界\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 2),
      );
      addTearDown(c.dispose);

      insertSnippet(c, '签名');

      expect(c.document.toPlainText(), contains('你好'),
          reason: '光标前的字被「整行替换」吃掉了');
      expect(c.document.toPlainText(), contains('世界'),
          reason: '光标后的字被「整行替换」吃掉了');
      expect(c.document.toPlainText(), contains('签名'));
    });

    test('光标在段落末尾（编辑器给的是 document.length - 1）：整句还在', () {
      final c = q.QuillController(
        document: q.Document.fromJson(<dynamic>[
          {'insert': '好的，我看看。\n'},
        ]),
        // 7 == '好的，我看看。'.length —— 也就是 `document.length - 1`
        // （点段落末尾时编辑器给的就是这个偏移；6 落在「。」之前，那是句中，
        // 不是段尾）。
        selection: const TextSelection.collapsed(offset: 7),
      );
      addTearDown(c.dispose);

      insertSnippet(c, '张三\n公司');

      expect(c.document.toPlainText(), contains('好的，我看看。'),
          reason: '写完一句话点「签名」，那句话必须还在');
    });

    test('空串：一个字节都不动', () {
      final c = q.QuillController(
        document: q.Document.fromJson(<dynamic>[
          {'insert': '你好世界\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 2),
      );
      addTearDown(c.dispose);
      final before = c.document.toPlainText();

      insertSnippet(c, '');

      expect(c.document.toPlainText(), before,
          reason: '空串是 insertSnippet 自己挡的：不挡的话走 '
              'insertParagraphText 会把整行文字换成一个空段落');
    });
  });
}
