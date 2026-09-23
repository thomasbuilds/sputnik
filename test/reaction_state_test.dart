// Audit (state/ST): reaction state vs what is published.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/models/identity.dart';
import 'package:sputnik/models/note.dart';
import 'package:sputnik/models/note_mapper.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/services/settings_store.dart';
import 'package:sputnik/widgets/reaction_buttons.dart';

import 'support/fake_secret_store.dart';
import 'support/in_memory_relay_client.dart';

/// An in-memory relay that also honors NIP-09 deletions of the author's own
/// events, as a compliant relay does.
class _HonoringRelay extends InMemoryRelayClient {
  _HonoringRelay(super.events);

  @override
  Future<Map<String, RelayPublishResult>> publish(
    NostrEvent event,
    Set<String> relayUrls,
  ) {
    if (event.kind == 5) {
      final ids = {
        for (final t in event.tags)
          if (t.length > 1 && t[0] == 'e') t[1],
      };
      events.removeWhere((e) => ids.contains(e.id) && e.pubkey == event.pubkey);
    }
    return super.publish(event, relayUrls);
  }
}

void main() {
  late String me;
  late NostrEvent target;
  late Note note;

  setUp(() async {
    final keypair = generateNostrKeyPair(); // throwaway, this run only
    me = keypair.publicKeyHex;
    identitiesNotifier.value = [
      Identity(pubkeyHex: me, createdAt: DateTime.now()),
    ];
    activeIdentityPubkeyNotifier.value = me;
    selectedRelaysNotifier.value = {'wss://relay.example'};
    confirmBeforeReactingNotifier.value = false;
    SettingsStore.secretStore = FakeSecretStore();
    await SettingsStore.savePrivateKey(me, keypair.privateKeyHex);

    final author = 'bb' * 32;
    target = NostrEvent(
      id: 'cc' * 32,
      pubkey: author,
      createdAt: DateTime.now().subtract(const Duration(hours: 1)),
      kind: 1,
      tags: const [],
      content: 'hello',
      sig: 'dd' * 64,
    );
    note = Note(
      id: target.id,
      pubkey: author,
      displayName: 'Bob',
      handle: 'bob',
      content: 'hello',
      postedAt: '1h',
      createdAt: target.createdAt,
    );
  });

  Future<void> pumpTwo(WidgetTester tester, RelayClient relay) =>
      // The same note shown twice, e.g. the Following and Global tabs (both
      // kept alive), or a feed tile and the PostScreen header.
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                LikeButton(
                  key: const Key('one'),
                  note: note,
                  relayClient: relay,
                ),
                LikeButton(
                  key: const Key('two'),
                  note: note,
                  relayClient: relay,
                ),
              ],
            ),
          ),
        ),
      );

  Finder heart(String key, IconData icon) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.byIcon(icon));

  testWidgets('ST-03a: a like made in one place is not reflected where the '
      'same note is shown elsewhere, so it gets liked twice', (tester) async {
    final relay = _HonoringRelay([target]);
    await pumpTwo(tester, relay);

    await tester.tap(heart('one', Icons.favorite_border));
    await tester.pumpAndSettle();
    final secondShowsUnliked = heart(
      'two',
      Icons.favorite_border,
    ).evaluate().isNotEmpty;
    if (secondShowsUnliked) {
      // The user likes it there too, a little later (an identical event in
      // the same second would have the same id: a relay-side duplicate).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.tap(heart('two', Icons.favorite_border));
      await tester.pumpAndSettle();
    }
    final likes = relay.published.where((e) => e.kind == 7).toList();
    // ignore: avoid_print
    print(
      'second button showed unliked: $secondShowsUnliked; kind 7 likes '
      'published for one note: ${likes.length} '
      '(distinct ids: ${likes.map((e) => e.id).toSet().length})',
    );
    expect(secondShowsUnliked, isFalse);
    expect(likes, hasLength(1), reason: 'one note, one like per user');
  });

  testWidgets('ST-03b: with two likes by me on a note, "unlike" deletes only '
      'the newest, so the note comes back as liked', (tester) async {
    final now = DateTime.now();
    NostrEvent myLike(String id, Duration ago) => fakeEvent(
      id: id,
      pubkey: me,
      kind: 7,
      content: '+',
      tags: [
        ['e', target.id],
        ['p', target.pubkey],
      ],
      createdAt: now.subtract(ago),
    );
    // e.g. liked from two screens (ST-03a) or from two clients.
    final relay = _HonoringRelay([
      target,
      myLike('11', const Duration(minutes: 5)),
      myLike('22', const Duration(minutes: 1)),
    ]);
    await pumpTwo(tester, relay);
    final liked = note.copyWith(likedByMe: true, likeCount: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LikeButton(note: liked, relayClient: relay),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite));
    await tester.pumpAndSettle();

    final deletion = relay.published.singleWhere((e) => e.kind == 5);
    final after = await RelayReactionsRepository(client: relay)
        .fetchReactions([target.id], {'wss://relay.example'});
    final reloaded = applyReactionCounts([note], after, myPubkeyHex: me).single;
    // ignore: avoid_print
    print(
      'deletion e-tags: ${deletion.tags.where((t) => t[0] == 'e').length}'
      ' of 2 likes; after reload likedByMe=${reloaded.likedByMe}',
    );
    expect(
      reloaded.likedByMe,
      isFalse,
      reason: 'after "unlike" the note must not come back as liked',
    );
  });

  testWidgets('checked: a double tap on one like button publishes at most '
      'one distinct like', (tester) async {
    final relay = _HonoringRelay([target]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LikeButton(note: note, relayClient: relay),
        ),
      ),
    );
    // Two taps inside one frame, before the button can rebuild as pending.
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.tap(find.byIcon(Icons.favorite_border), warnIfMissed: false);
    await tester.pumpAndSettle();
    final likes = relay.published.where((e) => e.kind == 7).toList();
    // ignore: avoid_print
    print(
      'double tap: ${likes.length} publish call(s), '
      '${likes.map((e) => e.id).toSet().length} distinct event id(s)',
    );
    expect(likes.map((e) => e.id).toSet(), hasLength(1));
  });
}
