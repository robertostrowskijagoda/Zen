import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/profile/presentation/mini_profile.dart';
import 'package:zen/src/features/profile/presentation/profile_photo_viewer.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// A profile photo opens on the whole screen, to be zoomed; a conversation's
/// header opens the whole profile.

const String _ada = 'ada.ygg';

/// A 1x1 PNG.
final Uint8List _png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

SocialHubState _people() => SocialHubState.empty().copyWith(
  book: FriendshipBook.restore(
    profiles: const <String, FriendProfile>{
      _ada: FriendProfile(
        address: _ada,
        displayName: 'Ada',
        status: FriendRelationshipStatus.accepted,
      ),
    },
  ),
);

Widget _app(Widget home) => ProviderScope(
  overrides: [
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(<String, List<ChatMessage>>{
        _ada: <ChatMessage>[
          ChatMessage(
            id: 'm-1',
            sender: _ada,
            text: 'Cześć',
            sentAtMillis: 1000000,
            direction: ChatMessageDirection.incoming,
          ),
        ],
      }),
    ),
    socialHubSeedProvider.overrideWithValue(_people()),
  ],
  child: MaterialApp(home: home),
);

void main() {
  testWidgets('a profile photo opens on the whole screen and zooms', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ZoomableProfilePhoto(
              image: MemoryImage(_png),
              child: const SizedBox(width: 92, height: 92),
            ),
          ),
        ),
      ),
    );
    final SemanticsHandle semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(const Key('profile-photo-open'))),
      containsSemantics(label: 'Zdjęcie profilowe', isButton: true),
      reason: 'a screen reader says what opens',
    );
    semantics.dispose();
    await tester.tap(find.byKey(const Key('profile-photo-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-photo-viewer')), findsOneWidget);
    final InteractiveViewer viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.maxScale, 5);

    // A double tap brings it up around the spot tapped, another one back.
    final Finder photo = find.byType(InteractiveViewer);
    final Rect area = tester.getRect(photo);
    final Offset spot = area.topLeft + const Offset(100, 150);
    await tester.tapAt(spot);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(spot);
    await tester.pumpAndSettle();
    final TransformationController zoom = viewer.transformationController!;
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
    // The spot stays under the finger: it moves by what the zoom added.
    final Offset moved = MatrixUtils.transformPoint(
      zoom.value,
      const Offset(100, 150),
    );
    expect(moved.dx, closeTo(100, 0.5));
    expect(moved.dy, closeTo(150, 0.5));
    await tester.tapAt(spot);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(spot);
    await tester.pumpAndSettle();
    expect(zoom.value, Matrix4.identity());

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-photo-viewer')), findsNothing);
  });

  testWidgets('without a photo (an initial) a tap opens nothing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: ZoomableProfilePhoto(
              image: null,
              child: SizedBox(width: 92, height: 92, child: Text('A')),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('profile-photo-open')), findsNothing);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-photo-viewer')), findsNothing);
  });

  testWidgets('the header of a conversation opens the whole profile, with '
      'no choice of profile or message first', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(const ConversationScreen(peerAddress: _ada, title: 'Ada')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-open-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.byType(MiniProfileSheet), findsNothing, reason: 'no choice');
  });
}
