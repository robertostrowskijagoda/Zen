import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/text_fit.dart';

/// The send button of a chat composer sits on the centre line of the
/// one-line text field (whose height is exactly the button's place), that
/// line goes through the middle of the letters (between the middle of the
/// small letters and of the capitals), its icon is in the middle of the
/// circle, and the circle is as far from the end of the rounded box as from
/// its top and bottom. For every text size, for faces with a small and a
/// tall ascent and for several line heights. Measured, no goldens.

const GroupProfile _group = GroupProfile(
  id: 'grp-1',
  name: 'Ekipa',
  createdById: 'self',
  createdAtMillis: 1000,
  memberAddresses: <String>['peer-alice'],
);

const List<double> _scales = <double>[0.85, 1, 1.15, 1.3, 1.5, 1.75, 2];

/// The faces measured, with where their small letters and capitals end
/// above the baseline (in ems, from the fonts' own tables); `null` for
/// Ahem, which draws every letter as a full square.
const Map<String, ({double x, double cap})?> _faces =
    <String, ({double x, double cap})?>{
      // The app's own.
      'Hanken Grotesk': (x: 0.493, cap: 0.697),
      'Fredoka': (x: 0.5, cap: 0.7),
      'DM Sans': (x: 0.526, cap: 0.7),
      // A tall ascent (1.12 em), like some phones' own fonts.
      'Space Mono': (x: 0.496, cap: 0.7),
      'Ahem': null,
    };

ThemeData _theme(String face) {
  final ThemeData theme = ZenTheme.dark();
  return theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: face));
}

Widget _chat(String face) => ProviderScope(
  overrides: [
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(),
    ),
    socialHubAutoHydrateProvider.overrideWithValue(false),
    socialHubSeedProvider.overrideWithValue(
      SocialHubState.empty().copyWith(
        friends: const <String, FriendProfile>{
          'ada.ygg': FriendProfile(
            address: 'ada.ygg',
            displayName: 'Ada',
            status: FriendRelationshipStatus.accepted,
          ),
        },
      ),
    ),
  ],
  child: MaterialApp(
    theme: _theme(face),
    home: const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
  ),
);

Widget _groupChat(String face) => ProviderScope(
  overrides: [
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(),
    ),
    socialHubAutoHydrateProvider.overrideWithValue(false),
    socialHubSeedProvider.overrideWithValue(
      SocialHubState.empty().copyWith(
        groups: <String, GroupProfile>{_group.id: _group},
      ),
    ),
  ],
  child: MaterialApp(
    theme: _theme(face),
    home: GroupConversationScreen(groupId: _group.id, groupName: _group.name),
  ),
);

/// The rounded box the composer row is drawn in.
Rect _composerBox(WidgetTester tester, Finder field) {
  final Finder row = find.ancestor(of: field, matching: find.byType(Row)).first;
  return tester.getRect(row);
}

/// The field [field] with the space the composer keeps around it
/// ([ChatComposerMetrics.fieldShift]).
Rect _fieldFrame(WidgetTester tester, Finder field) => tester.getRect(
  find.ancestor(of: field, matching: find.byType(Padding)).first,
);

/// Where the text of [box] stands, on the screen. (Read outside of a
/// layout, as a parent asking for its child's intrinsic sizes would.)
double _baselineOf(RenderBox box) {
  RenderObject.debugCheckingIntrinsics = true;
  try {
    final double distance = box.getDistanceToBaseline(TextBaseline.alphabetic)!;
    return box.localToGlobal(Offset(0, distance)).dy;
  } finally {
    RenderObject.debugCheckingIntrinsics = false;
  }
}

/// Where the text of [field] stands, on the screen.
double _baseline(WidgetTester tester, Finder field) => _baselineOf(
  tester
      .state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .renderEditable,
);

/// Where the text of the hint [text] stands, on the screen.
double _hintBaseline(WidgetTester tester, String text) =>
    _baselineOf(tester.renderObject<RenderParagraph>(find.text(text)));

/// The visible circle of [button]: its Material.
Rect _circle(WidgetTester tester, Finder button) => tester.getRect(
  find.descendant(of: button, matching: find.byType(Material)).first,
);

