import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/groups/group_board.dart';
import 'package:zen/src/features/groups/group_board_service.dart';
import 'package:zen/src/features/groups/presentation/group_board_view.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// Phones of one group, delivering frames to each other at once.
final class _Group {
  _Group(this.creator);

  final String creator;
  final Map<String, GroupBoardService> boards = <String, GroupBoardService>{};
  final Map<String, Set<String>> members = <String, Set<String>>{};

  /// Addresses whose frames are lost (the phone is away).
  final Set<String> away = <String>{};
  int now = 1000;

  GroupBoardService add(String address, {Set<String>? memberOf}) {
    members[address] = memberOf ?? <String>{};
    return boards[address] = GroupBoardService(
      disk: MemoryLedgerDisk(),
      host: _Host(this, address),
      now: () => now,
    );
  }
}

final class _Host implements GroupBoardHost {
  _Host(this.group, this.address);

  final _Group group;
  final String address;

  @override
  String ownAddress() => address;

  @override
  String ownName() => address.toUpperCase();

  @override
  List<String>? membersOf(String groupId) =>
      groupId == 'g1' && group.members[address]!.contains(address)
      ? <String>[
          for (final String m in group.members.keys)
            if (m != address && group.members[m]!.contains(m)) m,
        ]
      : null;

  @override
  bool isAdmin(String groupId, String who) => who == group.creator;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    if (group.away.contains(to)) {
      return;
    }
    await group.boards[to]?.handle(
      SignalTransportFrame(
        from: address,
        payload: payload,
        receivedAtMillis: group.now,
      ),
    );
  }
}

