import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../webdav/resolvers/dav_resource_resolver.dart';
import '../../webdav/resources/dav_resource.dart';
import '../services/video_hls_session_service.dart';

class PreviewHlsHandler {
  PreviewHlsHandler({
    required DavResourceResolver resourceResolver,
    VideoHlsSessionService? sessionService,
  }) : _resourceResolver = resourceResolver,
       _sessionService = sessionService;

  final DavResourceResolver _resourceResolver;
  final VideoHlsSessionService? _sessionService;

  Future<Response> manifest(Request request) async {
    final sessionService = _sessionService;
    if (sessionService == null) {
      return _errorResponse(
        501,
        'TRANSCODE_DISABLED',
        'Video transcoding is not available on this server.',
      );
    }

    final rawPath = request.url.queryParameters['path'];
    if (rawPath == null || rawPath.trim().isEmpty) {
      return _errorResponse(
        400,
        'INVALID_PARAMS',
        'Missing path parameter.',
      );
    }

    final resource = await _resolvePlayableResource(rawPath);
    if (resource == null || resource.isDirectory || resource.sourceRef == null) {
      return _errorResponse(404, 'PATH_NOT_FOUND', 'Video resource not found.');
    }

    try {
      final session = await sessionService.ensureSession(
        sourcePath: resource.sourceRef!,
      );
      final rawPlaylist = await sessionService.readPlaylist(session.id);
      final body = _rewritePlaylist(
        request: request,
        sessionId: session.id,
        rawPlaylist: rawPlaylist,
      );
      final bytes = utf8.encode(body);
      return Response.ok(
        body,
        headers: <String, String>{
          'Content-Type': 'application/vnd.apple.mpegurl',
          'Content-Length': bytes.length.toString(),
          'Cache-Control': 'no-store',
        },
      );
    } on StateError catch (error) {
      return _errorResponse(503, 'TRANSCODE_UNAVAILABLE', error.message);
    } catch (error) {
      return _errorResponse(500, 'INTERNAL_ERROR', error.toString());
    }
  }

  Future<Response> seek(Request request) async {
    final sessionService = _sessionService;
    if (sessionService == null) {
      return _errorResponse(
        501,
        'TRANSCODE_DISABLED',
        'Video transcoding is not available on this server.',
      );
    }

    final rawPath = request.url.queryParameters['path'];
    final rawTMs = request.url.queryParameters['tMs'];
    if (rawPath == null || rawPath.trim().isEmpty) {
      return _errorResponse(
        400,
        'INVALID_PARAMS',
        'Missing path parameter.',
      );
    }
    final tMs = int.tryParse(rawTMs ?? '');
    if (tMs == null || tMs < 0) {
      return _errorResponse(
        400,
        'INVALID_PARAMS',
        'Missing or invalid tMs parameter.',
      );
    }

    final resource = await _resolvePlayableResource(rawPath);
    if (resource == null || resource.isDirectory || resource.sourceRef == null) {
      return _errorResponse(404, 'PATH_NOT_FOUND', 'Video resource not found.');
    }

    try {
      final session = await sessionService.seekSession(
        sourcePath: resource.sourceRef!,
        seekOffsetMs: tMs,
      );
      return Response.ok(
        jsonEncode(<String, Object?>{
          'sessionId': session.id,
          'seekOffsetMs': session.seekOffsetMs,
        }),
        headers: const <String, String>{
          'Content-Type': 'application/json',
          'Cache-Control': 'no-store',
        },
      );
    } on StateError catch (error) {
      return _errorResponse(503, 'TRANSCODE_UNAVAILABLE', error.message);
    } catch (error) {
      return _errorResponse(500, 'INTERNAL_ERROR', error.toString());
    }
  }

  Future<Response> asset(Request request) async {
    final sessionService = _sessionService;
    if (sessionService == null) {
      return _errorResponse(
        501,
        'TRANSCODE_DISABLED',
        'Video transcoding is not available on this server.',
      );
    }

    final sessionId = request.params['sessionId']?.trim() ?? '';
    final assetName = request.params['asset']?.trim() ?? '';
    if (sessionId.isEmpty || assetName.isEmpty) {
      return _errorResponse(
        400,
        'INVALID_PARAMS',
        'Missing HLS session or asset name.',
      );
    }

    try {
      final file = await sessionService.waitForAsset(
        sessionId: sessionId,
        assetName: assetName,
      );
      final stat = await file.stat();
      return Response.ok(
        file.openRead(),
        headers: <String, String>{
          'Content-Type': _resolveAssetContentType(assetName),
          'Content-Length': stat.size.toString(),
          'Cache-Control': 'no-store',
        },
      );
    } on StateError catch (error) {
      return _errorResponse(404, 'PATH_NOT_FOUND', error.message);
    } catch (error) {
      return _errorResponse(500, 'INTERNAL_ERROR', error.toString());
    }
  }

  Future<DavResource?> _resolvePlayableResource(String rawPath) {
    final normalizedPath = rawPath.trim().startsWith('/')
        ? rawPath.trim()
        : '/${rawPath.trim()}';
    return _resourceResolver.resolve(normalizedPath);
  }

  String _rewritePlaylist({
    required Request request,
    required String sessionId,
    required String rawPlaylist,
  }) {
    final buffer = StringBuffer();
    for (final rawLine in LineSplitter.split(rawPlaylist)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        buffer.writeln(rawLine);
        continue;
      }

      final assetName = Uri.decodeComponent(line.split('/').last.trim());
      buffer.writeln(
        _buildAssetUrl(request: request, sessionId: sessionId, assetName: assetName),
      );
    }
    return buffer.toString();
  }

  String _buildAssetUrl({
    required Request request,
    required String sessionId,
    required String assetName,
  }) {
    final requestUri = request.requestedUri;
    return Uri(
      scheme: requestUri.scheme,
      userInfo: requestUri.userInfo,
      host: requestUri.host,
      port: requestUri.hasPort ? requestUri.port : null,
      path:
          '/api/v1/preview/hls/asset/$sessionId/${Uri.encodeComponent(assetName)}',
    ).toString();
  }

  String _resolveAssetContentType(String assetName) {
    final lowerCaseName = assetName.toLowerCase();
    if (lowerCaseName.endsWith('.m3u8')) {
      return 'application/vnd.apple.mpegurl';
    }
    if (lowerCaseName.endsWith('.ts')) {
      return 'video/mp2t';
    }
    return 'application/octet-stream';
  }

  Response _errorResponse(int status, String code, String message) {
    return Response(
      status,
      body: jsonEncode(<String, Object?>{
        'code': code,
        'message': message,
        'details': <String, Object?>{},
      }),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );
  }
}
