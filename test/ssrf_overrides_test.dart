import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/services/ssrf_guard.dart';

void main() {
  test('SsrfGuardedHttpOverrides guards a plain HttpClient, as NetworkImage '
      'uses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var served = 0;
    server.listen((request) {
      served++;
      request.response.close();
    });

    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/')),
        throwsA(isA<SocketException>()),
      );
    }, SsrfGuardedHttpOverrides());
    expect(served, 0);
  });
}
