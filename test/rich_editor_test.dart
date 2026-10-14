import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/feed/presentation/rich_post_body.dart';
import 'package:zen/src/features/feed/presentation/rich_text_controller.dart';
import 'package:zen/src/features/feed/rich_text.dart';

String _visible(String s) => visibleRuns(s).map((RichRun r) => r.text).join();

void main() {
  group('inline formatting', () {
    test('covers the source exactly and drops markers when shown', () {
      const String src =
          'Hej **gruby** i *krzywy*, __pod__ ~~skreśl~~ `kod` ||tajne||';
      expect(parseInline(src).map((RichRun r) => r.text).join(), src);
      expect(_visible(src), 'Hej gruby i krzywy, pod skreśl kod tajne');
      final List<RichRun> runs = visibleRuns(src);
      expect(runs.firstWhere((RichRun r) => r.text == 'gruby').bold, isTrue);
      expect(runs.firstWhere((RichRun r) => r.text == 'krzywy').italic, isTrue);
      expect(runs.firstWhere((RichRun r) => r.text == 'pod').underline, isTrue);
      expect(runs.firstWhere((RichRun r) => r.text == 'skreśl').strike, isTrue);
      expect(runs.firstWhere((RichRun r) => r.text == 'kod').code, isTrue);
      expect(runs.firstWhere((RichRun r) => r.text == 'tajne').spoiler, isTrue);
    });

    test('nested, unclosed, escaped and snake_case stay sane', () {
      expect(_visible('***oba***'), 'oba');
      final RichRun both = visibleRuns('***oba***').single;
      expect(both.bold && both.italic, isTrue);
      expect(
        _visible('2 * 3 = 6 i *nie zamknięte'),
        '2 * 3 = 6 i *nie zamknięte',
      );
      expect(_visible(r'\*nie kursywa\*'), '*nie kursywa*');
      expect(_visible('plik_moj_nowy.txt'), 'plik_moj_nowy.txt');
      expect(_visible('**a\nb**'), '**a\nb**');
    });

    test('links are found', () {
      final List<RichRun> runs = visibleRuns(
        'Zobacz https://zen.example/a?b=1.',
      );
      expect(
        runs.where((RichRun r) => r.link).single.text,
        'https://zen.example/a?b=1',
      );
    });
  });

  test('blocks: headings, quotes, lists, code and media', () {
    final List<RichBlock> b = parseBlocks(
      '# Tytuł\nZwykły tekst\n> cytat\n- jeden\n- dwa\n1. pierwszy\n'
      '{{media:0}}\n```\nkod();\n```\nKoniec',
    );
    expect(b.map((RichBlock x) => x.type).toList(), <RichBlockType>[
      RichBlockType.heading,
      RichBlockType.paragraph,
      RichBlockType.quote,
      RichBlockType.bullet,
      RichBlockType.bullet,
      RichBlockType.numbered,
      RichBlockType.media,
      RichBlockType.code,
      RichBlockType.paragraph,
    ]);
    expect(b[6].media, 0);
    expect(b[7].text, 'kod();');
    expect(referencedMedia('a\n{{media:1}}\n{{media:0}}'), <int>[1, 0]);
    expect(plainText('**Hej**\n{{media:0}}'), 'Hej\n[zdjęcie]');
  });

  test('controller toggles wrapping and line prefixes', () {
    final RichTextController c = RichTextController(text: 'Ala ma kota');
    c.selection = const TextSelection(baseOffset: 4, extentOffset: 6);
    c.toggleWrap('**');
    expect(c.text, 'Ala **ma** kota');
    c.toggleWrap('**');
    expect(c.text, 'Ala ma kota');
    c.selection = const TextSelection.collapsed(offset: 0);
    c.toggleLinePrefix('# ');
    expect(c.text, '# Ala ma kota');
    c.toggleLinePrefix('- ');
    expect(c.text, '- Ala ma kota');
    c.dispose();
  });

  testWidgets(
    'editor formats from the toolbar and puts a photo at the cursor',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 30)),
      );
      PostDraft? sent;
      await tester.pumpWidget(
        MaterialApp(
          home: PostEditorScreen(
            pickPhotos: () async => <Uint8List>[png],
            onSubmit: (PostDraft d) async {
              sent = d;
              return null;
            },
          ),
        ),
      );
      await tester.pump();
      final Finder field = find.byKey(const Key('post-text'));
      await tester.enterText(field, 'Przed zdjęciem\nPo zdjęciu');
      final TextField tf = tester.widget<TextField>(field);
      tf.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.tap(find.byKey(const Key('post-tool-bold')));
      await tester.pump();
      expect(tf.controller!.text, '**Przed** zdjęciem\nPo zdjęciu');

      // Cursor at the end of the first line, then a photo.
      tf.controller!.selection = const TextSelection.collapsed(offset: 18);
      await tester.tap(find.byKey(const Key('post-tool-photo')));
      for (int i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find
            .byKey(const Key('post-media-remove-0'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const Key('post-media-remove-0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('post-preview')));
      await tester.pump();
      expect(find.byType(RichPostBody), findsOneWidget);
      await tester.tap(find.byKey(const Key('post-preview')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('post-publish')));
      await tester.pump();
      expect(sent, isNotNull);
      expect(sent!.text, '**Przed** zdjęciem\n{{media:0}}\nPo zdjęciu');
      expect(sent!.media.single.mime, 'image/jpeg');
    },
  );

  testWidgets('removing a photo glues the text back', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 30)),
    );
    PostDraft? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          pickPhotos: () async => <Uint8List>[png],
          onSubmit: (PostDraft d) async {
            sent = d;
            return null;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('post-text')), 'Raz');
    await tester.tap(find.byKey(const Key('post-tool-photo')));
    for (int i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byKey(const Key('post-media-remove-0')).evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.enterText(find.byType(TextField).last, 'Dwa');
    await tester.tap(find.byKey(const Key('post-media-remove-0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('post-publish')));
    await tester.pump();
    expect(sent!.text, 'Raz\nDwa');
    expect(sent!.media, isEmpty);
  });
}
