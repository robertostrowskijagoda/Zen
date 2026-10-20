import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/app_data_reset.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/calls/presentation/call_recordings_screen.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart';
import 'package:zen/src/features/groups/presentation/create_group_sheet.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/ledger/bridge_host.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/presentation/alarm_screen.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/meet/presentation/intro_widgets.dart';
import 'package:zen/src/features/meet/presentation/meet_hub_screen.dart';
import 'package:zen/src/features/meet/presentation/met_level_prompt.dart';
import 'package:zen/src/features/meet/presentation/nearby_screen.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/permissions/presentation/permissions_screen.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/presentation/wallet_screen.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/device_integrity.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/presentation/age_gate.dart';
import 'package:zen/src/features/settings/presentation/experimental_features_screen.dart';
import 'package:zen/src/features/settings/presentation/group_invite_tile.dart';
import 'package:zen/src/features/settings/presentation/language_screen.dart';
import 'package:zen/src/features/settings/presentation/storage_limits_section.dart';
import 'package:zen/src/features/shell/presentation/health_screen.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/presentation/friend_nickname_prompt.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/presentation/friends_version_banner.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

part 'app_shell_screen_views.dart';
part 'app_shell_screen_settings_security.dart';
part 'app_shell_screen_widgets.dart';
part 'app_shell_screen_relay.dart';
part 'app_shell_screen_tabs.dart';

enum ServiceHealth { active, syncing, stopped, failed }

const Object _appShellSentinel = Object();

typedef SystemSoundPlayer = Future<void> Function(SystemSoundType type);

final Provider<SystemSoundPlayer> systemSoundPlayerProvider =
    Provider<SystemSoundPlayer>((Ref ref) {
      return SystemSound.play;
    });

@immutable
final class AppShellState {
  const AppShellState({
    this.health = ServiceHealth.active,
    this.peers = 12,
    this.activeTransfers = 1,
    this.latencyMs = 48,
    this.throughputMbps = 18.4,
    this.inboxLimitMb = 32,
    this.localAddress = '',
    this.routingEntries = 0,
    this.peerPoolCount = 0,
    this.selectedPeer = '',
    this.errorMessage,
  });

  final ServiceHealth health;
  final int peers;
  final int activeTransfers;
  final int latencyMs;
  final double throughputMbps;
  final int inboxLimitMb;
  final String localAddress;
  final int routingEntries;
  final int peerPoolCount;
  final String selectedPeer;
  final String? errorMessage;

  bool get serviceRunning =>
      health == ServiceHealth.active || health == ServiceHealth.syncing;

  bool get isConnected => serviceRunning && (peers > 0 || routingEntries > 0);

  bool get isConnecting => serviceRunning && !isConnected;

  String get healthLabel => switch (health) {
    ServiceHealth.active => t('Aktywny'),
    ServiceHealth.syncing => t('Synchronizacja'),
    ServiceHealth.stopped => t('Zatrzymany'),
    ServiceHealth.failed => t('Błąd'),
  };

  String get connectionLabel {
    if (health == ServiceHealth.failed || health == ServiceHealth.stopped) {
      return t('Brak sieci');
    }
    if (isConnected) {
      return t('Połączono');
    }
    return t('Łączę...');
  }

  String get healthSummary => switch (health) {
    ServiceHealth.active =>
      isConnected
          ? t('Połączenie działa — widzisz innych w sieci.')
          : t('Serwis działa i szuka połączeń z siecią.'),
    ServiceHealth.syncing => t(
      'Serwis odbudowuje trasę i odświeża stan połączeń.',
    ),
    ServiceHealth.stopped => t(
      'Sieć jest wstrzymana do ponownego uruchomienia.',
    ),
    ServiceHealth.failed => t(
      'Sieć nie wystartowała. Sprawdź szczegóły i uruchom ją ponownie.',
    ),
  };

  String get throughputLabel => '${throughputMbps.toStringAsFixed(1)} MB/s';

  String get toggleLabel =>
      serviceRunning ? t('Zatrzymaj serwis') : t('Uruchom serwis');

  AppShellState copyWith({
    ServiceHealth? health,
    int? peers,
    int? activeTransfers,
    int? latencyMs,
    double? throughputMbps,
    int? inboxLimitMb,
    String? localAddress,
    int? routingEntries,
    int? peerPoolCount,
    String? selectedPeer,
    Object? errorMessage = _appShellSentinel,
  }) {
    return AppShellState(
      health: health ?? this.health,
      peers: peers ?? this.peers,
      activeTransfers: activeTransfers ?? this.activeTransfers,
      latencyMs: latencyMs ?? this.latencyMs,
      throughputMbps: throughputMbps ?? this.throughputMbps,
      inboxLimitMb: inboxLimitMb ?? this.inboxLimitMb,
      localAddress: localAddress ?? this.localAddress,
      routingEntries: routingEntries ?? this.routingEntries,
      peerPoolCount: peerPoolCount ?? this.peerPoolCount,
      selectedPeer: selectedPeer ?? this.selectedPeer,
      errorMessage: identical(errorMessage, _appShellSentinel)
          ? this.errorMessage
          : castCopyWithValue<String>(errorMessage, fieldName: 'errorMessage'),
    );
  }
}