/// [circle] on the centre line of the one-line [text], which is the
/// button's place; that line through the middle of the letters of a line
/// standing on [baseline] at [scale] in [face].
void _expectOnTheLetters({
  required Rect circle,
  required Rect text,
  required double baseline,
  required double scale,
  required ({double x, double cap})? face,
  required String where,
}) {
  final double size = kChatComposerFontSize * scale;
  expect(
    circle.center.dy,
    closeTo(text.center.dy, 0.5),
    reason: '$where: on the centre line of the field',
  );
  expect(
    circle.center.dy,
    closeTo(baseline - kChatComposerOpticalCentre * size, 0.5),
    reason: '$where: through the middle of the letters',
  );
  if (face != null) {
    expect(
      baseline - face.x / 2 * size,
      greaterThanOrEqualTo(circle.center.dy - 0.5),
      reason: '$where: not above the middle of the small letters',
    );
    expect(
      baseline - face.cap / 2 * size,
      lessThanOrEqualTo(circle.center.dy + 0.5),
      reason: '$where: not below the middle of the capitals',
    );
  }
}

Future<void> _expectCentred(
  WidgetTester tester, {
  required Key fieldKey,
  required Key buttonKey,
  required double scale,
  required ({double x, double cap})? face,
  required String where,
}) async {
  final Finder field = find.byKey(fieldKey);
  final Finder button = find.byKey(buttonKey);
  expect(field, findsOneWidget);
  expect(button, findsOneWidget);

  final Rect circle = _circle(tester, button);
  final Rect icon = tester.getRect(
    find.descendant(of: button, matching: find.byIcon(Icons.send_rounded)),
  );
  final Rect text = _fieldFrame(tester, field);
  final Rect box = _composerBox(tester, field);

  expect(circle.width, closeTo(circle.height, 0.01), reason: '$where: round');
  expect(circle.width, closeTo(kChatComposerSendSize, 0.01));
  expect(icon.center.dx, closeTo(circle.center.dx, 0.5), reason: 'icon x');
  expect(icon.center.dy, closeTo(circle.center.dy, 0.5), reason: 'icon y');
  expect(
    text.height,
    closeTo(box.height, 0.5),
    reason: '$where: one line is the height of the row',
  );
  _expectOnTheLetters(
    circle: circle,
    text: text,
    baseline: _baseline(tester, field),
    scale: scale,
    face: face,
    where: where,
  );
  final double top = circle.top - box.top;
  final double bottom = box.bottom - circle.bottom;
  final double end = box.right - circle.right;
  expect(
    top,
    closeTo(bottom, 0.5),
    reason: '$where: as far from top as bottom',
  );
  expect(end, closeTo(top, 0.5), reason: '$where: as far from end as top');
}

Future<void> _pumpAt(WidgetTester tester, Widget app, double scale) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 500));
}

