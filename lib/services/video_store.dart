import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../nostr/blossom.dart';
import 'media_loader.dart';

const _dirPrefix = 'sputnik_media_';

/// Disk budget for videos kept this session, so scrolling back is free.
const videoCacheBytes = 300 * 1024 * 1024;

final _safeExtension = RegExp(r'^\.[A-Za-z0-9]{1,5}$');

Future<void> _deleteQuietly(FileSystemEntity entity) async {
  try {
    await entity.delete(recursive: true);
  } on FileSystemException {
    // Already gone, or still in use.
  }
}

final _chmod = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');

void _restrictToOwner(Directory directory) {
  final path = directory.path.toNativeUtf8();
  try {
    if (_chmod(path, 448 /* 0700 */) != 0) {
      throw FileSystemException('Could not make it private', directory.path);
    }
  } finally {
    malloc.free(path);
  }
}

/// Videos downloaded through the guarded client into a private temp folder.
class VideoStore {
  VideoStore({
    Future<Directory> Function()? tempDirectory,
    this.clientFactory = guardedHttpClient,
    this.cacheBytes = videoCacheBytes,
  }) : _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  static final instance = VideoStore();

  final Future<Directory> Function() _tempDirectory;
  final HttpClientFactory clientFactory;
  final int cacheBytes;

  final _files = <String, File>{};
  final _sizes = <String, int>{};
  Future<Directory>? _session;
  String? _ownPath;
  var _counter = 0;

  /// Deletes what earlier runs left behind.
  Future<void> sweepStale() async {
    final root = await _tempDirectory();
    await for (final entry in root.list(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entry is Directory &&
          name.startsWith(_dirPrefix) &&
          entry.path != _ownPath) {
        await _deleteQuietly(entry);
      }
    }
  }

  /// Set to mode 0700, so other users can't read what is played: on Linux
  /// the temp folder is the shared /tmp, and createTemp follows the umask.
  Future<Directory> _sessionDirectory() {
    return _session ??= () async {
      final directory = await (await _tempDirectory()).createTemp(_dirPrefix);
      if (Platform.isLinux || Platform.isMacOS) _restrictToOwner(directory);
      _ownPath = directory.path;
      return directory;
    }();
  }

  /// The video at [source] as a local file, downloaded and hash-checked.
  Future<File> fetch(
    MediaSource source, {
    void Function(int received, int? total)? onProgress,
    DownloadCanceller? canceller,
  }) async {
    final cached = _files.remove(source.url);
    if (cached != null) {
      if (cached.existsSync()) return _files[source.url] = cached;
      _sizes.remove(source.url);
    }

    final directory = await _sessionDirectory();
    final file = await source.fetch((uri) async {
      final extension = extensionOf(uri);
      final target = File(
        '${directory.path}/${_counter++}'
        '${_safeExtension.hasMatch(extension) ? extension : ''}',
      );
      final sink = target.openWrite();
      try {
        await downloadMedia(
          uri,
          maxBytes: maxVideoBytes,
          sha256: source.hashFor(uri),
          timeout: videoTimeout,
          onChunk: sink.add,
          onProgress: onProgress,
          canceller: canceller,
          clientFactory: clientFactory,
        );
        await sink.close();
        return target;
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {
          // The write already failed; the file is deleted next.
        }
        await _deleteQuietly(target);
        rethrow;
      }
    });

    _files[source.url] = file;
    _sizes[source.url] = await file.length();
    await _evict(keep: source.url);
    return file;
  }

  Future<void> _evict({required String keep}) async {
    var total = _sizes.values.fold(0, (sum, size) => sum + size);
    for (final url in _files.keys.toList()) {
      if (total <= cacheBytes) break;
      if (url == keep) continue;
      total -= _sizes.remove(url) ?? 0;
      final evicted = _files.remove(url);
      if (evicted != null) await _deleteQuietly(evicted);
    }
  }

  @visibleForTesting
  int get cachedCount => _files.length;
}
