import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/http_urls.dart';

void main() {
  group('withoutUrls', () {
    const url = 'https://a.example/1.jpg';

    test('removes a URL at the end of a line', () {
      expect(withoutUrls('look at this $url', {url}), 'look at this');
    });

    test('removes a line that held only the URL', () {
      expect(withoutUrls('first\n$url\nlast', {url}), 'first\nlast');
    });

    test('returns nothing when the text was only the URL', () {
      expect(withoutUrls(url, {url}), '');
      expect(withoutUrls('$url\n$url', {url}), '');
    });

    test('keeps the punctuation that followed the URL', () {
      expect(withoutUrls('wow $url.', {url}), 'wow .');
    });

    test('leaves other URLs and untouched lines exactly as written', () {
      const other = 'https://b.example/page';
      expect(withoutUrls('  a  \n$other\n$url', {url}), '  a  \n$other');
    });

    test('does not remove a URL that merely starts with a listed one', () {
      const longer = 'https://a.example/1.jpg.html';
      expect(withoutUrls(longer, {url}), longer);
    });
  });

  group('trimUrlEnd', () {
    // The quadratic original, kept as the oracle for the linear version.
    String reference(String url) {
      int count(int end, String char) {
        var n = 0;
        for (var i = 0; i < end; i++) {
          if (url[i] == char) n++;
        }
        return n;
      }

      const closers = {')': '(', ']': '[', '}': '{'};
      var end = url.length;
      while (end > 0) {
        final last = url[end - 1];
        final opener = closers[last];
        final trailing =
            '.,;:!?\'*'.contains(last) ||
            (opener != null && count(end, last) > count(end, opener));
        if (!trailing) break;
        end--;
      }
      return url.substring(0, end);
    }

    test('matches the reference on random URLs', () {
      final random = Random(1);
      const alphabet = '()[]{}.,;:!?\'*a/';
      for (var n = 0; n < 20000; n++) {
        final tail = List.generate(
          random.nextInt(24),
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();
        final url = 'https://a.example/$tail';
        expect(trimUrlEnd(url), reference(url), reason: url);
      }
    });

    test('stays linear on a long run of closing brackets', () {
      final url = 'https://a.example/${')' * 60000}';
      final watch = Stopwatch()..start();
      expect(trimUrlEnd(url), 'https://a.example/');
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });
}
