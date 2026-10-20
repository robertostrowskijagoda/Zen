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
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/feed/presentation/rich_text_controller.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/presentation/own_avatar.dart';
import 'package:zen/src/features/profile/profile_cover.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// Edits your profile: photo, cover, name and bio (§9). The short status
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
    super.dispose();
  }

  Future<void> _restoreLostAndroidPick() async {
    final LostDataResponse lost = await ImagePicker().retrieveLostData();
    final String? path = lost.file?.path;
    if (path == null || !mounted) {
      return;
    }
    await _storePickedAvatar(path);
  }

  Future<void> _pickAvatarImage() async {
    if (_isProcessingImage) {
      return;
    }
    String? originalPath;
    try {
      originalPath = await _selectAvatarSourcePath();
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
    if (originalPath == null || !mounted) {
      return;
    }
    await _storePickedAvatar(originalPath);
  }

  /// Returns the path of the image the user picked, or `null` when the picker
  /// was dismissed. Throws when the picker itself could not run — that has to
  /// reach the user instead of looking like a silent no-op.
  Future<String?> _selectAvatarSourcePath() async {
    final bool isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    if (isDesktop) {
      return _pickImageFileFromDisk();
    }

    final ZenColors zen = ZenColors.of(context);
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: zen.surfaceRaised,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.photo_library_outlined, color: zen.accent),
                title: Text(t('Wybierz z galerii')),
                onTap: () =>
                    Navigator.of(sheetContext).pop(ImageSource.gallery),
              ),
              ListTile(
                leading: Icon(Icons.photo_camera_outlined, color: zen.accent),
                title: Text(t('Zrób zdjęcie (Aparat)')),
                onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
              ),
              ListTile(
                leading: Icon(Icons.folder_open_outlined, color: zen.accent),
                title: Text(t('Wybierz plik z urządzenia')),
                onTap: () => Navigator.of(sheetContext).pop(null),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) {
      return null;
    }
    if (source == null) {
      return _pickImageFileFromDisk();
    }
    try {
      final XFile? image = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 88,
      );
      return image?.path;
    } catch (error, stackTrace) {
      // Some ROMs have no usable gallery/camera intent; the file browser is a
      // reliable fallback there.
      logZenError(
        'Image picker failed, falling back to files',
        error,
        stackTrace,
      );
      return _pickImageFileFromDisk();
    }
  }

  Future<String?> _pickImageFileFromDisk() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final List<PlatformFile> files = result?.files ?? const <PlatformFile>[];
    if (files.isEmpty) {
      return null;
    }
    return files.first.path;
  }

  Future<void> _storePickedAvatar(String sourcePath) async {
    setState(() => _isProcessingImage = true);
    try {
      // Everything else Zen owns lives in the support directory; Documents can
      // be redirected (OneDrive & co.) and is not a safe home for app data.
      final Directory storageDir = await ZenInstance.supportDirectory();

      // Strict security validation: magic bytes, size limits, dangerous payloads.
      final String sanitizedPath = await AvatarSanitizer.validateAndStoreAvatar(
        sourcePath: sourcePath,
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
    String? source;
    try {
      source = await _selectAvatarSourcePath();
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
      final String path = await storeCoverImage(
        sourcePath: source,
        storageDir: await ZenInstance.supportDirectory(),
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

    setState(() => _isSaving = true);
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
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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
                        borderRadius: BorderRadius.circular(2),
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
                      borderRadius: BorderRadius.circular(20),
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
                    borderRadius: BorderRadius.circular(18),
                    child: AspectRatio(
                      aspectRatio: 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          if (_coverPath != null &&
                              File(_coverPath!).existsSync())
                            Image.file(
                              File(_coverPath!),
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
                      borderRadius: BorderRadius.circular(14),
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
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: zen.outlineSoft),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: zen.outlineSoft),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: zen.accent, width: 1.5),
                      ),
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

/// Formatting for the bio: the same marks as in posts (§24).
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
