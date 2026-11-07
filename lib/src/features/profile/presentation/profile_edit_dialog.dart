import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/file_picking.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/presentation/rich_text_controller.dart';
import 'package:zen/src/features/media/crop_region.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/presentation/image_crop_screen.dart';
import 'package:zen/src/features/profile/presentation/keyboard_picture_dialog.dart';
import 'package:zen/src/features/profile/presentation/own_avatar.dart';
import 'package:zen/src/features/profile/profile_cover.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// Edits your profile: photo, cover, name and bio. The short status
/// is set from the top bar, not here.
class ProfileEditDialog extends ConsumerStatefulWidget {
  const ProfileEditDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) => const ProfileEditDialog(),
    );
  }

  @override
  ConsumerState<ProfileEditDialog> createState() => _ProfileEditDialogState();
}

/// A picked picture: a file, or bytes already in memory.
typedef _Picked = ({String? path, Uint8List? bytes});

/// Where a photo or a cover comes from.
enum _PictureSource { gallery, camera, file, gifSearch, keyboard }

class _ProfileEditDialogState extends ConsumerState<ProfileEditDialog> {
  late TextEditingController _nameController;
  late RichTextController _bioController;
  String? _avatarPath;
  String? _coverPath;
  bool _isProcessingCover = false;

  /// Cover written in this dialog and not saved yet (removed on cancel).
  String? _stagedCoverPath;
  bool _isProcessingImage = false;
  bool _isSaving = false;

  /// Who sees each field, as edited here.
  late Map<String, String> _visibility;
  late TextEditingController _nationalityController;
  String? _nationalityError;

  /// Avatar copy created inside this dialog but not committed yet. It is
  /// deleted when the user picks another image or closes without saving, so
  /// abandoned picks do not pile up in the sandbox.
  String? _stagedAvatarPath;

  @override
  void initState() {
    super.initState();
    final UserProfile profile = ref.read(userProfileControllerProvider);
    _nameController = TextEditingController(text: profile.displayName);
    _bioController = RichTextController(text: profile.bio);
    _avatarPath = profile.avatarPath;
    _coverPath = profile.coverPath;
    _visibility = Map<String, String>.of(profile.visibility);
    _nationalityController = TextEditingController(
      text: profile.nationalities.join(', '),
    );
    if (!kIsWeb && Platform.isAndroid) {
      // Android can tear the activity down while the camera/gallery is in
      // front; without this the picked photo is simply lost on return.
      unawaitedLogged(
        _restoreLostAndroidPick(),
        context: 'Restoring a lost Android avatar pick failed',
      );
    }
  }

  @override
  void dispose() {
    final String? staged = _stagedAvatarPath;
    if (staged != null) {
      unawaitedLogged(
        AvatarSanitizer.cleanupOldAvatar(staged),
        context: 'Discarding an abandoned avatar pick failed',
      );
    }
    final String? stagedCover = _stagedCoverPath;
    if (stagedCover != null) {
      unawaitedLogged(
        deleteCoverImage(stagedCover),
        context: 'Discarding an abandoned cover pick failed',
      );
    }
    _nameController.dispose();
    _bioController.dispose();
    _nationalityController.dispose();
    super.dispose();
  }

  Future<void> _restoreLostAndroidPick() async {
    final LostDataResponse lost = await ImagePicker().retrieveLostData();
    final String? path = lost.file?.path;
    if (path == null || !mounted) {
      return;
    }
    await _storePickedAvatar((path: path, bytes: null));
  }

  Future<void> _pickAvatarImage() async {
    if (_isProcessingImage) {
      return;
    }
    _Picked? picked;
    try {
      picked = await _selectPicture();
    } catch (error, stackTrace) {
      logZenError('Opening the avatar picker failed', error, stackTrace);
      _showAvatarMessage(
        t('Nie udało się otworzyć okna wyboru zdjęcia: {error}', {
          'error': error,
        }),
        isError: true,
      );
      return;
    }
    if (picked == null || !mounted) {
      return;
    }
    await _storePickedAvatar(picked);
  }

