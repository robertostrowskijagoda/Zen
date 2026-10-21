import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/dating/presentation/dating_reconfirm.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';
import 'package:zen/src/features/meet/graph/graph_providers.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The dating profile: built from the main profile with one tap,
/// separate from it, off by default.
class DatingProfileEditor extends ConsumerStatefulWidget {
  const DatingProfileEditor({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const SecureScreen(
        child: DatingReconfirm(child: DatingProfileEditor()),
      ),
    ),
  );

  @override
  ConsumerState<DatingProfileEditor> createState() =>
      _DatingProfileEditorState();
}

class _DatingProfileEditorState extends ConsumerState<DatingProfileEditor> {
  late final DatingService _dating = ref.read(datingServiceProvider);
  late final MyDating _me = _dating.me;
  late final TextEditingController _name = TextEditingController(
    text: _me.name,
  );
  late final TextEditingController _about = TextEditingController(
    text: _me.about,
  );
  late final TextEditingController _look = TextEditingController(
    text: _me.lookingFor,
  );
  late bool _enabled = _me.enabled || !_me.complete;
  late DatingGender _gender = _me.gender;
  late Set<DatingGender> _wantGenders = <DatingGender>{..._me.wants.genders};
  late int _hops = _me.wants.hops;
  late DatingIntent _intent = _me.wants.intent;
  late bool _friendsAnyGender =
      _me.wants.friendGenders.length == kDatingAllGenders.length;
  late Set<DatingGender> _friendGenders = <DatingGender>{
    ..._me.wants.friendGenders,
  };
  late final List<String> _interests = List<String>.of(_me.interests);
  late final TextEditingController _tag = TextEditingController();
  late final List<String> _photos = List<String>.of(_me.photos);
  late final Set<String> _hiddenFriends = <String>{..._me.hiddenFriends};
  late final Set<String> _hiddenCircles = <String>{..._me.hiddenCircles};
  late final Set<String> _hiddenGroups = <String>{..._me.hiddenGroups};

  /// All approved vouches are listed (otherwise the first few).
  bool _allVouches = false;

  /// "Pokazać Cię na grafie…?" (`null` until the saved answer is read).
  bool? _showOnGraph;

  @override
  void initState() {
    super.initState();
    final OpenToMeetService graph = ref.read(openToMeetServiceProvider);
    unawaited(
      graph.load().then((_) {
        if (mounted && _showOnGraph == null) {
          setState(() => _showOnGraph = graph.mine != null);
        }
      }),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _look.dispose();
    _tag.dispose();
    super.dispose();
  }

  Future<String?> _thumbnail(String path) async {
    // The main profile photo is kept encrypted: read through the
    // vault; a freshly picked file is read as it is.
    final Uint8List? bytes = await readOwnProfileImage(path);
    if (bytes == null) {
      return null;
    }
    final Uint8List? thumb = await compute(makeAvatarThumbnail, bytes);
    return thumb == null ? null : base64Encode(thumb);
  }

  /// One tap: name, "o mnie" and photo from the main profile.
  Future<void> _fromMain() async {
    final UserProfile p = ref.read(userProfileControllerProvider);
    final String? path = p.avatarPath;
    final String? photo = path == null ? null : await _thumbnail(path);
    if (!mounted) {
      return;
    }
    setState(() {
      if (p.displayName.trim().isNotEmpty) {
        _name.text = p.displayName.trim().split(' ').first;
      }
      if (p.bio.trim().isNotEmpty) {
        _about.text = p.bio.trim();
      }
      if (photo != null && !_photos.contains(photo)) {
        // The main photo goes first.
        if (_photos.length >= kDatingMaxPhotos) {
          _photos.removeLast();
        }
        _photos.insert(0, photo);
      }
    });
  }

  /// Adds photos from the gallery, up to [kDatingMaxPhotos] in all.
  Future<void> _pickPhotos() async {
    final int room = kDatingMaxPhotos - _photos.length;
    if (room <= 0) {
      return;
    }
    final FilePickerResult? r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: room > 1,
    );
    final List<String> paths = <String>[
      for (final PlatformFile f in r?.files ?? const <PlatformFile>[])
        if (f.path != null) f.path!,
    ];
    final List<String> added = <String>[];
    for (final String path in paths.take(room)) {
      final String? photo = await _thumbnail(path);
      if (photo != null) {
        added.add(photo);
      }
    }
    if (mounted && added.isNotEmpty) {
      setState(() {
        _photos.addAll(added.take(kDatingMaxPhotos - _photos.length));
      });
    }
  }

