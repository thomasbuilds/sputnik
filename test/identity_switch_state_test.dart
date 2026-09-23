import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/services/feed_loader.dart';

import 'support/in_memory_relay_client.dart';

final _a = 'a1' * 32; // identity A
final _b = 'b2' * 32; // identity B
final _alice = 'ac' * 32; // followed by A only
final _bob = 'bb' * 32; // followed by B only

// Holds contact-list answers for [heldAuthor] until [gate] completes.
class _GatedContacts extends InMemoryRelayClient {
  _GatedContacts(super.events);

  final gate = Completer<void>();
  String? heldAuthor;

  @override
  Future<RelayQueryResult> queryWithStatus(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async {
    if (filter.kinds?.contains(3) == true &&
        filter.authors?.contains(heldAuthor) == true) {
      await gate.future;
    }
    return super.queryWithStatus(relayUrls, filter);
  }
}

// Holds every page after the first (queries with an `until`) on [gate].
class _GatedPages extends InMemoryRelayClient {
  _GatedPages(super.events, this.gate);

  final Completer<void> gate;

  @override
  Future<List<NostrEvent>> query(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async {
    if (filter.kinds?.contains(1) == true && filter.until != null) {
      await gate.future;
    }
    return super.query(relayUrls, filter);
  }
}

List<NostrEvent> _world() => [
  fakeEvent(
    pubkey: _a,
    kind: 3,
    tags: [
      ['p', _alice],
    ],
  ),
  fakeEvent(
    pubkey: _b,
    kind: 3,
    tags: [
      ['p', _bob],
    ],
  ),
  fakeEvent(pubkey: _alice, content: 'by alice'),
  fakeEvent(pubkey: _bob, content: 'by bob'),
];

List<NostrEvent> _posts(String pubkey, int count) {
  final base = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  return [
    for (var i = 0; i < count; i++)
      fakeEvent(
        pubkey: pubkey,
        content: 'post $i',
        createdAt: base.subtract(Duration(minutes: i)),
      ),
  ];
}

// What main.dart's identity listener does.
Future<void> _switchTo(String pubkey) {
  activeIdentityPubkeyNotifier.value = pubkey;
  followingNotesNotifier.value = null;
  return loadFollowingFeed();
}

List<String> get _shown => [
  for (final note in followingNotesNotifier.value ?? const []) note.content,
];

void main() {
  setUp(() async {
    // No relays: hydration finishes at once, and a lookup through the real
    // pool counts as "not every relay answered".
    selectedRelaysNotifier.value = const {};
    profileCacheNotifier.value = const {};
    notesNotifier.value = null;
    followingNotesNotifier.value = null;
    activeIdentityPubkeyNotifier.value = null;
    await const RelayContactsRepository().ensureMyFollowingLoaded(const {});
  });

  tearDown(() => feedRelayClient = const RelayClient());

  test("a new identity whose list can't be confirmed does not inherit the "
      "previous identity's follows", () async {
    final relay = InMemoryRelayClient(_world());
    feedRelayClient = relay;
    activeIdentityPubkeyNotifier.value = _a;
    await RelayContactsRepository(client: relay)
        .ensureMyFollowingLoaded(selectedRelaysNotifier.value);
    expect(myFollowingNotifier.value, {_alice});

    await _switchTo(_b);

    expect(myFollowingNotifier.value ?? const {}, isNot(contains(_alice)));
    expect(_shown, isNot(contains('by alice')));
  });

  test("a load still running for the previous identity is not handed to "
      'the new one', () async {
    final relay = _GatedContacts(_world())..heldAuthor = _a;
    feedRelayClient = relay;
    activeIdentityPubkeyNotifier.value = _a;
    final aLoad = RelayContactsRepository(client: relay)
        .ensureMyFollowingLoaded(selectedRelaysNotifier.value);

    final bFeed = _switchTo(_b);
    relay.gate.complete();
    await aLoad;
    await bFeed;

    expect(myFollowingNotifier.value ?? const {}, isNot(contains(_alice)));
    expect(_shown, isNot(contains('by alice')));
  });

  test("an older page of the previous identity's feed is not appended "
      'after a switch', () async {
    final pageGate = Completer<void>();
    feedRelayClient = _GatedPages(_posts(_a, 40), pageGate);
    final contacts = _GatedContacts(_world())..heldAuthor = _b;
    activeIdentityPubkeyNotifier.value = _a;
    await loadFollowingFeed();
    expect(followingNotesNotifier.value, hasLength(30));

    final more = loadMoreFollowingFeed();
    activeIdentityPubkeyNotifier.value = _b;
    followingNotesNotifier.value = null;
    // B's own list is still loading while A's older page arrives.
    final bContacts = RelayContactsRepository(client: contacts)
        .ensureMyFollowingLoaded(selectedRelaysNotifier.value);
    final bFeed = loadFollowingFeed();
    pageGate.complete();
    await more;

    expect(followingNotesNotifier.value, isNull);

    contacts.gate.complete();
    await bContacts;
    await bFeed;
  });

  test('a refresh while an older page loads drops that page', () async {
    final pageGate = Completer<void>();
    feedRelayClient = _GatedPages(_posts(_alice, 40), pageGate);
    await loadGlobalFeed();

    final more = loadMoreGlobalFeed();
    await loadGlobalFeed();
    pageGate.complete();
    await more;

    final ids = [for (final note in notesNotifier.value!) note.id];
    expect(ids, hasLength(30));
    expect(ids.toSet(), hasLength(30));
  });
}
