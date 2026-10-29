import 'dart:convert';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The ids of the cells' group chats start with this.
const String kPyrCellGroupPrefix = 'pyrcell-';

/// A cell's group chat as the groups feature keeps it: its name and the
/// members' device addresses.
typedef PyrCellChat = ({String name, List<String> members});

/// The group chats of [me]'s cells in [s] — the cell it is a member of
/// and its own cell below, each with at least two people — by id. Every
/// member works out the same id (from the pyramid and the cell's place) and
/// the same people, so the chats need no invitations; [ownAddress] stands
/// for this device.
Map<String, PyrCellChat> pyramidCellChats(
  PyramidState s,
  String me,
  String ownAddress,
) {
  final String? p = s.pathOf(me);
  final Map<String, PyrCellChat> out = <String, PyrCellChat>{};
  if (p == null) {
    return out;
  }
  for (final String cell in <String>[if (p.isNotEmpty) PyrPath.parent(p), p]) {
    final List<String> people = s.cellOf(cell);
    if (people.length < 2 || !people.contains(me)) {
      continue;
    }
    final String id =
        '$kPyrCellGroupPrefix'
        '${sha256Hex(utf8.encode('${s.id}|$cell')).substring(0, 24)}';
    final String? head = s.members[s.occupant[cell]]?.name;
    out[id] = (
      name: cell.isEmpty
          ? t('Szczyt piramidy')
          : head == null
          ? t('Komórka piramidy')
          : t('Komórka: {name}', <String, Object?>{'name': head}),
      members: <String>[
        if (ownAddress.isNotEmpty) ownAddress,
        for (final String k in people)
          if (k != me && (s.members[k]?.addr ?? '').isNotEmpty)
            s.members[k]!.addr,
      ],
    );
  }
  return out;
}

/// Keeps a group chat for each of this person's cells in Chats: created
/// when a cell forms, its members updated when the cell changes, dropped
/// when this person is no longer in it. [apply] hands the wanted chats to
/// the groups feature (ids starting with [kPyrCellGroupPrefix]); false
/// when it could not yet (they go again with the next change).
final class PyramidCellChats {
  PyramidCellChats({required this.pyramid, required this.apply});

  final PyramidService pyramid;
  final Future<bool> Function(Map<String, PyrCellChat> chats) apply;
  String? _last;

  /// From now on (after the pyramid was read from disk, so a start never
  /// drops the chats for a moment).
  void start() {
    pyramid.addListener(_changed);
    _changed();
  }

  void stop() => pyramid.removeListener(_changed);

  void _changed() {
    final PyramidState? s = pyramid.state;
    final String? me = pyramid.myKey;
    final Map<String, PyrCellChat> wanted = s == null || me == null
        ? <String, PyrCellChat>{}
        : pyramidCellChats(s, me, pyramid.host.ownAddress());
    final List<String> ids = wanted.keys.toList()..sort();
    final String signature = jsonEncode(<String, Object>{
      for (final String id in ids)
        id: <String>[wanted[id]!.name, ...wanted[id]!.members],
    });
    if (signature == _last) {
      return;
    }
    unawaitedLogged(() async {
      if (await apply(wanted)) {
        _last = signature;
      }
    }(), context: 'Pyramid cell chats');
  }
}
