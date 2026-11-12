import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/passwords/password_generator.dart';
import 'package:zen/src/features/passwords/password_match.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';

/// The name every page of "Hasła" is pushed under: when Zen locks, all of
/// them (and the dialogs over them) are closed at once
/// ([closePasswordPages]).
const String kPasswordVaultRouteName = 'passwords';

/// The widest the pages of "Hasła" get on a wide window: one readable
/// column in the middle.
const double kPasswordPageMaxWidth = 720;

/// Pushes [page] as a page of "Hasła".
Future<T?> pushPasswordPage<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(
      MaterialPageRoute<T>(
        settings: const RouteSettings(name: kPasswordVaultRouteName),
        builder: (BuildContext context) => page,
      ),
    );

/// Closes every page of "Hasła" and whatever is open over them (a dialog,
/// the generator), unsaved changes included: nothing of the vault stays on
/// the screen once Zen locks.
void closePasswordPages(NavigatorState navigator) {
  navigator.popUntil(
    (Route<dynamic> route) =>
        route.settings.name != kPasswordVaultRouteName && route is! PopupRoute,
  );
}

/// [child] in the readable column of a wide window.
Widget passwordPageColumn(Widget child) => Align(
  alignment: AlignmentDirectional.topCenter,
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: kPasswordPageMaxWidth),
    child: child,
  ),
);

/// A steady colour of the theme's palette for an entry, from its name, so
/// the same site always looks the same.
Color passwordTone(ZenColors zen, String name) {
  int hash = 0;
  for (final int unit in name.trim().toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return zenTone(zen, hash % 8);
}

/// The first letter of an entry's name in a round badge of its colour
/// ([passwordTone]); a rounded square in the angular looks, as the avatars.
class PasswordAvatar extends StatelessWidget {
  const PasswordAvatar({required this.name, this.size = 40, super.key});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color tone = passwordTone(zen, name);
    final String trimmed = name.trim();
    final String initial = trimmed.isEmpty
        ? '?'
        : trimmed.characters.first.toUpperCase();
    final bool round = look.corner >= 0.5;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tone,
          shape: round ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: round ? null : look.br(size * 0.3),
        ),
        child: Text(
          initial,
          style: zen.display(
            color: ZenColors.foregroundFor(tone),
            size: size * 0.45,
            weight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// What a refused copy or a copy says.
Future<void> copyWithNotice(
  BuildContext context,
  Future<bool> Function() copy,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final bool copied = await copy();
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          copied
              ? t('Skopiowano — zniknie ze schowka za 30 s')
              : t('Nie udało się. Spróbuj jeszcze raz.'),
        ),
      ),
    );
}

/// The words for what the vault refused.
String passwordVaultErrorText(Object error) {
  if (error is PasswordVaultException &&
      error.error == PasswordVaultError.full) {
    return t('Brak miejsca na nowe hasła. Usuń te, których nie potrzebujesz.');
  }
  return t('Nie udało się. Spróbuj jeszcze raz.');
}

/// [address] as a web page the browser can open (`https://` added to a
/// bare host), or null when it is not one (an app, anything else).
String? passwordWebAddress(String address) {
  final String a = address.trim();
  if (a.isEmpty || a.contains(RegExp(r'\s'))) {
    return null;
  }
  final Uri? uri = Uri.tryParse(a);
  if (uri != null && uri.hasScheme) {
    final String scheme = uri.scheme.toLowerCase();
    return (scheme == 'https' || scheme == 'http') && uri.host.isNotEmpty
        ? a
        : null;
  }
  final Uri? bare = Uri.tryParse('https://$a');
  return bare != null && bare.host.contains('.') ? 'https://$a' : null;
}

/// The host of [address] for the list ("bank.example.com"), an app's
/// package (without the certificate's long hash), or the address itself.
String passwordAddressLabel(String address) {
  final String? web = passwordWebAddress(address);
  final String host = web == null ? '' : Uri.parse(web).host;
  if (host.isNotEmpty) {
    return host;
  }
  final PasswordAddress? app = PasswordAddress.parse(address);
  return app?.kind == PasswordAddressKind.app ? app!.package! : address.trim();
}

