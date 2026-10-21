/// The court of the pyramid ("Sąd") and appeals, as the fold keeps them.
///
/// A complaint ([PyrT.suit]) goes first to the head of the accused's cell.
/// Every decision against somebody — a ban, a removal, a verdict, and for
/// the one who complained a dismissal or no answer at all — can be appealed
/// ([PyrT.appeal]) one level above whoever decided; refused (or not
/// answered in time) it can be appealed again one level higher, up to the
/// top, whose refusal is final. Each next level gets twice as long
/// ([pyrStepTimeMs]), so the top is not flooded. Accepting at any level
/// overturns the decision.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';

/// The time the first level gets to answer: a complaint's first instance,
/// or the first appeal against a ban or a removal.
const int kPyrAppealBaseMs = 3 * 24 * 3600 * 1000;

/// How long the level at [step] (0 = the first one) has to answer:
/// 3 days, 6, 12, 24 …
int pyrStepTimeMs(int step) => kPyrAppealBaseMs * (1 << step.clamp(0, 16));

/// Open complaints one member may have at a time.
const int kPyrOpenSuits = 3;

/// The longest text of a complaint, a verdict, an appeal or an answer.
const int kPyrCourtTextChars = 1000;

/// A verdict names at most this many addresses of the accused.
const int kPyrVerdictAddrs = 16;

/// Address records of the accused a verdict read outside carries (the
/// newest).
const int kPyrVerdictAddrRecords = 4;

/// Kinds of verdicts: real-world statements about a person, never a
/// technical sanction.
const List<String> kPyrVerdictKinds = <String>[
  'fraud',
  'noloan',
  'beware',
  'other',
];

/// A verdict kind for people.
String pyrVerdictLabel(String kind) => switch (kind) {
  'fraud' => t('Ostrzeżenie: oszust'),
  'noloan' => t('Zakaz pożyczania pieniędzy'),
  'beware' => t('Uważajcie na tę osobę'),
  _ => t('Inne'),
};

/// What can be appealed.
enum PyrMatterKind {
  /// A ban (also one a report decision gave).
  ban,

  /// A removal from the pyramid by the person's cell.
  remove,

  /// A verdict of the court.
  verdict,

  /// A complaint dismissed or not answered in time (the plaintiff appeals).
  complaint,
}

/// A decision somebody may appeal.
final class PyrMatter {
  PyrMatter({
    required this.id,
    required this.kind,
    required this.party,
    required this.parties,
    required this.decider,
    required this.step,
    required this.at,
    this.oldPath,
  });

  /// The record of the decision (a complaint: the complaint itself).
  final String id;
  final PyrMatterKind kind;

  /// Who may appeal it.
  final String party;

  /// Who may never judge it (the people it is about).
  final Set<String> parties;

  /// The place that decided ('' = the top): appeals go above it.
  final String decider;

  /// The court step it was decided at (-1: not by the court).
  final int step;
  final int at;

  /// A removal: the place the person had.
  final String? oldPath;

  /// The appeals so far, in order.
  final List<String> appeals = <String>[];
  bool overturned = false;
}

/// One appeal, at one level.
final class PyrAppeal {
  PyrAppeal({
    required this.id,
    required this.matter,
    required this.by,
    required this.why,
    required this.at,
    required this.signedAt,
    required this.judge,
    required this.step,
    required this.deadline,
  });

  final String id;
  final String matter;
  final String by;
  final String why;

  /// When it counts from (its own time, or when this phone first saw it).
  final int at;

  /// Its own time: no answer may be dated before.
  final int signedAt;

  /// The place that judges it ('' = the top cell, 2 of 3).
  final String judge;
  final int step;
  final int deadline;

  /// Null while waiting; true accepted (the decision overturned), false
  /// refused.
  bool? ok;
  String? answer;
  String answerWhy = '';

  /// Waiting at [now]: not answered and still in time.
  bool openAt(int now) => ok == null && now < deadline;

  /// Not answered in time: the person may go one level higher.
  bool expiredAt(int now) => ok == null && now >= deadline;
}

/// Where a complaint stands.
enum PyrCaseStatus { open, guilty, dismissed }

/// A complaint of one member against another.
final class PyrCase {
  PyrCase({
    required this.id,
    required this.plaintiff,
    required this.accused,
    required this.kind,
    required this.text,
    required this.at,
    required this.signedAt,
    required this.judge,
    required this.deadline,
  });

  final String id;
  final String plaintiff;
  final String accused;

  /// What it is about ([kPyrVerdictKinds]).
  final String kind;
  final String text;
  final int at;
  final int signedAt;

  /// The first instance: the head of the accused's cell (or higher when
  /// that is the plaintiff); '' = the top cell.
  final String judge;
  final int deadline;
  PyrCaseStatus status = PyrCaseStatus.open;

  /// The verdict, once there is one.
  String? verdict;

  /// Why the first instance dismissed it.
  String why = '';

  /// No answer from the first instance in time.
  bool expiredAt(int now) => status == PyrCaseStatus.open && now >= deadline;
}

/// A verdict on a person: a signed statement every member sees, and
/// everybody who views that person's profile in Zen.
final class PyrVerdict {
  PyrVerdict({
    required this.id,
    required this.caseId,
    required this.accused,
    required this.plaintiff,
    required this.kind,
    required this.text,
    required this.at,
    required this.judge,
    required this.addrs,
    this.until,
  });

  final String id;
  final String caseId;
  final String accused;
  final String plaintiff;
  final String kind;
  final String text;
  final int at;

