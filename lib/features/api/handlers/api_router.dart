// 文件输入：shelf_router, BootstrapHandler, DashboardHandler, PreviewHandler, ThumbnailHandler, BatchThumbnailHandler, BatchDeleteHandler
// 文件职责：注册所有控制面 API 路由，将 /api/v1/* 路径映射到对应 Handler
// 文件对外接口：ApiRouter
// 文件包含：ApiRouter
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'batch_delete_handler.dart';
import 'backup_preflight_handler.dart';
import 'batch_thumbnail_handler.dart';
import 'bootstrap_handler.dart';
import 'device_profile_api_handler.dart';
import 'device_api_handler.dart';
import 'dashboard_handler.dart';
import 'file_list_handler.dart';
import 'preview_handler.dart';
import 'preview_hls_handler.dart';
import 'thumbnail_handler.dart';
import '../../benchmark/handlers/benchmark_api_router.dart';
import '../../relay/handlers/relay_api_router.dart';
import '../../realtime/handlers/realtime_ws_handler.dart';

class ApiRouter {
  ApiRouter({
    required BootstrapHandler bootstrapHandler,
    required DashboardHandler dashboardHandler,
    required BackupPreflightHandler backupPreflightHandler,
    required FileListHandler fileListHandler,
    required PreviewHandler previewHandler,
    required PreviewHlsHandler previewHlsHandler,
    required ThumbnailHandler thumbnailHandler,
    required BatchThumbnailHandler batchThumbnailHandler,
    required BatchDeleteHandler batchDeleteHandler,
    required RealtimeWsHandler realtimeWsHandler,
    required RelayApiRouter relayApiRouter,
    required DeviceApiHandler deviceApiHandler,
    required DeviceProfileApiHandler deviceProfileApiHandler,
    BenchmarkApiRouter? benchmarkApiRouter,
  }) : _bootstrapHandler = bootstrapHandler,
       _dashboardHandler = dashboardHandler,
       _backupPreflightHandler = backupPreflightHandler,
       _fileListHandler = fileListHandler,
       _previewHandler = previewHandler,
       _previewHlsHandler = previewHlsHandler,
       _thumbnailHandler = thumbnailHandler,
       _batchThumbnailHandler = batchThumbnailHandler,
       _batchDeleteHandler = batchDeleteHandler,
       _realtimeWsHandler = realtimeWsHandler,
       _relayApiRouter = relayApiRouter,
       _deviceApiHandler = deviceApiHandler,
       _deviceProfileApiHandler = deviceProfileApiHandler,
       _benchmarkApiRouter = benchmarkApiRouter;

  final BootstrapHandler _bootstrapHandler;
  final DashboardHandler _dashboardHandler;
  final BackupPreflightHandler _backupPreflightHandler;
  final FileListHandler _fileListHandler;
  final PreviewHandler _previewHandler;
  final PreviewHlsHandler _previewHlsHandler;
  final ThumbnailHandler _thumbnailHandler;
  final BatchThumbnailHandler _batchThumbnailHandler;
  final BatchDeleteHandler _batchDeleteHandler;
  final RealtimeWsHandler _realtimeWsHandler;
  final RelayApiRouter _relayApiRouter;
  final DeviceApiHandler _deviceApiHandler;
  final DeviceProfileApiHandler _deviceProfileApiHandler;
  final BenchmarkApiRouter? _benchmarkApiRouter;

  Handler get handler {
    final router = Router();

    router.get('/bootstrap', _bootstrapHandler.handler);
    router.mount('/me/', _deviceProfileApiHandler.handler);
    router.mount('/devices/', _deviceApiHandler.handler);
    router.get('/dashboard', _dashboardHandler.handler);
    router.post('/backup/preflight', _backupPreflightHandler.handle);
    router.get('/files/list', _fileListHandler.handle);
    router.get('/preview/meta', _previewHandler.handler);
    router.get('/preview/hls/manifest.m3u8', _previewHlsHandler.manifest);
    router.post('/preview/hls/seek', _previewHlsHandler.seek);
    router.get('/preview/hls/asset/<sessionId>/<asset|.*>', _previewHlsHandler.asset);
    router.get('/thumbnail', _thumbnailHandler.handler);
    router.post('/thumbnails/batch', _batchThumbnailHandler.handler);
    router.post('/files/batch-delete', _batchDeleteHandler.handle);
    router.get('/realtime/ws', _realtimeWsHandler.handler);
    router.mount('/relay/', _relayApiRouter.handler);
    final benchmarkApiRouter = _benchmarkApiRouter;
    if (benchmarkApiRouter != null) {
      router.mount('/debug/benchmark/', benchmarkApiRouter.handler);
    }

    router.all('/<ignored|.*>', (request) {
      return Response.notFound(
        '{"code":"PATH_NOT_FOUND","message":"API endpoint not found","details":{}}',
        headers: {'Content-Type': 'application/json'},
      );
    });

    return router.call;
  }
}
