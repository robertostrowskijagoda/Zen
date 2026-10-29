import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/key_file_io.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// One person of the recovery circle as the person sees them.
typedef RecoveryCircleMember = ({
  String address,
  String name,
  String? inviteCode,
  bool confirmed,
});

/// The circle of [service] with names from [social].
List<RecoveryCircleMember> recoveryCircleMembers(
  RecoveryService service,
  SocialHubState social,
) {
  final Map<String, int> acks = service.acks;
  return <RecoveryCircleMember>[
    for (final String address in service.circle)
      (
        address: address,
        name: switch (social.friendByAddress(address)) {
          final FriendProfile f => social.nameFor(f),
          null => PeerShareCodec.displayNameForAddress(address),
        },
        inviteCode: PeerShareCodec.inviteCodeForAddress(address),
        confirmed: acks.containsKey(address),
      ),
  ];
}

/// The list to keep with the paper key: who holds the pieces, with their
/// invitation codes (typed in on the new device) and what to do.
String recoveryCircleListText({
  required String fingerprint,
  required List<RecoveryCircleMember> members,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln(t('Zen — krąg odzyskiwania'))
    ..writeln(
      t('Odcisk konta: {fingerprint}', <String, Object?>{
        'fingerprint': fingerprint,
      }),
    )
    ..writeln()
    ..writeln(t('Klucze odzyskiwania przechowują:'));
  for (final RecoveryCircleMember m in members) {
    out.writeln(
      m.inviteCode == null
          ? '- ${m.name}'
          : t('- {name} — kod: {code}', <String, Object?>{
              'name': m.name,
              'code': m.inviteCode,
            }),
    );
  }
  out
    ..writeln()
    ..writeln(
      t(
        'Nowy telefon: Konto i odzyskiwanie → Zacznij odzyskiwanie. Wpisz '
        'tam kody tych osób i poproś dwie z nich o pomoc (z hasłem konta), '
        'albo cztery (bez hasła, 7 dni).',
      ),
    );
  return out.toString();
}

/// "Kto przechowuje klucze": the names of the circle, who confirmed, and
/// "Zapisz listę" (a text file to keep with the paper key or print).
class RecoveryCircleMembersView extends ConsumerWidget {
  const RecoveryCircleMembersView({super.key});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    String fingerprint,
    List<RecoveryCircleMember> members,
  ) async {
    final String text = recoveryCircleListText(
      fingerprint: fingerprint,
      members: members,
    );
    String? path;
    Object? failure;
    try {
      path = await ref
          .read(keyFileIoProvider)
          .save(
            'zen-krag-odzyskiwania.txt',
            Uint8List.fromList(utf8.encode(text)),
          );
    } on Object catch (error, stack) {
      logZenError('Recovery circle list', error, stack);
      failure = error;
    }
    if (!context.mounted || (path == null && failure == null)) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failure != null
              ? t('Nie udało się zapisać pliku: {error}', <String, Object?>{
                  'error': failure,
                })
              : t(
                  'Zapisano: {path}. Wydrukuj albo przepisz listę i trzymaj '
                  'ją razem z kopią klucza.',
                  <String, Object?>{'path': path},
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RecoveryService? service = ref.watch(recoveryServiceProvider);
    final LedgerNode? node = ref.watch(ledgerNodeProvider);
    final SocialHubState social = watchSocialPeople(ref);
    final ZenColors zen = ZenColors.of(context);
    if (service == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<void>(
      stream: service.changes,
      builder: (BuildContext context, AsyncSnapshot<void> _) {
        final List<RecoveryCircleMember> members = recoveryCircleMembers(
          service,
          social,
        );
        if (members.isEmpty) {
          return ZenInfo(
            key: const Key('recovery-circle-empty'),
            icon: Icons.group_off_outlined,
            tone: zen.textMuted,
            text: t('Nikt jeszcze nie przechowuje kluczy Twojego konta.'),
          );
        }
        final String fingerprint = node != null && node.isReady
            ? accountFingerprint(node.identity.account)
            : '';
        return Column(
          key: const Key('recovery-circle-members'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t('KTO PRZECHOWUJE KLUCZE'),
              style: zen.label(color: zen.textMuted),
            ),
            const SizedBox(height: 4),
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final RecoveryCircleMember m in members)
                    Padding(
                      key: Key('recovery-circle-member-${m.address}'),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            m.confirmed
                                ? Icons.check_circle_rounded
                                : Icons.schedule_rounded,
                            size: 18,
                            color: m.confirmed ? zen.success : zen.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              m.confirmed
                                  ? m.name
                                  : t('{name} (jeszcze nie potwierdził(a))', {
                                      'name': m.name,
                                    }),
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 14,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('recovery-circle-save'),
              onPressed: () =>
                  unawaited(_save(context, ref, fingerprint, members)),
              icon: const Icon(Icons.print_outlined),
              label: Text(t('Zapisz listę do wydruku')),
            ),
          ],
        );
      },
    );
  }
}
