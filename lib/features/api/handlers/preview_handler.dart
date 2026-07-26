// 文件输入：FileSystemService, ContentTypeResolver
// 文件职责：处理 GET /api/v1/preview/meta 请求，返回预览元信息
// 文件对外接口：PreviewHandler
// 文件包含：PreviewHandler
import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../../../core/auth/auth_headers.dart';
import '../../../core/storage/ffmpeg_duration_probe.dart';
import '../../webdav/resolvers/dav_resource_resolver.dart';
import '../../webdav/utils/content_type_resolver.dart';

class PreviewHandler {
  PreviewHandler({
    required DavResourceResolver resourceResolver,
    required ContentTypeResolver contentTypeResolver,
    bool mediaLibraryEnabled = false,
    bool imagePreviewEnabled = true,
    bool videoPreviewEnabled = true,
    bool progressiveVideoPreviewEnabled = true,
    bool hlsVideoPreviewEnabled = false,
    bool transcodeVideoPreviewEnabled = false,
    bool thumbnailEnabled = true,
  }) : _resourceResolver = resourceResolver,
       _contentTypeResolver = contentTypeResolver,
       _mediaLibraryEnabled = mediaLibraryEnabled,
       _imagePreviewEnabled = imagePreviewEnabled,
       _videoPreviewEnabled = videoPreviewEnabled,
       _progressiveVideoPreviewEnabled = progressiveVideoPreviewEnabled,
       _hlsVideoPreviewEnabled = hlsVideoPreviewEnabled,
       _transcodeVideoPreviewEnabled = transcodeVideoPreviewEnabled,
       _thumbnailEnabled = thumbnailEnabled,
       _unsupportedResponse = const {
         'kind': null,
         'strategy': 'unsupported',
         'url': null,
         'headers': null,
         'contentType': null,
         'size': null,
         'thumbnailUrl': null,
         'posterUrl': null,
         'expiresAt': null,
       };

  final DavResourceResolver _resourceResolver;
  final ContentTypeResolver _contentTypeResolver;
  final bool _mediaLibraryEnabled;
  final bool _imagePreviewEnabled;
  final bool _videoPreviewEnabled;
  final bool _progressiveVideoPreviewEnabled;
  final bool _hlsVideoPreviewEnabled;
  final bool _transcodeVideoPreviewEnabled;
  final bool _thumbnailEnabled;
  final Map<String, dynamic> _unsupportedResponse;

