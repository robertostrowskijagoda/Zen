import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

void main() {
  testWidgets('the editor opens a post with its photo and can take it out', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final DraftMedia photo = DraftMedia(
      bytes: _png(),
      mime: 'image/jpeg',
      stored: const <String, dynamic>{'id': 'x'},
    );
    PostDraft? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          editing: true,
          initialText: 'Przed\n{{media:0}}\nPo',
          initialMedia: <DraftMedia>[photo],
          onSubmit: (PostDraft d) async {
            saved = d;
            return null;
          },
        ),
      ),
    );
    await tester.pump();
    FilledButton save() =>
        tester.widget<FilledButton>(find.byKey(const Key('post-publish')));
    // The photo is in place, not a "{{media:0}}" line, and nothing changed.
    expect(find.byKey(const Key('post-media-remove-0')), findsOneWidget);
    expect(find.textContaining('{{media'), findsNothing);
    expect(save().onPressed, isNull);
    // Photo and video tools are there when editing too.
    expect(find.byKey(const Key('post-tool-photo')), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-media-remove-0')));
    await tester.pump();
    expect(save().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('post-publish')));
    await tester.pump();
    expect(saved!.media, isEmpty);
    expect(saved!.text, contains('Przed'));
    expect(saved!.text, contains('Po'));
    expect(saved!.text, isNot(contains('{{media')));
  });

  testWidgets('own posts are edited and deleted from the profile', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(ProfileScreen)),
    );
    final LedgerNode node = container.read(ledgerNodeProvider)!;
    for (int i = 0; i < 20 && !node.isReady; i++) {
      await tester.runAsync(() => _settle());
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Published from the test's own (fake) zone, like the app does: the
    // ledger already wrote from there, so a write from runAsync would wait
    // on it forever.
    final Future<LogEntry> publishing = () async {
      final Map<String, dynamic> photo = await storeMedia(node.blobs, _png());
      return node.publish(
        kPostKind,
        newPostBody(
          'Stary tekst\n{{media:0}}',
          images: <Map<String, dynamic>>[photo],
        ),
        blobs: mediaIds(<Map<String, dynamic>>[photo]),
      );
    }();
    Future<void> until(bool Function() done) async {
      for (int i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => _settle());
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await until(() => find.text('Stary tekst').evaluate().isNotEmpty);
    final String id = (await publishing).id;
    Future<void> settle() async {
      // No pumpAndSettle: a photo may still be loading (a spinner).
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.byKey(Key('profile-post-menu-$id')));
    await settle();
    await tester.tap(find.byKey(const Key('profile-post-edit')));
    await until(
      () => find.byKey(const Key('post-editor')).evaluate().isNotEmpty,
    );
    await settle(); // the editor slides in
    expect(find.byKey(const Key('post-media-remove-0')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('post-text')), 'Nowy tekst');
    await tester.pump();
    await tester.tap(find.byKey(const Key('post-publish')));
    await until(
      () =>
          find.byKey(const Key('post-editor')).evaluate().isEmpty &&
          find.text('Nowy tekst').evaluate().isNotEmpty,
    );
    expect(find.text('Nowy tekst'), findsOneWidget);
    expect(find.textContaining('edytowano'), findsOneWidget);
    // The photo stayed.
    final FeedPost edited = buildFeed(
      node,
      nameOf: (_) => '',
    ).firstWhere((FeedPost p) => p.id == id);
    expect(edited.images, hasLength(1));

    await tester.tap(find.byKey(Key('profile-post-menu-$id')));
    await settle();
    await tester.tap(find.byKey(const Key('profile-post-delete')));
    await settle();
    await tester.tap(find.byKey(const Key('feed-delete-confirm')));
    await until(() => find.text('Nowy tekst').evaluate().isEmpty);
    expect(find.text('Nowy tekst'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });
}
