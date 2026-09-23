// Audit (state/ST): the NIP-05 result cache pins a transient failure.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nip05.dart';

/// An HttpClient whose every request fails as if the network blipped.
class _OfflineClient implements HttpClient {
  static int requests = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    throw const SocketException('network is unreachable');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null; // e.g. setters
}

class _Offline extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineClient();
}

void main() {
  test('ST-15: a transient network failure is cached as "Could not verify" '
      'for an hour; checking again does not retry', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final pubkey = 'ab' * 32;
      final first = await verifyNip05(
        identifier: 'alice@example.com',
        pubkeyHex: pubkey,
      );
      // The network is back a minute later; the profile is reopened or
      // refreshed and checks again.
      final again = await verifyNip05(
        identifier: 'alice@example.com',
        pubkeyHex: pubkey,
      );
      // ignore: avoid_print
      print(
        'first=$first again=$again http requests=${_OfflineClient.requests}',
      );
      expect(first, Nip05Status.unreachable);
      expect(
        _OfflineClient.requests,
        2,
        reason: 'an unreachable result should not be cached like a verdict',
      );
    }, _Offline());
  });
}
