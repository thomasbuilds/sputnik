// Audit (state/ST): follow-sync queue durability across identity switches
// and restarts.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/models/identity.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/services/follow_sync.dart';
import 'package:sputnik/services/settings_store.dart';

import 'support/fake_secret_store.dart';

/// Relays that are down until [up] is set, then hold one kind 3 per author.
class _Relay extends RelayClient {
  bool up = false;
  final lists = <String, List<String>>{};
  final listTimes = <String, DateTime>{};
  final published = <NostrEvent>[];

  @override
  Future<List<NostrEvent>> query(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async => (await queryWithStatus(relayUrls, filter)).events;

  @override
  Future<RelayQueryResult> queryWithStatus(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async {
    if (!up) {
      return const RelayQueryResult(
        events: [],
        answeredRelays: 0,
        queriedRelays: 2,
      );
    }
    final author = filter.authors!.first;
    final follows = lists[author];
    return RelayQueryResult(
      events: [
        if (follows != null)
          NostrEvent(
            id: '${author.substring(0, 60)}beef',
            pubkey: author,
            createdAt: listTimes[author] ?? DateTime(2020),
            kind: 3,
            tags: [
              for (final p in follows) ['p', p],
            ],
            content: '',
            sig: 'sig',
          ),
      ],
      answeredRelays: 2,
      queriedRelays: 2,
    );
  }

  @override
  Future<Map<String, RelayPublishResult>> publish(
    NostrEvent event,
    Set<String> relayUrls,
  ) async {
    if (!up) {
      return {
        for (final url in relayUrls)
          url: const RelayPublishResult(RelayPublishOutcome.connectionFailed),
      };
    }
    published.add(event);
    lists[event.pubkey] = [for (final t in event.tags) t[1]];
    listTimes[event.pubkey] = event.createdAt;
    return {
      for (final url in relayUrls)
        url: const RelayPublishResult(RelayPublishOutcome.accepted),
    };
  }
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String a;
  late String b;
  final x = 'cc' * 32;
  final y = 'dd' * 32;
  late FakeSecretStore secrets;

  setUp(() async {
    resetFollowSync();
    resetKnownContactLists();
    followSyncRetryDelays = const [Duration(milliseconds: 100)];
    SharedPreferences.setMockInitialValues({});
    secrets = FakeSecretStore();
    SettingsStore.secretStore = secrets;
    // Throwaway keypairs generated for this run only.
    final ka = generateNostrKeyPair();
    final kb = generateNostrKeyPair();
    a = ka.publicKeyHex;
    b = kb.publicKeyHex;
    await SettingsStore.savePrivateKey(a, ka.privateKeyHex);
    await SettingsStore.savePrivateKey(b, kb.privateKeyHex);
    identitiesNotifier.value = [
      Identity(pubkeyHex: a, createdAt: DateTime.now()),
      Identity(pubkeyHex: b, createdAt: DateTime.now()),
    ];
    selectedRelaysNotifier.value = {'wss://r1.example', 'wss://r2.example'};
    activeIdentityPubkeyNotifier.value = a;
  });

  tearDown(resetFollowSync);

  test('ST-05a: a queued follow for A is silently dropped once B follows '
      'someone', () async {
    final relay = _Relay()
      ..lists[a] = []
      ..lists[b] = [];

    // A follows X while the relays are down: first attempt fails, a retry
    // is scheduled, and A's button shows "Following".
    scheduleFollowingSync(x, follow: true, relayClient: relay);
    await _wait(800);
    expect(relay.published, isEmpty);

    // The user switches to B and follows Y; then the relays come back.
    activeIdentityPubkeyNotifier.value = b;
    scheduleFollowingSync(y, follow: true, relayClient: relay);
    relay.up = true;
    await _wait(1500);

    final byA = relay.published.where((e) => e.pubkey == a).toList();
    final byB = relay.published.where((e) => e.pubkey == b).toList();
    // ignore: avoid_print
    print(
      'published by A: ${byA.length}, by B: ${byB.length}; '
      "A's list on relays now: ${relay.lists[a]}",
    );
    expect(byB, isNotEmpty);
    expect(
      relay.lists[a],
      contains(x),
      reason: 'the follow A made (and was shown as done) must be published',
    );
  });

  test('checked: unfollowing while the follow is being published ends with '
      'the person not followed, on relays and on screen; no overlap', () async {
    final relay = _GatedPublishRelay()
      ..up = true
      ..lists[a] = [y];
    myFollowingNotifier.value = {y};

    myFollowingNotifier.value = {...myFollowingNotifier.value!, x};
    scheduleFollowingSync(x, follow: true, relayClient: relay);
    await _wait(700); // debounce over; first publish is in flight (held)
    expect(relay.inFlight, 1);

    // The user changes their mind while it is being published.
    myFollowingNotifier.value = {...myFollowingNotifier.value!}..remove(x);
    scheduleFollowingSync(x, follow: false, relayClient: relay);
    await _wait(700); // the debounce fires while the first sync still runs
    expect(relay.maxConcurrent, 1, reason: 'syncs must not overlap');

    relay.release();
    await _wait(1500);
    // ignore: avoid_print
    print(
      'publishes: ${relay.published.length}; final list on relays: '
      '${relay.lists[a]!.map((p) => p.substring(0, 2))}; on screen: '
      '${myFollowingNotifier.value!.map((p) => p.substring(0, 2))}',
    );
    expect(relay.lists[a], isNot(contains(x)));
    expect(relay.lists[a], contains(y));
    expect(myFollowingNotifier.value, {y});
    expect(relay.maxConcurrent, 1);
  });
}

/// Holds the first publish until [release]; counts concurrent publishes.
class _GatedPublishRelay extends _Relay {
  final _gate = Completer<void>();
  int inFlight = 0;
  int maxConcurrent = 0;

  void release() => _gate.complete();

  @override
  Future<Map<String, RelayPublishResult>> publish(
    NostrEvent event,
    Set<String> relayUrls,
  ) async {
    inFlight++;
    if (inFlight > maxConcurrent) maxConcurrent = inFlight;
    try {
      await _gate.future;
      return await super.publish(event, relayUrls);
    } finally {
      inFlight--;
    }
  }
}
