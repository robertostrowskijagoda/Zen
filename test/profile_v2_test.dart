import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/presentation/profile_edit_dialog.dart';
import 'package:zen/src/features/profile/profile_cover.dart';

void main() {
  test('a cover is cropped to 3:1, scaled down and re-encoded', () {
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 3000, height: 2000)),
    );
    final img.Image out = img.decodeJpg(makeCoverImage(png)!)!;
    expect(out.width, kCoverWidth);
    expect(out.height, kCoverHeight);
    expect(makeCoverImage(Uint8List.fromList(<int>[1, 2, 3, 4])), isNull);
    // A small picture is cropped, not blown up.
    final img.Image small = img.decodeJpg(
      makeCoverImage(
        Uint8List.fromList(img.encodePng(img.Image(width: 600, height: 600))),
      )!,
    )!;
    expect((small.width, small.height), (600, 200));
  });

  test('the cover travels in the profile entry and survives JSON', () {
    final Map<String, dynamic> body = profileBody(
      name: 'Ada',
      cover: <String, dynamic>{'id': 'x'},
    );
    expect(body['cover'], <String, dynamic>{'id': 'x'});
    expect(profileBody(name: 'Ada').containsKey('cover'), isFalse);
    const UserProfile p = UserProfile(coverPath: '/tmp/cover_1.jpg');
    expect(UserProfile.fromJson(p.toJson()).coverPath, '/tmp/cover_1.jpg');
    expect(p.copyWith(clearCoverPath: true).coverPath, isNull);
  });

  testWidgets('the editor: no status field, a cover, a formatted bio', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => ProfileEditDialog.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-status-field')), findsNothing);
    expect(find.byKey(const Key('profile-pick-cover-button')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('profile-bio-field')), '');
    await tester.tap(find.byKey(const Key('bio-tool-bold')));
    await tester.pump();
    final TextField bio = tester.widget(
      find.byKey(const Key('profile-bio-field')),
    );
    expect(bio.controller!.text, '****');
    // Formatting shows right in the field; no separate preview.
    expect(find.byKey(const Key('profile-bio-preview')), findsNothing);
  });
}
