import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Nothing but the friendship book makes someone a friend. This reads the
/// app's code and fails on any way around it: a friend list built or
/// written outside the book, a book made from a list anywhere but where the
/// stored state is read, a new way into a friendship that was not added to
/// the list below on purpose.

/// Where the book may be made from a list of entries: reading the stored
/// state, and the preview state.
const Set<String> _restoreAllowed = <String>{
  'lib/src/features/social/social_snapshot_store.dart',
  'lib/src/features/social/social_hub_state.dart',
};

/// Where a whole state may be made from scratch (with a book in it).
const Set<String> _stateAllowed = <String>{
  'lib/src/features/social/social_snapshot_store.dart',
  'lib/src/features/social/social_hub_state.dart',
};

/// Where records of the account's devices (or copies of the account) are
/// merged into the book.
const Set<String> _mergeAllowed = <String>{
  'lib/src/features/social/social_hub_controller_devices.dart',
  'lib/src/features/social/social_hub_controller_lifecycle_signal.dart',
};

/// Every way into a friendship: file → the evidence it admits on.
const Map<String, Set<String>> _admissions = <String, Set<String>>{
  // Their answer to an invitation from here; both invited each other.
  'lib/src/features/social/social_hub_controller_helpers.dart': <String>{
    'theyAcceptedMine',
    'bothInvited',
  },
  // The user accepts their invitation.
  'lib/src/features/social/social_hub_controller_social.dart': <String>{
    'iAcceptedTheirs',
  },
};

/// A standing written as a literal outside the book: only where entries are
/// shaped (the book sets the standing itself) or the preview.
const Set<String> _statusLiteralAllowed = <String>{
  'lib/src/features/social/friendship_book.dart',
  'lib/src/domain/friends/friend_lifecycle_reducer.dart',
  'lib/src/features/social/social_hub_state.dart',
};

const String _book = 'lib/src/features/social/friendship_book.dart';

void main() {
  final List<(String, String)> sources = <(String, String)>[
    for (final FileSystemEntity f in Directory('lib').listSync(recursive: true))
      if (f is File && f.path.endsWith('.dart'))
        (f.path.replaceAll(r'\', '/'), f.readAsStringSync()),
  ];

  List<String> hits(
    RegExp pattern,
    bool Function(String path) allowed,
  ) => <String>[
    for (final (String path, String text) in sources)
      if (path != _book && !allowed(path))
        for (final RegExpMatch m in pattern.allMatches(text))
          '$path:${'\n'.allMatches(text.substring(0, m.start)).length + 1}: '
              '${m[0]}',
  ];

  test('the code is read at all', () {
    expect(
      sources.map(((String, String) s) => s.$1),
      contains('lib/src/features/social/social_hub_controller.dart'),
    );
  });

  test('nobody writes into a friend list', () {
    expect(
      hits(
        RegExp(
          r'\b(?:state|current|persisted|hub|next|s)\.friends\s*'
          r'(?:\[[^\]]*\]\s*=[^=]|\.(?:remove|removeWhere|clear|addAll|'
          r'addEntries|putIfAbsent|update|updateAll)\()',
        ),
        (_) => false,
      ),
      isEmpty,
    );
    expect(
      hits(RegExp(r'\bfriends\s*:\s*(?:const\s*)?<String,\s*FriendProfile>'), (
        _,
      ) {
        return false;
      }),
      isEmpty,
      reason: 'a state is never given a friend list',
    );
  });

  test('a book is made from a list only where the stored state is read', () {
    expect(
      hits(RegExp(r'FriendshipBook\.restore\('), _restoreAllowed.contains),
      isEmpty,
    );
    expect(
      hits(RegExp(r'(?<![\w.])SocialHubState\('), _stateAllowed.contains),
      isEmpty,
    );
  });

  test('records are merged only from own devices and copies', () {
    expect(
      hits(RegExp(r'\bbook\.merge(?:All)?\('), _mergeAllowed.contains),
      isEmpty,
    );
  });

  test('every way into a friendship is one of the known ones', () {
    final Map<String, Set<String>> found = <String, Set<String>>{};
    final RegExp admit = RegExp(
      r'\.admit\(\s*[^,]+,\s*FriendshipEvidence\.(\w+)',
      multiLine: true,
    );
    final RegExp anyAdmit = RegExp(r'\.admit\(');
    for (final (String path, String text) in sources) {
      if (path == _book) {
        continue;
      }
      final int all = anyAdmit.allMatches(text).length;
      final Iterable<RegExpMatch> known = admit.allMatches(text);
      expect(
        known.length,
        all,
        reason: '$path admits on something other than named evidence',
      );
      for (final RegExpMatch m in known) {
        (found[path] ??= <String>{}).add(m[1]!);
      }
    }
    expect(found, _admissions);
  });

  test('a standing is not written outside the book', () {
    expect(
      hits(
        RegExp(r'status:\s*FriendRelationshipStatus\.(?:accepted|blocked)'),
        _statusLiteralAllowed.contains,
      ),
      isEmpty,
    );
  });
}
