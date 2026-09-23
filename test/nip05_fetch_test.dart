import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nip05.dart';

import 'support/public_https_server.dart';

// The fetch behind verifyNip05, offline: a real TLS server on loopback,
// reached through the SSRF guard as if it were a public host.
void main() {
  final pubkey = 'aa' * 32;
  late PublicHttpsServer domain;
  late void Function(HttpRequest request) handle;
  final requested = <String>[];

  setUp(() async {
    requested.clear();
    domain = await PublicHttpsServer.start((request) {
      requested.add('${request.uri}');
      handle(request);
    });
  });

  tearDown(() => domain.close());

  void answer(Object body, {int status = HttpStatus.ok}) {
    handle = (request) => request.response
      ..statusCode = status
      ..write(jsonEncode(body))
      ..close();
  }

  // Each test uses its own name: results are cached per identifier.
  Future<Nip05Status> verify(String identifier, String pubkeyHex) => domain.run(
    () => verifyNip05(identifier: identifier, pubkeyHex: pubkeyHex),
  );

  // Regression test: the guarded connectionFactory must complete a real TLS
  // handshake itself, which a fake client can't catch.
  test('asks the domain over TLS and verifies a name it lists', () async {
    answer({
      'names': {'bob': pubkey},
    });

    final status = await verify('bob@$publicTestAddress', pubkey);

    expect(status, Nip05Status.verified);
    expect(domain.connectTargets, ['$publicTestAddress:443']);
    expect(requested, ['/.well-known/nostr.json?name=bob']);
  });

  test('a name listed for another key, or not listed, is a mismatch', () async {
    answer({
      'names': {'carol': 'bb' * 32},
    });

    expect(
      await verify('carol@$publicTestAddress', pubkey),
      Nip05Status.mismatch,
    );
    expect(
      await verify('dave@$publicTestAddress', pubkey),
      Nip05Status.mismatch,
    );
  });

  test('the listed key may use upper-case hex', () async {
    answer({
      'names': {'erin': pubkey.toUpperCase()},
    });

    expect(
      await verify('erin@$publicTestAddress', pubkey),
      Nip05Status.verified,
    );
  });

  test('a redirect is not followed', () async {
    handle = (request) {
      if (request.uri.path == '/moved.json') {
        request.response
          ..write(
            jsonEncode({
              'names': {'frank': pubkey},
            }),
          )
          ..close();
      } else {
        request.response.redirect(Uri.parse('/moved.json?name=frank'));
      }
    };

    expect(
      await verify('frank@$publicTestAddress', pubkey),
      Nip05Status.unreachable,
    );
    expect(requested, hasLength(1));
  });

  test('an error status is unreachable, whatever the body says', () async {
    answer({
      'names': {'gina': pubkey},
    }, status: HttpStatus.notFound);

    expect(
      await verify('gina@$publicTestAddress', pubkey),
      Nip05Status.unreachable,
    );
  });

  test('a response over 64 KiB is refused', () async {
    answer({
      'names': {'hank': pubkey},
      'padding': 'x' * (64 * 1024),
    });

    expect(
      await verify('hank@$publicTestAddress', pubkey),
      Nip05Status.unreachable,
    );
  });

  test('a certificate for another host is refused', () async {
    answer({
      'names': {'ivan': pubkey},
    });

    // The server's certificate names publicTestAddress only.
    expect(await verify('ivan@93.184.215.15', pubkey), Nip05Status.unreachable);
    expect(domain.connectTargets, ['93.184.215.15:443']);
  });
}
