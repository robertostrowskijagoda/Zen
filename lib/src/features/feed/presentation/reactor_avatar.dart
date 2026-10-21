import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/presentation/ledger_picture.dart';

/// The round photo of someone who liked or commented: their
/// profile photo from the mini-profile that came with the reaction, fetched
/// from your friends when it is not on the phone yet; the initial until
/// then, and when the reaction came without a photo.
class ReactorAvatar extends StatefulWidget {
  const ReactorAvatar({
    required this.name,
    required this.size,
    this.node,
    this.avatar,
    super.key,
  });

  final LedgerNode? node;
  final MediaRef? avatar;
  final String name;
  final double size;

  @override
  State<ReactorAvatar> createState() => _ReactorAvatarState();
}

class _ReactorAvatarState extends State<ReactorAvatar> {
  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(ReactorAvatar old) {
    super.didUpdateWidget(old);
    if (old.avatar?.id != widget.avatar?.id) {
      _fetch();
    }
  }

  void _fetch() {
    final LedgerNode? node = widget.node;
    final MediaRef? avatar = widget.avatar;
    if (node == null || avatar == null || !node.isReady) {
      return;
    }
    node.replicator.fetchBlob(avatar.id, node.friendAccounts.keys.toList());
  }

  @override
  Widget build(BuildContext context) {
    final LedgerNode? node = widget.node;
    final MediaRef? avatar = widget.avatar;
    if (node == null || avatar == null) {
      return ZenBlobAvatar(
        name: widget.name,
        size: widget.size,
        showStatus: false,
      );
    }
    return LedgerAvatar(
      node: node,
      media: avatar,
      name: widget.name,
      size: widget.size,
    );
  }
}
