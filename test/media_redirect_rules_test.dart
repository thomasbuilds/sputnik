import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/services/media_loader.dart';

class _RealHttp extends HttpOverrides {}

HttpClient _realClient() =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

void main() {
  late HttpServer server;
  final paths = <String>[];

  setUp(() async {
    paths.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() => server.close(force: true));

  test('refuses to follow a redirect to a URL with credentials', () async {
    server.listen((request) {
      paths.add(request.uri.path);
      if (request.uri.path == '/start') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://user:pass@127.0.0.1:${server.port}/final',
          )
          ..close();
      } else {
        request.response
          ..add([9])
          ..close();
      }
    });

    await expectLater(
      fetchImageBytes(
        Uri.parse('http://127.0.0.1:${server.port}/start'),
        clientFactory: _realClient,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(paths, ['/start']);
  });

  test(
    'a redirect with an oversized body is cut off by the body cap',
    () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/next');
        for (var i = 0; i < 100; i++) {
          request.response.add(Uint8List(8 * 1024));
        }
        await request.response.close();
      });

      await expectLater(
        fetchImageBytes(
          Uri.parse('http://127.0.0.1:${server.port}/'),
          clientFactory: _realClient,
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            'Redirect body too large',
          ),
        ),
      );
    },
  );
}
