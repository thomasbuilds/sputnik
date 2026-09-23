// Audit (state/ST): the relay-data cache on a real temp directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/services/cache_store.dart';

import 'support/in_memory_relay_client.dart';

void main() {
  late Directory dir;

  // The boxes are late final, so they can only be opened once per process.
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('audit_state_cache');
    await CacheStore.init(directory: dir);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  final p = 'ab' * 32;
  final t0 = DateTime.now().subtract(const Duration(minutes: 5));

  group('ST-08: an older replaceable event overwrites a newer cached one', () {
    test('profile (kind 0): pull-to-refresh while the relay holding the '
        'newest copy does not answer', () async {
      profileCacheNotifier.value = const {};
      final newer = fakeEvent(
        pubkey: p,
        kind: 0,
        content: '{"name":"new name"}',
        createdAt: t0,
      );
      final older = fakeEvent(
        pubkey: p,
        kind: 0,
        content: '{"name":"old name"}',
        createdAt: t0.subtract(const Duration(days: 30)),
      );
      await RelayProfileRepository(client: InMemoryRelayClient([newer]))
          .fetchProfile(p, const {'wss://r1'});
      expect(profileCacheNotifier.value[p]!.name, 'new name');

      // Same relays, but this time only a lagging one answers.
      await RelayProfileRepository(client: InMemoryRelayClient([older]))
          .fetchProfile(p, const {'wss://r1'}, force: true);

      // ignore: avoid_print
      print(
        'in memory: ${profileCacheNotifier.value[p]!.name}; '
        'on disk: ${CacheStore.loadAllProfiles()[p]!.name}',
      );
      expect(profileCacheNotifier.value[p]!.name, 'new name');
      expect(CacheStore.loadAllProfiles()[p]!.name, 'new name');
    });

    test('follow list (kind 3), as shown on a profile', () async {
      final newer = fakeEvent(
        pubkey: p,
        kind: 3,
        tags: [
          ['p', 'c' * 64],
          ['p', 'd' * 64],
        ],
        createdAt: t0,
      );
      final older = fakeEvent(
        pubkey: p,
        kind: 3,
        tags: [
          ['p', 'c' * 64],
        ],
        createdAt: t0.subtract(const Duration(days: 30)),
      );
      await RelayContactsRepository(client: InMemoryRelayClient([newer]))
          .fetchFollowing(p, const {'wss://r1'}, force: true);
      await RelayContactsRepository(client: InMemoryRelayClient([older]))
          .fetchFollowing(p, const {'wss://r1'}, force: true);
      // ignore: avoid_print
      print(
        'cached following: ${CacheStore.getFollowing(p)!.length} '
        '(newest list has 2)',
      );
      expect(CacheStore.getFollowing(p), hasLength(2));
    });
  });

  test('ST-09 (checked): Clear cached data leaves no relay data in the '
      'relay_cache folder', () async {
    const marker = 'AUDIT-MARKER-7f3a';
    await CacheStore.putProfiles({p: const NostrMetadata(name: marker)});
    await CacheStore.putFollowing(p, ['$marker-following'.padRight(64, '0')]);
    await CacheStore.putFollowers(p, ['$marker-followers'.padRight(64, '0')]);
    await CacheStore.putPaymentTargets(p, [
      const NostrPaymentTarget(type: 'monero', address: '${marker}addr'),
    ]);
    // Also exercise the prune path (append-only delete frames).
    await CacheStore.putProfiles({
      'ee' * 32: const NostrMetadata(name: marker),
    });

    bool anyFileHasMarker() {
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        final text = String.fromCharCodes(f.readAsBytesSync());
        if (text.contains(marker)) return true;
      }
      return false;
    }

    expect(anyFileHasMarker(), isTrue, reason: 'positive control');
    await CacheStore.clearAll();
    final files = {
      for (final f in dir.listSync(recursive: true).whereType<File>())
        f.uri.pathSegments.last: f.lengthSync(),
    };
    // ignore: avoid_print
    print(
      'after clearAll: $files; marker still on disk: ${anyFileHasMarker()}',
    );
    expect(anyFileHasMarker(), isFalse);
  });

  test('ST-11: one malformed cached payment-target entry makes '
      'getPaymentTargets throw instead of being skipped', () async {
    final q = 'cd' * 32;
    await Hive.box<Map>('paymentTargets').put(q, {
      'data': [
        {'type': 'monero'}, // e.g. written by another app version
      ],
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
    });
    Object? error;
    try {
      await RelayPaymentTargetsRepository(client: InMemoryRelayClient())
          .fetchPaymentTargets(q, const {'wss://r1'});
    } catch (e) {
      error = e;
    }
    // ignore: avoid_print
    print('fetchPaymentTargets on a malformed cache entry threw: $error');
    expect(error, isNull);
  });

  test('ST-16: a cache entry dated in the future is served as fresh forever '
      'and never pruned (e.g. a tampered payment address)', () async {
    final victim = 'fa' * 32;
    final relay = InMemoryRelayClient([
      fakeEvent(
        pubkey: victim,
        kind: 10133,
        tags: [
          ['payto', 'monero', '4REALADDRESS'],
        ],
      ),
    ]);
    // Written by anything that can write the app's support folder.
    await Hive.box<Map>('paymentTargets').put(victim, {
      'data': [
        {'type': 'monero', 'address': '4ATTACKERADDRESS'},
      ],
      'fetchedAt': DateTime(2100).millisecondsSinceEpoch,
    });
    await CacheStore.pruneExpired(
      Hive.box<Map>('paymentTargets'),
      now: DateTime.now().add(const Duration(days: 365)),
    );
    final shown = await RelayPaymentTargetsRepository(client: relay)
        .fetchPaymentTargets(victim, const {'wss://r1'});
    // ignore: avoid_print
    print(
      'shown: ${shown.map((t) => t.address)}; relay queries: '
      '${relay.queries.length}; still cached a year later: '
      '${Hive.box<Map>('paymentTargets').containsKey(victim)}',
    );
    expect(shown.single.address, '4REALADDRESS');
  });
}
