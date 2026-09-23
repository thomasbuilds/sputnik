import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/models/identity.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/services/follow_sync.dart';
import 'package:sputnik/services/settings_store.dart';

import 'support/fake_secret_store.dart';

enum _Relays {
  // Nobody answers.
  down,

  // One relay says "nothing here"; the one holding the list is unreachable.
  partiallyDown,
  up,
}

class _FlakyRelay extends RelayClient {
  _FlakyRelay(this.me, this.followed);

  final String me;
  final List<String> followed;
  _Relays relays = _Relays.down;
  NostrEvent? lastPublished;
  final published = <NostrEvent>[];

  // When set, a publish waits for it to complete.
  Completer<void>? publishGate;

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
    switch (relays) {
      case _Relays.down:
        return const RelayQueryResult(
          events: [],
          answeredRelays: 0,
          queriedRelays: 2,
        );
      case _Relays.partiallyDown:
        return const RelayQueryResult(
          events: [],
          answeredRelays: 1,
          queriedRelays: 2,
        );
      case _Relays.up:
        return RelayQueryResult(
          events: [
            NostrEvent(
              id: 'id',
              pubkey: me,
              createdAt: DateTime.now(),
              kind: 3,
              tags: [
                for (final pubkey in followed) ['p', pubkey],
              ],
              content: '',
              sig: 'sig',
            ),
          ],
          answeredRelays: 2,
          queriedRelays: 2,
        );
    }
  }

  @override
  Future<Map<String, RelayPublishResult>> publish(
    NostrEvent event,
    Set<String> relayUrls,
  ) async {
    await publishGate?.future;
    lastPublished = event;
    published.add(event);
    return {
      for (final url in relayUrls)
        url: const RelayPublishResult(RelayPublishOutcome.accepted),
    };
  }
}

// The follow-sync loop debounces before publishing.
Future<void> _waitForSync() =>
    Future<void>.delayed(const Duration(milliseconds: 800));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final alice = 'aa' * 32;
  final bob = 'bb' * 32;
  final carol = 'cc' * 32;
  late String me;

  tearDown(resetFollowSync);

  setUp(() async {
    resetFollowSync();
    followSyncRetryDelays = const [Duration(milliseconds: 100)];

    // A throwaway keypair, never a real saved identity.
    final keypair = generateNostrKeyPair();
    me = keypair.publicKeyHex;
    SettingsStore.secretStore = FakeSecretStore();
    await SettingsStore.savePrivateKey(me, keypair.privateKeyHex);
    identitiesNotifier.value = [
      Identity(pubkeyHex: me, createdAt: DateTime.now()),
    ];
    activeIdentityPubkeyNotifier.value = me;
    selectedRelaysNotifier.value = {'wss://relay.example'};
    myFollowingNotifier.value = null;
  });

  test('a failed startup load is not mistaken for "follows nobody"', () async {
    final relay = _FlakyRelay(me, [alice, bob]);
    Future<void> load() =>
        RelayContactsRepository(client: relay)
            .ensureMyFollowingLoaded({'wss://relay.example'});

    await load();
    expect(myFollowingNotifier.value, isNull);

    relay.relays = _Relays.partiallyDown;
    await load();
    expect(myFollowingNotifier.value, isNull);

    relay.relays = _Relays.up;
    await load();
    expect(myFollowingNotifier.value, {alice, bob});
  });

  test(
    'following someone after a failed startup load keeps the real list',
    () async {
      final relay = _FlakyRelay(me, [alice, bob]);
      await RelayContactsRepository(client: relay)
          .ensureMyFollowingLoaded({'wss://relay.example'});

      // The relays recover, then the user taps Follow.
      relay.relays = _Relays.up;
      myFollowingNotifier.value = {carol};
      scheduleFollowingSync(carol, follow: true, relayClient: relay);
      await _waitForSync();

      expect([
        for (final tag in relay.lastPublished!.tags) tag[1],
      ], unorderedEquals([alice, bob, carol]));
      expect(myFollowingNotifier.value, {alice, bob, carol});
    },
  );

  test('a follow made while relays are unreachable is retried until it '
      'goes through', () async {
    final relay = _FlakyRelay(me, [alice, bob]);

    scheduleFollowingSync(carol, follow: true, relayClient: relay);
    await _waitForSync();
    expect(relay.lastPublished, isNull);

    relay.relays = _Relays.up;
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect([
      for (final tag in relay.lastPublished!.tags) tag[1],
    ], unorderedEquals([alice, bob, carol]));
  });

  test('a relay saying "nothing here" is not trusted while another may '
      'still hold the list', () async {
    final relay = _FlakyRelay(me, [alice, bob])..relays = _Relays.partiallyDown;

    scheduleFollowingSync(carol, follow: true, relayClient: relay);
    await _waitForSync();
    expect(relay.lastPublished, isNull);

    relay.relays = _Relays.up;
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect([
      for (final tag in relay.lastPublished!.tags) tag[1],
    ], unorderedEquals([alice, bob, carol]));
  });

  test(
    'follows queued by one identity are not published by the next',
    () async {
      final next = generateNostrKeyPair();
      await SettingsStore.savePrivateKey(next.publicKeyHex, next.privateKeyHex);
      final relay = _FlakyRelay(next.publicKeyHex, [])..relays = _Relays.up;

      scheduleFollowingSync(alice, follow: true, relayClient: relay);
      activeIdentityPubkeyNotifier.value = next.publicKeyHex;
      scheduleFollowingSync(bob, follow: true, relayClient: relay);
      await _waitForSync();

      final byNext = [
        for (final event in relay.published)
          if (event.pubkey == next.publicKeyHex) event,
      ];
      expect([for (final tag in byNext.last.tags) tag[1]], [bob]);
      expect([
        for (final event in byNext)
          for (final tag in event.tags) tag[1],
      ], isNot(contains(alice)));
    },
  );

  test('a publish that ends after switching identity leaves the new one\'s '
      'follows alone', () async {
    final relay = _FlakyRelay(me, [alice])
      ..relays = _Relays.up
      ..publishGate = Completer<void>();

    scheduleFollowingSync(bob, follow: true, relayClient: relay);
    await _waitForSync();
    activeIdentityPubkeyNotifier.value = 'dd' * 32;
    myFollowingNotifier.value = {carol};
    relay.publishGate!.complete();
    await _waitForSync();

    expect(relay.lastPublished!.pubkey, me);
    expect(myFollowingNotifier.value, {carol});
  });

  test('changes made in a row are all applied', () async {
    final relay = _FlakyRelay(me, [alice, bob])..relays = _Relays.up;

    scheduleFollowingSync(carol, follow: true, relayClient: relay);
    scheduleFollowingSync(alice, follow: false, relayClient: relay);
    await _waitForSync();

    expect([
      for (final tag in relay.lastPublished!.tags) tag[1],
    ], unorderedEquals([bob, carol]));
    expect(myFollowingNotifier.value, {bob, carol});
  });
}
