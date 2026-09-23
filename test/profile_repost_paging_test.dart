// Audit (state/ST): the profile's repost paging decides "no more pages" from
// the number of reposts it could *resolve*, not the number the relay returned.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/screens/profile_screen.dart';

import 'support/in_memory_relay_client.dart';

Finder get _list => find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .hitTestable()
    .last;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    selectedRelaysNotifier.value = const {};
    profileCacheNotifier.value = const {};
    activeIdentityPubkeyNotifier.value = null;
    notesNotifier.value = null;
  });

  testWidgets('ST-13: one unresolvable repost among the newest 100 ends the '
      "profile's repost paging; older reposts never show", (tester) async {
    final reposter = 'ab' * 32;
    final other = generateNostrKeyPair(); // throwaway, signs the targets
    final base = DateTime.now().subtract(const Duration(days: 1));
    late List<NostrEvent> events;
    await tester.runAsync(() async {
      events = [
        for (var i = 0; i < 150; i++)
          () {
            final target = signEvent(
              seckeyHex: other.privateKeyHex,
              pubkeyHex: other.publicKeyHex,
              kind: 1,
              content: 'reposted note $i',
              createdAt: base.subtract(Duration(minutes: i)),
            );
            return fakeEvent(
              id: 'r$i'.padRight(64, '0'),
              pubkey: reposter,
              kind: 6,
              // #5 has no embedded copy and its note is not on the relays.
              content: i == 5 ? '' : jsonEncode(target.toJson()),
              tags: [
                ['e', i == 5 ? 'f' * 64 : target.id],
              ],
              createdAt: base.subtract(Duration(minutes: i, seconds: -30)),
            );
          }(),
      ];
    });
    final client = InMemoryRelayClient(events);

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileScreen(pubkeyHex: reposter, relayClient: client),
      ),
    );
    await _settle(tester);
    expect(find.text('reposted note 0'), findsOneWidget);

    var reachedOldest = true;
    try {
      await tester.scrollUntilVisible(
        find.text('reposted note 149'),
        800,
        scrollable: _list,
        maxScrolls: 300,
      );
    } on StateError {
      reachedOldest = false;
    }
    final kind6Queries = client.queries.where(
      (f) => f.kinds?.contains(6) == true,
    );
    // ignore: avoid_print
    print(
      'kind 6 page queries: ${kind6Queries.length}; oldest repost shown: '
      '$reachedOldest',
    );
    expect(reachedOldest, isTrue);
  });
}
