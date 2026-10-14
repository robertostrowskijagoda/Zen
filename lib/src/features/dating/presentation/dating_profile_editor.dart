import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The dating profile (§19.1): built from the main profile with one tap,
/// separate from it, off by default.
class DatingProfileEditor extends ConsumerStatefulWidget {
  const DatingProfileEditor({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const DatingProfileEditor(),
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
  late final TextEditingController _age = TextEditingController(
    text: _me.age >= 18 ? '${_me.age}' : '',
  );
  late final TextEditingController _about = TextEditingController(
    text: _me.about,
  );
  late final TextEditingController _look = TextEditingController(
    text: _me.lookingFor,
  );
  late bool _enabled = _me.enabled || !_me.complete;
  late DatingGender _gender = _me.gender;
  late RangeValues _ages = RangeValues(
    _me.wants.minAge.toDouble(),
    _me.wants.maxAge.toDouble(),
  );
  late Set<DatingGender> _wantGenders = <DatingGender>{..._me.wants.genders};
  late int _hops = _me.wants.hops;
  late final List<String> _photos = List<String>.of(_me.photos);
  late final Set<String> _hiddenFriends = <String>{..._me.hiddenFriends};
  late final Set<String> _hiddenGroups = <String>{..._me.hiddenGroups};

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _about.dispose();
    _look.dispose();
    super.dispose();
  }

  Future<String?> _thumbnail(String path) async {
    final File file = File(path);
    if (!await file.exists() || await file.length() > 20 * 1024 * 1024) {
      return null;
    }
    final Uint8List? thumb = await compute(
      makeAvatarThumbnail,
      await file.readAsBytes(),
    );
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
    final int age = int.tryParse(_age.text.trim()) ?? 0;
    if (_enabled) {
      String? problem;
      if (_name.text.trim().isEmpty) {
        problem = 'Wpisz imię.';
      } else if (age < 18 || age > 120) {
        problem = 'Wpisz wiek (co najmniej 18).';
      } else if (_wantGenders.isEmpty) {
        problem = 'Zaznacz, kogo szukasz.';
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
        ..adult = true
        ..name = _name.text.trim()
        ..age = age
        ..gender = _gender
        ..about = _about.text.trim()
        ..lookingFor = _look.text.trim()
        ..wants = DatingWants(
          minAge: _ages.start.round(),
          maxAge: _ages.end.round(),
          genders: _wantGenders,
          hops: _hops,
        )
        ..photos.clear()
        ..photos.addAll(_photos);
      m.hiddenFriends
        ..clear()
        ..addAll(_hiddenFriends);
      m.hiddenGroups
        ..clear()
        ..addAll(_hiddenGroups);
    });
    // „Randkuję” (§16.2) goes out with dating; with new hiding it is sent
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
          title: const Text('Kogo poprosić o kilka słów?'),
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: ZenInfo(
                icon: Icons.info_outline_rounded,
                text: 'Ta osoba dowie się, że randkujesz.',
              ),
            ),
            if (social.acceptedFriends.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Text(
                  'Nie masz jeszcze znajomych.',
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
          const SnackBar(
            content: Text('Wysłane. Gdy odpisze, zatwierdzisz tekst tutaj.'),
          ),
        );
      }
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
    final TextStyle rowTitle = TextStyle(
      color: zen.textPrimary,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    final TextStyle note = TextStyle(
      color: zen.textSecondary,
      fontSize: 13.5,
      height: 1.4,
    );
    return Scaffold(
      key: const Key('dating-editor'),
      appBar: AppBar(
        title: const Text('Profil randkowy'),
        actions: <Widget>[
          TextButton(
            key: const Key('dating-save'),
            onPressed: () => unawaited(_save()),
            child: const Text('Zapisz'),
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
                title: const Text('Randki włączone'),
                subtitle: const Text(
                  'Wyłączone: Twój profil przestaje się rozchodzić i po ~2 '
                  'tygodniach znika u innych.',
                ),
                onChanged: (bool v) => setState(() => _enabled = v),
              ),
            ],
          ),
          const ZenSection('Zdjęcia'),
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Do $kDatingMaxPhotos zdjęć. Pierwsze jest główne — dotknij innego, '
                  'żeby je nim zrobić.',
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
                            borderRadius: BorderRadius.circular(22),
                            onTap: i == 0 ? null : () => _makeMain(i),
                            child: datingPhoto(_photos[i], size: 76),
                          ),
                          if (i == 0)
                            Positioned(
                              left: 4,
                              bottom: 4,
                              child: IgnorePointer(
                                child: ZenPill(
                                  text: 'Główne',
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
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => unawaited(_pickPhotos()),
                        child: Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
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
                      label: const Text('Dodaj zdjęcia'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('dating-from-main'),
                      onPressed: () => unawaited(_fromMain()),
                      icon: const Icon(Icons.content_copy_rounded),
                      label: const Text('Weź z mojego profilu'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const ZenSection('O Tobie'),
          TextField(
            key: const Key('dating-name'),
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Imię',
              hintText: 'np. Ola',
              prefixIcon: Icon(Icons.badge_rounded),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('dating-age'),
            controller: _age,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Wiek',
              hintText: 'co najmniej 18',
              prefixIcon: Icon(Icons.cake_rounded),
            ),
          ),
          const SizedBox(height: 16),
          Text('JESTEM', style: zen.label(color: zen.textMuted)),
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
            decoration: const InputDecoration(
              labelText: 'O mnie',
              hintText: 'Co lubisz, czym się zajmujesz, co Cię śmieszy…',
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _look,
            maxLines: 2,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Czego szukam',
              hintText: 'np. kogoś na długie spacery i dłużej',
            ),
          ),
          const ZenSection('Kogo szukasz'),
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
          const SizedBox(height: 8),
          ZenCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text('Wiek', style: rowTitle)),
                    ZenPill(
                      text: '${_ages.start.round()}–${_ages.end.round()}',
                      tone: tone,
                    ),
                  ],
                ),
                RangeSlider(
                  values: _ages,
                  min: 18,
                  max: 99,
                  divisions: 81,
                  activeColor: tone,
                  onChanged: (RangeValues v) => setState(() => _ages = v),
                ),
                Divider(height: 16, color: zen.outlineSoft),
                Row(
                  children: <Widget>[
                    Expanded(child: Text('Jak daleko', style: rowTitle)),
                    ZenPill(
                      text:
                          '$_hops ${_hops == 1 ? 'krok' : 'kroki'} znajomości',
                      tone: tone,
                    ),
                  ],
                ),
                Slider(
                  value: _hops.toDouble(),
                  min: 1,
                  max: 3,
                  divisions: 2,
                  label: '$_hops',
                  activeColor: tone,
                  onChanged: (double v) => setState(() => _hops = v.round()),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '1 — Twoi znajomi, 2 — ich znajomi, 3 — o krok dalej.',
                    style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const ZenSection('Ukryj przed'),
          ZenInfo(
            icon: Icons.visibility_off_rounded,
            tone: tone,
            text:
                'Ci ludzie nie zobaczą Twojego profilu (np. rodzina, praca). '
                'Działa też, gdy profil dotrze do nich okrężną drogą.',
          ),
          const SizedBox(height: 8),
          if (social.groups.isEmpty && social.acceptedFriends.isEmpty)
            Text(
              'Nie masz jeszcze znajomych ani grup.',
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
                  showCheckmark: false,
                  avatar: Icon(
                    _hiddenFriends.contains(f.address)
                        ? Icons.visibility_off_rounded
                        : Icons.person_rounded,
                    size: 18,
                  ),
                  label: Text(
                    social.nameFor(f),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: _hiddenFriends.contains(f.address),
                  onSelected: (bool v) => setState(
                    () => _toggle<String>(_hiddenFriends, f.address, v),
                  ),
                ),
            ],
          ),
          const ZenSection('Znajomi o mnie'),
          ListenableBuilder(
            listenable: _dating,
            builder: (BuildContext context, Widget? _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_dating.me.vouches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Kilka słów od znajomego mówi o Tobie więcej niż najlepszy opis.',
                      style: note,
                    ),
                  ),
                for (final DatingVouch v in _dating.me.vouches)
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
                                '${v.by} · ✓ podpisane'
                                '${v.approved ? ' · na profilu' : ' · czeka na Twoją zgodę'}',
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
                            tooltip: 'Pokaż na profilu',
                            color: zen.success,
                            icon: const Icon(Icons.check_rounded),
                            onPressed: () =>
                                unawaited(_dating.setVouch(v.id, keep: true)),
                          ),
                        IconButton(
                          tooltip: 'Usuń',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () =>
                              unawaited(_dating.setVouch(v.id, keep: false)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => unawaited(_askVouch(social)),
            icon: const Icon(Icons.rate_review_rounded),
            label: const Text('Poproś znajomego o kilka słów'),
          ),
        ],
      ),
    );
  }
}
