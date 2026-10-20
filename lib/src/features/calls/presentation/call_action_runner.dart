import 'package:flutter/material.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/calls/presentation/call_surface_screen.dart';
import 'package:zen/src/features/groups/presentation/group_call_screen.dart';

Future<bool> runCallAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  String? message;
  try {
    await action();
    return true;
  } on FormatException catch (error) {
    message = error.message;
  } catch (error) {
    message = t('Nie udało się obsłużyć rozmowy: {error}', {'error': error});
  }
  // The call overlays live above the root Navigator, so their own context may
  // not reach a messenger; fall back to the root one.
  ScaffoldMessengerState? messenger;
  if (context.mounted) {
    messenger = ScaffoldMessenger.maybeOf(context);
  }
  final BuildContext? rootContext = zenRootNavigatorKey.currentContext;
  if (messenger == null && rootContext != null) {
    // Read fresh from the global key, so it cannot be a stale context.
    // ignore: use_build_context_synchronously
    messenger = ScaffoldMessenger.maybeOf(rootContext);
  }
  if (messenger == null) {
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  return false;
}

/// Opens the full call surface on the root navigator.
///
/// The call overlays sit above that navigator, so `Navigator.of(context)` is
/// not reachable from them — everything call related routes through here.
/// [fallbackNavigator] is only used by embeddings that do not install
/// [zenRootNavigatorKey] (tests, previews).
Future<void> openCallSurface({
  required String peerAddress,
  required String title,
  bool returnToConversation = false,
  NavigatorState? fallbackNavigator,
}) async {
  // Answering can be asked for twice — once by the in-app overlay and once by
  // the launch intent the notification queued — and two stacked surfaces mean
  // the user has to dismiss the call screen twice after hanging up.
  if (_callSurfaceRoute?.isActive ?? false) {
    return;
  }
  final NavigatorState? navigator =
      zenRootNavigatorKey.currentState ?? fallbackNavigator;
  if (navigator == null || !navigator.mounted) {
    return;
  }
  final MaterialPageRoute<void> route = MaterialPageRoute<void>(
    builder: (BuildContext context) => CallSurfaceScreen(
      peerAddress: peerAddress,
      title: title,
      returnToConversation: returnToConversation,
    ),
  );
  _callSurfaceRoute = route;
  try {
    await navigator.push(route);
  } finally {
    if (identical(_callSurfaceRoute, route)) {
      _callSurfaceRoute = null;
    }
  }
}

/// Opens the group call surface on the root navigator.
Future<void> openGroupCallSurface({
  required String groupId,
  required String groupName,
  bool initialVideo = false,
  NavigatorState? fallbackNavigator,
}) async {
  if (_callSurfaceRoute?.isActive ?? false) {
    return;
  }
  final NavigatorState? navigator =
      zenRootNavigatorKey.currentState ?? fallbackNavigator;
  if (navigator == null || !navigator.mounted) {
    return;
  }
  final MaterialPageRoute<void> route = MaterialPageRoute<void>(
    builder: (BuildContext context) => GroupCallScreen(
      groupId: groupId,
      groupName: groupName,
      initialVideo: initialVideo,
    ),
  );
  _callSurfaceRoute = route;
  try {
    await navigator.push(route);
  } finally {
    if (identical(_callSurfaceRoute, route)) {
      _callSurfaceRoute = null;
    }
  }
}

/// The call surface currently pushed by [openCallSurface] or [openGroupCallSurface], if any.
///
/// A popped route reports `isActive == false`, so a stale reference can never
/// block a later call.
Route<void>? _callSurfaceRoute;