void main() {
  _Group threeMembers() {
    final _Group g = _Group('ada');
    for (final String a in <String>['ada', 'bob', 'cel']) {
      g.add(a, memberOf: <String>{a});
    }
    return g;
  }

  test(
    'a post reaches every member, newest first; only from its author',
    () async {
      final _Group g = threeMembers();
      await g.boards['ada']!.publish('g1', 'Spotkanie w piątek');
      g.now += 10;
      await g.boards['bob']!.publish('g1', 'Przyniosę ciasto');
      expect(
        g.boards['cel']!.postsOf('g1').map((GroupBoardPost p) => p.text),
        <String>['Przyniosę ciasto', 'Spotkanie w piątek'],
      );
      expect(g.boards['cel']!.postsOf('g1').last.authorName, 'ADA');

      // Bob cannot put words in Ada's mouth.
      final GroupBoardPost forged = GroupBoardPost(
        id: 'abcdef0123456789',
        author: 'ada',
        authorName: 'Ada',
        text: 'Nie przychodźcie',
        createdAt: g.now,
        version: g.now,
      );
      await g.boards['cel']!.handle(
        SignalTransportFrame(
          from: 'bob',
          payload: <String, dynamic>{
            'type': kGroupPostType,
            'g': 'g1',
            'p': forged.toJson(),
          },
          receivedAtMillis: g.now,
        ),
      );
      expect(g.boards['cel']!.postsOf('g1'), hasLength(2));

      // Nobody outside the group gets in.
      final GroupBoardService stranger = g.add('eve');
      expect(await stranger.publish('g1', 'Spam'), isNull);
    },
  );

  test('edits and removals: the author, and the creator removes any', () async {
    final _Group g = threeMembers();
    final GroupBoardPost post = (await g.boards['bob']!.publish(
      'g1',
      'Pierwsza wersja',
    ))!;
    g.now += 5;
    expect(await g.boards['cel']!.edit('g1', post.id, 'Cudza'), isFalse);
    expect(await g.boards['bob']!.edit('g1', post.id, 'Druga wersja'), isTrue);
    final GroupBoardPost seen = g.boards['cel']!.postsOf('g1').single;
    expect(seen.text, 'Druga wersja');
    expect(seen.edited, isTrue);

    expect(await g.boards['cel']!.remove('g1', post.id), isFalse);
    g.now += 5;
    expect(await g.boards['ada']!.remove('g1', post.id), isTrue);
    expect(g.boards['bob']!.postsOf('g1'), isEmpty);
    expect(g.boards['cel']!.postsOf('g1'), isEmpty);
  });

  test('a member who was away catches up from the authors', () async {
    final _Group g = threeMembers()..away.add('cel');
    await g.boards['ada']!.publish('g1', 'Od Ady');
    await g.boards['bob']!.publish('g1', 'Od Boba');
    expect(g.boards['cel']!.postsOf('g1'), isEmpty);
    g.away.clear();
    await g.boards['cel']!.open('g1');
    expect(
      g.boards['cel']!.postsOf('g1').map((GroupBoardPost p) => p.text).toSet(),
      <String>{'Od Ady', 'Od Boba'},
    );
  });

  test(
    'posts nobody asked for, or dated in the future, are not taken',
    () async {
      final _Group g = threeMembers();
      Map<String, dynamic> post(String id, int at) => GroupBoardPost(
        id: id,
        author: 'bob',
        authorName: 'Bob',
        text: 'Reklama $id',
        createdAt: at,
        version: at,
      ).toJson();
      Future<void> fromBob(Map<String, dynamic> payload) =>
          g.boards['cel']!.handle(
            SignalTransportFrame(
              from: 'bob',
              payload: payload,
              receivedAtMillis: g.now,
            ),
          );

      // A whole board's worth of "answers" cel never asked for.
      await fromBob(<String, dynamic>{
        'type': kGroupBoardPutType,
        'g': 'g1',
        'ps': <Map<String, dynamic>>[
          for (int i = 0; i < 10; i++) post('${'a' * 15}$i', g.now),
        ],
      });
      expect(g.boards['cel']!.postsOf('g1'), isEmpty);

      // A post from next year would stay on top for good.
      await fromBob(<String, dynamic>{
        'type': kGroupPostType,
        'g': 'g1',
        'p': post('bbbbbbbbbbbbbbbb', g.now + 365 * 24 * 3600 * 1000),
      });
      expect(g.boards['cel']!.postsOf('g1'), isEmpty);

      await fromBob(<String, dynamic>{
        'type': kGroupPostType,
        'g': 'g1',
        'p': post('cccccccccccccccc', g.now),
      });
      expect(g.boards['cel']!.postsOf('g1'), hasLength(1));
    },
  );

  testWidgets('the board view lists posts, with a hint when empty', (
    WidgetTester tester,
  ) async {
    final _Group g = threeMembers();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupBoardView(
            board: g.boards['cel']!,
            groupId: 'g1',
            nameOf: (GroupBoardPost p) => 'Ada',
            canPost: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Tablica grupy jest pusta'), findsOneWidget);

    await g.boards['ada']!.publish('g1', 'Spotkanie w piątek');
    await tester.pump();
    expect(find.text('Spotkanie w piątek'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
  });

  test('a photo post carries only the photo\'s reference; removing it '
      'drops the reference too', () async {
    final _Group g = threeMembers();
    final GroupBoardPost? post = await g.boards['bob']!.publish(
      'g1',
      '',
      media: <String, dynamic>{'id': 'blk-1', 'mime': 'image/jpeg'},
    );
    expect(post, isNotNull);
    final GroupBoardPost atCel = g.boards['cel']!.postsOf('g1').single;
    expect(atCel.media?['id'], 'blk-1');
    expect(atCel.text, isEmpty);

    // Neither an empty post nor an oversized reference goes out.
    expect(await g.boards['bob']!.publish('g1', '  '), isNull);
    expect(
      await g.boards['bob']!.publish(
        'g1',
        'Za dużo',
        media: <String, dynamic>{'id': 'blk-2', 'x': 'y' * 4000},
      ),
      isNull,
    );

    g.now += 10;
    expect(await g.boards['ada']!.remove('g1', post!.id), isTrue);
    expect(g.boards['cel']!.postsOf('g1'), isEmpty);
    // A removal that still names a photo keeps nothing of it.
    final GroupBoardPost removed = GroupBoardPost.fromJson(<String, dynamic>{
      ...atCel.toJson(),
      'd': true,
      'v': g.now,
    })!;
    expect(removed.deleted, isTrue);
    expect(removed.media, isNull);
    expect(atCel.copyWith(deleted: true).media, isNull);
  });

  testWidgets('the board shows a post\'s photo once it is fetched', (
    WidgetTester tester,
  ) async {
    final _Group g = threeMembers();
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );
    final _Blocks blocks = _Blocks(<String, Uint8List>{'blk-1': png});
    final GroupBoardPost post = (await g.boards['ada']!.publish(
      'g1',
      'Zdjęcie z wyjazdu',
      media: <String, dynamic>{'id': 'blk-1', 'mime': 'image/png'},
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupBoardView(
            board: g.boards['cel']!,
            groupId: 'g1',
            nameOf: (GroupBoardPost p) => 'Ada',
            canPost: true,
            blocks: blocks,
            sourcesOf: (GroupBoardPost p) => <String>[p.author, 'bob'],
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text('Zdjęcie z wyjazdu'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('group-board-photo-${post.id}')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(blocks.asked.single, <String>['ada', 'bob']);
  });
}

final class _Blocks implements ChatMediaBlocks {
  _Blocks(this.held);

  final Map<String, Uint8List> held;
  final List<List<String>> asked = <List<String>>[];

  @override
  Future<Map<String, dynamic>> store(
    Uint8List bytes, {
    required String mime,
    int? durationMs,
  }) async => <String, dynamic>{'id': 'blk-${held.length}', 'mime': mime};

  @override
  Future<Uint8List?> fetch(
    Map<String, dynamic> ref,
    List<String> sources, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    asked.add(sources);
    return held[ref['id']];
  }
}
