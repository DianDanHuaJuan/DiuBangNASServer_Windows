import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/ffmpeg_hls_encoder.dart';
import '../../../core/storage/ffmpeg_locator.dart';

class VideoHlsSession {
  const VideoHlsSession({
    required this.id,
    required this.playlistPath,
    required this.seekOffsetMs,
  });

  final String id;
  final String playlistPath;
  final int seekOffsetMs;
}

class VideoHlsSessionService {
  VideoHlsSessionService({
    required String rootPath,
    FfmpegLocator ffmpegLocator = const FfmpegLocator(),
  }) : _sessionRoot = Directory(p.join(rootPath, '.relay', 'preview_hls')),
       _ffmpegLocator = ffmpegLocator;

  final Directory _sessionRoot;
  final FfmpegLocator _ffmpegLocator;
  final Map<String, _ManagedVideoHlsSession> _sessionsBySourceKey =
      <String, _ManagedVideoHlsSession>{};
  final Map<String, _ManagedVideoHlsSession> _sessionsById =
      <String, _ManagedVideoHlsSession>{};
  int _nextSessionId = 0;

  static const Duration _startupTimeout = Duration(seconds: 30);
  static const Duration _assetWaitTimeout = Duration(seconds: 2);
  static const Duration _sessionTtl = Duration(minutes: 20);
  static const Duration _pollInterval = Duration(milliseconds: 250);

  Future<VideoHlsSession> ensureSession({required String sourcePath}) async {
    final session = await _obtainSession(sourcePath: sourcePath);
    try {
      session.startFuture ??= _startSession(session, seekOffsetMs: 0);
      await session.startFuture;
    } catch (_) {
      session.startFuture = null;
      rethrow;
    }

    return VideoHlsSession(
      id: session.id,
      playlistPath: session.playlistPath,
      seekOffsetMs: session.seekOffsetMs,
    );
  }

  /// Restart FFmpeg from [seekOffsetMs] (plan A: seek-restart session).
  Future<VideoHlsSession> seekSession({
    required String sourcePath,
    required int seekOffsetMs,
  }) async {
    final clampedSeekMs = seekOffsetMs < 0 ? 0 : seekOffsetMs;
    final session = await _obtainSession(sourcePath: sourcePath);

    // Serialize seeks on the same session.
    final previous = session.seekFuture;
    final next = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      await _restartSessionAt(session, seekOffsetMs: clampedSeekMs);
    }();
    session.seekFuture = next;
    try {
      await next;
    } finally {
      if (identical(session.seekFuture, next)) {
        session.seekFuture = null;
      }
    }

