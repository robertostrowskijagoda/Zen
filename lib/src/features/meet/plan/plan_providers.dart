import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/plan/plan_model.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// "Plan na weekend" (§17.6) in the app.
final Provider<PlanService> planServiceProvider = Provider<PlanService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final LedgerDisk disk = ref.read(ledgerDiskProvider);
  final PlanService plans = PlanService(
    host: appEventHost(ref, meet),
    disk: disk,
    events: ref.watch(eventServiceProvider),
    closeFriends: () => meet.host.closeFriends(),
  );
  // The event comes with a chat: a group of the friends who joined.
  plans.onEvent = (WeekendPlan plan, MeetEvent event) async {
    final List<String> members = <String>[
      for (final PlanAnswer a in plan.joined)
        if (a.via == null) a.address,
    ];
    if (members.isEmpty) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .createGroup(
          name: plan.title,
          description: 'Plan na weekend',
          memberAddresses: members,
        );
  };
  Future<void> refresh() => plans.load().then((_) => plans.checkThresholds());
  unawaitedLogged(refresh(), context: 'Odczyt planów');
  listenFrames(ref, plans.handle, 'Plan na weekend');
  // The Android background service may take answers while the app is
  // away; plans that reached their threshold meanwhile convert here.
  final AppLifecycleListener life = AppLifecycleListener(
    onResume: () => unawaitedLogged(refresh(), context: 'Odczyt planów'),
  );
  ref.onDispose(() {
    life.dispose();
    plans.dispose();
  });
  return plans;
});
