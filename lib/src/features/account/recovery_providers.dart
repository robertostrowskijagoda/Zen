import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Keys of accepted friends (normalised addresses).
Set<String> _acceptedFriends(SocialHubState state) => <String>{
  for (final FriendProfile f in state.friends.values)
    if (f.status == FriendRelationshipStatus.accepted)
      PeerShareCodec.normalizeAddress(f.address),
};

/// The recovery service, running with the ledger; `null` while the
/// ledger is off (tests, previews).
final Provider<RecoveryService?> recoveryServiceProvider =
    Provider<RecoveryService?>((Ref ref) {
      if (!ref.watch(ledgerNodeEnabledProvider)) {
        return null;
      }
      final RecoveryService service = RecoveryService(
        transport: ref.read(meshTransportProvider),
        disk: ref.read(ledgerDiskProvider),
        isFriend: (String address) => _acceptedFriends(
          ref.read(socialHubControllerProvider),
        ).contains(PeerShareCodec.normalizeAddress(address)),
      );
      // Help requests and alarms must reach the person even with the
      // screen closed.
      Future<void> post(String id, String title, String body) async {
        await ref
            .read(runtimeSystemNotificationServiceProvider)
            .show(
              RuntimeSystemNotification(
                id: id,
                title: title,
                body: body,
                createdAtMillis: DateTime.now().millisecondsSinceEpoch,
                category: RuntimeSystemNotificationCategory.social,
                slotKey: id,
              ),
            );
      }

      service
        ..onHelpRequested = (RecoveryHelpRequest request) {
          unawaitedLogged(
            post(
              'recovery-help-${request.from}',
              t('Ktoś prosi o pomoc w odzyskaniu konta'),
              t(
                'Nowe urządzenie podało Cię jako osobę z kręgu. Zanim '
                'pomożesz, upewnij się (najlepiej na żywo), kto to jest: '
                'Ustawienia → Konto i odzyskiwanie.',
              ),
            ),
            context: 'Powiadomienie o prośbie o pomoc',
          );
        }
        ..onAlarm = (RecoveryAlarm alarm) {
          final SocialHubState social = ref.read(socialHubControllerProvider);
          final FriendProfile? helper = social.friendByAddress(alarm.helper);
          unawaitedLogged(
            post(
              'recovery-alarm-${alarm.helper}',
              t('Ktoś odzyskuje Twoje konto'),
              t(
                '{name} wyda klucz Twojego konta nowemu urządzeniu. Jeśli to '
                'nie Ty, zatrzymaj to w Ustawienia → Konto i odzyskiwanie.',
                <String, Object?>{
                  'name': helper == null ? t('Ktoś') : social.nameFor(helper),
                },
              ),
            ),
            context: 'Powiadomienie o wydaniu klucza',
          );
        };
      unawaitedLogged(
        service.start(),
        context: 'Start odzyskiwania konta nie udał się',
      );
      ref.onDispose(() {
        unawaitedLogged(service.stop(), context: 'Zatrzymanie odzyskiwania');
      });
      return service;
    });

/// The copy of this account's data kept by its recovery circle, and the
/// copies this device keeps for the circles it is in; `null` while the
/// ledger is off.
final Provider<CircleBackupService?> circleBackupServiceProvider =
    Provider<CircleBackupService?>((Ref ref) {
      final RecoveryService? recovery = ref.watch(recoveryServiceProvider);
      final LedgerNode? node = ref.watch(ledgerNodeProvider);
      if (recovery == null || node == null) {
        return null;
      }
      final CircleBackupService service = CircleBackupService(
        transport: ref.read(meshTransportProvider),
        disk: ref.read(ledgerDiskProvider),
        data: AppCircleBackupData(ref, node),
        identity: () {
          if (!node.isReady) {
            return null;
          }
          final Uint8List? selfKey = node.identity.selfKey;
          return selfKey == null
              ? null
              : CircleBackupIdentity(
                  account: node.identity.account,
                  selfKey: selfKey,
                  deviceKey: node.identity.deviceKey,
                  certificate: node.identity.certificate,
                );
        },
        holders: () => recovery.acks.keys,
        isInCircle: (String account) => recovery.heldAccounts.contains(account),
        restoreCandidates: () =>
            _acceptedFriends(ref.read(socialHubControllerProvider)),
      );
      // A new friend, a group joined or left: a fresh copy soon.
      ref.listen<String>(
        socialHubControllerProvider.select(
          (SocialHubState s) => jsonEncode(contactsBackupOf(s)),
        ),
        (String? previous, String next) {
          if (previous != null && previous != next) {
            service.changed();
          }
        },
      );
      unawaitedLogged(
        node.start().then((_) => service.start()),
        context: 'Start kopii u kręgu nie udał się',
      );
      ref.onDispose(() {
        unawaitedLogged(service.stop(), context: 'Zatrzymanie kopii u kręgu');
      });
      return service;
    });

/// The app's data for the circle copy: what goes in, and where it goes
/// back after a recovery.
final class AppCircleBackupData implements CircleBackupData {
  AppCircleBackupData(this.ref, this.node);

  final Ref ref;
  final LedgerNode node;

  SocialHubController get _hub =>
      ref.read(socialHubControllerProvider.notifier);

