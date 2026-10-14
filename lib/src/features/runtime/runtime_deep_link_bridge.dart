import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

final Provider<bool> runtimeDeepLinkBindingEnabledProvider = Provider<bool>((
  Ref ref,
) {
  return true;
});

final deepLinkSourceProvider = Provider<DeepLinkSource>((Ref ref) {
  return AppLinksDeepLinkSource();
});

abstract interface class DeepLinkSource {
  Future<Uri?> getInitialLink();

  Stream<Uri> get linkStream;
}

final class AppLinksDeepLinkSource implements DeepLinkSource {
  AppLinksDeepLinkSource([AppLinks? appLinks])
    : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> getInitialLink() {
    return _appLinks.getInitialLink();
  }

  @override
  Stream<Uri> get linkStream => _appLinks.uriLinkStream;
}

class RuntimeDeepLinkBridge extends ConsumerStatefulWidget {
  const RuntimeDeepLinkBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RuntimeDeepLinkBridge> createState() {
    return _RuntimeDeepLinkBridgeState();
  }
}

final class _RuntimeDeepLinkBridgeState
    extends ConsumerState<RuntimeDeepLinkBridge> {
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    if (!ref.read(runtimeDeepLinkBindingEnabledProvider)) {
      return;
    }
    Future<void>.microtask(_startListening);
  }

  @override
  void dispose() {
    unawaitedLogged(
      _linkSubscription?.cancel(),
      context: 'Deep-link subscription cancellation failed',
    );
    _linkSubscription = null;
    super.dispose();
  }

  Future<void> _startListening() async {
    if (!mounted || !ref.read(runtimeDeepLinkBindingEnabledProvider)) {
      return;
    }
    final DeepLinkSource source = ref.read(deepLinkSourceProvider);
    try {
      final Uri? initialLink = await source.getInitialLink();
      if (initialLink != null) {
        await _handleLink(initialLink);
      }
    } catch (error, stackTrace) {
      logZenError('Initial deep-link bootstrap failed', error, stackTrace);
    }
    if (!mounted) {
      return;
    }
    _linkSubscription = source.linkStream.listen(
      (Uri uri) {
        unawaitedLogged(_handleLink(uri), context: 'Deep-link handling failed');
      },
      onError: (Object error, StackTrace stackTrace) {
        logZenError('Deep-link stream error', error, stackTrace);
      },
    );
  }

  Future<void> _handleLink(Uri uri) async {
    if (!mounted) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .requestLaunchFromRouteKey(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