  void _removePhoto(int i) => setState(() => _photos.removeAt(i));

  /// Makes photo [i] the main one (first).
  void _makeMain(int i) =>
      setState(() => _photos.insert(0, _photos.removeAt(i)));

  Future<void> _save() async {
    final MeetService meet = ref.read(meetServiceProvider);
    if (_enabled) {
      String? problem;
      if (_name.text.trim().isEmpty) {
        problem = t('Wpisz imię.');
      } else if ((_intent != DatingIntent.friends && _wantGenders.isEmpty) ||
          (_intent != DatingIntent.dates &&
              !_friendsAnyGender &&
              _friendGenders.isEmpty)) {
        problem = t('Zaznacz, kogo szukasz.');
      }
      if (problem != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(problem)));
        return;
      }
    }
    await _dating.saveMine((MyDating m) {
      m
        ..enabled = _enabled
        ..name = _name.text.trim()
        ..gender = _gender
        ..about = _about.text.trim()
        ..lookingFor = _look.text.trim()
        ..wants = DatingWants(
          genders: _wantGenders.isEmpty ? kDatingAllGenders : _wantGenders,
          hops: _hops,
          intent: _intent,
          friendGenders: _friendsAnyGender || _friendGenders.isEmpty
              ? kDatingAllGenders
              : _friendGenders,
        )
        ..photos.clear()
        ..photos.addAll(_photos);
      m.interests
        ..clear()
        ..addAll(datingTagsFrom(_interests));
      m.hiddenFriends
        ..clear()
        ..addAll(_hiddenFriends);
      m.hiddenCircles
        ..clear()
        ..addAll(_hiddenCircles.where(_hiddenFriends.contains));
      m.hiddenGroups
        ..clear()
        ..addAll(_hiddenGroups);
    });
    // On the graph: only the intention, only while dating is on, never to
    // the people it is hidden from.
    final OpenToMeetService graph = ref.read(openToMeetServiceProvider);
    await graph.load();
    final bool onGraph = _enabled && (_showOnGraph ?? graph.mine != null);
    await graph.setMine(
      onGraph ? OpenToMeet.forIntent(_intent) : null,
      hiddenFrom: _dating.hiddenAddresses(),
    );
    // „Randkuję” goes out with dating; with new hiding it is sent
    // again, so newly hidden people stop seeing it.
    final IntentStatus? status = meet.book.myIntent;
    if (status != null && status.kind == IntentKind.dating) {
      await meet.setMyIntent(
        _enabled ? status : null,
        except: _dating.hiddenAddresses(),
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _askVouch(SocialHubState social) async {
    final String? friend = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return SimpleDialog(
          title: Text(t('Kogo poprosić o kilka słów?')),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: ZenInfo(
                icon: Icons.info_outline_rounded,
                text: t('Ta osoba dowie się, że randkujesz.'),
              ),
            ),
            if (social.acceptedFriends.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Text(
                  t('Nie masz jeszcze znajomych.'),
                  style: TextStyle(color: zen.textMuted),
                ),
              ),
            for (final FriendProfile f in social.acceptedFriends)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(f.address),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.person_rounded,
                      color: datingTone(zen),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        social.nameFor(f),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: zen.textPrimary, fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
    if (friend != null) {
      await _dating.requestVouch(friend);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Wysłane. Gdy odpisze, zatwierdzisz tekst tutaj.')),
          ),
        );
      }
    }
  }

  /// Vouches listed before "Pokaż wszystkie".
  static const int _vouchesFirst = 5;

  /// Vouches waiting for approval first, then the first few shown ones (or
  /// all of them).
  List<DatingVouch> _shownVouches() {
    final List<DatingVouch> all = <DatingVouch>[
      ..._dating.me.vouches.where((DatingVouch v) => !v.approved),
      ..._dating.me.vouches.where((DatingVouch v) => v.approved),
    ];
    return _allVouches ? all : all.take(_vouchesFirst).toList();
  }

  /// Adds an interest typed or picked ([datingTag]); the same one twice
  /// (by [datingTagKey]) is not added.
  void _addTag(String raw) {
    final String? tag = datingTag(raw);
    if (tag == null || _interests.length >= kDatingMaxInterests) {
      return;
    }
    setState(() {
      if (!_interests.any((String i) => datingTagKey(i) == datingTagKey(tag))) {
        _interests.add(tag);
      }
      _tag.clear();
    });
  }

  /// "Ukryj przed" one friend: not at all, only from them, or from them and
  /// everyone this person reaches only through them.
  Future<void> _chooseHiding(String address, String name) async {
    final int current = !_hiddenFriends.contains(address)
        ? 0
        : _hiddenCircles.contains(address)
        ? 2
        : 1;
    final int? choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final (int, IconData, String, String) o
                in <(int, IconData, String, String)>[
                  (0, Icons.person_rounded, t('Nie ukrywaj'), ''),
                  (
                    1,
                    Icons.visibility_off_rounded,
                    t('Ukryj tylko przed nim / nią'),
                    t(
                      'Jego/jej znajomi mogą Cię dalej zobaczyć, także przez '
                      'tę osobę.',
                    ),
                  ),
                  (
                    2,
                    Icons.group_off_rounded,
                    t('Ukryj przed nim / nią i jego/jej kręgiem'),
                    t(
                      'Nikt, do kogo docierasz tylko przez tę osobę, nie '
                      'zobaczy Twojego profilu (ani Ty jego).',
                    ),
                  ),
                ])
              ListTile(
                key: Key('dating-hide-choice-${o.$1}'),
                leading: Icon(o.$2),
                title: Text(o.$3),
                subtitle: o.$4.isEmpty ? null : Text(o.$4),
                trailing: current == o.$1
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(context).pop(o.$1),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) {
      return;
    }
    setState(() {
      _toggle<String>(_hiddenFriends, address, choice > 0);
      _toggle<String>(_hiddenCircles, address, choice == 2);
    });
  }

  /// Turning the graph flag on asks once more: it shows people that this
  /// person dates.
  Future<void> _setShowOnGraph(bool on) async {
    if (!on) {
      setState(() => _showOnGraph = false);
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Pokazać na grafie?')),
        content: Text(
          t(
            'Znajomi do 3 kroków (i osoby za otwartymi bramami), którzy widzą '
            'Cię na grafie, zobaczą przy Twoim imieniu, że jesteś otwarta(-y) '
            'na poznanie. Możesz to w każdej chwili wyłączyć.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('dating-graph-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Pokaż')),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _showOnGraph = true);
    }
  }

  void _toggle<T>(Set<T> set, T value, bool on) {
    if (on) {
      set.add(value);
    } else {
      set.remove(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final SocialHubState social = watchSocialPeople(ref);
    final TextStyle note = TextStyle(
      color: zen.textSecondary,
      fontSize: 13.5,
      height: 1.4,
    );
    return Scaffold(
      key: const Key('dating-editor'),
      appBar: AppBar(
        title: Text(t('Profil randkowy')),
        actions: <Widget>[
          TextButton(
            key: const Key('dating-save'),
            onPressed: () => unawaited(_save()),
            child: Text(t('Zapisz')),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          ZenGroup(
            children: <Widget>[
              SwitchListTile(
                key: const Key('dating-enabled'),
                value: _enabled,
                secondary: Icon(
                  _enabled
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: _enabled ? tone : zen.textMuted,
                ),
                title: Text(t('Randki włączone')),
                subtitle: Text(
                  t(
                    'Wyłączone: Twój profil przestaje się rozchodzić i po ~2 '
                    'tygodniach znika u innych.',
                  ),
                ),
                onChanged: (bool v) => setState(() => _enabled = v),
              ),
            ],
          ),
          ZenSection(t('Zdjęcia')),
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  t(
                    'Do {count} zdjęć. Pierwsze jest główne — dotknij '
                    'innego, żeby je nim zrobić.',
                    {'count': kDatingMaxPhotos},
                  ),
                  style: note,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    for (int i = 0; i < _photos.length; i++)
                      Stack(
                        key: Key('dating-photo-$i'),
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          InkWell(
                            borderRadius: context.zenRadius(22),
                            onTap: i == 0 ? null : () => _makeMain(i),
                            child: datingPhoto(_photos[i], size: 76),
                          ),
                          if (i == 0)
                            Positioned(
                              left: 4,
                              bottom: 4,
                              child: IgnorePointer(
                                child: ZenPill(
                                  text: t('Główne'),
                                  tone: tone,
                                  filled: true,
                                ),
                              ),
                            ),
                          Positioned(
                            right: -6,
                            top: -6,
                            child: Material(
                              color: zen.surfaceRaised,
                              shape: CircleBorder(
                                side: BorderSide(color: zen.outlineSoft),
                              ),
                              child: InkWell(
                                key: Key('dating-photo-remove-$i'),
                                customBorder: const CircleBorder(),
                                onTap: () => _removePhoto(i),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: zen.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_photos.length < kDatingMaxPhotos)
                      InkWell(
                        key: const Key('dating-photo-add'),
                        borderRadius: context.zenRadius(22),
                        onTap: () => unawaited(_pickPhotos()),
                        child: Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            borderRadius: context.zenRadius(22),
                            color: tone.withValues(alpha: 0.08),
                            border: Border.all(
                              color: tone.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Icon(Icons.add_a_photo_rounded, color: tone),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _photos.length >= kDatingMaxPhotos
                          ? null
                          : () => unawaited(_pickPhotos()),
                      icon: const Icon(Icons.photo_library_rounded),
                      label: Text(t('Dodaj zdjęcia')),
                    ),
                    OutlinedButton.icon(
                      key: const Key('dating-from-main'),
                      onPressed: () => unawaited(_fromMain()),
                      icon: const Icon(Icons.content_copy_rounded),
                      label: Text(t('Weź z mojego profilu')),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ZenSection(t('O Tobie')),
          TextField(
            key: const Key('dating-name'),
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: t('Imię'),
              hintText: t('np. Ola'),
              prefixIcon: const Icon(Icons.badge_rounded),
            ),
          ),
          const SizedBox(height: 12),
          Text(t('JESTEM'), style: zen.label(color: zen.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final DatingGender g in DatingGender.values)
                ChoiceChip(
                  label: Text(g.label),
                  selected: _gender == g,
                  onSelected: (_) => setState(() => _gender = g),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _about,
            maxLines: 4,
            minLines: 2,
            maxLength: 1000,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: t('O mnie'),
              hintText: t('Co lubisz, czym się zajmujesz, co Cię śmieszy…'),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _look,
            maxLines: 2,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: t('Czego szukam'),
              hintText: t('np. kogoś na długie spacery i dłużej'),
            ),
          ),
          ZenSection(t('Szukam')),
          ZenGroup(
            children: <Widget>[
              for (final DatingIntent i in DatingIntent.values)
                ListTile(
                  key: Key('dating-intent-${i.code}'),
                  selected: _intent == i,
                  selectedColor: tone,
                  leading: Icon(switch (i) {
                    DatingIntent.dates => Icons.favorite_rounded,
                    DatingIntent.friends => Icons.waving_hand_rounded,
                    DatingIntent.both => Icons.diversity_3_rounded,
                  }),
                  title: Text(i.label),
                  subtitle: Text(i.hint),
                  trailing: _intent == i
                      ? Icon(Icons.check_circle_rounded, color: tone)
                      : null,
                  onTap: () => setState(() => _intent = i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ZenGroup(
            children: <Widget>[
              SwitchListTile(
                key: const Key('dating-show-on-graph'),
                value: _enabled && (_showOnGraph ?? false),
                secondary: Icon(Icons.hub_rounded, color: tone),
                title: Text(
                  t('Pokazać Cię na grafie jako osobę otwartą na poznanie?'),
                ),
                subtitle: Text(
                  t(
                    'Domyślnie nie. Włączone: ludzie do 3 kroków znajomości '
                    '(i za otwartymi bramami) zobaczą na grafie Twoje imię '
                    'z „randki” albo „znajomości” — czyli że randkujesz. '
                    'Nic więcej z profilu; osoby z „Ukryj przed” nie '
                    'zobaczą nic.',
                  ),
                ),
                onChanged: _enabled
                    ? (bool v) => unawaited(_setShowOnGraph(v))
                    : null,
              ),
            ],
          ),
          if (_intent != DatingIntent.friends) ...<Widget>[
            ZenSection(
              _intent == DatingIntent.both
                  ? t('Kogo szukasz na randki')
                  : t('Kogo szukasz'),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final DatingGender g in DatingGender.values)
                  FilterChip(
                    label: Text(g.label),
                    selected: _wantGenders.contains(g),
                    onSelected: (bool v) => setState(() {
                      _wantGenders = <DatingGender>{..._wantGenders};
                      if (v) {
                        _wantGenders.add(g);
                      } else {
                        _wantGenders.remove(g);
                      }
                    }),
                  ),
              ],
            ),
          ],
          if (_intent != DatingIntent.dates) ...<Widget>[
            ZenSection(t('Nowi znajomi')),
            ZenGroup(
              children: <Widget>[
                SwitchListTile(
                  key: const Key('dating-friends-any-gender'),
                  value: _friendsAnyGender,
                  title: Text(t('Dowolna płeć')),
                  onChanged: (bool v) => setState(() => _friendsAnyGender = v),
                ),
              ],
            ),
            if (!_friendsAnyGender) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final DatingGender g in DatingGender.values)
                    FilterChip(
                      label: Text(g.label),
                      selected: _friendGenders.contains(g),
                      onSelected: (bool v) => setState(() {
                        _friendGenders = <DatingGender>{..._friendGenders};
                        if (v) {
                          _friendGenders.add(g);
                        } else {
                          _friendGenders.remove(g);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ],
          ZenSection(t('Jak daleko chcesz widzieć')),
          Text(
            t(
              'Tylko ludzie w tym zasięgu zobaczą Twój profil i Ty ich. Do 3 '
              'kroków nie trzeba otwierać bram.',
            ),
            style: note,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (int h = 1; h <= kDatingRangeGates; h++)
                ChoiceChip(
                  key: Key('dating-reach-$h'),
                  label: Text(datingReachLabel(h)),
                  selected: _hops == h,
                  onSelected: (_) => setState(() => _hops = h),
                ),
            ],
          ),
          ZenSection(t('Zainteresowania')),
          Text(
            t(
              'Wpisz własne albo wybierz z podpowiedzi — do {count}. Wielkość '
              'liter i polskie znaki nie mają znaczenia w filtrach.',
              {'count': kDatingMaxInterests},
            ),
            style: note,
          ),
          const SizedBox(height: 8),
          if (_interests.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String tag in _interests)
                  InputChip(
                    key: Key('dating-tag-$tag'),
                    label: Text(tag),
                    selected: true,
                    showCheckmark: false,
                    onDeleted: () => setState(() => _interests.remove(tag)),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('dating-tag-input'),
            controller: _tag,
            enabled: _interests.length < kDatingMaxInterests,
            maxLength: kDatingTagMaxChars,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: t('Dodaj zainteresowanie'),
              hintText: t('np. wspinaczka'),
              suffixIcon: IconButton(
                key: const Key('dating-tag-add'),
                tooltip: t('Dodaj'),
                icon: const Icon(Icons.add_rounded),
                onPressed: () => _addTag(_tag.text),
              ),
            ),
            onSubmitted: _addTag,
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String tag in datingTagSuggestions())
                if (!_interests.any(
                  (String i) => datingTagKey(i) == datingTagKey(tag),
                ))
                  ActionChip(
                    key: Key('dating-tag-suggest-$tag'),
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: Text(tag),
                    onPressed: _interests.length >= kDatingMaxInterests
                        ? null
                        : () => _addTag(tag),
                  ),
            ],
          ),
          ZenSection(t('Ukryj przed')),
          ZenInfo(
            icon: Icons.visibility_off_rounded,
            tone: tone,
            text: t(
              'Ci ludzie nie zobaczą Twojego profilu (np. rodzina, praca), '
              'także gdy dotrze do nich okrężną drogą. Przy znajomym możesz '
              'wybrać: tylko on(a), albo też jego/jej krąg — wtedy nie '
              'poznasz nikogo, do kogo docierasz tylko przez tę osobę.',
            ),
          ),
          const SizedBox(height: 8),
          if (social.groups.isEmpty && social.acceptedFriends.isEmpty)
            Text(
              t('Nie masz jeszcze znajomych ani grup.'),
              style: TextStyle(color: zen.textMuted, fontSize: 13.5),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final GroupProfile g in social.groups.values)
                FilterChip(
                  showCheckmark: false,
                  avatar: Icon(
                    _hiddenGroups.contains(g.id)
                        ? Icons.visibility_off_rounded
                        : Icons.groups_rounded,
                    size: 18,
                  ),
                  label: Text(
                    g.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: _hiddenGroups.contains(g.id),
                  onSelected: (bool v) =>
                      setState(() => _toggle<String>(_hiddenGroups, g.id, v)),
                ),
              for (final FriendProfile f in social.acceptedFriends)
                FilterChip(
                  key: Key('dating-hide-${f.address}'),
                  showCheckmark: false,
                  avatar: Icon(
                    !_hiddenFriends.contains(f.address)
                        ? Icons.person_rounded
                        : _hiddenCircles.contains(f.address)
                        ? Icons.group_off_rounded
                        : Icons.visibility_off_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _hiddenCircles.contains(f.address) &&
                            _hiddenFriends.contains(f.address)
                        ? t('{name} i krąg', {'name': social.nameFor(f)})
                        : social.nameFor(f),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: _hiddenFriends.contains(f.address),
                  onSelected: (_) =>
                      unawaited(_chooseHiding(f.address, social.nameFor(f))),
                ),
            ],
          ),
          ZenSection(t('Znajomi o mnie')),
          ListenableBuilder(
            listenable: _dating,
            builder: (BuildContext context, Widget? _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_dating.me.vouches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      t(
                        'Kilka słów od znajomego mówi o Tobie więcej niż '
                        'najlepszy opis.',
                      ),
                      style: note,
                    ),
                  ),
                for (final DatingVouch v in _shownVouches())
                  ZenCard(
                    tone: v.approved ? null : zen.warning,
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.format_quote_rounded,
                            color: tone,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '„${v.text}”',
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontSize: 14.5,
                                  height: 1.4,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                v.approved
                                    ? t('{name} · ✓ podpisane · na profilu', {
                                        'name': v.by,
                                      })
                                    : t(
                                        '{name} · ✓ podpisane · czeka na '
                                        'Twoją zgodę',
                                        {'name': v.by},
                                      ),
                                style: TextStyle(
                                  color: v.approved
                                      ? zen.textMuted
                                      : zen.warning,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!v.approved)
                          IconButton(
                            tooltip: t('Pokaż na profilu'),
                            color: zen.success,
                            icon: const Icon(Icons.check_rounded),
                            onPressed: () =>
                                unawaited(_dating.setVouch(v.id, keep: true)),
                          ),
                        IconButton(
                          tooltip: t('Usuń'),
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () =>
                              unawaited(_dating.setVouch(v.id, keep: false)),
                        ),
                      ],
                    ),
                  ),
                if (_dating.me.vouches.length > _vouchesFirst)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('dating-editor-vouches-more'),
                      onPressed: () =>
                          setState(() => _allVouches = !_allVouches),
                      icon: Icon(
                        _allVouches
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                      ),
                      label: Text(
                        _allVouches
                            ? t('Pokaż mniej')
                            : t('Pokaż wszystkie ({count})', {
                                'count': _dating.me.vouches.length,
                              }),
                      ),
                    ),
                  ),
                Text(
                  t('Na profilu: {count} z {max}', {
                    'count': _dating.me.vouches
                        .where((DatingVouch v) => v.approved)
                        .length,
                    'max': kDatingMaxVouches,
                  }),
                  style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => unawaited(_askVouch(social)),
            icon: const Icon(Icons.rate_review_rounded),
            label: Text(t('Poproś znajomego o kilka słów')),
          ),
        ],
      ),
    );
  }
}
