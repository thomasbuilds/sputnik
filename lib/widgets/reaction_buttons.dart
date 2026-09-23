import 'package:flutter/material.dart';

import '../main.dart';
import '../models/note.dart';
import '../nostr/nostr.dart';
import '../services/reaction_actions.dart';
import '../theme/app_text_styles.dart';

/// Likes/reposts toggled this session, by "identity:kind:note id", so every
/// button showing the same note agrees, whichever one was tapped.
final reactionOverrides = ValueNotifier<Map<String, bool>>(const {});

String? _overrideKey(int kind, Note note) {
  final me = activeIdentityPubkeyNotifier.value;
  return me == null ? null : '$me:$kind:${note.id}';
}

void _setOverride(int kind, Note note, bool value) {
  final key = _overrideKey(kind, note);
  if (key == null) return;
  reactionOverrides.value = {...reactionOverrides.value, key: value};
}

bool? _override(int kind, Note note) {
  final key = _overrideKey(kind, note);
  return key == null ? null : reactionOverrides.value[key];
}

/// A like button for [note]; toggles a like on tap.
class LikeButton extends StatefulWidget {
  const LikeButton({
    super.key,
    required this.note,
    this.relayClient = const RelayClient(),
    this.showCount = true,
    this.size = 16,
  });

  final Note note;
  final RelayClient relayClient;
  final bool showCount;
  final double size;

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton> {
  bool _pending = false;

  bool? get _localOverride => _override(7, widget.note);

  @override
  void initState() {
    super.initState();
    reactionOverrides.addListener(_rebuild);
    activeIdentityPubkeyNotifier.addListener(_rebuild);
  }

  @override
  void dispose() {
    reactionOverrides.removeListener(_rebuild);
    activeIdentityPubkeyNotifier.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  Future<void> _tap() async {
    final liked =
        _localOverride ??
        widget.note.likedBy(activeIdentityPubkeyNotifier.value);
    setState(() => _pending = true);
    final succeeded = liked
        ? await unlikeNote(
            context,
            widget.note,
            relayClient: widget.relayClient,
          )
        : await likeNote(context, widget.note, relayClient: widget.relayClient);
    if (!mounted) return;
    setState(() => _pending = false);
    if (succeeded) _setOverride(7, widget.note, !liked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final liked =
        _localOverride ??
        widget.note.likedBy(activeIdentityPubkeyNotifier.value);
    final count =
        widget.note.likeCount +
        (liked == widget.note.likedBy(activeIdentityPubkeyNotifier.value)
            ? 0
            : (liked ? 1 : -1));
    final color = liked ? theme.colorScheme.primary : theme.colorScheme.outline;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          liked ? Icons.favorite : Icons.favorite_border,
          size: widget.size,
          color: color,
        ),
        if (widget.showCount && count > 0) ...[
          const SizedBox(width: 4),
          Text('$count', style: theme.metadata),
        ],
      ],
    );

    return Tooltip(
      message: liked ? 'Liked' : 'Like',
      child: InkResponse(
        onTap: _pending ? null : _tap,
        radius: 20,
        child: Padding(padding: const EdgeInsets.all(4), child: content),
      ),
    );
  }
}

/// A repost button for [note]; toggles a repost on tap.
class RepostButton extends StatefulWidget {
  const RepostButton({
    super.key,
    required this.note,
    this.relayClient = const RelayClient(),
    this.showCount = true,
    this.size = 16,
  });

  final Note note;
  final RelayClient relayClient;
  final bool showCount;
  final double size;

  @override
  State<RepostButton> createState() => _RepostButtonState();
}

class _RepostButtonState extends State<RepostButton> {
  bool _pending = false;

  bool? get _localOverride => _override(6, widget.note);

  @override
  void initState() {
    super.initState();
    reactionOverrides.addListener(_rebuild);
    activeIdentityPubkeyNotifier.addListener(_rebuild);
  }

  @override
  void dispose() {
    reactionOverrides.removeListener(_rebuild);
    activeIdentityPubkeyNotifier.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  Future<void> _tap() async {
    final reposted =
        _localOverride ??
        widget.note.repostedBy(activeIdentityPubkeyNotifier.value);
    setState(() => _pending = true);
    final succeeded = reposted
        ? await unrepostNote(
            context,
            widget.note,
            relayClient: widget.relayClient,
          )
        : await repostNote(
            context,
            widget.note,
            relayClient: widget.relayClient,
          );
    if (!mounted) return;
    setState(() => _pending = false);
    if (succeeded) _setOverride(6, widget.note, !reposted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reposted =
        _localOverride ??
        widget.note.repostedBy(activeIdentityPubkeyNotifier.value);
    final count =
        widget.note.repostCount +
        (reposted == widget.note.repostedBy(activeIdentityPubkeyNotifier.value)
            ? 0
            : (reposted ? 1 : -1));
    final color = reposted
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.repeat, size: widget.size, color: color),
        if (widget.showCount && count > 0) ...[
          const SizedBox(width: 4),
          Text('$count', style: theme.metadata),
        ],
      ],
    );

    return Tooltip(
      message: reposted ? 'Reposted' : 'Repost',
      child: InkResponse(
        onTap: _pending ? null : _tap,
        radius: 20,
        child: Padding(padding: const EdgeInsets.all(4), child: content),
      ),
    );
  }
}
