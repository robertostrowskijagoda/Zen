import 'package:flutter/widgets.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Keeps page names the system pushes away from the app's Navigator.
///
/// Zen has no named pages: links and opened files reach it through
/// app_links (runtime_deep_link_bridge.dart, opened_files.dart). A link
/// the system's own routing hands to Flutter anyway (Android started
/// through a launcher alias read Flutter's switch from the alias) was
/// pushed by name and crashed the app with nothing to build it. Placed
/// above the [WidgetsApp], so this observer is asked first and takes the
/// push.
class PlatformRouteGuard extends StatefulWidget {
  const PlatformRouteGuard({required this.child, super.key});

  final Widget child;

  @override
  State<PlatformRouteGuard> createState() => _PlatformRouteGuardState();
}

class _PlatformRouteGuardState extends State<PlatformRouteGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    // Only the scheme: the rest may name a person or an invitation code.
    logZenWarning(
      'A page pushed by the system was ignored '
      '(scheme: "${routeInformation.uri.scheme}")',
    );
    return Future<bool>.value(true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// [WidgetsApp.onUnknownRoute] for a page name nothing builds: a page that
/// takes itself away at once instead of a crash.
Route<void> zenUnknownRoute(RouteSettings settings) {
  logZenWarning('A page with an unknown name was asked for and closed');
  return PageRouteBuilder<void>(
    settings: settings,
    opaque: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) => const _ClosesItself(),
  );
}

class _ClosesItself extends StatefulWidget {
  const _ClosesItself();

  @override
  State<_ClosesItself> createState() => _ClosesItselfState();
}

class _ClosesItselfState extends State<_ClosesItself> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
