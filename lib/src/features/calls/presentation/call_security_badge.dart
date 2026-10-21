import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/call_media_e2ee.dart';

/// A small pill telling how the call's audio and video are protected.
class CallSecurityBadge extends StatelessWidget {
  const CallSecurityBadge({required this.security, super.key});

  final CallMediaSecurity security;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final (IconData icon, Color color, String label) = switch (security) {
      CallMediaSecurity.postQuantum => (
        Icons.lock_rounded,
        zen.success,
        t('Szyfrowanie odporne na komputery kwantowe'),
      ),
      CallMediaSecurity.standard => (
        Icons.lock_outline_rounded,
        zen.textSecondary,
        t('Szyfrowanie standardowe'),
      ),
      CallMediaSecurity.negotiating => (
        Icons.hourglass_top_rounded,
        zen.textMuted,
        t('Ustalanie szyfrowania…'),
      ),
    };
    return Container(
      key: Key('call-security-${security.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: context.zenRadius(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
