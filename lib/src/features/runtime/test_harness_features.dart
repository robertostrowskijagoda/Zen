import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Harness endpoints of the newer features (`/x/…`), for driving several
/// running apps from a script (tool/zen_drive.dart). Debug builds only,
/// like the rest of the harness. Returns null for an unknown path.
Future<Map<String, dynamic>?> handleFeatureHarness(
  WidgetRef ref,
  String path,
  Map<String, dynamic> body,
) async {
  final PyramidService pyr = ref.read(pyramidServiceProvider);
  String? keyByName(String? name) {
    final PyramidState? s = pyr.state;
    if (s == null || name == null) {
      return null;
    }
    for (final PyrMember m in s.members.values) {
      if (m.name == name) {
        return m.key;
      }
    }
    return null;
  }

  String str(String k, [String d = '']) =>
      body[k] is String ? body[k] as String : d;
  int integer(String k, [int d = 0]) => body[k] is int ? body[k] as int : d;

  switch (path) {
    case '/x/state':
      final PyramidState? s = pyr.state;
      final String? me = pyr.myKey;
      final DatingService dating = ref.read(datingServiceProvider);
      final NeighborsService flats = ref.read(neighborsServiceProvider);
      return <String, dynamic>{
        'ok': true,
        'pyramid': s == null
            ? null
            : <String, dynamic>{
                'id': s.id,
                'name': s.name,
                'member': me != null && s.isMember(me),
                'path': me == null ? null : s.pathOf(me),
                'members': s.members.length,
                'structure': s.describe(),
                'applied': s.applied.length,
                'rejected': s.rejected.length,
                // The last reasons, for a script that wonders why.
                'whyRejected': s.rejected.values
                    .toList()
                    .reversed
                    .take(8)
                    .toList(),
                'term': s.term,
                'balance': me == null ? 0 : s.balanceOf(me),
                'posts': s.posts.length,
                'referenda': <String, dynamic>{
                  for (final PyrReferendum r in s.referenda.values)
                    r.id: <String, dynamic>{
                      'q': r.question,
                      'result': s.resultOf(r.id),
                      'tallies': <String>[
                        for (final PyrTally t in r.tallies.values)
                          '${t.path}:${t.counts.join('/')}',
                      ],
                    },
                },
              },
        'proposals': <String>[
          for (final PyrProposal p in pyr.proposals.values) p.record.type,
        ],
        'dating': <String, dynamic>{
          'active': dating.active,
          'toDecide': dating.toDecide
              .map((SeenProfile p) => p.profile.name)
              .toList(),
          'matches': dating.matches
              .map((SeenProfile p) => p.profile.name)
              .toList(),
        },
        'flat': <String, dynamic>{
          'name': flats.profile?.label,
          'neighbors': flats.neighbors
              .map((NeighborFlat f) => f.profile.label)
              .toList(),
        },
      };
    case '/x/pyramid/create':
      final String id = await pyr.createPyramid(
        name: str('name', 'Test'),
        myName: str('me', 'Ja'),
        nat: str('nat', 'PL'),
        birthYear: integer('year', 1990),
        gender: str('g', 'k'),
      );
      return <String, dynamic>{'ok': true, 'id': id};
    case '/x/pyramid/invite':
      return <String, dynamic>{
        'ok': pyr.inviteCode() != null,
        'code': pyr.inviteCode(),
      };
    case '/x/pyramid/join':
      final bool ok = await pyr.askToJoin(
        invite: str('code'),
        myName: str('me', 'Ja'),
        nat: str('nat', 'PL'),
        birthYear: integer('year', 1990),
        gender: str('g', 'k'),
      );
      return <String, dynamic>{'ok': ok};
    case '/x/pyramid/approve':
      final String type = str('type');
      int n = 0;
      for (final PyrProposal p in pyr.proposals.values.toList()) {
        if (type.isEmpty || p.record.type == type) {
          await pyr.approve(p.record.id);
          n++;
        }
      }
      return <String, dynamic>{'ok': true, 'approved': n};
    case '/x/pyramid/post':
      return <String, dynamic>{'ok': await pyr.post(str('text')) != null};
    case '/x/pyramid/swap':
      final String? up = keyByName(str('up'));
      return <String, dynamic>{
        'ok': up != null && await pyr.proposeSwap(str('cell'), up) != null,
      };
    case '/x/pyramid/referendum':
      await pyr.referendum(
        question: str('q', 'Pytanie?'),
        options: body['opts'] is List
            ? (body['opts'] as List).whereType<String>().toList()
            : <String>['Tak', 'Nie'],
        end: pyr.now + integer('minutes', 5) * 60 * 1000,
      );
      return <String, dynamic>{'ok': true};
    case '/x/pyramid/vote':
      final PyramidState? s = pyr.state;
      final String? refId = str('ref').isNotEmpty
          ? str('ref')
          : (s?.referenda.values.toList()?..sort(
                  (PyrReferendum a, PyrReferendum b) => b.at.compareTo(a.at),
                ))
                ?.firstOrNull
                ?.id;
      return <String, dynamic>{
        'ok': refId != null && await pyr.voteReferendum(refId, integer('opt')),
      };
    case '/x/pyramid/duties':
      await pyr.duties();
      return <String, dynamic>{'ok': true};
    case '/x/pyramid/greet':
      await pyr.greet();
      return <String, dynamic>{'ok': true};
    case '/x/pyramid/emit':
      final String? to = keyByName(str('to'));
      return <String, dynamic>{
        'ok':
            to != null &&
            await pyr.emit(to, integer('amount'), str('why', 'test')) != null,
      };
    case '/x/pyramid/pay':
      final String? to = keyByName(str('to'));
      return <String, dynamic>{
        'ok':
            to != null &&
            await pyr.pay(to, integer('amount'), memo: str('memo')) != null,
      };
    case '/x/dating/enable':
      final DatingService dating = ref.read(datingServiceProvider);
      await dating.saveMine((MyDating m) {
        m
          ..enabled = true
          ..name = str('name', 'Ja')
          ..gender = DatingGender.byCode(str('g', 'k')) ?? DatingGender.other;
      });
      return <String, dynamic>{'ok': dating.active};
    case '/x/dating/publish':
      await ref.read(datingServiceProvider).maybePublish(force: true);
      return <String, dynamic>{'ok': true};
    case '/x/dating/decide':
      final DatingService dating = ref.read(datingServiceProvider);
      final SeenProfile? p = dating.toDecide
          .where((SeenProfile s) => s.profile.name == str('name'))
          .firstOrNull;
      if (p != null) {
        await dating.decide(p.profile.key, body['yes'] != false);
      }
      return <String, dynamic>{'ok': p != null};
    case '/x/flat/create':
      final FlatProfile? f = await ref
          .read(neighborsServiceProvider)
          .createFlat(str('name', 'Mieszkanie'), place: str('place'));
      return <String, dynamic>{'ok': f != null};
    case '/x/flat/door':
      return <String, dynamic>{
        'ok': true,
        'code': ref.read(neighborsServiceProvider).doorCode?.toQr(),
      };
    case '/x/flat/accept':
      // Lets in everyone knocking on the door (§18.2).
      final NeighborsService knocked = ref.read(neighborsServiceProvider);
      int accepted = 0;
      for (final FlatKnock k in knocked.knocks) {
        if (await knocked.acceptKnock(k.key)) {
          accepted++;
        }
      }
      return <String, dynamic>{'ok': true, 'accepted': accepted};
    case '/x/flat/scan':
      final FlatDoorCode? code = FlatDoorCode.parse(str('code'));
      if (code == null) {
        return <String, dynamic>{'ok': false};
      }
      final FlatScan r = await ref
          .read(neighborsServiceProvider)
          .scanDoor(code);
      return <String, dynamic>{
        'ok': r == FlatScan.sent || r == FlatScan.alreadyNeighbor,
        'result': r.name,
      };
  }
  return null;
}
