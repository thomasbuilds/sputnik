import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sputnik/main.dart';
import 'package:sputnik/screens/identities_screen.dart';
import 'package:sputnik/services/settings_store.dart';

import 'support/fake_secret_store.dart';

void main() {
  late List<String> copied;
  late bool failCopy;
  late String? clipboardText;
  late bool backgrounded;

  setUp(() {
    copied = [];
    failCopy = false;
    clipboardText = null;
    backgrounded = false;
    notesNotifier.value = const [];
    identitiesNotifier.value = const [];
    activeIdentityPubkeyNotifier.value = null;
    SettingsStore.secretStore = FakeSecretStore();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (failCopy) {
              throw PlatformException(code: 'clipboard-unavailable');
            }
            final text = (call.arguments as Map)['text'] as String;
            copied.add(text);
            clipboardText = text;
            return null;
          }
          if (call.method == 'Clipboard.getData') {
            // Android 10+ gives apps in the background no clipboard at all.
            return backgrounded ? null : {'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> revealPrivateKey(WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.tap(find.byKey(const Key('profileAvatarButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('identitiesCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('generateIdentityButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View private key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reveal'));
    await tester.pumpAndSettle();
  }

  testWidgets('copying puts the key on the clipboard and says so', (
    tester,
  ) async {
    await revealPrivateKey(tester);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, startsWith('nsec1'));
    expect(find.textContaining('Copied private key'), findsOneWidget);

    // Let the pending clear timer run out within the test's fake clock.
    await tester.pump(nsecClipboardClearDelay);
    await tester.pumpAndSettle();
  });

  testWidgets('a failed copy is reported instead of claimed as success', (
    tester,
  ) async {
    await revealPrivateKey(tester);
    failCopy = true;

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, isEmpty);
    expect(find.text('Could not copy the private key'), findsOneWidget);
    expect(find.textContaining('Copied private key'), findsNothing);
  });

  testWidgets('the clipboard is cleared automatically after copying', (
    tester,
  ) async {
    await revealPrivateKey(tester);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cleared from the'), findsOneWidget);
    expect(clipboardText, startsWith('nsec1'));

    await tester.pump(nsecClipboardClearDelay);
    await tester.pumpAndSettle();

    expect(clipboardText, isEmpty);
  });

  testWidgets('a clipboard overwritten by something else is left alone', (
    tester,
  ) async {
    await revealPrivateKey(tester);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    clipboardText = 'something else the user copied';

    await tester.pump(nsecClipboardClearDelay);
    await tester.pumpAndSettle();

    expect(clipboardText, 'something else the user copied');
  });

  Future<void> setLifecycle(WidgetTester tester, AppLifecycleState state) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'flutter/lifecycle',
            const StringCodec().encodeMessage(state.toString()),
            (_) {},
          );

  testWidgets('a clear that falls due in the background happens on resume', (
    tester,
  ) async {
    await revealPrivateKey(tester);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    await setLifecycle(tester, AppLifecycleState.paused);
    backgrounded = true;
    await tester.pump(nsecClipboardClearDelay);
    await tester.pumpAndSettle();
    expect(clipboardText, startsWith('nsec1'));

    backgrounded = false;
    await setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(clipboardText, isEmpty);
  });

  testWidgets('the revealed key is not selectable text', (tester) async {
    await revealPrivateKey(tester);

    // A selection toolbar would offer an uncleared Copy and text actions
    // (e.g. Translate) that hand the key to other apps.
    expect(find.byType(SelectableText), findsNothing);
    expect(find.textContaining('nsec1'), findsOneWidget);
  });

  testWidgets('the nsec field opts out of IME learning and suggestions', (
    tester,
  ) async {
    await tester.pumpWidget(const MainApp());
    await tester.tap(find.byKey(const Key('profileAvatarButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('identitiesCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('importIdentityButton')));
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(TextFormField));

    final setClient = tester.testTextInput.log.lastWhere(
      (call) => call.method == 'TextInput.setClient',
    );
    final config = (setClient.arguments as List)[1] as Map;
    expect(config['obscureText'], isTrue);
    expect(config['autocorrect'], isFalse);
    expect(config['enableSuggestions'], isFalse);
    expect(config['enableIMEPersonalizedLearning'], isFalse);
  });
}
