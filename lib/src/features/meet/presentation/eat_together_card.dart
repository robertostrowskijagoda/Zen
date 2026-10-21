import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/meet/eat_together.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';

/// "Ola jest niedaleko i chce coś zjeść — napisz?": a gentle card for a
/// friend who wants to eat together and was near within the last hour
/// (worked out on this phone, [eatTogetherNearby]). "Nie teraz" hides it
/// until the app restarts.
class EatTogetherCard extends ConsumerStatefulWidget {
  const EatTogetherCard({super.key});

  @override
  ConsumerState<EatTogetherCard> createState() => _EatTogetherCardState();
}

class _EatTogetherCardState extends ConsumerState<EatTogetherCard> {
  static final Set<String> _dismissed = <String>{};

  @override
  Widget build(BuildContext context) {
    final MeetService meet = ref.watch(meetServiceProvider);
    final NearbyService nearby = ref.watch(nearbyServiceProvider);
    final EncounterLog log = ref.watch(encounterLogProvider);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[meet, nearby, log]),
      builder: (BuildContext context, Widget? _) {
        final List<EatTogether> near = eatTogetherNearby(
          hungry: meet.friendsWith(IntentKind.eat),
          people: nearby.people,
          encounters: log.encounters,
          now: meet.now,
          dismissed: _dismissed,
        );
        if (near.isEmpty) {
          return const SizedBox.shrink();
        }
        final EatTogether first = near.first;
        final String name = meet.host.nameOf(first.friend);
        final ZenColors zen = ZenColors.of(context);
        final Color tone = zenTone(zen, 3);
        return ZenCard(
          key: const Key('eat-together'),
          tone: tone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(
                    icon: Icons.restaurant_rounded,
                    tone: tone,
                    size: 38,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('{name} jest niedaleko i chce coś zjeść — napisz?', {
                        'name': name,
                      }),
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
              if (first.status.note.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  first.status.note,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    key: const Key('eat-together-write'),
                    onPressed: () => unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) => ConversationScreen(
                            peerAddress: first.friend,
                            title: name,
                          ),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.chat_rounded),
                    label: Text(t('Napisz')),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _dismissed.add(first.friend)),
                    child: Text(t('Nie teraz')),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