final class AppShellController extends Notifier<AppShellState> {
  @override
  AppShellState build() {
    final RuntimeTransportSnapshot runtime = ref.watch(
      runtimeNodeSnapshotProvider,
    );
    return AppShellState(
      health: _serviceHealthFor(runtime.health),
      peers: runtime.peers,
      activeTransfers: runtime.activeTransfers,
      latencyMs: runtime.latencyMs,
      throughputMbps: runtime.throughputMbps,
      inboxLimitMb: runtime.inboxLimitMb,
      localAddress: runtime.localAddress,
      routingEntries: runtime.routingEntries,
      peerPoolCount: runtime.peerPoolCount,
      selectedPeer: runtime.selectedPeer,
      errorMessage: runtime.errorMessage,
    );
  }

  Future<void> resetService() async {
    await ref.read(runtimeNodeRuntimeProvider).restart();
  }

  Future<void> toggleService() async {
    if (state.serviceRunning) {
      await ref.read(runtimeNodeRuntimeProvider).stop();
      return;
    }
    await ref.read(runtimeNodeRuntimeProvider).start();
  }

  ServiceHealth _serviceHealthFor(RuntimeTransportHealth health) {
    return switch (health) {
      RuntimeTransportHealth.active => ServiceHealth.active,
      RuntimeTransportHealth.syncing => ServiceHealth.syncing,
      RuntimeTransportHealth.stopped => ServiceHealth.stopped,
      RuntimeTransportHealth.failed => ServiceHealth.failed,
    };
  }
}

final NotifierProvider<AppShellController, AppShellState>
appShellControllerProvider =
    NotifierProvider<AppShellController, AppShellState>(AppShellController.new);

@immutable
final class ConversationPreview {
  const ConversationPreview({
    required this.address,
    required this.name,
    required this.status,
    required this.lastMessage,
    required this.timeLabel,
    required this.unreadCount,
    required this.isOnline,
    this.isTyping = false,
    this.avatarPath,
    this.nickname = '',
  });

  final String address;
  final String name;

  /// What the user calls them, shown under [name] ('' when not set).
  final String nickname;

  /// The peer's own photo, when it sent one.
  final String? avatarPath;
  final FriendRelationshipStatus status;
  final String lastMessage;
  final String timeLabel;
  final int unreadCount;
  final bool isOnline;
  final bool isTyping;
}

class AppShellScreen extends ConsumerWidget {
  const AppShellScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // With the social network on, the app gets its vertical tabs (§25);
    // the plain messenger layout stays for builds without it.
    if (ref.watch(ledgerNodeEnabledProvider)) {
      return const _TabbedShell();
    }
    return const Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _CallFeedbackHost(),
            _StatusBar(),
            // The chat list shows the last messages (S-9).
            Expanded(
              child: SecureScreen(child: _ChatsPage(key: Key('chats-page'))),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plays ring feedback for incoming/outgoing calls regardless of the
/// visible tab.
class _CallFeedbackHost extends ConsumerStatefulWidget {
  const _CallFeedbackHost();

  @override
  ConsumerState<_CallFeedbackHost> createState() => _CallFeedbackHostState();
}

class _CallFeedbackHostState extends ConsumerState<_CallFeedbackHost> {
  Timer? _ringTimer;
  String? _activeFeedbackKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncFeedback(_currentSession());
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<CallSession?>(
      socialHubControllerProvider.select(
        (SocialHubState state) =>
            state.lifecycle.isInteractive ? state.activeCall : null,
      ),
      (CallSession? previous, CallSession? next) {
        _syncFeedback(next);
      },
    );
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _ringTimer?.cancel();
    super.dispose();
  }

  CallSession? _currentSession() {
    return ref.read(
      socialHubControllerProvider.select(
        (SocialHubState state) =>
            state.lifecycle.isInteractive ? state.activeCall : null,
      ),
    );
  }

  void _syncFeedback(CallSession? session) {
    final String? nextKey =
        session != null && session.status == CallSessionStatus.ringing
        ? '${session.id}:${session.isIncoming}'
        : null;
    if (_activeFeedbackKey == nextKey) {
      return;
    }
    _activeFeedbackKey = nextKey;
    _ringTimer?.cancel();
    _ringTimer = null;
    if (session == null || session.status != CallSessionStatus.ringing) {
      return;
    }
    _playAlert();
    _ringTimer = Timer.periodic(
      session.isIncoming
          ? const Duration(milliseconds: 1100)
          : const Duration(seconds: 3),
      (Timer timer) => _playAlert(),
    );
  }

  void _playAlert() {
    final bool incoming = _currentSession()?.isIncoming ?? false;
    if (incoming) {
      unawaitedLogged(
        HapticFeedback.heavyImpact(),
        context: 'incoming call haptic',
      );
    }
    final SystemSoundPlayer player = ref.read(systemSoundPlayerProvider);
    unawaitedLogged(
      player(SystemSoundType.alert),
      context: 'call feedback alert',
    );
    if (incoming) {
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        unawaitedLogged(
          player(SystemSoundType.alert),
          context: 'incoming call ring pulse',
        );
        unawaitedLogged(
          HapticFeedback.mediumImpact(),
          context: 'incoming call haptic pulse',
        );
      });
    }
  }
}
