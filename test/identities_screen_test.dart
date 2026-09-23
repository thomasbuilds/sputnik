import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sputnik/main.dart';
import 'package:sputnik/services/settings_store.dart';

import 'support/fake_secret_store.dart';

// A secure store that can refuse reads or deletes, like a locked keyring.
class _FlakySecretStore extends FakeSecretStore {
  bool failReads = false;
  bool failDeletes = false;

  @override
  Future<String?> read(String key) {
    if (failReads) throw StateError('KeyringLocked');
    return super.read(key);
  }

  @override
  Future<void> delete(String key) {
    if (failDeletes) throw StateError('KeyringLocked');
    return super.delete(key);
  }
}

void main() {
  setUp(() {
    // Avoid HomeScreen's indefinite loading spinner, which would keep
    // pumpAndSettle spinning forever.
    notesNotifier.value = const [];
    identitiesNotifier.value = const [];
    activeIdentityPubkeyNotifier.value = null;
    SettingsStore.secretStore = FakeSecretStore();
  });

  Future<void> openIdentitiesScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.tap(find.byKey(const Key('profileAvatarButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('identitiesCard')));
    await tester.pumpAndSettle();
  }

  testWidgets('generates a keypair and makes it the active identity', (
    tester,
  ) async {
    await openIdentitiesScreen(tester);

    expect(find.text('No identities yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('generateIdentityButton')));
    await tester.pumpAndSettle();

    expect(find.text('No identities yet'), findsNothing);
    expect(identitiesNotifier.value, hasLength(1));
    expect(
      activeIdentityPubkeyNotifier.value,
      identitiesNotifier.value.single.pubkeyHex,
    );
    final privkeyHex = await SettingsStore.loadPrivateKey(
      identitiesNotifier.value.single.pubkeyHex,
    );
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(privkeyHex ?? ''), isTrue);
  });

  testWidgets('deleting the active identity clears the active pointer', (
    tester,
  ) async {
    await openIdentitiesScreen(tester);

    await tester.tap(find.byKey(const Key('generateIdentityButton')));
    await tester.pumpAndSettle();
    expect(identitiesNotifier.value, hasLength(1));
    final pubkeyHex = identitiesNotifier.value.single.pubkeyHex;

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(identitiesNotifier.value, isEmpty);
    expect(activeIdentityPubkeyNotifier.value, isNull);
    expect(find.text('No identities yet'), findsOneWidget);
    expect(await SettingsStore.loadPrivateKey(pubkeyHex), isNull);
  });

  const seckeyHex =
      '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
  const nsec =
      'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

  testWidgets('imports an nsec and makes it the active identity', (
    tester,
  ) async {
    await openIdentitiesScreen(tester);

    await tester.tap(find.byKey(const Key('importIdentityButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), nsec);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(identitiesNotifier.value, hasLength(1));
    expect(
      await SettingsStore.loadPrivateKey(
        identitiesNotifier.value.single.pubkeyHex,
      ),
      seckeyHex,
    );
    expect(
      activeIdentityPubkeyNotifier.value,
      identitiesNotifier.value.single.pubkeyHex,
    );
  });

  testWidgets('rejects a malformed nsec without adding an identity', (
    tester,
  ) async {
    await openIdentitiesScreen(tester);

    await tester.tap(find.byKey(const Key('importIdentityButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'not an nsec');
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid nsec key'), findsOneWidget);
    expect(identitiesNotifier.value, isEmpty);
  });

  testWidgets('rejects importing an already-imported identity', (tester) async {
    await openIdentitiesScreen(tester);

    await tester.tap(find.byKey(const Key('importIdentityButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), nsec);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(identitiesNotifier.value, hasLength(1));

    await tester.tap(find.byKey(const Key('importIdentityButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), nsec);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('This identity is already imported'), findsOneWidget);
    expect(identitiesNotifier.value, hasLength(1));
  });

  testWidgets('a failed private key delete keeps the identity and says so', (
    tester,
  ) async {
    final store = _FlakySecretStore();
    SettingsStore.secretStore = store;
    await openIdentitiesScreen(tester);
    await tester.tap(find.byKey(const Key('generateIdentityButton')));
    await tester.pumpAndSettle();
    final pubkeyHex = identitiesNotifier.value.single.pubkeyHex;

    store.failDeletes = true;
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(identitiesNotifier.value.single.pubkeyHex, pubkeyHex);
    expect(find.textContaining('Could not delete the private key'), findsOne);
    expect(await SettingsStore.loadPrivateKey(pubkeyHex), isNotNull);
  });

  testWidgets('an identity added after a failed startup load is still saved', (
    tester,
  ) async {
    final store = _FlakySecretStore();
    SettingsStore.secretStore = store;
    const earlier =
        'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
    await store.write(
      'identities',
      jsonEncode([
        {'pubkeyHex': earlier, 'createdAt': 0},
      ]),
    );

    // As in main(): the index can't be read (a locked keyring), so the list
    // stays empty and nothing is bound to save it.
    store.failReads = true;
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    await bindPersisted(
      identitiesNotifier,
      SettingsStore.loadIdentities,
      SettingsStore.saveIdentities,
    );
    FlutterError.onError = previous;
    expect(identitiesNotifier.value, isEmpty);

    // The keyring is unlocked later in the same session.
    store.failReads = false;
    await openIdentitiesScreen(tester);
    await tester.tap(find.byKey(const Key('generateIdentityButton')));
    await tester.pumpAndSettle();

    final added = activeIdentityPubkeyNotifier.value;
    final saved = await SettingsStore.loadIdentities();
    expect(saved.map((i) => i.pubkeyHex), [earlier, added]);
    expect(identitiesNotifier.value.map((i) => i.pubkeyHex), [earlier, added]);
  });
}
