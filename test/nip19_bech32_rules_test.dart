import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/bech32.dart';
import 'package:sputnik/nostr/hex.dart';
import 'package:sputnik/nostr/nip19.dart';

void main() {
  const hex1 =
      '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
  const npub1 =
      'npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6';
  const nsec =
      'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
  final idBytes = hexDecode(hex1);

  test('rejects a string with a typo, which the checksum catches', () {
    // Changes one data character; a pasted nsec with a typo must not import
    // as some other key.
    String typo(String s) => s.replaceRange(10, 11, s[10] == 'q' ? 'p' : 'q');

    expect(hexFromNpub(typo(npub1)), isNull);
    expect(hexFromNsec(typo(nsec)), isNull);
  });

  test('accepts one case throughout but rejects mixed case', () {
    expect(hexFromNpub(npub1.toUpperCase()), hex1);
    expect(hexFromNpub('N${npub1.substring(1)}'), isNull);
  });

  test('rejects a payload longer than 32 bytes', () {
    final payload = convertBits([...idBytes, 1], 8, 5, pad: true);

    expect(hexFromNsec(bech32Encode('nsec', payload)), isNull);
  });

  test('rejects a TLV cut shorter than its declared length', () {
    // Declares 32 bytes but carries 16.
    final data = <int>[0, 32, ...idBytes.sublist(0, 16)];
    final payload = convertBits(data, 8, 5, pad: true);

    expect(hexFromNevent(bech32Encode('nevent', payload)), isNull);
  });

  test('skips relay, author, kind and unknown TLVs before the id', () {
    final relay = 'wss://r.x.com'.codeUnits;
    final data = <int>[
      ...[1, relay.length, ...relay],
      ...[2, 32, ...List.filled(32, 7)],
      ...[3, 4, 0, 0, 0, 1],
      ...[9, 1, 0], // a type NIP-19 does not define
      ...[0, 32, ...idBytes],
    ];
    final nevent = bech32Encode('nevent', convertBits(data, 8, 5, pad: true));

    expect(hexFromNevent(nevent), hex1);
  });
}
