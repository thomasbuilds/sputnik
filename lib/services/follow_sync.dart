import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../main.dart';
import '../nostr/nostr.dart';
import 'settings_store.dart';

const _debounceDuration = Duration(milliseconds: 500);

/// Delay before each retry of a failed publish; the last one repeats.
@visibleForTesting
List<Duration> followSyncRetryDelays = const [
  Duration(seconds: 5),
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
];

/// Unpublished changes per identity (identity -> pubkey -> follow?), each
/// sent on top of that identity's list on the relays.
final _pendingByIdentity = <String, Map<String, bool>>{};

Timer? _timer;
bool _syncRunning = false;
int _failedAttempts = 0;
RelayClient _syncClient = const RelayClient();

/// Queues a follow change, published in a batch after a short debounce.
void scheduleFollowingSync(
  String targetPubkeyHex, {
  required bool follow,
  RelayClient relayClient = const RelayClient(),
}) {
  final myPubkeyHex = activeIdentityPubkeyNotifier.value;
  if (myPubkeyHex == null) return;

  (_pendingByIdentity[myPubkeyHex] ??= {})[targetPubkeyHex.toLowerCase()] =
      follow;

  _syncClient = relayClient;
  _timer?.cancel();
  _timer = Timer(_debounceDuration, _runSync);
}

@visibleForTesting
void resetFollowSync() {
  _timer?.cancel();
  _pendingByIdentity.clear();
  _failedAttempts = 0;
}

void _retryLater() {
  // The user is told once per streak of failures, not on every retry.
  if (_failedAttempts == 0) _reportSyncFailure();

  final delays = followSyncRetryDelays;
  final delay = delays[min(_failedAttempts, delays.length - 1)];
  _failedAttempts++;
  _timer?.cancel();
  _timer = Timer(delay, _runSync);
}

/// Publishes queued changes until none are left, backing off on failure.
Future<void> _runSync() async {
  if (_syncRunning) return;
  _syncRunning = true;
  try {
    while (_pendingByIdentity.isNotEmpty) {
      final myPubkeyHex = _pendingByIdentity.keys.first;
      final pending = _pendingByIdentity[myPubkeyHex]!;
      final changes = Map<String, bool>.of(pending);

      final privkeyHex = await SettingsStore.loadPrivateKey(myPubkeyHex);
      if (privkeyHex == null) {
        // The identity was deleted; its queue can never be published.
        _pendingByIdentity.remove(myPubkeyHex);
        _reportSyncFailure();
        continue;
      }

      final outcome = await RelayContactsRepository(client: _syncClient)
          .applyFollowChanges(
            seckeyHex: privkeyHex,
            myPubkeyHex: myPubkeyHex,
            changes: changes,
            relayUrls: selectedRelaysNotifier.value,
          );
      final accepted = outcome.results.values.any(
        (result) => result.outcome == RelayPublishOutcome.accepted,
      );
      if (!accepted) {
        _retryLater();
        return;
      }
      _failedAttempts = 0;

      // Anything toggled again mid-publish stays queued for the next pass.
      for (final change in changes.entries) {
        if (pending[change.key] == change.value) pending.remove(change.key);
      }
      if (pending.isEmpty) _pendingByIdentity.remove(myPubkeyHex);

      if (activeIdentityPubkeyNotifier.value == myPubkeyHex) {
        myFollowingNotifier.value = {
          for (final pubkey in outcome.following)
            if (pending[pubkey] != false) pubkey,
          for (final change in pending.entries)
            if (change.value) change.key,
        };
      }
    }
  } finally {
    _syncRunning = false;
  }
}

void _reportSyncFailure() {
  final context = navigatorKey.currentContext;
  if (context != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not update your follow list')),
    );
  }
}
