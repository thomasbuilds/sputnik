// Audit (state/ST): what Settings > "Clear cached data" leaves behind in
// memory, and what that does to the UI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/main.dart';
import 'package:sputnik/models/note.dart';
import 'package:sputnik/nostr/hex.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/screens/settings_screen.dart';
import 'package:sputnik/widgets/linkified_text.dart';
import 'package:sputnik/widgets/note_content.dart';

import 'support/in_memory_relay_client.dart';

Future<void> _clearCachedData(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
  await tester.ensureVisible(find.byKey(const Key('clearCacheCard')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('clearCacheCard')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Clear'));
  await tester.pumpAndSettle();
  expect(find.text('Cleared cached data'), findsOneWidget);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    selectedRelaysNotifier.value = const {};
    profileCacheNotifier.value = const {};
  });

  testWidgets('ST-10a: after "Clear cached data", @mentions already looked up '
      'this session stay as npubs instead of names', (tester) async {
    final alice = generateNostrKeyPair().publicKeyHex; // throwaway
    final relay = InMemoryRelayClient([
      fakeEvent(pubkey: alice, kind: 0, content: '{"name":"Alice"}'),
    ]);
    final text = 'gm nostr:${npubFromHex(alice)}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LinkifiedText(text, relayClient: relay)),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('@Alice', findRichText: true), findsOneWidget);

    await _clearCachedData(tester);

    // Another note mentioning her (or the same one, scrolled back to).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LinkifiedText('again $text', relayClient: relay)),
      ),
    );
    await _settle(tester);
    final profileQueries = relay.queries.where(
      (f) => f.kinds?.contains(0) == true,
    );
    // ignore: avoid_print
    print(
      'kind 0 lookups: ${profileQueries.length}; name shown after clear: '
      '${find.textContaining('@Alice', findRichText: true).evaluate().isNotEmpty}',
    );
    expect(find.textContaining('@Alice', findRichText: true), findsOneWidget);
  });

  testWidgets('ST-10b: a quoted note stays cached in memory (with the '
      "author's old name) after \"Clear cached data\"", (tester) async {
    final quotedId = 'c' * 64;
    final author = 'b' * 64;
    final before = InMemoryRelayClient([
      fakeEvent(id: quotedId, pubkey: author, content: 'the quoted words'),
      fakeEvent(pubkey: author, kind: 0, content: '{"name":"Old Name"}'),
    ]);
    final nevent = bech32Encode(
      'nevent',
      convertBits([0, 32, ...hexDecode(quotedId)], 8, 5, pad: true),
    );
    final quoting = Note(
      id: 'a' * 64,
      pubkey: 'e' * 64,
      displayName: 'Quoter',
      handle: 'h',
      content: 'look\n\nnostr:$nevent',
      postedAt: '1m',
      createdAt: DateTime(2024),
    );
    Future<void> show(RelayClient client) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NoteContent(note: quoting, relayClient: client),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    await show(before);
    expect(find.text('Old Name'), findsOneWidget);

    await _clearCachedData(tester);

    // The author renamed themselves meanwhile.
    final after = InMemoryRelayClient([
      fakeEvent(id: quotedId, pubkey: author, content: 'the quoted words'),
      fakeEvent(pubkey: author, kind: 0, content: '{"name":"New Name"}'),
    ]);
    await show(after);
    // ignore: avoid_print
    print(
      'relay queries after clear: ${after.queries.length}; shows '
      '"Old Name": ${find.text('Old Name').evaluate().isNotEmpty}',
    );
    expect(find.text('Old Name'), findsNothing);
  });
}
