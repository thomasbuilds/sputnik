import 'package:flutter/foundation.dart';

import '../main.dart';
import '../services/cache_store.dart';
import 'models/nostr_event.dart';
import 'models/nostr_filter.dart';
import 'relay_client.dart';
import 'replaceable_events.dart';

final _pubkeyPattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// Newest own contact list seen or published, per pubkey, so a lagging relay's
/// older copy is never republished over it.
final _newestOwnContactList = <String, DateTime>{};

@visibleForTesting
void resetKnownContactLists() => _newestOwnContactList.clear();

void _noteContactList(String pubkeyHex, DateTime createdAt) {
  final key = pubkeyHex.toLowerCase();
  final known = _newestOwnContactList[key];
  if (known == null || createdAt.isAfter(known)) {
    _newestOwnContactList[key] = createdAt;
  }
}

/// The identity [myFollowingNotifier] was last loaded for.
String? _myFollowingLoadedForPubkeyHex;

/// The load in flight, so concurrent callers share one fetch.
Future<void>? _myFollowingLoadingFuture;

bool _isFollowTag(List<String> tag) =>
    tag.length > 1 && tag[0] == 'p' && _pubkeyPattern.hasMatch(tag[1]);

/// The identity [_myFollowingLoadingFuture] is loading for.
String? _myFollowingLoadingForPubkeyHex;

List<String> _followedPubkeys(NostrEvent event) {
  return [
    for (final tag in event.tags)
      if (_isFollowTag(tag)) tag[1].toLowerCase(),
  ];
}

class RelayContactsRepository {
  const RelayContactsRepository({this.client = const RelayClient()});

  final RelayClient client;

  /// The pubkeys a person follows, read from their own kind:3 contact list.
  Future<List<String>> fetchFollowing(
    String pubkeyHex,
    Set<String> relayUrls, {
    bool force = false,
  }) async =>
      await _fetchFollowingOrNull(pubkeyHex, relayUrls, force: force) ??
      const <String>[];

  /// Null when nothing was found and some relay may still hold a list.
  Future<List<String>?> _fetchFollowingOrNull(
    String pubkeyHex,
    Set<String> relayUrls, {
    bool force = false,
  }) async {
    if (!force && CacheStore.isFollowingFresh(pubkeyHex)) {
      final cached = CacheStore.getFollowing(pubkeyHex);
      if (cached != null) return cached;
    }

    final result = await client.queryWithStatus(
      relayUrls,
      NostrFilter(kinds: const [3], authors: [pubkeyHex], limit: 1),
    );

    final author = pubkeyHex.toLowerCase();
    final own = [
      for (final event in result.events)
        if (event.kind == 3 && event.pubkey == author) event,
    ]..sort(compareNewestFirst);

    if (own.isEmpty) {
      return result.allRelaysAnswered ? const <String>[] : null;
    }

    final createdAt = own.first.createdAt.millisecondsSinceEpoch ~/ 1000;
    final known = CacheStore.followingCreatedAt(pubkeyHex);
    // A lagging relay's older copy must not replace a newer one.
    if (known != null && createdAt < known) {
      return CacheStore.getFollowing(pubkeyHex);
    }
    // So a later edit never builds on an older copy than this one.
    _noteContactList(pubkeyHex, own.first.createdAt);
    final following = _followedPubkeys(own.first);
    await CacheStore.putFollowing(pubkeyHex, following, createdAt: createdAt);
    return following;
  }

  /// The pubkeys of people whose own contact list currently includes this
  /// pubkey.
  Future<List<String>> fetchFollowers(
    String pubkeyHex,
    Set<String> relayUrls, {
    bool force = false,
  }) async {
    if (!force && CacheStore.isFollowersFresh(pubkeyHex)) {
      final cached = CacheStore.getFollowers(pubkeyHex);
      if (cached != null) return cached;
    }

    final tagged = await client.query(
      relayUrls,
      NostrFilter(
        kinds: const [3],
        tags: {
          'p': [pubkeyHex],
        },
        limit: 500,
      ),
    );
    if (tagged.isEmpty) return const <String>[];

    final candidates = {
      for (final event in tagged)
        if (event.kind == 3) event.pubkey,
    };
    if (candidates.isEmpty) return const <String>[];

    final latestEventsByChunk = await Future.wait(
      chunkedAuthors(candidates.toList()).map(
        (chunk) => client.query(
          relayUrls,
          NostrFilter(kinds: const [3], authors: chunk),
        ),
      ),
    );
    final latestEvents = latestEventsByChunk.expand((events) => events).toList()
      ..sort(compareNewestFirst);

    final latestByAuthor = <String, NostrEvent>{};
    for (final event in latestEvents) {
      if (event.kind != 3) continue;
      latestByAuthor.putIfAbsent(event.pubkey, () => event);
    }

    final subject = pubkeyHex.toLowerCase();
    final followers = [
      for (final event in latestByAuthor.values)
        if (event.tags.any(
          (tag) =>
              tag.length > 1 &&
              tag[0] == 'p' &&
              tag[1].toLowerCase() == subject,
        ))
          event.pubkey,
    ];

    await CacheStore.putFollowers(pubkeyHex, followers);
    return followers;
  }

