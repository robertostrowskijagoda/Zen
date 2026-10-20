import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class AskTypes {
  static const String ask = 'ask';
  static const String answer = 'ask_answer';

  static const Set<String> all = <String>{ask, answer};
}

/// How long a question lives (§17.5).
const Duration kQuestionLife = Duration(days: 7);

/// Flood guard on the receiving side: questions this phone takes in from
/// one friend a day (their own and those they pass on). Nobody central
/// checks anything — each phone protects itself, so a broken or modified
/// app cannot flood friends. Ordinary use never comes near it.
const int kQuestionsFromFriendPerDay = 20;

/// Longest answer (what the app lets one write).
const int kAnswerMaxChars = 1000;

/// Answers kept for one question, and taken from one friend (their own and
/// the ones they pass back); answers passed back for one question.
const int kAnswersPerQuestion = 200;
const int kAnswersFromFriendPerQuestion = 50;

/// What the answerer signs with their device key (§17.5): the question,
/// their own address and name, the words and the pyramid key a tip goes to.
/// Whoever passes the answer back adds their name to the path but cannot
/// change any of this without the signature failing.
Uint8List askAnswerSignedBytes({
  required String id,
  required String answerer,
  required String name,
  required String text,
  String? pyramidKey,
  String? pyramid,
}) => canonicalJsonBytes(<String, dynamic>{
  't': 'zen_ask_answer_v1',
  'q': id,
  'a': answerer,
  'n': name,
  'txt': text,
  'k': pyramidKey ?? '',
  'py': pyramid ?? '',
});

/// One answer, with the way it came back ("znajomy Bartka").
@immutable
final class AskAnswer {
  const AskAnswer({
    required this.text,
    required this.path,
    required this.at,
    required this.from,
    this.pyramidKey,
    this.pyramid,
    this.tipped = 0,
  });

  final String text;

  /// Names from the one who answered back towards the asker (the first is
  /// the one who answered).
  final List<String> path;
  final int at;

  /// The one who answered, in the pyramid (when a member): where a tip
  /// goes (§24). Only what they said about themselves.
  final String? pyramidKey;
  final String? pyramid;

  /// Tips this person gave for it, in hundredths.
  final int tipped;

  /// The friend it came from (who answered, or passed the answer back).
  final String from;

  AskAnswer withTip(int amount) => AskAnswer(
    text: text,
    path: path,
    at: at,
    pyramidKey: pyramidKey,
    pyramid: pyramid,
    tipped: tipped + amount,
    from: from,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': text,
    'p': path,
    'at': at,
    'k': ?pyramidKey,
    'py': ?pyramid,
    if (tipped > 0) 'tip': tipped,
    'f': from,
  };

  static AskAnswer? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] is! String ||
        json['at'] is! int ||
        json['f'] is! String) {
      return null;
    }
    final Object? p = json['p'];
    return AskAnswer(
      text: json['t'] as String,
      path: p is List
          ? p.whereType<String>().take(5).toList()
          : const <String>[],
      at: json['at'] as int,
      pyramidKey: askKeyField(json['k']),
      pyramid: askKeyField(json['py']),
      tipped: json['tip'] is int && (json['tip'] as int) > 0
          ? json['tip'] as int
          : 0,
      from: json['f'] as String,
    );
  }
}

/// A pyramid key or id from a frame: a short string, else null.
String? askKeyField(Object? v) =>
    v is String && v.isNotEmpty && v.length <= 100 ? v : null;

/// A question asked of the network (§17.5): no database of
/// recommendations, just people asking people.
final class Question {
  Question({
    required this.id,
    required this.text,
    required this.askerName,
    required this.at,
    required this.hops,
    this.from,
    this.via = const <String>[],
    List<AskAnswer>? answers,
    this.answeredByMe = false,
    this.forwarded = false,
    Set<String>? sentTo,
  }) : answers = answers ?? <AskAnswer>[],
       sentTo = sentTo ?? <String>{};

  final String id;
  final String text;
  final String askerName;
  final int at;

  /// How many more times it may be passed on.
  final int hops;

  /// Who gave it to this device (`null` for this person's own question).
  final String? from;

  /// Names it was passed through, from the asker's friend onwards.
  final List<String> via;
  final List<AskAnswer> answers;
  bool answeredByMe;
  bool forwarded;

  /// The friends this device gave the question to (asked or passed on):
  /// answers come only from them.
  final Set<String> sentTo;

  bool get isMine => from == null;

