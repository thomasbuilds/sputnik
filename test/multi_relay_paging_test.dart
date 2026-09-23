// Audit (state/ST): paging across several relays, merged the way
// RelayConnectionPool.queryWithStatus merges them (each relay applies the
// filter's limit on its own; results are unioned and deduplicated by id).
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/services/post_cursor.dart';

import 'support/in_memory_relay_client.dart';

class _MultiRelayClient extends RelayClient {
  _MultiRelayClient(this.relays);

  final Map<String, InMemoryRelayClient> relays;

  @override
  Future<List<NostrEvent>> query(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async {
    final byId = <String, NostrEvent>{};
    for (final url in relayUrls) {
      for (final e in await relays[url]!.query({url}, filter)) {
        byId[e.id] = e;
      }
    }
    return byId.values.toList();
  }
}

final _t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);

NostrEvent _event(String id, int secondsAgo, {bool reply = false}) => fakeEvent(
  id: id.padLeft(64, '0'),
  content: id,
  createdAt: _t0.subtract(Duration(seconds: secondsAgo)),
  tags: [
    if (reply) ['e', 'f' * 64, '', 'reply'],
  ],
);

void main() {
  test(
    'ST-02: a sparse relay\'s old posts let a page run past what a busy '
    'relay returned, so the busy relay\'s posts in between are skipped',
    () async {
      // Busy relay: a post every 10 s, 4 in 5 of them replies.
      final busy = [
        for (var i = 0; i < 400; i++)
          _event('busy$i', i * 10, reply: i % 5 != 0),
      ];
      // Quiet relay: 20 top-level posts spread over hours.
      final quiet = [
        for (var i = 0; i < 20; i++) _event('quiet$i', 500 + i * 1000),
      ];
      final client = _MultiRelayClient({
        'wss://busy': InMemoryRelayClient(busy),
        'wss://quiet': InMemoryRelayClient(quiet),
      });
      // The global feed's page: 30 posts, replies left out.
      final repository = RelayPostRepository(
        relayUrls: const {'wss://busy', 'wss://quiet'},
        client: client,
      );
      final cursor = PostCursor(
        (until) => repository.fetchPage(includeReplies: false, until: until),
      );

      final shown = <NostrEvent>[];
      shown.addAll(await _events(cursor.first(), [...busy, ...quiet]));
      var pages = 1;
      while (cursor.hasMore.value && pages < 50) {
        shown.addAll(await _events(cursor.more(), [...busy, ...quiet]));
        pages++;
      }

      final shownIds = {for (final e in shown) e.id};
      final oldestShown = shown
          .map((e) => e.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final everyTopLevel = [...busy, ...quiet]
          .where((e) => !e.tags.any((t) => t[0] == 'e'))
          .where((e) => !e.createdAt.isBefore(oldestShown))
          .toList();
      final skipped = [
        for (final e in everyTopLevel)
          if (!shownIds.contains(e.id)) e.content,
      ];
      // ignore: avoid_print
      print(
        'pages=$pages shown=${shown.length} of ${everyTopLevel.length} '
        'top-level posts in the scrolled range; never shown: '
        '${skipped.length} e.g. ${skipped.take(5).toList()}',
      );
      expect(skipped, isEmpty);
    },
  );
}

Future<List<NostrEvent>> _events(
  Future<List<NostrPost>> posts,
  List<NostrEvent> all,
) async {
  final byId = {for (final e in all) e.id: e};
  return [for (final p in await posts) byId[p.id]!];
}
