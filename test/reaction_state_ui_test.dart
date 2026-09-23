// Audit (state/ST): like state in the real HomeScreen, end to end through the
// app's real RelayConnectionPool against a relay bound to 127.0.0.1.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/models/identity.dart';
import 'package:sputnik/models/note.dart';
import 'package:sputnik/models/note_mapper.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/screens/home_screen.dart';
import 'package:sputnik/services/feed_loader.dart';
import 'package:sputnik/services/settings_store.dart';
import 'package:sputnik/widgets/note_tile.dart';

import 'support/local_relay.dart';
import 'support/fake_secret_store.dart';

void main() {
  late NostrKeyPair meA;
  late NostrKeyPair meB;
  late NostrKeyPair author;
  late LocalRelay relay;

  NostrEvent note(String text, Duration ago) => signEvent(
    seckeyHex: author.privateKeyHex,
    pubkeyHex: author.publicKeyHex,
    kind: 1,
    content: text,
    createdAt: DateTime.now().subtract(ago),
  );

  Note toNote(NostrEvent e) =>
      notesFromPosts([nostrPostFromEvent(e)], const {}).single;

  // Waits on real I/O (the local relay), then lets the widget tree catch up.
  Future<void> settleIo(WidgetTester tester, [int ms = 700]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder tileHeart(String text, IconData icon) => find.descendant(
    of: find.ancestor(of: find.text(text), matching: find.byType(NoteTile)),
    matching: find.byIcon(icon),
  );

  setUp(() async {
    // Throwaway keypairs for this run only.
    meA = generateNostrKeyPair();
    meB = generateNostrKeyPair();
    author = generateNostrKeyPair();
    SettingsStore.secretStore = FakeSecretStore();
    await SettingsStore.savePrivateKey(meA.publicKeyHex, meA.privateKeyHex);
    await SettingsStore.savePrivateKey(meB.publicKeyHex, meB.privateKeyHex);
    identitiesNotifier.value = [
      Identity(pubkeyHex: meA.publicKeyHex, createdAt: DateTime.now()),
      Identity(pubkeyHex: meB.publicKeyHex, createdAt: DateTime.now()),
    ];
    activeIdentityPubkeyNotifier.value = meA.publicKeyHex;
    confirmBeforeReactingNotifier.value = false;
    profileCacheNotifier.value = const {};
    bookmarkedNotesNotifier.value = const {};
    notesNotifier.value = null;
    followingNotesNotifier.value = null;
    myFollowingNotifier.value = {author.publicKeyHex};
    feedRelayClient = const RelayClient();
  });

  testWidgets('ST-06: a like sticks to the list position, not the note: after '
      'a refresh prepends a newer note, that note shows as liked', (
    tester,
  ) async {
    final n1 = note('older note N1', const Duration(minutes: 10));
    final n2 = note('oldest note N2', const Duration(minutes: 20));
    final n0 = note('newer note N0', const Duration(minutes: 1));
    await tester.runAsync(() async {
      relay = await LocalRelay.start([n0, n1, n2]);
    });
    selectedRelaysNotifier.value = {relay.url};
    followingNotesNotifier.value = [toNote(n1), toNote(n2)];

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeScreen())),
    );
    await tester.pump();

    // Like N1 (the first tile).
    await tester.runAsync(
      () => tester.tap(tileHeart('older note N1', Icons.favorite_border)),
    );
    await settleIo(tester);
    expect(tileHeart('older note N1', Icons.favorite), findsOneWidget);
    expect(relay.published.where((e) => e.kind == 7), hasLength(1));

    // Pull-to-refresh finds a newer note; the feed now starts with N0.
    followingNotesNotifier.value = [toNote(n0), toNote(n1), toNote(n2)];
    await tester.pump();

    final n0Liked = tileHeart('newer note N0', Icons.favorite).evaluate();
    final n1Liked = tileHeart('older note N1', Icons.favorite).evaluate();
    // ignore: avoid_print
    print(
      'after refresh: N0 (never liked) shows liked=${n0Liked.isNotEmpty}; '
      'N1 (liked) shows liked=${n1Liked.isNotEmpty}',
    );

    // Tapping N0's filled heart tries to *unlike* a note never liked.
    if (n0Liked.isNotEmpty) {
      await tester.runAsync(
        () => tester.tap(tileHeart('newer note N0', Icons.favorite)),
      );
      await settleIo(tester);
      // ignore: avoid_print
      print(
        'snackbar: ${find.byType(SnackBar).evaluate().isEmpty ? '-' : (tester.widget<SnackBar>(find.byType(SnackBar)).content as Text).data}',
      );
    }
    await tester.runAsync(relay.close);

    expect(n0Liked, isEmpty, reason: 'N0 was never liked');
    expect(n1Liked, isNotEmpty, reason: 'N1 was liked a moment ago');
  });

  testWidgets('ST-07: after switching identity, the global feed still shows '
      'the previous identity\'s likes as the new identity\'s', (tester) async {
    final n = note('a note A liked', const Duration(minutes: 5));
    final likeByA = signEvent(
      seckeyHex: meA.privateKeyHex,
      pubkeyHex: meA.publicKeyHex,
      kind: 7,
      content: '+',
      tags: [
        ['e', n.id, ''],
        ['p', n.pubkey, ''],
      ],
      createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    await tester.runAsync(() async {
      relay = await LocalRelay.start([n, likeByA]);
      selectedRelaysNotifier.value = {relay.url};
      await loadGlobalFeed(); // as A
    });
    expect(notesNotifier.value!.single.likedByMe, isTrue);

    // Switch to B, doing what main.dart's identity listener does.
    activeIdentityPubkeyNotifier.value = meB.publicKeyHex;
    followingNotesNotifier.value = null;

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeScreen())),
    );
    await tester.tap(find.text('Global'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final shownLiked = tileHeart('a note A liked', Icons.favorite).evaluate();
    // ignore: avoid_print
    print(
      'active=B; global feed shows the note as liked: '
      '${shownLiked.isNotEmpty}',
    );
    if (shownLiked.isNotEmpty) {
      await tester.runAsync(
        () => tester.tap(tileHeart('a note A liked', Icons.favorite)),
      );
      await settleIo(tester);
      final bar = find.byType(SnackBar);
      // ignore: avoid_print
      print(
        'tap as B -> snackbar: ${bar.evaluate().isEmpty ? '-' : (tester.widget<SnackBar>(bar).content as Text).data}; '
        'events B published: ${relay.published.where((e) => e.pubkey == meB.publicKeyHex).length}',
      );
    }
    await tester.runAsync(relay.close);
    expect(shownLiked, isEmpty, reason: 'B never liked this note');
  });
}