  /// What the person picked: a file ([_Picked.path]) or a picture already in
  /// memory ([_Picked.bytes]: a GIF from the search or the keyboard); `null`
  /// when they closed the picker. Throws when the picker itself could not
  /// run — that has to reach the user instead of looking like a silent
  /// no-op.
  Future<_Picked?> _selectPicture() async {
    final bool isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final bool gifs = ref.read(gifSearchEnabledProvider);
    if (isDesktop && !gifs) {
      return _fromFile();
    }

    final ZenColors zen = ZenColors.of(context);
    Widget option(
      BuildContext sheet,
      _PictureSource source,
      IconData icon,
      String label,
    ) => ListTile(
      key: Key('profile-picture-${source.name}'),
      leading: Icon(icon, color: zen.accent),
      title: Text(label),
      onTap: () => Navigator.of(sheet).pop(source),
    );
    final _PictureSource? source = await showModalBottomSheet<_PictureSource>(
      context: context,
      backgroundColor: zen.surfaceRaised,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      shape: context.zenSheetShape(),
      builder: (BuildContext sheet) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (!isDesktop) ...<Widget>[
                  option(
                    sheet,
                    _PictureSource.gallery,
                    Icons.photo_library_outlined,
                    t('Wybierz z galerii'),
                  ),
                  option(
                    sheet,
                    _PictureSource.camera,
                    Icons.photo_camera_outlined,
                    t('Zrób zdjęcie (Aparat)'),
                  ),
                ],
                option(
                  sheet,
                  _PictureSource.file,
                  Icons.folder_open_outlined,
                  t('Wybierz plik z urządzenia'),
                ),
                if (gifs)
                  option(
                    sheet,
                    _PictureSource.gifSearch,
                    Icons.gif_box_outlined,
                    t('Wyszukaj GIF'),
                  ),
                if (!isDesktop)
                  option(
                    sheet,
                    _PictureSource.keyboard,
                    Icons.keyboard_alt_outlined,
                    t('GIF z klawiatury'),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || source == null) {
      return null;
    }
    switch (source) {
      case _PictureSource.file:
        return _fromFile();
      case _PictureSource.gifSearch:
        final GifCatalogEntry? entry = await showChatGifPicker(context, ref);
        if (entry == null || !mounted) {
          return null;
        }
        // This device fetches the GIF; friends get it as the photo itself.
        final Uint8List bytes;
        try {
          bytes = await ref.read(gifDownloaderProvider).download(entry.sendUrl);
        } on Object {
          throw FormatException(t('Nie udało się pobrać GIF-a.'));
        }
        return (path: null, bytes: bytes);
      case _PictureSource.keyboard:
        final Uint8List? bytes = await showKeyboardPictureDialog(context);
        return bytes == null ? null : (path: null, bytes: bytes);
      case _PictureSource.gallery:
      case _PictureSource.camera:
        break;
    }
    try {
      final XFile? image = await ImagePicker().pickImage(
        source: source == _PictureSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 88,
      );
      return image == null ? null : (path: image.path, bytes: null);
    } catch (error, stackTrace) {
      // Some ROMs have no usable gallery/camera intent; the file browser is a
      // reliable fallback there.
      logZenError(
        'Image picker failed, falling back to files',
        error,
        stackTrace,
      );
      return _fromFile();
    }
  }

  Future<_Picked?> _fromFile() async {
    final String? path = await pickOnePath(type: FileType.image);
    return path == null ? null : (path: path, bytes: null);
  }

  /// The picture [picked], read and checked before it is framed: throws
  /// [FormatException] (said to the person) when it is too big or not a
  /// picture this app takes.
  Future<Uint8List> _readPicked(_Picked picked, {required int max}) async {
    Uint8List? bytes = picked.bytes;
    if (bytes == null) {
      final File source = File(picked.path!);
      if (!source.existsSync() || source.lengthSync() > max) {
        bytes = null;
      } else {
        bytes = await source.readAsBytes();
      }
    }
    if (bytes == null || bytes.length > max) {
      throw FormatException(
        t(
          'To zdjęcie jest za duże albo nie da się go otworzyć (najwyżej 20 MB).',
        ),
      );
    }
    if (AvatarSanitizer.hasDangerousHeader(bytes)) {
      throw FormatException(
        t('Wykryto niebezpieczną zawartość lub plik wykonywalny.'),
      );
    }
    if (!AvatarSanitizer.isValidImageBytes(bytes)) {
      throw FormatException(
        t('Nieobsługiwany format pliku. Wybierz obraz JPG, PNG, WEBP lub GIF.'),
      );
    }
    return bytes;
  }

  Future<void> _storePickedAvatar(_Picked source) async {
    setState(() => _isProcessingImage = true);
    try {
      final Uint8List picked = await _readPicked(
        source,
        max: kMaxAvatarSourceBytes,
      );
      if (!mounted) {
        return;
      }
      // The person frames it: a circle over the picture.
      final CropRegion? region = await ImageCropScreen.open(
        context,
        bytes: picked,
        aspect: 1,
        round: true,
        title: t('Kadruj zdjęcie'),
      );
      if (region == null) {
        if (mounted) {
          setState(() => _isProcessingImage = false);
        }
        return;
      }
      final Uint8List? framed = await compute(makeAvatarImage, (
        picked,
        region,
      ));
      if (framed == null) {
        throw FormatException(
          t('To nie wygląda na zdjęcie (obsługiwane: JPEG, PNG, WebP, GIF).'),
        );
      }
      // Everything else Zen owns lives in the support directory; Documents can
      // be redirected (OneDrive & co.) and is not a safe home for app data.
      final Directory storageDir = await ZenInstance.supportDirectory();

      // Strict security validation: magic bytes, size limits, dangerous payloads.
      final String sanitizedPath =
          await AvatarSanitizer.validateAndStoreAvatarBytes(
            rawBytes: framed,
            storageDir: storageDir,
          );
      final String? previousStaged = _stagedAvatarPath;
      if (previousStaged != null && previousStaged != sanitizedPath) {
        await AvatarSanitizer.cleanupOldAvatar(previousStaged);
      }
      if (!mounted) {
        await AvatarSanitizer.cleanupOldAvatar(sanitizedPath);
        return;
      }
      // A replaced file could otherwise be served from the decoded-image cache.
      await FileImage(File(sanitizedPath)).evict();
      setState(() {
        _stagedAvatarPath = sanitizedPath;
        _avatarPath = sanitizedPath;
        _isProcessingImage = false;
      });
    } catch (error, stackTrace) {
      logZenError('Storing the picked avatar failed', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() => _isProcessingImage = false);
      _showAvatarMessage(
        error is FormatException
            ? error.message
            : t('Nie udało się wczytać zdjęcia awatara: {error}', {
                'error': error,
              }),
        isError: true,
      );
    }
  }

  void _showAvatarMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    final ZenColors zen = ZenColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? zen.danger : null,
      ),
    );
  }

  Future<void> _pickCover() async {
    if (_isProcessingCover) {
      return;
    }
    _Picked? source;
    try {
      source = await _selectPicture();
    } catch (error, stackTrace) {
      logZenError('Opening the cover picker failed', error, stackTrace);
      _showAvatarMessage(
        t('Nie udało się otworzyć wyboru zdjęcia.'),
        isError: true,
      );
      return;
    }
    if (source == null || !mounted) {
      return;
    }
    setState(() => _isProcessingCover = true);
    try {
      final Uint8List picked = await _readPicked(
        source,
        max: kMaxCoverSourceBytes,
      );
      if (!mounted) {
        return;
      }
      // The person frames it: the 3:1 band behind the profile header.
      final CropRegion? region = await ImageCropScreen.open(
        context,
        bytes: picked,
        aspect: kCoverWidth / kCoverHeight,
        title: t('Kadruj tło'),
      );
      if (region == null) {
        if (mounted) {
          setState(() => _isProcessingCover = false);
        }
        return;
      }
      final String path = await storeCoverBytes(
        bytes: picked,
        storageDir: await ZenInstance.supportDirectory(),
        region: region,
      );
      final String? previous = _stagedCoverPath;
      if (previous != null) {
        await deleteCoverImage(previous);
      }
      if (!mounted) {
        await deleteCoverImage(path);
        return;
      }
      setState(() {
        _stagedCoverPath = path;
        _coverPath = path;
        _isProcessingCover = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isProcessingCover = false);
      _showAvatarMessage(
        error is FormatException
            ? error.message
            : t('Nie udało się: {error}', {'error': error}),
        isError: true,
      );
    }
  }

  void _clearAvatarImage() {
    setState(() {
      _avatarPath = null;
    });
  }

  Future<void> _save() async {
    if (_isSaving) {
      return;
    }
    final String name = _nameController.text.trim();
    final String bio = _bioController.text.trim();
    if (name.isEmpty) {
      _showAvatarMessage(t('Podaj nazwę wyświetlaną.'), isError: true);
      return;
    }
    final List<String> nationalities;
    try {
      nationalities = parseNationalities(_nationalityController.text);
    } on ArgumentError catch (e) {
      setState(() => _nationalityError = e.message as String?);
      return;
    }

    setState(() {
      _isSaving = true;
      _nationalityError = null;
    });
    try {
      final UserProfile prevProfile = ref.read(userProfileControllerProvider);
      final String? previousAvatarPath = prevProfile.avatarPath;
      final String? previousCoverPath = prevProfile.coverPath;

      await ref
          .read(userProfileControllerProvider.notifier)
          .updateProfile(
            displayName: name,
            avatarPath: _avatarPath,
            clearAvatarPath: _avatarPath == null,
            coverPath: _coverPath,
            clearCoverPath: _coverPath == null,
            bio: bio,
            visibility: _visibility,
            nationalities: nationalities,
          );
      // The new copy is committed, so the dialog no longer owns it.
      _stagedAvatarPath = null;
      _stagedCoverPath = null;
      if (previousCoverPath != null && previousCoverPath != _coverPath) {
        await deleteCoverImage(previousCoverPath);
      }
      if (previousAvatarPath != null && previousAvatarPath != _avatarPath) {
        await AvatarSanitizer.cleanupOldAvatar(previousAvatarPath);
      }

      if (!mounted) {
        return;
      }
      // Grab the messenger before popping — afterwards this context is gone.
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(content: Text(t('Profil zaktualizowany.'))),
      );
    } catch (error, stackTrace) {
      logZenError('Saving the profile failed', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() => _isSaving = false);
      _showAvatarMessage(
        t('Nie udało się zapisać profilu: {error}', {'error': error}),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final double keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final double systemBottomInset = MediaQuery.of(context).padding.bottom;
    final bool hasCustomPhoto =
        _avatarPath != null && File(_avatarPath!).existsSync();

    return ZenFadeSlide(
      duration: const Duration(milliseconds: 240),
      offset: const Offset(0, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: zen.surfaceRaised,
          borderRadius: context.zenTopRadius(28),
          border: Border.all(color: zen.outlineSoft),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              20 + keyboardInset + (keyboardInset > 0 ? 0 : systemBottomInset),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: zen.outline,
                        borderRadius: context.zenRadius(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      ZenIconBadge(
                        icon: Icons.person_rounded,
                        tone: zen.accent,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          t('Edytuj profil'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 22,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: t('Zamknij'),
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _EditSection(
                    icon: Icons.account_circle_outlined,
                    title: t('Zdjęcie profilowe'),
                  ),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: zen.surface,
                      borderRadius: context.zenRadius(20),
                      border: Border.all(color: zen.outlineSoft),
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: <Color>[zen.accent, zen.accentSecondary],
                            ),
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: zen.surface,
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: <Widget>[
                                OwnAvatar(
                                  size: 72,
                                  path: _avatarPath,
                                  usePath: true,
                                ),
                                if (_isProcessingImage)
                                  const SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              FilledButton.tonalIcon(
                                key: const Key('profile-pick-photo-button'),
                                onPressed: _isProcessingImage
                                    ? null
                                    : _pickAvatarImage,
                                icon: const Icon(
                                  Icons.add_photo_alternate_rounded,
                                  size: 18,
                                ),
                                label: Text(t('Wybierz zdjęcie')),
                              ),
                              if (hasCustomPhoto)
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    foregroundColor: zen.danger,
                                  ),
                                  onPressed: _clearAvatarImage,
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                  ),
                                  label: Text(t('Usuń zdjęcie')),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const Key('profile-name-field'),
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: t('Nazwa wyświetlana'),
                      hintText: t('Twoje imię lub pseudonim'),
                      helperText: t('Tak zobaczą Cię znajomi.'),
                      prefixIcon: const Icon(Icons.badge_outlined),
                    ),
                  ),
                  _EditSection(
                    icon: Icons.wallpaper_rounded,
                    title: t('Zdjęcie w tle'),
                  ),
                  ClipRRect(
                    borderRadius: context.zenRadius(18),
                    child: AspectRatio(
                      aspectRatio: 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          if (_coverPath != null &&
                              File(_coverPath!).existsSync())
                            Image(
                              // A saved cover is in the vault.
                              image: mediaFileImage(_coverPath!),
                              key: const Key('profile-cover-preview'),
                              fit: BoxFit.cover,
                            )
                          else
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: <Color>[
                                    zen.accent.withValues(alpha: 0.40),
                                    zen.accentSecondary.withValues(alpha: 0.20),
                                    zen.accentTertiary.withValues(alpha: 0.15),
                                  ],
                                ),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.landscape_rounded,
                                  size: 34,
                                  color: zen.textPrimary.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                            ),
                          if (_isProcessingCover)
                            const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        key: const Key('profile-pick-cover-button'),
                        onPressed: _isProcessingCover
                            ? null
                            : () => unawaitedLogged(
                                _pickCover(),
                                context: 'Picking a cover failed',
                              ),
                        icon: const Icon(Icons.wallpaper_rounded, size: 18),
                        label: Text(t('Wybierz zdjęcie w tle')),
                      ),
                      if (_coverPath != null)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: zen.danger,
                          ),
                          onPressed: () => setState(() => _coverPath = null),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                          label: Text(t('Usuń')),
                        ),
                    ],
                  ),
                  _EditSection(icon: Icons.notes_rounded, title: t('O mnie')),
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: zen.surfaceMuted,
                      borderRadius: context.zenRadius(14),
                    ),
                    child: _BioToolbar(controller: _bioController),
                  ),
                  TextField(
                    key: const Key('profile-bio-field'),
                    controller: _bioController,
                    minLines: 4,
                    maxLines: 12,
                    maxLength: kMaxProfileBio,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    // A tall box: gently rounded corners (the theme's pill
                    // shape suits one-line fields only).
                    decoration: InputDecoration(
                      hintText: t(
                        'Kim jesteś, czym się zajmujesz, co lubisz… '
                        'Możesz pogrubiać, wypunktować, dodać link.',
                      ),
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                        borderRadius: context.zenRadius(16),
                        borderSide: BorderSide(color: zen.outlineSoft),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: context.zenRadius(16),
                        borderSide: BorderSide(color: zen.outlineSoft),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: context.zenRadius(16),
                        borderSide: BorderSide(color: zen.accent, width: 1.5),
                      ),
                    ),
                  ),
                  _EditSection(
                    icon: Icons.flag_outlined,
                    title: t('Narodowość'),
                  ),
                  TextField(
                    key: const Key('profile-nationality-field'),
                    controller: _nationalityController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'PL',
                      prefixIcon: const Icon(Icons.flag_outlined),
                      helperText: t(
                        'Kody krajów, np. PL, UA (najwyżej 3). Otwiera sekcję '
                        'krajową. Możesz zostawić puste.',
                      ),
                      helperMaxLines: 3,
                      errorText: _nationalityError,
                    ),
                  ),
                  _EditSection(
                    icon: Icons.lock_outline_rounded,
                    title: t('Kto widzi'),
                  ),
                  Container(
                    padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 8, 4),
                    decoration: BoxDecoration(
                      color: zen.surface,
                      borderRadius: context.zenRadius(20),
                      border: Border.all(color: zen.outlineSoft),
                    ),
                    child: Column(
                      children: <Widget>[
                        for (final ProfileField field in ProfileField.values)
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  kProfileFieldLabels[field]!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: zen.textPrimary,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<FieldVisibility>(
                                  key: Key('profile-visibility-${field.name}'),
                                  value:
                                      fieldVisibilityByName(
                                        _visibility[field.name],
                                      ) ??
                                      kDefaultFieldVisibility[field],
                                  borderRadius: context.zenRadius(16),
                                  style: TextStyle(
                                    color: zen.textSecondary,
                                    fontSize: 13.5,
                                  ),
                                  onChanged: (FieldVisibility? v) {
                                    if (v == null) {
                                      return;
                                    }
                                    setState(
                                      () => _visibility = withFieldVisibility(
                                        _visibility,
                                        field,
                                        v,
                                      ),
                                    );
                                  },
                                  items: <DropdownMenuItem<FieldVisibility>>[
                                    for (final FieldVisibility v
                                        in FieldVisibility.values)
                                      DropdownMenuItem<FieldVisibility>(
                                        value: v,
                                        child: Text(kFieldVisibilityLabels[v]!),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('profile-save-button'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: _isSaving || _isProcessingImage ? null : _save,
                      icon: _isSaving
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(
                        _isSaving ? t('Zapisywanie...') : t('Zapisz profil'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small heading of one part of the editor: icon and title.
class _EditSection extends StatelessWidget {
  const _EditSection({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 10),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: zen.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Formatting for the bio: the same marks as in posts.
class _BioToolbar extends StatelessWidget {
  const _BioToolbar({required this.controller});

  final RichTextController controller;

  @override
  Widget build(BuildContext context) {
    Widget tool(String key, IconData icon, String tip, VoidCallback onTap) =>
        IconButton(
          key: Key('bio-tool-$key'),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon, size: 20),
        );
    return Wrap(
      children: <Widget>[
        tool(
          'bold',
          Icons.format_bold_rounded,
          t('Pogrubienie'),
          () => controller.toggleWrap('**'),
        ),
        tool(
          'italic',
          Icons.format_italic_rounded,
          t('Kursywa'),
          () => controller.toggleWrap('*'),
        ),
        tool(
          'underline',
          Icons.format_underlined_rounded,
          t('Podkreślenie'),
          () => controller.toggleWrap('__'),
        ),
        tool(
          'strike',
          Icons.format_strikethrough_rounded,
          t('Przekreślenie'),
          () => controller.toggleWrap('~~'),
        ),
        tool(
          'heading',
          Icons.title_rounded,
          t('Nagłówek'),
          () => controller.toggleLinePrefix('### '),
        ),
        tool(
          'quote',
          Icons.format_quote_rounded,
          t('Cytat'),
          () => controller.toggleLinePrefix('> '),
        ),
        tool(
          'list',
          Icons.format_list_bulleted_rounded,
          t('Lista'),
          () => controller.toggleLinePrefix('- '),
        ),
        tool(
          'numbered',
          Icons.format_list_numbered_rounded,
          t('Lista numerowana'),
          () => controller.toggleLinePrefix('1. '),
        ),
      ],
    );
  }
}