/// A password: dots until shown, then in the monospace face. The dots do
/// not tell its length.
class PasswordSecretText extends StatelessWidget {
  const PasswordSecretText({
    required this.password,
    required this.shown,
    this.size = 15,
    super.key,
  });

  final String password;
  final bool shown;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (!shown) {
      return Text(
        '•' * 10,
        maxLines: 1,
        style: TextStyle(
          color: zen.textPrimary,
          fontSize: size,
          letterSpacing: 2,
        ),
      );
    }
    return Text(
      password,
      style: zen.mono(color: zen.textPrimary, size: size, height: 1.35),
    );
  }
}

/// The words for a strength level.
String passwordStrengthLabel(PasswordStrengthLevel level) => switch (level) {
  PasswordStrengthLevel.veryWeak => t('Bardzo słabe'),
  PasswordStrengthLevel.weak => t('Słabe'),
  PasswordStrengthLevel.fair => t('Średnie'),
  PasswordStrengthLevel.strong => t('Silne'),
  PasswordStrengthLevel.veryStrong => t('Bardzo silne'),
};

/// How strong [password] looks ([estimatePasswordStrength]): five bars and
/// a word. Told by the word and the number of lit bars, not by colour
/// alone.
class PasswordStrengthLine extends StatelessWidget {
  const PasswordStrengthLine({required this.password, super.key});

  final String password;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PasswordStrengthLevel level = estimatePasswordStrength(
      password,
    ).level;
    final Color tone = switch (level) {
      PasswordStrengthLevel.veryWeak ||
      PasswordStrengthLevel.weak => zen.danger,
      PasswordStrengthLevel.fair => zen.warning,
      PasswordStrengthLevel.strong ||
      PasswordStrengthLevel.veryStrong => zen.success,
    };
    final String label = passwordStrengthLabel(level);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        key: const Key('password-strength'),
        children: <Widget>[
          for (
            int i = 0;
            i < PasswordStrengthLevel.values.length;
            i++
          ) ...<Widget>[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: Container(
                height: 5,
                decoration: BoxDecoration(
                  color: i <= level.index ? tone : zen.outlineSoft,
                  borderRadius: context.zenRadius(3),
                ),
              ),
            ),
          ],
          const SizedBox(width: 10),
          Flexible(
            flex: 3,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A field that holds a password: copying and cutting out of it are left
/// out (its menu, and the keys), since that would put the password on the
/// plain clipboard, where it stays; the vault's own copy buttons clear it
/// after [kPasswordClipboardTtl]. Pasting into it works.
class NoCopyField extends StatelessWidget {
  const NoCopyField({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{
      CopySelectionTextIntent: DoNothingAction(consumesKey: false),
    },
    child: child,
  );
}

/// The context menu of a password field without "Kopiuj" and "Wytnij".
Widget passwordFieldMenu(BuildContext context, EditableTextState state) =>
    AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: <ContextMenuButtonItem>[
        for (final ContextMenuButtonItem item in state.contextMenuButtonItems)
          if (item.type != ContextMenuButtonType.copy &&
              item.type != ContextMenuButtonType.cut)
            item,
      ],
    );

/// An icon button of the vault: a 44 px hit box, a tooltip.
Widget passwordIconButton({
  required Key key,
  required String tooltip,
  required IconData icon,
  required VoidCallback? onPressed,
  Color? color,
}) => IconButton(
  key: key,
  tooltip: tooltip,
  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
  onPressed: onPressed,
  icon: Icon(icon, size: 20, color: color),
);

/// Runs [work]; what the vault refused is said in a snack bar. True when
/// it went through.
Future<bool> runPasswordAction(
  BuildContext context,
  Future<void> Function() work,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await work();
    return true;
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text(passwordVaultErrorText(error))),
    );
    return false;
  }
}
