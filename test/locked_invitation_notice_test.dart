import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final String ania = PeerShareCodec.normalizeAddress('200::a1');

Map<String, dynamic> _request(String note) => <String, dynamic>{
  'type': 'friend_request',
  'senderName': 'Ania',
  'message': note,
};

void main() {
  test('a locked phone tells who invited and their words, as the level '
      'allows; an acceptance names who accepted', () {
    NoticeText? notice(NotificationPrivacy level, String type) =>
        LockedNoticeKit(privacy: level).invitationNotice(
          from: ania,
          type: type,
          payload: type == 'friend_request'
              ? _request('Cześć, z kursu tańca')
              : <String, dynamic>{'type': type, 'senderName': 'Ania'},
        );

    final NoticeText? full = notice(
      NotificationPrivacy.senderAndContent,
      'friend_request',
    );
    expect(full?.title, 'Nowe zaproszenie od Ania');
    expect(full?.body, 'Cześć, z kursu tańca');

    final NoticeText? name = notice(
      NotificationPrivacy.senderOnly,
      'friend_request',
    );
    expect(name?.title, 'Nowe zaproszenie od Ania');
    expect(name?.body, 'Chce dodać Cię do znajomych.');

    final NoticeText? plain = notice(
      NotificationPrivacy.generic,
      'friend_request',
    );
    expect(plain?.title, 'Nowe zaproszenie do znajomych');
    expect(plain?.body, isNot(contains('Ania')));

    expect(
      notice(NotificationPrivacy.senderAndContent, 'friend_accept')?.title,
      'Ania zaakceptował(a) zaproszenie',
    );
    expect(
      notice(NotificationPrivacy.generic, 'friend_accept')?.title,
      'Ktoś przyjął Twoje zaproszenie',
    );
    expect(notice(NotificationPrivacy.generic, 'group_invite'), isNull);
  });

  test('the name this person gave a friend wins over the one they sent', () {
    final NoticeText? n =
        LockedNoticeKit(
          names: <String, String>{ania: 'Ania z pracy'},
        ).invitationNotice(
          from: ania,
          type: 'friend_accept',
          payload: <String, dynamic>{
            'type': 'friend_accept',
            'senderName': 'A.',
          },
        );
    expect(n?.title, 'Ania z pracy zaakceptował(a) zaproszenie');
  });
}
