import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/services/image_saver.dart';
import 'package:sputnik/services/media_loader.dart';

Uint8List _png() => Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

void main() {
  test(
    'names the file from the URL but trusts the bytes for the extension',
    () {
      expect(imageFileName('https://a.example/dir/cat.jpg', _png()), 'cat.png');
      expect(
        imageFileName('https://a.example/a.png', [0xff, 0xd8, 0xff, 0]),
        'a.jpg',
      );
      expect(
        imageFileName('https://a.example/a', [
          ...'RIFF'.codeUnits,
          0,
          0,
          0,
          0,
          ...'WEBP'.codeUnits,
        ]),
        'a.webp',
      );
      // Unrecognized bytes fall back to a plausible URL extension, else none.
      expect(imageFileName('https://a.example/a.gif', [1, 2]), 'a.gif');
      expect(imageFileName('https://a.example/a.exe', [1, 2]), 'a');
    },
  );

  test('cannot be steered out of the folder or made unwieldy by the URL', () {
    expect(
      imageFileName('https://a.example/..%2F..%2Fetc%2Fpasswd', _png()),
      isNot(contains('/')),
    );
    expect(imageFileName('https://a.example/.hidden', _png()), 'hidden.png');
    expect(imageFileName('https://a.example/', _png()), 'image.png');
    expect(
      imageFileName('https://a.example/${'a' * 200}.png', _png()).length,
      lessThanOrEqualTo(64),
    );
  });

  test(
    'holds a fallback copy to the hash, but not the author\'s own URL',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (request.uri.path == '/cat.png') {
          request.response.add(_png());
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        request.response.close();
      });
      // Loopback is refused by the guarded client, so use a plain one here.
      replaceSharedImageClient(HttpClient.new);
      addTearDown(() => replaceSharedImageClient(null));
      final base = 'http://127.0.0.1:${server.port}';
      Future<String?> backend(Uint8List bytes, String name) async => name;

      // The author's URL is gone, so the copy comes from a fallback server.
      final matching = await saveImage(
        MediaSource(
          url: '$base/gone.png',
          sha256: sha256.convert(_png()).toString(),
          fallbackUrls: ['$base/cat.png'],
        ),
        backend: backend,
      );
      final tampered = await saveImage(
        MediaSource(
          url: '$base/gone.png',
          sha256: 'ab' * 32,
          fallbackUrls: ['$base/cat.png'],
        ),
        backend: backend,
      );
      // NIP-96 hosts re-encode uploads, so the author's own URL is not held
      // to the hash its name or tags carry.
      final ownUrl = await saveImage(
        MediaSource(url: '$base/cat.png', sha256: 'ab' * 32),
        backend: backend,
      );

      expect(matching.outcome, SaveOutcome.saved);
      expect(tampered.outcome, SaveOutcome.failed);
      expect(ownUrl.outcome, SaveOutcome.saved);
    },
  );

  test('reports each way saving can end', () async {
    final source = MediaSource(url: 'https://a.example/cat.png');
    Future<Uint8List> fetch(MediaSource _) async => _png();

    Future<SaveResult> run(SaveBackend backend) =>
        saveImage(source, backend: backend, fetchBytes: fetch);

    final names = <String>[];
    final saved = await run((bytes, name) async {
      names.add(name);
      return '/home/me/cat.png';
    });
    expect(saved.outcome, SaveOutcome.saved);
    expect(saveMessage(saved), 'Saved to /home/me/cat.png');
    expect(names, ['cat.png']);

    final cancelled = await run((bytes, name) async => null);
    expect(cancelled.outcome, SaveOutcome.cancelled);
    expect(saveMessage(cancelled), isNull);

    final denied = await run((bytes, name) async => throw const SaveDenied());
    expect(denied.outcome, SaveOutcome.denied);

    final failed = await run((bytes, name) async => throw StateError('disk'));
    expect(failed.outcome, SaveOutcome.failed);

    final noDownload = await saveImage(
      source,
      backend: (bytes, name) async => 'never',
      fetchBytes: (_) async => throw StateError('offline'),
    );
    expect(noDownload.outcome, SaveOutcome.failed);
  });
}
