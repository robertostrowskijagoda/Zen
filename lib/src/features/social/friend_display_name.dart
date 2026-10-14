/// Names of friends: the one a peer gives itself (from its profile, not
/// editable here) and the nickname this user may add under it.
library;

/// The longest name a peer can give itself (the same as a profile name).
const int kMaxPeerName = 60;

/// The longest nickname this user can give a friend.
const int kMaxFriendNickname = 40;

final RegExp _controlChars = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);
final RegExp _spaces = RegExp(r'\s+');

String _oneLine(String? value, int max) {
  final String clean = (value ?? '')
      .replaceAll(_controlChars, ' ')
      .replaceAll(_spaces, ' ')
      .trim();
  if (clean.length <= max) {
    return clean;
  }
  String cut = clean.substring(0, max);
  final int last = cut.codeUnitAt(cut.length - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    // Do not leave half of an emoji behind.
    cut = cut.substring(0, cut.length - 1);
  }
  return cut.trim();
}

/// A name as a peer sent it: one line, no control or direction-changing
/// characters (which could make it look like someone else's), clipped.
String sanitizePeerName(String? value) => _oneLine(value, kMaxPeerName);

/// A nickname as typed here: one line, clipped. '' removes it.
String sanitizeFriendNickname(String? value) =>
    _oneLine(value, kMaxFriendNickname);
