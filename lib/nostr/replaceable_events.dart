import 'models/nostr_event.dart';
import 'models/nostr_filter.dart';
import 'relay_client.dart';

/// The newest copy of one of the user's replaceable events, if any. Only build
/// an edit on it when [conclusive].
class OwnEvent {
  const OwnEvent({required this.event, required this.conclusive});

  final NostrEvent? event;

  /// False unless every relay answered, or a majority did and one had it.
  final bool conclusive;
}

/// Queries [relayUrls] for the newest [kind] event by [pubkeyHex]. With
/// [requireAllRelays], a found event is only [OwnEvent.conclusive] when every
/// relay answered, since a silent one may hold a newer copy.
Future<OwnEvent> fetchOwnReplaceable(
  RelayClient client, {
  required int kind,
  required String pubkeyHex,
  required Set<String> relayUrls,
  bool requireAllRelays = false,
}) async {
  final result = await client.queryWithStatus(
    relayUrls,
    NostrFilter(kinds: [kind], authors: [pubkeyHex], limit: 1),
  );
  final author = pubkeyHex.toLowerCase();
  final own = [
    for (final event in result.events)
      if (event.kind == kind && event.pubkey == author) event,
  ]..sort(compareNewestFirst);

  return OwnEvent(
    event: own.isEmpty ? null : own.first,
    // A lagging relay can hold an older copy while the newest one is silent.
    conclusive:
        result.allRelaysAnswered ||
        (!requireAllRelays &&
            own.isNotEmpty &&
            result.answeredRelays * 2 > result.queriedRelays),
  );
}

/// Of two same-second versions relays keep the lowest ID (NIP-01), which may
/// be the old one, so an edit must be at least a second newer.
DateTime nextReplaceableTime(NostrEvent? previous) {
  final now = DateTime.now();
  if (previous == null) return now;
  final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
  final previousSeconds = previous.createdAt.millisecondsSinceEpoch ~/ 1000;
  return nowSeconds > previousSeconds
      ? now
      : DateTime.fromMillisecondsSinceEpoch((previousSeconds + 1) * 1000);
}
