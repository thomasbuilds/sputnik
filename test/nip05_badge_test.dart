import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nip05.dart';
import 'package:sputnik/widgets/nip05_badge.dart';

void main() {
  testWidgets(
    'tapping the status icon shows its tooltip (mobile has no hover)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Nip05Badge(
              identifier: 'bob@example.com',
              status: Nip05Status.verified,
            ),
          ),
        ),
      );

      expect(find.text('Verified by bob@example.com'), findsNothing);

      await tester.tap(find.byIcon(Icons.verified));
      await tester.pump();

      expect(find.text('Verified by bob@example.com'), findsOneWidget);
    },
  );

  testWidgets('a long identifier wraps rather than hiding its domain', (
    tester,
  ) async {
    const identifier =
        'jack@cash.app.verify-your-nostr-login-portal.evil.example';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              child: Nip05Badge(
                identifier: identifier,
                status: Nip05Status.verified,
              ),
            ),
          ),
        ),
      ),
    );

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text(identifier),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.text.style?.overflow, isNot(TextOverflow.ellipsis));
    expect(paragraph.overflow, isNot(TextOverflow.ellipsis));
  });
}
