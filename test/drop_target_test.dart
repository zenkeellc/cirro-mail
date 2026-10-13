import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/drop_target.dart';

/// 把一条「平台 → Dart」的方法调用塞进 `desktop_drop` 那条 channel。
/// 这就是拖放真实到达 Dart 侧的路径（`DesktopDrop._handleMethodChannel`），
/// 比直接调私有回调真实得多 —— 它顺带验证了「事件的名字与参数形状没接错」。
Future<void> emit(
  WidgetTester tester,
  String method,
  Object? arguments,
) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// 一次完整的「拖进来 → 悬停 → 松手」。[at] 是视口坐标。
Future<void> dropFiles(
  WidgetTester tester,
  List<String> paths, {
  Offset at = const Offset(20, 20),
}) async {
  await emit(tester, 'entered', [at.dx, at.dy]);
  await emit(tester, 'performOperation', paths);
}

Widget host({required Widget child, bool enabled = true}) => MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: MailDropTarget(
            enabled: enabled,
            onDrop: (_) {},
            child: child,
          ),
        ),
      ),
    );

void main() {
  group('DropClassifier', () {
    test('按扩展名分图片（桌面端 mimeType 一律是 null）', () {
      final items = <DropItem>[
        DropItemFile('/tmp/photo.PNG'),
        DropItemFile('/tmp/report.pdf'),
        DropItemFile('/tmp/pic.jpeg'),
        DropItemFile('/tmp/notes.txt'),
        DropItemFile('/tmp/anim.gif'),
      ];
      expect(
        DropClassifier.images(items).map((i) => i.name),
        ['photo.PNG', 'pic.jpeg', 'anim.gif'],
      );
      expect(
        DropClassifier.attachments(items).map((i) => i.name),
        ['report.pdf', 'notes.txt'],
      );
    });

    test('目录两边都不算 —— 读它会抛 PathNotFoundException', () {
      final items = <DropItem>[
        DropItemDirectory('/tmp/somedir', const []),
        DropItemFile('/tmp/a.png'),
      ];
      expect(DropClassifier.images(items).map((i) => i.name), ['a.png']);
      expect(DropClassifier.attachments(items), isEmpty);
      expect(DropClassifier.hasIgnoredDirectories(items), isTrue);
    });

    test('没有目录时不报「忽略了目录」', () {
      expect(
        DropClassifier.hasIgnoredDirectories([DropItemFile('/tmp/a.png')]),
        isFalse,
      );
    });

    test('未知后缀 → 附件（宁可进附件，也不要插一张打不开的图）', () {
      final items = <DropItem>[DropItemFile('/tmp/mystery')];
      expect(DropClassifier.images(items), isEmpty);
      expect(DropClassifier.attachments(items).length, 1);
    });
  });

  group('MailDropTarget', () {
    testWidgets('拖进来 → 出提示；拖走 → 提示消失', (tester) async {
      await tester.pumpWidget(host(child: const Text('正文')));
      expect(find.text('松手，图片会插进正文'), findsNothing);

      await emit(tester, 'entered', [10.0, 10.0]);
      expect(find.text('松手，图片会插进正文'), findsOneWidget);

      await emit(tester, 'exited', null);
      expect(find.text('松手，图片会插进正文'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('悬停遮罩不吃指针事件（否则松手那一下会被它吞掉）', (tester) async {
      await tester.pumpWidget(host(child: const Text('正文')));
      await emit(tester, 'entered', [10.0, 10.0]);
      // 遮罩本身就得是 `IgnorePointer`，而且**真的在忽略** —— 挂个
      // `ignoring: false` 的壳子等于没做，测试也照样过。
      final overlay = tester.widget<IgnorePointer>(
        find.byKey(dropOverlayKey),
      );
      expect(overlay.ignoring, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('松手 → onDrop 拿到文件，且悬停态清掉', (tester) async {
      final seen = <DropDoneDetails>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: MailDropTarget(
              onDrop: seen.add,
              child: const Text('正文'),
            ),
          ),
        ),
      ));
      await dropFiles(tester, ['/tmp/a.png']);
      expect(seen, hasLength(1));
      expect(seen.single.files.map((f) => f.path), ['/tmp/a.png']);
      // 松手后遮罩必须收掉，否则它一直盖着正文。
      expect(find.text('松手，图片会插进正文'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('enabled=false → 一个事件都不收（页面被盖住时的保护）', (tester) async {
      final seen = <DropDoneDetails>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: MailDropTarget(
              enabled: false,
              onDrop: seen.add,
              child: const Text('正文'),
            ),
          ),
        ),
      ));
      await dropFiles(tester, ['/tmp/a.png']);
      expect(seen, isEmpty);
      expect(find.text('松手，图片会插进正文'), findsNothing);
    });
  });

  group('dropOffsetInDocument', () {
    testWidgets('松手位置换算成文档偏移；滚下去之后坐标要跟着走', (tester) async {
      final editorKey = GlobalKey<q.EditorState>();
      final controller = q.QuillController(
        document: q.Document.fromJson([
          {'insert': '第一行\n'},
          {'insert': '第二行\n'},
          {'insert': '第三行\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 60,
            child: q.QuillEditor(
              controller: controller,
              focusNode: FocusNode(),
              scrollController: ScrollController(),
              config: q.QuillEditorConfig(editorKey: editorKey),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 编辑器视口顶部那一小块 → 文档前几个字符。
      final top = dropOffsetInDocument(
        localPosition: const Offset(4, 2),
        editorState: editorKey,
        scrollOffset: 0,
      );
      expect(top, isNotNull);
      expect(top!, lessThan(6));

      // 同一处落点，但内容整体上滚 40 像素 → 偏移必须增大（落到了后面的字上）。
      final scrolled = dropOffsetInDocument(
        localPosition: const Offset(4, 2),
        editorState: editorKey,
        scrollOffset: 40,
      );
      expect(scrolled, isNotNull);
      expect(scrolled!, greaterThan(top));
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('拿不到几何信息 → null（调用方退回光标处）', (tester) async {
      expect(
        dropOffsetInDocument(
          localPosition: Offset.zero,
          editorState: GlobalKey<q.EditorState>(),
          scrollOffset: 0,
        ),
        isNull,
      );
    });
  });
}