/// The row of a composer as the screens build it, for a line [height]
/// other than the screens' own.
Widget _row(StrutStyle strut, double scale) {
  return MaterialApp(
    theme: ZenTheme.dark(),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        // Unbounded in height, like the screens' columns.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            Builder(
              builder: (BuildContext context) {
                final ChatComposerMetrics metrics = ChatComposerMetrics.measure(
                  strut,
                  MediaQuery.textScalerOf(context),
                );
                return DecoratedBox(
                  key: const Key('row-box'),
                  decoration: const BoxDecoration(),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Expanded(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: metrics.rowHeight,
                          ),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Padding(
                              padding: metrics.fieldShift,
                              child: TextField(
                                key: const Key('row-field'),
                                minLines: 1,
                                maxLines: 6,
                                strutStyle: metrics.strut,
                                style: metrics
                                    .textStyle(Colors.white)
                                    .copyWith(fontFamily: strut.fontFamily),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: false,
                                  visualDensity: VisualDensity.standard,
                                  border: InputBorder.none,
                                  contentPadding: metrics.fieldPadding(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      metrics.sendSlot(
                        const SizedBox.square(
                          key: Key('row-send'),
                          dimension: kChatComposerSendSize,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadAppFonts);

  for (final MapEntry<String, ({double x, double cap})?> face
      in _faces.entries) {
    group('face ${face.key}', () {
      for (final double scale in _scales) {
        testWidgets('the chat send button is centred at text scale $scale', (
          WidgetTester tester,
        ) async {
          await _pumpAt(tester, _chat(face.key), scale);
          // The hint stands where the text will.
          final Finder field = find.byKey(
            const Key('conversation-composer-field'),
          );
          expect(
            _hintBaseline(tester, 'Wiadomość…'),
            closeTo(_baseline(tester, field), 0.5),
          );
          await _expectCentred(
            tester,
            fieldKey: const Key('conversation-composer-field'),
            buttonKey: const Key('conversation-send-button'),
            scale: scale,
            face: face.value,
            where: 'empty',
          );
          // With a line of text (and an emoji, from another face) it stays
          // put.
          await tester.enterText(field, 'Ćma 😀');
          await tester.pump(const Duration(milliseconds: 300));
          await _expectCentred(
            tester,
            fieldKey: const Key('conversation-composer-field'),
            buttonKey: const Key('conversation-send-button'),
            scale: scale,
            face: face.value,
            where: 'with text',
          );
        });

        testWidgets('the group send button is centred at text scale $scale', (
          WidgetTester tester,
        ) async {
          await _pumpAt(tester, _groupChat(face.key), scale);
          await _expectCentred(
            tester,
            fieldKey: const Key('group-chat-composer-field'),
            buttonKey: const Key('group-chat-send-button'),
            scale: scale,
            face: face.value,
            where: 'group',
          );
          // Its tap target is larger than the circle, around it evenly.
          final Rect target = tester.getRect(
            find.byKey(const Key('group-chat-send-button')),
          );
          final Rect circle = _circle(
            tester,
            find.byKey(const Key('group-chat-send-button')),
          );
          expect(target.width, greaterThanOrEqualTo(kMinInteractiveDimension));
          expect(target.height, greaterThanOrEqualTo(kMinInteractiveDimension));
          expect(target.center.dy, closeTo(circle.center.dy, 0.01));
          // The attach button on the same line.
          final Rect attach = tester.getRect(
            find.byKey(const Key('group-chat-attach-button')),
          );
          expect(attach.center.dy, closeTo(circle.center.dy, 0.5));
        });
      }
    });
  }

  group('line heights', () {
    for (final String face in _faces.keys) {
      for (final double height in <double>[1, 1.2, 1.35, 1.6, 2]) {
        testWidgets('$face, line height $height', (WidgetTester tester) async {
          for (final double scale in _scales) {
            await tester.pumpWidget(
              _row(
                StrutStyle(
                  fontFamily: face,
                  fontSize: kChatComposerFontSize,
                  height: height,
                  leadingDistribution: TextLeadingDistribution.even,
                  forceStrutHeight: true,
                ),
                scale,
              ),
            );
            final Finder field = find.byKey(const Key('row-field'));
            final Rect circle = tester.getRect(
              find.byKey(const Key('row-send')),
            );
            final Rect box = tester.getRect(find.byKey(const Key('row-box')));
            final Rect text = _fieldFrame(tester, field);
            expect(text.height, closeTo(box.height, 0.5));
            expect(box.height, greaterThanOrEqualTo(kChatComposerRowHeight));
            _expectOnTheLetters(
              circle: circle,
              text: text,
              baseline: _baseline(tester, field),
              scale: scale,
              face: _faces[face],
              where: 'scale $scale',
            );
            expect(
              box.right - circle.right,
              closeTo(circle.top - box.top, 0.5),
              reason: 'scale $scale: concentric with the round end',
            );
          }
        });
      }
    }
  });

  testWidgets('a long message grows the field and the button stays by the '
      'last line', (WidgetTester tester) async {
    await loadAppFonts();
    await _pumpAt(tester, _chat('Hanken Grotesk'), 1);
    final Finder field = find.byKey(const Key('conversation-composer-field'));
    final double oneLine = tester.getRect(field).height;
    final double firstBaseline = _baseline(tester, field);
    await tester.enterText(field, 'a\nb\nc\nd');
    await tester.pump(const Duration(milliseconds: 300));
    final Rect text = tester.getRect(field);
    expect(text.height, greaterThan(oneLine + 20));
    final double lineHeight = (text.height - oneLine) / 3;
    final Rect circle = _circle(
      tester,
      find.byKey(const Key('conversation-send-button')),
    );
    final Rect box = _composerBox(tester, field);
    expect(box.bottom - circle.bottom, closeTo(box.right - circle.right, 0.5));
    // The last line stands where the only one stood.
    expect(lineHeight, closeTo(kChatComposerFontSize * 1.35, 0.5));
    expect(
      _baseline(tester, field) + 3 * lineHeight,
      closeTo(firstBaseline, 0.5),
    );
  });
}
