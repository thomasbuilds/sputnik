import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../nostr/models/nostr_metadata.dart';
import '../nostr/models/nostr_payment_target.dart';

/// Local Hive-backed cache for data fetched from relays. Each entry is stored
/// with a fetch timestamp, so callers can decide whether it's fresh enough to
/// skip a relay round-trip.
class CacheStore {
  CacheStore._();

  static const staleAfter = Duration(hours: 1);

  /// Entries not refreshed within this long are dropped when the cache opens.
  static const maxAge = Duration(days: 30);

  static late final Box<Map> _profiles;
  static late final Box<Map> _contacts;
  static late final Box<Map> _paymentTargets;

  static bool _ready = false;

  /// Not the documents folder, which is user-visible and often synced.
  static Future<Directory> _cacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/relay_cache').create(recursive: true);
  }

  static Future<void> init({@visibleForTesting Directory? directory}) async {
    try {
      Hive.init((directory ?? await _cacheDirectory()).path);
      final boxes = await Future.wait([
        Hive.openBox<Map>('profiles'),
        Hive.openBox<Map>('contacts'),
        Hive.openBox<Map>('paymentTargets'),
      ]);
      _profiles = boxes[0];
      _contacts = boxes[1];
      _paymentTargets = boxes[2];
      _ready = true;
      await Future.wait(boxes.map(pruneExpired));
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'sputnik',
          context: ErrorDescription('opening the relay data cache'),
        ),
      );
    }
  }

  /// Deletes entries whose `fetchedAt` is older than [maxAge].
  @visibleForTesting
  static Future<void> pruneExpired(Box<Map> box, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now())
        .subtract(maxAge)
        .millisecondsSinceEpoch;
    final latest = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return box.deleteAll([
      for (final key in box.keys)
        if (_outside((box.get(key)?['fetchedAt'] as int?) ?? 0, cutoff, latest))
          key,
    ]);
  }

  /// Too old, or dated in the future (a wrong clock, or a tampered file).
  static bool _outside(int fetchedAt, int cutoff, int latest) =>
      fetchedAt < cutoff || fetchedAt > latest;

  static bool _isFresh(int? fetchedAtMillis) {
    if (fetchedAtMillis == null) return false;
    final fetchedAt = DateTime.fromMillisecondsSinceEpoch(fetchedAtMillis);
    final age = DateTime.now().difference(fetchedAt);
    return !age.isNegative && age < staleAfter;
  }

  static Map<String, NostrMetadata> loadAllProfiles() {
    if (!_ready) return const <String, NostrMetadata>{};
    final result = <String, NostrMetadata>{};
    for (final key in _profiles.keys) {
      final data = _profiles.get(key)?['data'];
      if (data == null) continue;
      try {
        result[key as String] = NostrMetadata.fromJson(
          Map<String, dynamic>.from(data as Map),
        );
      } catch (_) {
        // Skip malformed cache entries.
      }
    }
    return result;
  }

  static bool isProfileFresh(String pubkeyHex) {
    if (!_ready) return false;
    return _isFresh(_profiles.get(pubkeyHex)?['fetchedAt'] as int?);
  }

  /// When the cached profile's event was created, in seconds, if known.
  static int? profileCreatedAt(String pubkeyHex) =>
      _ready ? (_profiles.get(pubkeyHex)?['createdAt'] as int?) : null;

  /// [createdAt] (seconds) is the event each profile came from, so an older
  /// copy fetched later never replaces it.
  static Future<void> putProfiles(
    Map<String, NostrMetadata> profiles, {
    Map<String, int> createdAt = const {},
  }) async {
    if (!_ready) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _profiles.putAll({
      for (final entry in profiles.entries)
        entry.key: {
          'data': entry.value.toJson(),
          'fetchedAt': now,
          'createdAt': ?createdAt[entry.key],
        },
    });
  }

  /// Empties every box, including the follow lists that hint at who was viewed.
  static Future<void> clearAll() async {
    if (!_ready) return;
    await Future.wait([
      _profiles.clear(),
      _contacts.clear(),
      _paymentTargets.clear(),
    ]);
  }

  static List<String>? getFollowing(String pubkeyHex) =>
      _getList('$pubkeyHex:following');

  static List<String>? getFollowers(String pubkeyHex) =>
      _getList('$pubkeyHex:followers');

  static bool isFollowingFresh(String pubkeyHex) =>
      _ready &&
      _isFresh(_contacts.get('$pubkeyHex:following')?['fetchedAt'] as int?);

  static bool isFollowersFresh(String pubkeyHex) =>
      _ready &&
      _isFresh(_contacts.get('$pubkeyHex:followers')?['fetchedAt'] as int?);

  static Future<void> putFollowing(
    String pubkeyHex,
    List<String> pubkeys, {
    int? createdAt,
  }) => _putList('$pubkeyHex:following', pubkeys, createdAt: createdAt);

  /// When the cached follow list's event was created, in seconds, if known.
  static int? followingCreatedAt(String pubkeyHex) => _ready
      ? (_contacts.get('$pubkeyHex:following')?['createdAt'] as int?)
      : null;

  static Future<void> putFollowers(String pubkeyHex, List<String> pubkeys) =>
      _putList('$pubkeyHex:followers', pubkeys);

  static List<String>? _getList(String key) {
    if (!_ready) return null;
    final entry = _contacts.get(key);
    if (entry == null) return null;
    return List<String>.from(entry['pubkeys'] as List? ?? const []);
  }

  static Future<void> _putList(
    String key,
    List<String> pubkeys, {
    int? createdAt,
  }) {
    if (!_ready) return Future.value();
    return _contacts.put(key, {
      'pubkeys': pubkeys,
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      'createdAt': ?createdAt,
    });
  }

  static List<NostrPaymentTarget>? getPaymentTargets(String pubkeyHex) {
    if (!_ready) return null;
    final data = _paymentTargets.get(pubkeyHex)?['data'] as List?;
    if (data == null) return null;
    try {
      return [
        for (final item in data)
          NostrPaymentTarget.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (_) {
      // Unreadable (e.g. written by another version): a miss, so it refetches.
      return null;
    }
  }

  static bool isPaymentTargetsFresh(String pubkeyHex) {
    if (!_ready) return false;
    return _isFresh(_paymentTargets.get(pubkeyHex)?['fetchedAt'] as int?);
  }

  static Future<void> putPaymentTargets(
    String pubkeyHex,
    List<NostrPaymentTarget> targets,
  ) {
    if (!_ready) return Future.value();
    return _paymentTargets.put(pubkeyHex, {
      'data': [for (final target in targets) target.toJson()],
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