    return VideoHlsSession(
      id: session.id,
      playlistPath: session.playlistPath,
      seekOffsetMs: session.seekOffsetMs,
    );
  }

  Future<_ManagedVideoHlsSession> _obtainSession({
    required String sourcePath,
  }) async {
    await _cleanupExpiredSessions();

    final sourceFile = File(sourcePath);
    final stat = await sourceFile.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('Video source is not available for HLS transcoding.');
    }

    final sourceKey =
        '$sourcePath|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
    var session = _sessionsBySourceKey[sourceKey];
    if (session == null) {
      final sessionId = 'hls_${++_nextSessionId}';
      final outputDir = Directory(p.join(_sessionRoot.path, sessionId));
      session = _ManagedVideoHlsSession(
        id: sessionId,
        sourceKey: sourceKey,
        sourcePath: sourcePath,
        outputDir: outputDir,
      );
      _sessionsBySourceKey[sourceKey] = session;
      _sessionsById[sessionId] = session;
    }

    session.lastAccessedAt = DateTime.now();
    return session;
  }

  Future<void> _restartSessionAt(
    _ManagedVideoHlsSession session, {
    required int seekOffsetMs,
  }) async {
    await _stopProcess(session);
    session.startFuture = null;
    session.exitCode = null;
    session.lastError = null;
    session.seekOffsetMs = seekOffsetMs;
    session.startFuture = _startSession(session, seekOffsetMs: seekOffsetMs);
    try {
      await session.startFuture;
    } catch (_) {
      session.startFuture = null;
      rethrow;
    }
  }

  Future<String> readPlaylist(String sessionId) async {
    final session = _sessionsById[sessionId];
    if (session == null) {
      throw StateError('HLS session not found.');
    }
    session.lastAccessedAt = DateTime.now();
    return File(session.playlistPath).readAsString();
  }

  Future<File> waitForAsset({
    required String sessionId,
    required String assetName,
  }) async {
    final session = _sessionsById[sessionId];
    if (session == null) {
      throw StateError('HLS session not found.');
    }

    final normalizedAssetName = p.basename(assetName.trim());
    if (normalizedAssetName.isEmpty || normalizedAssetName != assetName.trim()) {
      throw StateError('Invalid HLS asset name.');
    }

    session.lastAccessedAt = DateTime.now();
    final assetFile = File(p.join(session.outputDir.path, normalizedAssetName));
    final deadline = DateTime.now().add(_assetWaitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isCompleteAsset(assetFile)) {
        return assetFile;
      }
      if (session.exitCode != null && session.exitCode != 0) {
        break;
      }
      await Future<void>.delayed(_pollInterval);
    }

    if (await _isCompleteAsset(assetFile)) {
      return assetFile;
    }

    throw StateError(
      session.lastError ?? 'HLS asset is not ready yet for playback.',
    );
  }

  Future<bool> _isCompleteAsset(File assetFile) async {
    if (!await assetFile.exists()) {
      return false;
    }
    final first = await assetFile.stat();
    if (first.size <= 0) {
      return false;
    }
    // Avoid serving a segment still being written by FFmpeg.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!await assetFile.exists()) {
      return false;
    }
    final second = await assetFile.stat();
    return second.size > 0 && second.size == first.size;
  }

  Future<void> _startSession(
    _ManagedVideoHlsSession session, {
    required int seekOffsetMs,
  }) async {
    final ffmpegPath = await _ffmpegLocator.find();
    if (ffmpegPath == null) {
      throw StateError('ffmpeg.exe is not available for video transcoding.');
    }

    await _sessionRoot.create(recursive: true);
    if (await session.outputDir.exists()) {
      await session.outputDir.delete(recursive: true);
    }
    await session.outputDir.create(recursive: true);

    final playlistFile = File(session.playlistPath);
    final videoEncoder = await FfmpegHlsEncoder.resolve(ffmpegPath);
    final startNumber = seekOffsetMs <= 0 ? 0 : (seekOffsetMs / 4000).floor();
    final args = <String>[
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      if (seekOffsetMs > 0) ...<String>[
        '-ss',
        (seekOffsetMs / 1000.0).toStringAsFixed(3),
      ],
      '-i',
      session.sourcePath,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      // Preview ladder: keep encode fast enough for seek-restart.
      '-vf',
      "scale='min(1280,iw)':-2",
      ...FfmpegHlsEncoder.videoEncoderArgs(videoEncoder),
      '-c:a',
      'aac',
      '-b:a',
      '96k',
      '-ac',
      '2',
      '-f',
      'hls',
      '-hls_time',
      '4',
      '-hls_list_size',
      '0',
      '-hls_playlist_type',
      'event',
      '-hls_flags',
      'independent_segments+append_list+temp_file',
      '-start_number',
      '$startNumber',
      '-hls_segment_filename',
      p.join(session.outputDir.path, 'segment_%05d.ts'),
      playlistFile.path,
    ];

    final process = await Process.start(
      ffmpegPath,
      args,
      workingDirectory: session.outputDir.path,
    );

    session.process = process;
    session.stderrFuture = process.stderr.transform(utf8.decoder).join();
    unawaited(process.stdout.drain<void>());
    unawaited(_watchProcessExit(session));

    await _waitUntilSessionReady(session);
  }

  Future<void> _stopProcess(_ManagedVideoHlsSession session) async {
    final process = session.process;
    if (process == null) {
      return;
    }
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
    session.process = null;
  }

  Future<void> _watchProcessExit(_ManagedVideoHlsSession session) async {
    final process = session.process;
    if (process == null) {
      return;
    }

    final exitCode = await process.exitCode;
    session.exitCode = exitCode;
    final stderr = (await session.stderrFuture)?.trim();
    session.lastError = stderr == null || stderr.isEmpty ? null : stderr;
    session.process = null;
  }

  Future<void> _waitUntilSessionReady(_ManagedVideoHlsSession session) async {
    final deadline = DateTime.now().add(_startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _playlistHasPlayableSegments(session.playlistPath)) {
        return;
      }
      if (session.exitCode != null) {
        break;
      }
      await Future<void>.delayed(_pollInterval);
    }

    if (await _playlistHasPlayableSegments(session.playlistPath)) {
      return;
    }

    throw StateError(
      session.lastError ?? 'HLS playlist did not become ready in time.',
    );
  }

  Future<bool> _playlistHasPlayableSegments(String playlistPath) async {
    final playlistFile = File(playlistPath);
    if (!await playlistFile.exists()) {
      return false;
    }

    final content = await playlistFile.readAsString();
    for (final rawLine in LineSplitter.split(content)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      return true;
    }
    return false;
  }

  Future<void> _cleanupExpiredSessions() async {
    final now = DateTime.now();
    final expiredSessions = _sessionsById.values
        .where((session) => now.difference(session.lastAccessedAt) > _sessionTtl)
        .toList(growable: false);

    for (final session in expiredSessions) {
      await _stopProcess(session);
      _sessionsById.remove(session.id);
      _sessionsBySourceKey.remove(session.sourceKey);
      if (await session.outputDir.exists()) {
        await session.outputDir.delete(recursive: true);
      }
    }
  }
}

class _ManagedVideoHlsSession {
  _ManagedVideoHlsSession({
    required this.id,
    required this.sourceKey,
    required this.sourcePath,
    required this.outputDir,
  });

  final String id;
  final String sourceKey;
  final String sourcePath;
  final Directory outputDir;

  Future<void>? startFuture;
  Future<void>? seekFuture;
  Future<String>? stderrFuture;
  Process? process;
  int? exitCode;
  String? lastError;
  int seekOffsetMs = 0;
  DateTime lastAccessedAt = DateTime.now();

  String get playlistPath => p.join(outputDir.path, 'playlist.m3u8');
}