  /// Populates myFollowingNotifier for the active identity, once per identity.
  Future<void> ensureMyFollowingLoaded(Set<String> relayUrls) {
    final myPubkeyHex = activeIdentityPubkeyNotifier.value;
    if (myPubkeyHex == null) {
      myFollowingNotifier.value = null;
      _myFollowingLoadedForPubkeyHex = null;
      return Future.value();
    }
    if (_myFollowingLoadedForPubkeyHex == myPubkeyHex &&
        myFollowingNotifier.value != null) {
      return Future.value();
    }
    if (_myFollowingLoadedForPubkeyHex != null &&
        _myFollowingLoadedForPubkeyHex != myPubkeyHex) {
      // Another identity's list must never stand in for this one's.
      myFollowingNotifier.value = null;
      _myFollowingLoadedForPubkeyHex = null;
    }
    final inFlight = _myFollowingLoadingFuture;
    if (inFlight != null && _myFollowingLoadingForPubkeyHex == myPubkeyHex) {
      return inFlight;
    }
    _myFollowingLoadingForPubkeyHex = myPubkeyHex;
    late final Future<void> load;
    load = _fetchFollowingOrNull(myPubkeyHex, relayUrls)
        .then((following) {
          // Left unloaded on failure, or once another identity is active.
          if (following == null ||
              activeIdentityPubkeyNotifier.value != myPubkeyHex) {
            return;
          }
          myFollowingNotifier.value = following.toSet();
          _myFollowingLoadedForPubkeyHex = myPubkeyHex;
        })
        .whenComplete(() {
          if (identical(_myFollowingLoadingFuture, load)) {
            _myFollowingLoadingFuture = null;
          }
        });
    return _myFollowingLoadingFuture = load;
  }

  Future<({List<List<String>> tags, NostrEvent? event})?> _fetchOwnContactList(
    String pubkeyHex,
    Set<String> relayUrls,
  ) async {
    final own = await fetchOwnReplaceable(
      client,
      kind: 3,
      pubkeyHex: pubkeyHex,
      relayUrls: relayUrls,
      // The republished list replaces the whole thing everywhere, and a
      // relay that did not answer may hold a newer one.
      requireAllRelays: true,
    );
    if (!own.conclusive) return null;

    final known = _newestOwnContactList[pubkeyHex.toLowerCase()];
    final event = own.event;
    if (event == null) {
      // A list we saw before that no relay returns now is lagging, not gone.
      if (known != null) return null;
      return (tags: const <List<String>>[], event: null);
    }
    if (known != null && event.createdAt.isBefore(known)) return null;
    _noteContactList(pubkeyHex, event.createdAt);

    // Every tag carries over (other clients keep e.g. followed hashtags or
    // communities here); only well-formed p tags are edited.
    return (tags: event.tags, event: event);
  }

  /// Applies follow (true) / unfollow (false) changes to the relays' list,
  /// which NIP-02 has us republish in full each time.
  Future<({Map<String, RelayPublishResult> results, Set<String> following})>
  applyFollowChanges({
    required String seckeyHex,
    required String myPubkeyHex,
    required Map<String, bool> changes,
    required Set<String> relayUrls,
  }) async {
    final current = await _fetchOwnContactList(myPubkeyHex, relayUrls);
    // Publishing blind would replace the real list with just these changes.
    if (current == null) {
      return (
        results: const <String, RelayPublishResult>{},
        following: const <String>{},
      );
    }

    final desired = {
      for (final tag in current.tags)
        if (_isFollowTag(tag)) tag[1].toLowerCase(),
    };
    for (final change in changes.entries) {
      final target = change.key.toLowerCase();
      if (change.value) {
        desired.add(target);
      } else {
        desired.remove(target);
      }
    }

    final results = await _publishFollowing(
      seckeyHex: seckeyHex,
      myPubkeyHex: myPubkeyHex,
      currentTags: current.tags,
      previous: current.event,
      desiredFollowing: desired,
      relayUrls: relayUrls,
    );
    return (results: results, following: desired);
  }

  Future<Map<String, RelayPublishResult>> _publishFollowing({
    required String seckeyHex,
    required String myPubkeyHex,
    required List<List<String>> currentTags,
    required NostrEvent? previous,
    required Set<String> desiredFollowing,
    required Set<String> relayUrls,
  }) async {
    final kept = [
      for (final tag in currentTags)
        if (!_isFollowTag(tag) ||
            desiredFollowing.contains(tag[1].toLowerCase()))
          tag,
    ];
    final keptPubkeys = {
      for (final tag in kept)
        if (_isFollowTag(tag)) tag[1].toLowerCase(),
    };
    final newTags = [
      ...kept,
      for (final pubkey in desiredFollowing)
        if (!keptPubkeys.contains(pubkey)) ['p', pubkey],
    ];

    final event = signEvent(
      seckeyHex: seckeyHex,
      pubkeyHex: myPubkeyHex,
      kind: 3,
      tags: newTags,
      content: '',
      createdAt: nextReplaceableTime(previous),
    );
    final results = await client.publish(event, relayUrls);

    final accepted = results.values.any(
      (result) => result.outcome == RelayPublishOutcome.accepted,
    );
    if (accepted) {
      _noteContactList(myPubkeyHex, event.createdAt);
      await CacheStore.putFollowing(
        myPubkeyHex,
        desiredFollowing.toList(),
        createdAt: event.createdAt.millisecondsSinceEpoch ~/ 1000,
      );
    }
    return results;
  }
}
