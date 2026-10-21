import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/runtime/public_peers.dart';

/// The line under a peer: where it stands, what a check found, and a
/// warning for a link without encryption.
String publicPeerStatusText(PublicPeer peer, PublicPeerProbe? probe) {
  final List<String> parts = <String>[
    if (peer.country.isNotEmpty) peer.country,
    if (probe != null)
      if (!probe.reachable)
        t('Nie odpowiada')
      else if (probe.keyMatches == false)
        t('Klucz się nie zgadza')
      else if (probe.latencyMs != null)
        t('{ms} ms', <String, Object?>{'ms': probe.latencyMs!.round()}),
    if (!peer.encrypted) t('Łącze bez szyfrowania'),
  ];
  return parts.join(' · ');
}

/// Ustawienia → Publiczne węzły: the public Yggdrasil peers this device
/// connects through. The user can add, remove and switch off peers, check
/// which answer and how fast, and go back to the built-in list. Changes
/// apply at once.
class PublicPeersSection extends ConsumerStatefulWidget {
  const PublicPeersSection({super.key});

  @override
  ConsumerState<PublicPeersSection> createState() => _PublicPeersSectionState();
}

class _PublicPeersSectionState extends ConsumerState<PublicPeersSection> {
  final TextEditingController _input = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final String? problem = await ref
        .read(publicPeersProvider.notifier)
        .add(_input.text);
    if (!mounted) {
      return;
    }
    setState(() => _problem = problem);
    if (problem == null) {
      _input.clear();
    }
  }

  Future<void> _change(Future<String?> change) async {
    final String? problem = await change;
    if (!mounted) {
      return;
    }
    setState(() => _problem = problem);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PublicPeersState state = ref.watch(publicPeersProvider);
    final PublicPeersController controller = ref.read(
      publicPeersProvider.notifier,
    );
    final TextStyle note = TextStyle(color: zen.textSecondary, height: 1.35);
    return Column(
      key: const Key('public-peers'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          t(
            'Publiczne węzły łączą Zen z siecią Yggdrasil. Zmiany działają '
            'od razu. Węzły z kluczem (key=) są sprawdzane, czy to na pewno '
            'one.',
          ),
          style: note,
        ),
        const SizedBox(height: 8),
        Text(
          state.custom
              ? tn(
                  state.activeCount,
                  one: 'Twoja lista: {n} włączony węzeł',
                  few: 'Twoja lista: {n} włączone węzły',
                  many: 'Twoja lista: {n} włączonych węzłów',
                )
              : t('Lista domyślna'),
          key: const Key('public-peers-status'),
          style: TextStyle(color: zen.textPrimary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('public-peers-input'),
          controller: _input,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: t('Nowy węzeł'),
            hintText: 'tls://host:443?key=…',
            errorText: _problem,
            errorMaxLines: 3,
          ),
          onSubmitted: (_) => unawaited(_add()),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('public-peers-add'),
              onPressed: () => unawaited(_add()),
              icon: const Icon(Icons.add_rounded),
              label: Text(t('Dodaj')),
            ),
            OutlinedButton.icon(
              key: const Key('public-peers-check'),
              onPressed: state.checking || state.peers.isEmpty
                  ? null
                  : () => unawaited(controller.check()),
              icon: state.checking
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_rounded),
              label: Text(t('Sprawdź węzły')),
            ),
            if (state.custom)
              TextButton.icon(
                key: const Key('public-peers-restore'),
                onPressed: () {
                  setState(() => _problem = null);
                  unawaited(controller.restoreDefaults());
                },
                icon: const Icon(Icons.restore_rounded),
                label: Text(t('Przywróć domyślne')),
              ),
          ],
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              state.error!,
              key: const Key('public-peers-error'),
              style: TextStyle(color: zen.danger, height: 1.35),
            ),
          ),
        const SizedBox(height: 8),
        if (!state.loaded)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (state.peers.isEmpty)
          Text(t('Lista jest pusta.'), style: note)
        else
          for (final PublicPeer peer in state.peers)
            _PeerRow(
              key: ValueKey<String>('public-peer-${peer.uri}'),
              peer: peer,
              probe: state.probes[peer.uri],
              onEnabled: (bool value) =>
                  unawaited(_change(controller.setEnabled(peer.uri, value))),
              onRemove: () => unawaited(_change(controller.remove(peer.uri))),
              onPinKey: () => unawaited(_change(controller.pinKey(peer.uri))),
            ),
      ],
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({
    required this.peer,
    required this.probe,
    required this.onEnabled,
    required this.onRemove,
    required this.onPinKey,
    super.key,
  });

  final PublicPeer peer;
  final PublicPeerProbe? probe;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onRemove;
  final VoidCallback onPinKey;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String status = publicPeerStatusText(peer, probe);
    final PublicPeerProbe? result = probe;
    final bool bad =
        result != null && (!result.reachable || result.keyMatches == false);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Switch(value: peer.enabled, onChanged: onEnabled),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(
                  peer.uri,
                  style: TextStyle(
                    color: peer.enabled ? zen.textPrimary : zen.textMuted,
                  ),
                ),
                if (status.isNotEmpty)
                  Text(
                    status,
                    softWrap: true,
                    style: TextStyle(
                      color: bad ? zen.danger : zen.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                if (result?.key != null && !publicPeerHasPinnedKey(peer.uri))
                  TextButton.icon(
                    key: ValueKey<String>('public-peer-pin-${peer.uri}'),
                    onPressed: onPinKey,
                    icon: const Icon(Icons.key_rounded, size: 18),
                    label: Text(t('Przypnij klucz')),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: t('Usuń'),
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}
