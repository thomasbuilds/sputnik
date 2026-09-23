import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/services/settings_store.dart';

void main() {
  test('loads the saved value, then saves every change in order', () async {
    final notifier = ValueNotifier(0);
    final saved = <int>[];
    final firstSave = Completer<void>();
    await bindPersisted(notifier, () async => 1, (value) async {
      if (value == 2) await firstSave.future;
      saved.add(value);
    });
    expect(notifier.value, 1);

    notifier.value = 2;
    notifier.value = 3;
    await pumpEventQueue();
    firstSave.complete();
    await pumpEventQueue();

    expect(saved, [2, 3]);
  });

  // e.g. an identity index that could not be read must not be replaced by
  // the next change.
  test('never overwrites a value it could not load', () async {
    final reported = <FlutterErrorDetails>[];
    final onError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = onError);
    final notifier = ValueNotifier(<String>[]);
    final saved = <List<String>>[];

    await bindPersisted<List<String>>(
      notifier,
      () async => throw StateError('keystore locked'),
      (value) async => saved.add(value),
    );
    notifier.value = ['a new identity'];
    await pumpEventQueue();

    expect(saved, isEmpty);
    expect(reported, hasLength(1));
  });
}