  /// The place whose head (or the top) gave it.
  final String judge;

  /// The accused's device addresses when it was given (checked by the
  /// fold): where it shows outside the pyramid.
  final List<String> addrs;
  final int? until;
  bool overturned = false;

  bool activeAt(int now) => !overturned && (until == null || now < until!);
}

/// A change of the emission limit waiting its 30 days.
final class PyrEmitChange {
  PyrEmitChange({
    required this.id,
    required this.at,
    required this.effectiveAt,
    required this.oldLimit,
    required this.oldDelayHours,
    this.limit,
    this.delayHours,
  });

  final String id;
  final int at;
  final int effectiveAt;

  /// The new values (null: unchanged).
  final int? limit;
  final int? delayHours;

  /// The values when it was announced.
  final int oldLimit;
  final int oldDelayHours;
  bool cancelled = false;
  bool done = false;

  bool get pending => !cancelled && !done;
}

/// A verdict as somebody outside the pyramid reads it: the verdict signed
/// by its judge (a [PyrT.verdict], or the [PyrT.appealAnswer] of a higher
/// level that gave it), passed on by a friend who is a member, with the
/// address records the accused signed (where it shows) and, when it was
/// overturned, the accused's appeal and the answer that accepted it.
/// What only the friend says (the pseudonym) is not signed.
@immutable
final class PyrOutsideVerdict {
  const PyrOutsideVerdict({
    required this.record,
    required this.name,
    this.addrRecords = const <PyramidRecord>[],
    this.overturn = const <PyramidRecord>[],
    this.from = '',
  });

  final PyramidRecord record;

  /// The accused's pseudonym, as the friend sees it.
  final String name;

  /// Addresses the accused signed after the verdict ([PyrT.address]
  /// records, checked on arrival).
  final List<PyramidRecord> addrRecords;

  /// [appeal, answer] when overturned (checked on arrival).
  final List<PyramidRecord> overturn;
  final String from;

  String get id => record.id;
  String get pyramid => record.pyramid;
  String get accused => record.str('k');
  String get kind => record.str('type');
  String get text => record.str('text');
  int get at => record.at;
  int? get until =>
      record.body['until'] is int ? record.integer('until') : null;
  bool get overturned => overturn.length == 2;

  /// Every address it shows at: those the verdict names and those the
  /// accused signed since.
  Set<String> get addresses => <String>{
    if (record.body['addrs'] is List)
      ...(record.body['addrs'] as List).whereType<String>(),
    for (final PyramidRecord x in addrRecords) x.str('addr'),
  };

  bool activeAt(int now) => !overturned && (until == null || now < until!);

  /// The newest change it carries (the verdict, an address since, or its
  /// overturning).
  int get changedAt => <int>[
    at,
    for (final PyramidRecord x in addrRecords) x.at,
    for (final PyramidRecord x in overturn) x.at,
  ].reduce(max);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'r': record.toJson(),
    'n': name,
    if (addrRecords.isNotEmpty)
      'a': <Map<String, dynamic>>[
        for (final PyramidRecord x in addrRecords) x.toJson(),
      ],
    if (overturn.isNotEmpty)
      'ov': <Map<String, dynamic>>[
        for (final PyramidRecord r in overturn) r.toJson(),
      ],
    if (from.isNotEmpty) 'f': from,
  };

  /// Parses one (signatures are checked by the service); null for
  /// anything but a verdict-giving record with its accused. Address
  /// records other than the accused's own are dropped.
  static PyrOutsideVerdict? fromJson(Object? json, {String? from}) {
    if (json is! Map) {
      return null;
    }
    final PyramidRecord? r = PyramidRecord.fromJson(json['r']);
    if (r == null ||
        (r.type != PyrT.verdict && r.type != PyrT.appealAnswer) ||
        !PyramidRecord.isCanonicalKey(r.body['k']) ||
        !kPyrVerdictKinds.contains(r.str('type'))) {
      return null;
    }
    final Object? n = json['n'];
    final Object? a = json['a'];
    final Object? ov = json['ov'];
    final List<PyramidRecord> overturn = <PyramidRecord>[
      if (ov is List)
        for (final Object? x in ov.take(2)) ?PyramidRecord.fromJson(x),
    ];
    final Object? f = json['f'];
    final String accused = r.str('k');
    return PyrOutsideVerdict(
      record: r,
      name: n is String ? String.fromCharCodes(n.runes.take(40)) : '',
      addrRecords: <PyramidRecord>[
        if (a is List)
          for (final Object? x in a.take(kPyrVerdictAddrRecords))
            if (PyramidRecord.fromJson(x) case final PyramidRecord ad
                when ad.type == PyrT.address &&
                    ad.pyramid == r.pyramid &&
                    ad.str('k') == accused &&
                    ad.sigs.length == 1 &&
                    ad.sigs.containsKey(accused) &&
                    ad.str('addr').length <= 300)
              ad,
      ],
      overturn: overturn.length == 2 ? overturn : const <PyramidRecord>[],
      from: from ?? (f is String ? f : ''),
    );
  }
}

/// A verdict as a profile shows it, from the records (a member) or from
/// what member friends passed on (anybody else).
@immutable
final class PyrVerdictView {
  const PyrVerdictView({
    required this.id,
    required this.kind,
    required this.text,
    required this.at,
    required this.name,
    this.until,
  });

  final String id;
  final String kind;
  final String text;
  final int at;

  /// The accused's pseudonym in the pyramid.
  final String name;
  final int? until;
}