  static const _supportedImageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
  };
  static const _supportedVideoExtensions = {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.webm',
    '.3gp',
  };

  Handler get handler {
    return (Request request) async {
      final rawPath = request.url.queryParameters['path'];

      if (rawPath == null || rawPath.trim().isEmpty) {
        return Response(
          400,
          body: jsonEncode({
            'code': 'INVALID_PARAMS',
            'message': 'Missing path parameter',
            'details': {},
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final pathParam = _normalizePath(rawPath);

      if (!_isSupportedRoot(pathParam)) {
        return Response(
          400,
          body: jsonEncode({
            'code': 'INVALID_PARAMS',
            'message': 'Path must start with ${_describeSupportedRoots()}',
            'details': {},
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final resource = await _resourceResolver.resolve(pathParam);
      if (resource == null) {
        return Response(
          404,
          body: jsonEncode({
            'code': 'PATH_NOT_FOUND',
            'message': 'Resource not found',
            'details': {},
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (resource.isDirectory) {
        return Response.ok(
          jsonEncode(_unsupportedResponse),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final extension = _getFileExtension(pathParam);
      final kind = _resolveKind(extension);

      if (kind == null) {
        return Response.ok(
          jsonEncode(_unsupportedResponse),
          headers: {'Content-Type': 'application/json'},
        );
      }
      final strategy = _resolveStrategy(kind, extension);
      if (strategy == null) {
        return Response.ok(
          jsonEncode(_unsupportedResponse),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final authHeader = request.headers['Authorization']?.trim();
      final deviceId = request.headers[deviceIdHeaderName]?.trim();
      final headers = <String, String>{};
      if (authHeader != null && authHeader.isNotEmpty) {
        headers['Authorization'] = authHeader;
      }
      if (deviceId != null && deviceId.isNotEmpty) {
        headers[deviceIdHeaderName] = deviceId;
      }
      final thumbnailUrl = _thumbnailEnabled
          ? _buildApiUrl(
              request: request,
              path: '/api/v1/thumbnail',
              queryParameters: {'path': pathParam, 'type': 'grid'},
            )
          : null;
      final response = <String, dynamic>{
        'kind': kind,
        'strategy': strategy,
        'url': _resolvePreviewUrl(
          request: request,
          pathParam: pathParam,
          kind: kind,
          strategy: strategy,
        ),
        'headers': headers.isEmpty ? null : headers,
        'contentType':
            resource.contentType ?? _contentTypeResolver.resolve(extension),
        'size': resource.size,
        'thumbnailUrl': thumbnailUrl,
        'posterUrl': kind == 'video' && _thumbnailEnabled
            ? _buildApiUrl(
                request: request,
                path: '/api/v1/thumbnail',
                queryParameters: {'path': pathParam, 'type': 'preview'},
              )
            : null,
        'expiresAt': null,
      };

      // HLS EVENT playlists only expose encoded segments so far; give clients
      // the real source duration for scrubber UI.
      if (strategy == 'hls' && resource.sourceRef != null) {
        final durationMs = await probeDurationMs(resource.sourceRef!);
        if (durationMs != null) {
          response['durationMs'] = durationMs;
        }
      }

      return Response.ok(
        jsonEncode(response),
        headers: {'Content-Type': 'application/json'},
      );
    };
  }

  String _normalizePath(String pathParam) {
    final trimmed = pathParam.trim();
    if (trimmed.isEmpty) {
      return '/';
    }
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }

  bool _isSupportedRoot(String path) {
    if (path == '/fs' || path.startsWith('/fs/')) {
      return true;
    }
    if (_mediaLibraryEnabled &&
        (path == '/library' || path.startsWith('/library/'))) {
      return true;
    }
    return false;
  }

  String? _resolveKind(String extension) {
    if (_imagePreviewEnabled && _supportedImageExtensions.contains(extension)) {
      return 'image';
    }
    if (_videoPreviewEnabled && _supportedVideoExtensions.contains(extension)) {
      return 'video';
    }
    return null;
  }

  String? _resolveStrategy(String kind, String extension) {
    return switch (kind) {
      'image' => 'direct',
      'video' => _resolveVideoStrategy(extension),
      _ => null,
    };
  }

  String? _resolveVideoStrategy(String extension) {
    if (_hlsVideoPreviewEnabled && _shouldUseHlsTranscode(extension)) {
      return 'hls';
    }
    if (_progressiveVideoPreviewEnabled) {
      return 'progressive';
    }
    if (_transcodeVideoPreviewEnabled && _hlsVideoPreviewEnabled) {
      return 'hls';
    }
    return null;
  }

  bool _shouldUseHlsTranscode(String extension) {
    if (!_transcodeVideoPreviewEnabled) {
      return false;
    }
    return extension != '.mp4';
  }

  String _resolvePreviewUrl({
    required Request request,
    required String pathParam,
    required String kind,
    required String strategy,
  }) {
    if (kind == 'image' && _thumbnailEnabled) {
      return _buildApiUrl(
        request: request,
        path: '/api/v1/thumbnail',
        queryParameters: <String, String>{'path': pathParam, 'type': 'preview'},
      );
    }
    if (strategy == 'hls') {
      return _buildApiUrl(
        request: request,
        path: '/api/v1/preview/hls/manifest.m3u8',
        queryParameters: <String, String>{'path': pathParam},
      );
    }
    return _buildApiUrl(request: request, path: '/dav$pathParam');
  }

  String _describeSupportedRoots() {
    return _mediaLibraryEnabled ? '/fs or /library' : '/fs';
  }

  String _buildApiUrl({
    required Request request,
    required String path,
    Map<String, String>? queryParameters,
  }) {
    final requestUri = request.requestedUri;
    return Uri(
      scheme: requestUri.scheme,
      userInfo: requestUri.userInfo,
      host: requestUri.host,
      port: requestUri.hasPort ? requestUri.port : null,
      path: path,
      queryParameters: queryParameters,
    ).toString();
  }

  String _getFileExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot == -1) return '';
    return path.substring(lastDot).toLowerCase();
  }
}