  bool aliveAt(int now) => now - at < kQuestionLife.inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'text': text,
    'name': askerName,
    'at': at,
    'hops': hops,
    if (from != null) 'from': from,
    'via': via,
    'answers': <Map<String, dynamic>>[
      for (final AskAnswer a in answers) a.toJson(),
    ],
    if (answeredByMe) 'answered': true,
    if (forwarded) 'fwd': true,
    if (sentTo.isNotEmpty) 'to': sentTo.toList(),
  };

  static Question? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['text'] is! String ||
        json['at'] is! int ||
        json['hops'] is! int) {
      return null;
    }
    final Object? via = json['via'];
    final Object? answers = json['answers'];
    final Object? to = json['to'];
    return Question(
      id: json['id'] as String,
      text: json['text'] as String,
      askerName: json['name'] is String ? json['name'] as String : '',
      at: json['at'] as int,
      hops: json['hops'] as int,
      from: json['from'] is String ? json['from'] as String : null,
      via: via is List ? via.whereType<String>().toList() : const <String>[],
      answers: <AskAnswer>[
        if (answers is List)
          for (final Object? a in answers)
            if (AskAnswer.fromJson(a) != null) AskAnswer.fromJson(a)!,
      ],
      answeredByMe: json['answered'] == true,
      forwarded: json['fwd'] == true,
      sentTo: <String>{if (to is List) ...to.whereType<String>()},
    );
  }
}

/// "Zapytaj sieć" (§17.5): a question goes to friends; anyone may answer
/// or, by hand, pass it on (at most two steps from the asker). Answers go
/// back the same way, so the asker never needs to know who is two steps
/// away — they see "znajomy Bartka: …".
final class AskService extends ChangeNotifier {
  AskService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;
  static const String _key = 'meet/questions';

  final Map<String, Question> _questions = <String, Question>{};

  /// This installation's ledger identity, for signing answers (read from
  /// the store when first needed; none before the ledger made the keys).
  LedgerIdentity? _identity;

  /// Questions taken in per friend per day (spam guard).
  final Map<String, List<int>> _received = <String, List<int>>{};

  /// Answers passed back per question (spam guard).
  final Map<String, int> _relayed = <String, int>{};

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  List<Question> get mine => _sorted((Question q) => q.isMine);

  List<Question> get fromOthers => _sorted((Question q) => !q.isMine);

  List<Question> _sorted(bool Function(Question) where) {
    final int t = _now();
    return _questions.values
        .where((Question q) => where(q) && q.aliveAt(t))
        .toList()
      ..sort((Question a, Question b) => b.at.compareTo(a.at));
  }

