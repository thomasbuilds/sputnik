import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nostr.dart';

import 'support/answering_relay_client.dart';

// Answers every query with all of [events], unsorted and past any limit, as
// several relays each sending their own copies would.
class _RelayReturning extends RelayClient with AnsweringRelayClient {
  const _RelayReturning(this.events);

  final List<NostrEvent> events;

  @override
  Future<List<NostrEvent>> query(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async => events;
}

void main() {
  final owner = 'aa' * 32;
  final other = 'bb' * 32;
  final lowId = '11' * 32;
  final highId = '22' * 32;
  final newer = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
  final older = newer.subtract(const Duration(days: 1));

  NostrEvent event({
    required String pubkey,
    required int kind,
    String id = '33',
    List<List<String>> tags = const [],
    String content = '',
    DateTime? createdAt,
  }) => NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt ?? newer,
    kind: kind,
    tags: tags,
    content: content,
    sig: 'sig',
  );

  group('replaceable events', () {
    test(
      'of two contact lists from the same second, the lowest id counts',
      () async {
        // NIP-01 keeps the lowest id when replaceable events share a timestamp.
        final repository = RelayContactsRepository(
          client: _RelayReturning([
            event(
              pubkey: owner,
              kind: 3,
              id: highId,
              tags: [
                ['p', other],
              ],
            ),
            event(
              pubkey: owner,
              kind: 3,
              id: lowId,
              tags: [
                ['p', 'cc' * 32],
              ],
            ),
          ]),
        );

        expect(await repository.fetchFollowing(owner, {'wss://r'}), [
          'cc' * 32,
        ]);
      },
    );

    test(
      'payment targets come from the newest list, whatever the order',
      () async {
        final repository = RelayPaymentTargetsRepository(
          client: _RelayReturning([
            event(
              pubkey: owner,
              kind: 10133,
              id: highId,
              createdAt: older,
              tags: [
                ['payto', 'bitcoin', 'retired-address'],
              ],
            ),
            event(
              pubkey: owner,
              kind: 10133,
              id: lowId,
              tags: [
                ['payto', 'bitcoin', 'current-address'],
              ],
            ),
          ]),
        );

        final targets = await repository.fetchPaymentTargets(owner, {
          'wss://r',
        });
        expect(targets.map((t) => t.address), ['current-address']);
      },
    );
  });

  group('reactions', () {
    test('a custom emoji reaction is not counted as a like', () async {
      final repository = RelayReactionsRepository(
        client: _RelayReturning([
          event(
            pubkey: other,
            kind: 7,
            content: ':shortcode:',
            tags: [
              ['e', lowId],
            ],
          ),
        ]),
      );

      final reactions = await repository.fetchReactions([lowId], {'wss://r'});
      expect(reactions[lowId]!.likerPubkeys, isEmpty);
    });

    test('the like to retract is my newest like of that note, not a newer '
        'decoy', () async {
      NostrEvent reaction(
        String id,
        String pubkey,
        String note,
        String content,
        DateTime at,
      ) => event(
        pubkey: pubkey,
        kind: 7,
        id: id,
        content: content,
        createdAt: at,
        tags: [
          ['e', note],
        ],
      );
      // Every decoy is newer than the right answer, so each one would be
      // picked if it were not ruled out.
      final later = newer.add(const Duration(minutes: 1));
      final mine = reaction('e5' * 32, owner, lowId, '+', newer);
      final repository = RelayReactionsRepository(
        client: _RelayReturning([
          reaction('e1' * 32, other, lowId, '+', later),
          reaction('e2' * 32, owner, lowId, '-', later),
          reaction('e3' * 32, owner, highId, '+', later),
          reaction('e4' * 32, owner, lowId, '+', older),
          mine,
        ]),
      );

      final found = await repository.fetchOwnReaction(
        myPubkeyHex: owner,
        noteId: lowId,
        kind: 7,
        relayUrls: {'wss://r'},
      );

      expect(found?.id, mine.id);
    });
  });

  group('reposts', () {
    test('a repost embedding something other than a note falls back to its '
        'e tag', () async {
      final keypair = generateNostrKeyPair();
      final embeddedReaction = signEvent(
        seckeyHex: keypair.privateKeyHex,
        pubkeyHex: keypair.publicKeyHex,
        kind: 7,
        content: '+',
      );
      final note = event(
        pubkey: other,
        kind: 1,
        id: lowId,
        content: 'the reposted note',
      );
      final repost = event(
        pubkey: owner,
        kind: 6,
        id: highId,
        tags: [
          ['e', note.id, ''],
        ],
        content: jsonEncode(embeddedReaction.toJson()),
      );
      final repository = RelayPostRepository(
        relayUrls: const {'wss://r'},
        client: _RelayReturning([repost, note]),
      );

      final posts = await repository.fetchReposts([owner], {'wss://r'});

      expect(posts.map((post) => post.content), ['the reposted note']);
    });
  });
}
