import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nostr.dart';

import 'support/in_memory_relay_client.dart';

class _FakeRelayClient extends RelayClient {
  _FakeRelayClient(this.reposts, this.originalsById);

  final List<NostrEvent> reposts;
  final Map<String, NostrEvent> originalsById;

  @override
  Future<List<NostrEvent>> query(
    Set<String> relayUrls,
    NostrFilter filter,
  ) async {
    if (filter.kinds?.contains(6) == true) return reposts;
    if (filter.kinds?.contains(1) == true && filter.ids != null) {
      final original = originalsById[filter.ids!.first.toLowerCase()];
      return original == null ? const [] : [original];
    }
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final reposterPubkey = 'aa' * 32;
  final otherAuthorPubkey = 'bb' * 32;

  test('fetchReposts resolves embedded content, falls back to fetching by id, '
      'and skips a dangling repost', () async {
    // A genuinely signed event, so its embedded-JSON round trip through
    // NostrEvent.fromJson (which verifies id/sig) actually succeeds.
    final keypair = generateNostrKeyPair();
    final embeddedOriginal = signEvent(
      seckeyHex: keypair.privateKeyHex,
      pubkeyHex: keypair.publicKeyHex,
      kind: 1,
      content: 'hello from embedded content',
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
    final repostWithEmbeddedContent = NostrEvent(
      id: 'e1' * 32,
      pubkey: reposterPubkey,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      kind: 6,
      tags: [
        ['e', embeddedOriginal.id, ''],
      ],
      content: jsonEncode(embeddedOriginal.toJson()),
      sig: 'f1' * 64,
    );

    // No embedded content, so this one only resolves via the fallback
    // fetch-by-id.
    final fallbackOriginal = NostrEvent(
      id: 'c2' * 32,
      pubkey: otherAuthorPubkey,
      createdAt: DateTime.now().subtract(const Duration(hours: 3)),
      kind: 1,
      tags: const [],
      content: 'hello via fallback fetch',
      sig: 'd2' * 64,
    );
    final repostWithoutEmbeddedContent = NostrEvent(
      id: 'e2' * 32,
      pubkey: reposterPubkey,
      createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
      kind: 6,
      tags: [
        ['e', fallbackOriginal.id, ''],
      ],
      content: '',
      sig: 'f2' * 64,
    );

    // Points at a note no relay has -- should be dropped, not crash.
    final danglingRepost = NostrEvent(
      id: 'e3' * 32,
      pubkey: reposterPubkey,
      createdAt: DateTime.now().subtract(const Duration(minutes: 15)),
      kind: 6,
      tags: [
        ['e', 'ff' * 32, ''],
      ],
      content: '',
      sig: 'f3' * 64,
    );

    final client = _FakeRelayClient(
      [repostWithEmbeddedContent, repostWithoutEmbeddedContent, danglingRepost],
      {fallbackOriginal.id: fallbackOriginal},
    );
    final repository = RelayPostRepository(
      relayUrls: {'wss://relay.example'},
      client: client,
    );

    final posts = await repository.fetchReposts(
      [reposterPubkey],
      {'wss://relay.example'},
    );

    expect(posts.length, 2);
    final byOriginalId = {for (final post in posts) post.id: post};

    final embedded = byOriginalId[embeddedOriginal.id]!;
    expect(embedded.content, 'hello from embedded content');
    expect(embedded.author.pubkey, keypair.publicKeyHex);
    expect(embedded.repostedByPubkey, reposterPubkey);
    expect(embedded.repostedAt, repostWithEmbeddedContent.createdAt);

    final fallback = byOriginalId[fallbackOriginal.id]!;
    expect(fallback.content, 'hello via fallback fetch');
    expect(fallback.author.pubkey, otherAuthorPubkey);
    expect(fallback.repostedByPubkey, reposterPubkey);
  });
  test('a repost without content is looked up by a lowercase ID, and one '
      'whose e tag is not an ID is not looked up at all', () async {
    final original = fakeEvent(id: 'c3' * 32, pubkey: otherAuthorPubkey);
    final upper = fakeEvent(
      id: 'e4' * 32,
      pubkey: reposterPubkey,
      kind: 6,
      tags: [
        ['e', original.id.toUpperCase(), ''],
      ],
    );
    final garbage = fakeEvent(
      id: 'e5' * 32,
      pubkey: reposterPubkey,
      kind: 6,
      tags: [
        ['e', 'note1notanid', ''],
      ],
    );
    final client = InMemoryRelayClient([original, upper, garbage]);

    final posts = await RelayPostRepository(
      relayUrls: const {'wss://relay.example'},
      client: client,
    ).fetchReposts([reposterPubkey], const {'wss://relay.example'});

    expect(posts.map((post) => post.id), [original.id]);
    final hex = RegExp(r'^[0-9a-f]{64}$');
    for (final filter in client.queries) {
      expect(filter.ids ?? const <String>[], everyElement(matches(hex)));
    }
  });
}