  Question? question(String id) => _questions[id];

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      _diskUnreadable = false;
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is List) {
        _questions.clear();
        for (final Object? item in json) {
          final Question? q = Question.fromJson(item);
          if (q != null) {
            _questions[q.id] = q;
          }
        }
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt pytań', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    final int t = _now();
    _questions.removeWhere((String _, Question q) => !q.aliveAt(t));
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<Map<String, dynamic>>[
          for (final Question q in _questions.values) q.toJson(),
        ]),
      ),
    );
    notifyListeners();
  }

  /// Asks friends ([twoSteps]: they may pass it on once more). Returns
  /// `null` for an empty question.
  Future<Question?> ask(String text, {bool twoSteps = true}) async {
    if (text.trim().isEmpty) {
      return null;
    }
    final Question q = Question(
      id: List<String>.generate(
        14,
        (_) => _random.nextInt(36).toRadixString(36),
      ).join(),
      text: text.trim().length > 500
          ? text.trim().substring(0, 500)
          : text.trim(),
      askerName: host.ownName(),
      at: _now(),
      hops: twoSteps ? 1 : 0,
    );
    q.sentTo.addAll(host.friends().map(_n));
    _questions[q.id] = q;
    await _save();
    for (final String f in host.friends()) {
      await _sendAsk(f, q, via: const <String>[], hops: q.hops);
    }
    return q;
  }

  Future<void> _sendAsk(
    String to,
    Question q, {
    required List<String> via,
    required int hops,
  }) => _send(to, <String, dynamic>{
    'type': AskTypes.ask,
    'id': q.id,
    'text': q.text,
    'name': q.askerName,
    'at': q.at,
    'hops': hops,
    'via': via,
  });

  /// Passes someone's question on to [friends] (always by hand).
  Future<bool> forward(String id, List<String> friends) async {
    final Question? q = _questions[id];
    if (q == null || q.isMine || q.hops <= 0) {
      return false;
    }
    for (final String f in friends) {
      if (_n(f) != q.from) {
        q.sentTo.add(_n(f));
        await _sendAsk(
          f,
          q,
          via: <String>[...q.via, host.ownName()],
          hops: q.hops - 1,
        );
      }
    }
    q.forwarded = true;
    await _save();
    return true;
  }

  /// Answers; it travels back to the asker the way the question came.
  /// A member of a pyramid adds its pyramid key ([pyramidKey], of
  /// [pyramid]), so the asker can give a tip (§24).
  Future<void> answer(
    String id,
    String text, {
    String? pyramidKey,
    String? pyramid,
  }) async {
    final Question? q = _questions[id];
    final String? from = q?.from;
    if (q == null || from == null || text.trim().isEmpty) {
      return;
    }
    final String body = text.trim().length > kAnswerMaxChars
        ? text.trim().substring(0, kAnswerMaxChars)
        : text.trim();
    final String name = sanitizePeerName(host.ownName()).isEmpty
        ? host.ownName()
        : sanitizePeerName(host.ownName());
    final String? key = askKeyField(pyramidKey);
    final String? py = askKeyField(pyramid);
    final Map<String, dynamic>? proof = await _signAnswer(
      id: id,
      name: name,
      text: body,
      pyramidKey: key,
      pyramid: py,
    );
    if (proof == null) {
      return; // an answer nobody can check is not sent
    }
    await _send(from, <String, dynamic>{
      'type': AskTypes.answer,
      'id': id,
      't': body,
      'p': <String>[name],
      'k': ?key,
      'py': ?py,
      'sg': proof,
    });
    q.answeredByMe = true;
    await _save();
  }

  /// This person's signature on an answer ([askAnswerSignedBytes]); null
  /// before the ledger made the keys.
  Future<Map<String, dynamic>?> _signAnswer({
    required String id,
    required String name,
    required String text,
    String? pyramidKey,
    String? pyramid,
  }) async {
    final String own = host.ownAddress();
    if (own.isEmpty) {
      return null;
    }
    try {
      final LedgerIdentity? me = _identity ??= await LedgerIdentity.read(disk);
      if (me == null) {
        return null;
      }
      final String answerer = _n(own);
      final Uint8List sig = await me.deviceKey.sign(
        askAnswerSignedBytes(
          id: id,
          answerer: answerer,
          name: name,
          text: text,
          pyramidKey: pyramidKey,
          pyramid: pyramid,
        ),
      );
      return <String, dynamic>{
        'd': me.certificate.toJson(),
        's': b64(sig),
        'a': answerer,
      };
    } on Object catch (error, stack) {
      logZenError('Zapytaj sieć: podpis', error, stack);
      return null;
    }
  }

  /// Checks the answerer's signature ([proof]) over what came:
  ///  - `true`: signed by the device in its certificate, for this question,
  ///    these words, this name (the first of [path]) and tip key, and (for
  ///    a friend's own answer) by the friend who sent it;
  ///  - `false` (the answer is dropped): missing, malformed or not
  ///    matching.
  Future<bool> _checkAnswer(
    Object? proof, {
    required String id,
    required String from,
    required List<String> path,
    required String text,
    String? pyramidKey,
    String? pyramid,
  }) async {
    if (proof is! Map ||
        proof['s'] is! String ||
        (proof['s'] as String).length > 200 ||
        proof['a'] is! String ||
        !isRoutablePeerAddress(proof['a'] as String) ||
        path.isEmpty) {
      return false;
    }
    final DeviceCertificate? cert = DeviceCertificate.fromJson(proof['d']);
    if (cert == null) {
      return false;
    }
    final String answerer = _n(proof['a'] as String);
    final bool sound =
        await cert.verify() &&
        await verifyLedgerSignature(
          publicKey: cert.device,
          message: askAnswerSignedBytes(
            id: id,
            answerer: answerer,
            name: path.first,
            text: text,
            pyramidKey: pyramidKey,
            pyramid: pyramid,
          ),
          signature: proof['s'] as String,
        );
    if (!sound) {
      return false;
    }
    return path.length != 1 || answerer == from;
  }

  /// Notes a tip given for answer [index] of this person's question [id].
  Future<void> noteTip(String id, int index, int amount) async {
    final Question? q = _questions[id];
    if (q == null ||
        !q.isMine ||
        index < 0 ||
        index >= q.answers.length ||
        amount <= 0) {
      return;
    }
    q.answers[index] = q.answers[index].withTip(amount);
    await _save();
  }

  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !AskTypes.all.contains(type)) {
      return false;
    }
    final String from = _n(frame.from);
    if (!host.isFriend(from)) {
      return true;
    }
    try {
      if (type == AskTypes.ask) {
        await _onAsk(from, frame.payload);
      } else {
        await _onAnswer(from, frame.payload);
      }
    } on Object catch (error, stack) {
      logZenError('Zapytaj sieć', error, stack);
    }
    return true;
  }

  Future<void> _onAsk(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? text = p['text'];
    final Object? at = p['at'];
    final Object? hops = p['hops'];
    if (id is! String ||
        id.length > 40 ||
        text is! String ||
        at is! int ||
        hops is! int ||
        _questions.containsKey(id) ||
        _now() - at > kQuestionLife.inMilliseconds) {
      return;
    }
    final int nowMs = _now();
    final List<int> recent = (_received[from] ??= <int>[])
      ..removeWhere((int x) => nowMs - x > 24 * 3600 * 1000);
    if (recent.length >= kQuestionsFromFriendPerDay) {
      return;
    }
    recent.add(nowMs);
    final Object? via = p['via'];
    final Object? name = p['name'];
    final Question q = Question(
      id: id,
      text: text.length > 500 ? text.substring(0, 500) : text,
      askerName: name is String
          ? (name.length > 60 ? name.substring(0, 60) : name)
          : '',
      // A date far ahead would keep the question forever.
      at: min(at, nowMs + 10 * 60 * 1000),
      hops: hops.clamp(0, 1),
      from: from,
      via: via is List
          ? <String>[
              for (final String v in via.whereType<String>().take(3))
                v.length > 60 ? v.substring(0, 60) : v,
            ]
          : const <String>[],
    );
    _questions[id] = q;
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'ask-$id',
        title: q.via.isEmpty
            ? t('{name} pyta', {'name': host.nameOf(from)})
            : t('{name} pyta (przez {via})', {
                'name': q.askerName,
                'via': host.nameOf(from),
              }),
        body: q.text,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'ask',
      ),
    );
  }

  Future<void> _onAnswer(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? raw = p['t'];
    final Object? path = p['p'];
    final Question? q = id is String ? _questions[id] : null;
    // Only from a friend the question went to.
    if (q == null ||
        raw is! String ||
        raw.trim().isEmpty ||
        path is! List ||
        !q.sentTo.contains(from)) {
      return;
    }
    final String text = raw.length > kAnswerMaxChars
        ? raw.substring(0, kAnswerMaxChars)
        : raw;
    final List<String> names = <String>[
      for (final String n in path.whereType<String>().take(4))
        n.length > 60 ? n.substring(0, 60) : n,
    ];
    final String? key = askKeyField(p['k']);
    final String? pyramid = askKeyField(p['py']);
    // A signed answer is checked before it is shown or passed on; a missing
    // signature, or one that does not fit (words, name or tip key
    // changed), drops it.
    final Object? sg = p['sg'];
    final bool checked = raw.length > kAnswerMaxChars
        ? false
        : await _checkAnswer(
            sg,
            id: q.id,
            from: from,
            path: names,
            text: raw,
            pyramidKey: key,
            pyramid: pyramid,
          );
    if (!checked) {
      return;
    }
    if (q.isMine) {
      final int fromThem = q.answers
          .where((AskAnswer a) => a.from == from)
          .length;
      if (q.answers.length >= kAnswersPerQuestion ||
          fromThem >= kAnswersFromFriendPerQuestion) {
        return;
      }
      q.answers.add(
        AskAnswer(
          text: text,
          path: names,
          at: _now(),
          pyramidKey: key,
          pyramid: pyramid,
          from: from,
        ),
      );
      await _save();
      await host.notify(
        RuntimeSystemNotification(
          id: 'ask-answer-$id-${q.answers.length}',
          title: t('Odpowiedź: {question}', {'question': q.text}),
          body: '${answerSource(names)}: $text',
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'ask-answer:$id',
        ),
      );
      return;
    }
    // Passed on by this person: pass the answer back, adding our name.
    final String? back = q.from;
    final int relayed = _relayed[q.id] ?? 0;
    if (back != null && q.forwarded && relayed < kAnswersPerQuestion) {
      _relayed[q.id] = relayed + 1;
      await _send(back, <String, dynamic>{
        'type': AskTypes.answer,
        'id': id,
        't': text,
        'p': <String>[...names, host.ownName()],
        'k': ?key,
        'py': ?pyramid,
        // Passed on untouched: the answerer's signature covers the rest.
        'sg': ?sg,
      });
    }
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Zapytaj sieć: ${payload['type']} do $to: $error');
    }
  }
}

/// "Kasia" for a friend's own answer, "znajomy(-a) Bartka" for an answer
/// from further away.
String answerSource(List<String> path) {
  if (path.isEmpty) {
    return t('ktoś');
  }
  if (path.length == 1) {
    return path.first;
  }
  return t('{name}, znajomy(-a) {friend}', {
    'name': path.first,
    'friend': path.last,
  });
}