  @override
  Future<CircleBackupContent> collect({required bool chats}) async {
    final SocialHubState state = ref.read(socialHubControllerProvider);
    final Map<String, dynamic> profile =
        ref.read(userProfileControllerProvider).toJson()
          // Photos stay out (no media in the copy).
          ..remove('avatarPath')
          ..remove('coverPath');
    final PyramidService pyramid = ref.read(pyramidServiceProvider);
    final String? me = pyramid.myKey;
    final int? balance = me == null || !pyramid.isMember
        ? null
        : pyramid.balance;
    final Map<String, List<Map<String, dynamic>>> conversations =
        <String, List<Map<String, dynamic>>>{};
    if (chats) {
      for (final String key in _hub.conversationKeys()) {
        final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
          for (final ChatMessage m in await _hub.conversationMessages(key))
            // Disappearing messages are meant to go: never in a copy.
            if (m.expiresAtMillis == null) chatMessageToSync(m),
        ];
        if (messages.isNotEmpty) {
          conversations[key] = messages;
        }
      }
    }
    return CircleBackupContent(
      sections: <String, Object?>{
        CircleBackupSections.profile: profile,
        CircleBackupSections.contacts: _hub.contactsBackup(),
        CircleBackupSections.levels: <String, String>{
          for (final String address in _acceptedFriends(state))
            address: node.levelOf(address).name,
        },
        CircleBackupSections.settings: ref
            .read(appSettingsControllerProvider)
            .toJson(),
        CircleBackupSections.pyramid: ?pyramid.sharedState(),
        CircleBackupSections.household: ?ref
            .read(neighborsServiceProvider)
            .backupState(),
        CircleBackupSections.dating: _datingWithoutPhotos(
          ref.read(datingServiceProvider).me,
        ),
        if (balance != null)
          CircleBackupSections.wallet: <String, Object>{
            'key': me!,
            'balance': balance,
            'at': DateTime.now().millisecondsSinceEpoch,
          },
      },
      chats: conversations,
    );
  }

  @override
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  ) async {
    final int total = 7 + content.messageCount;
    int done = 0;
    void step() => progress(++done, total);
    final Object? settings = content.sections[CircleBackupSections.settings];
    if (settings is Map<String, dynamic>) {
      await ref
          .read(appSettingsControllerProvider.notifier)
          .restoreAll(AppSettings.fromJson(settings));
    }
    step();
    final Object? profile = content.sections[CircleBackupSections.profile];
    if (profile is Map<String, dynamic>) {
      final UserProfile p = UserProfile.fromJson(profile);
      await ref
          .read(userProfileControllerProvider.notifier)
          .updateProfile(
            displayName: profile['displayName'] as String?,
            avatarPreset: p.avatarPreset,
            customStatus: profile['customStatus'] as String?,
            bio: profile['bio'] as String?,
            visibility: p.visibility,
            nationalities: p.nationalities,
          );
    }
    step();
    final Object? contacts = content.sections[CircleBackupSections.contacts];
    if (contacts is Map<String, dynamic>) {
      await _hub.importContactsBackup(contacts);
    }
    step();
    final Object? levels = content.sections[CircleBackupSections.levels];
    if (levels is Map) {
      for (final MapEntry<dynamic, dynamic> e in levels.entries) {
        final FriendLevel? level = FriendLevel.values
            .where((FriendLevel l) => l.name == e.value)
            .firstOrNull;
        if (e.key is String && level != null) {
          await node.setLevel(e.key as String, level);
        }
      }
    }
    step();
    final Object? pyramid = content.sections[CircleBackupSections.pyramid];
    if (pyramid is Map<String, dynamic>) {
      await ref.read(pyramidServiceProvider).mergeFromOwnDevice(pyramid);
    }
    step();
    // The household: kept as a copy; "Przenieś mieszkanie na to
    // urządzenie" starts it here (a key changed meanwhile is never undone).
    final Object? household = content.sections[CircleBackupSections.household];
    if (household is Map<String, dynamic>) {
      await ref.read(neighborsServiceProvider).restoreFromBackup(household);
    }
    step();
    final Object? dating = content.sections[CircleBackupSections.dating];
    if (dating is Map<String, dynamic>) {
      final DatingService service = ref.read(datingServiceProvider);
      // Only into an empty profile: one made here since stays.
      if (!service.me.complete) {
        final MyDating from = MyDating.fromJson(dating);
        await service.saveMine((MyDating me) => restoreDatingProfile(me, from));
      }
    }
    step();
    for (final MapEntry<String, List<Map<String, dynamic>>> c
        in content.chats.entries) {
      for (final Map<String, dynamic> json in c.value) {
        final ChatMessage? m = chatMessageFromSync(json);
        if (m != null) {
          // The copy never has the files: they do not come from here.
          await _hub.importSyncedMessage(c.key, chatMessageWithoutFile(m));
        }
        step();
      }
    }
  }
}

/// The dating profile and its settings for the circle copy: everything but
/// the photos (no media in the copy).
Map<String, dynamic> _datingWithoutPhotos(MyDating me) =>
    me.toJson()..remove('ph');

/// [from] (the circle copy) into [me]: text, settings, hidden lists and
/// friends' vouches; photos stay as they are.
void restoreDatingProfile(MyDating me, MyDating from) {
  me
    ..enabled = from.enabled
    ..name = from.name
    ..gender = from.gender
    ..about = from.about
    ..lookingFor = from.lookingFor
    ..wants = from.wants;
  me.interests
    ..clear()
    ..addAll(from.interests);
  me.hiddenFriends
    ..clear()
    ..addAll(from.hiddenFriends);
  me.hiddenCircles
    ..clear()
    ..addAll(from.hiddenCircles);
  me.hiddenGroups
    ..clear()
    ..addAll(from.hiddenGroups);
  me.vouches
    ..clear()
    ..addAll(from.vouches);
}
