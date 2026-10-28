import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/search/chat_search_controller.dart';

/// Ctrl+F (⌘F on a Mac) opens the search of the conversation below it,
/// Esc closes it. On a computer the screen takes the keyboard focus when it
/// opens, so the keys work before anything is tapped. Rebuild it when the
/// search opens or closes.
class ChatSearchShortcuts extends StatelessWidget {
  const ChatSearchShortcuts({
    required this.search,
    required this.child,
    super.key,
  });

  final ChatSearchController search;
  final Widget child;

  static bool get _computer => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
          search.open(text: search.text),
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
          search.open(text: search.text),
      // Only while searching: Esc means nothing to this screen otherwise.
      if (search.active)
        const SingleActivator(LogicalKeyboardKey.escape): search.close,
    },
    child: Focus(autofocus: _computer, skipTraversal: true, child: child),
  );
}

/// The search field that stands in for a conversation's title while its
/// search is open: Enter goes to the next older match, Shift+Enter to the
/// newer one, Esc closes.
class ChatSearchField extends StatefulWidget {
  const ChatSearchField({required this.search, super.key});

  final ChatSearchController search;

  @override
  State<ChatSearchField> createState() => _ChatSearchFieldState();
}

class _ChatSearchFieldState extends State<ChatSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.search.text,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'chat-search');

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _enter({required bool newer}) {
    final ChatSearchController search = widget.search;
    if (search.total == 0) {
      search.searchNow();
    } else if (newer) {
      search.newer();
    } else {
      search.older();
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.search.close,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            _enter(newer: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
            _enter(newer: false),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
            _enter(newer: true),
      },
      child: TextField(
        key: const Key('chat-search-field'),
        controller: _controller,
        focusNode: _focus,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: widget.search.setText,
        onSubmitted: (_) => _enter(newer: false),
        style: TextStyle(color: zen.textPrimary, fontSize: 16),
        decoration: InputDecoration.collapsed(
          hintText: t('Szukaj w rozmowie'),
          hintStyle: TextStyle(color: zen.textMuted, fontSize: 16),
        ),
      ),
    );
  }
}

/// The row under a conversation's title while its search is open: the
/// field, and closing it.
class ChatSearchBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatSearchBar({required this.search, super.key});

  final ChatSearchController search;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return DecoratedBox(
      key: const Key('chat-search-bar'),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: zen.outlineSoft)),
      ),
      child: SizedBox(
        height: preferredSize.height,
        child: Row(
          children: <Widget>[
            const SizedBox(width: 16),
            ExcludeSemantics(
              child: Icon(Icons.search_rounded, size: 20, color: zen.textMuted),
            ),
            const SizedBox(width: 12),
            Expanded(child: ChatSearchField(search: search)),
            IconButton(
              key: const Key('chat-search-close'),
              tooltip: t('Zamknij wyszukiwanie'),
              icon: const Icon(Icons.close_rounded),
              onPressed: search.close,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// Under the conversation while its search is open, in place of the field
/// to write in: how many messages match, which one is shown, and arrows
/// to the older and newer ones.
class ChatSearchNavigator extends StatelessWidget {
  const ChatSearchNavigator({required this.search, super.key});

  final ChatSearchController search;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int total = search.total;
    final String label;
    if (!search.query.searchesMessages) {
      label = search.query.isEmpty
          ? t('Wpisz, czego szukasz')
          : t('Wpisz co najmniej 2 znaki');
    } else if (search.busy && total == 0) {
      label = t('Szukam…');
    } else if (total == 0) {
      label = t('Brak wyników');
    } else {
      label = t('{current} z {total}', {
        'current': search.position,
        'total': search.capped ? '$total+' : total,
      });
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: zen.surface,
        border: Border(top: BorderSide(color: zen.outlineSoft)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: <Widget>[
              if (search.busy)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: zen.accent,
                    ),
                  ),
                ),
              Expanded(
                // Its own node, read out each time it changes.
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(
                    label,
                    key: const Key('chat-search-count'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('chat-search-older'),
                tooltip: t('Starszy wynik'),
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                onPressed: total > 0 ? search.older : null,
              ),
              IconButton(
                key: const Key('chat-search-newer'),
                tooltip: t('Nowszy wynik'),
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onPressed: total > 0 ? search.newer : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The search button of a conversation's app bar.
class ChatSearchButton extends StatelessWidget {
  const ChatSearchButton({required this.search, super.key});

  final ChatSearchController search;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('chat-search-button'),
    tooltip: t('Szukaj w rozmowie'),
    icon: const Icon(Icons.search_rounded),
    onPressed: () => search.open(),
  );
}
