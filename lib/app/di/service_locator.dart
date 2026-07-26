// 文件输入：所有 Repository、DataSource、UseCase、Cubit、Service 的具体实现
// 文件职责：集中注册所有依赖关系，提供全局依赖获取入口
// 文件对外接口：setupServiceLocator()
// 文件包含：setupServiceLocator 函数
import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/desktop/desktop_runtime_controller.dart';
import '../../core/platform/app_platform.dart';
import '../../core/platform/app_storage_paths.dart';
import '../../core/startup/startup_telemetry.dart';
import '../../core/auth/auth_session_store.dart';
import '../../core/auth/bearer_auth_middleware.dart';
import '../../core/auth/owner_credential_store.dart';
import '../../core/device_registry/device_models.dart';
import '../../core/device_registry/device_store.dart';
import '../../core/device_registry/device_avatar_store.dart';
import '../../core/device_registry/device_registry_admin.dart';
import '../../core/profile/device_identity_store.dart';
import '../../core/runtime/runtime_build_info.dart';
import '../../core/runtime/runtime_presence_bridge.dart';
import '../../core/storage/key_value_store.dart';
import '../../core/storage/file_system_service.dart';
import '../../core/storage/file_index_service.dart';
import '../../core/storage/backup_catalog_service.dart';
import '../../core/storage/media_store_service.dart';
import '../../core/storage/ffmpeg_locator.dart';
import '../../core/storage/thumbnail_service.dart';
import '../../core/storage/thumbnail_warmup_service.dart';
import '../../core/storage/thumbnail_concurrency_limiter.dart';
import '../../core/device/local_network_address_service.dart';
import '../../core/device/network_info_helper.dart';
import '../../core/device/nsd_manager_plugin.dart';
import '../../core/device/permission_service.dart';
import '../../core/device/battery_optimization_service.dart';
import '../../core/device/device_info_service.dart';
import '../../core/device/mdns_runtime_status.dart';
import '../../core/device/system_info_service.dart';
import '../../core/device/system_status_cache.dart';
import '../../core/tls/server_tls_manager.dart';
import '../../features/benchmark/benchmark_feature.dart';
import '../../features/pairing/application/pairing_service.dart';
import '../../features/pairing/handlers/pairing_handler.dart';
import '../../features/server/data/datasources/http_server_data_source.dart';
import '../../features/server/data/datasources/server_activity_tracker.dart';
import '../../features/server/data/repositories/server_repository_impl.dart';
import '../../features/server/domain/repositories/server_repository.dart';
import '../../features/server/application/use_cases/start_server_use_case.dart';
import '../../features/server/application/use_cases/stop_server_use_case.dart';
import '../../features/server/presentation/cubit/server_cubit.dart';
import '../../features/settings/application/use_cases/load_server_settings_use_case.dart';
import '../../features/settings/application/use_cases/update_server_settings_use_case.dart';
import '../../features/settings/data/datasources/settings_local_data_source.dart';
import '../../features/settings/data/repositories/settings_repository_impl.dart';
import '../../features/settings/domain/entities/settings_apply_status.dart';
import '../../features/settings/domain/entities/server_settings_entity.dart';
import '../../features/settings/domain/repositories/settings_repository.dart';
import '../../features/settings/presentation/cubit/settings_cubit.dart';
import '../../features/api/handlers/api_router.dart';
import '../../features/api/handlers/auth_router.dart';
import '../../features/api/handlers/auth_session_handler.dart';
import '../../features/api/handlers/credential_device_enroll_handler.dart';
import '../../features/api/handlers/batch_delete_handler.dart';
import '../../features/api/handlers/backup_preflight_handler.dart';
import '../../features/api/handlers/batch_thumbnail_handler.dart';
import '../../features/api/handlers/bootstrap_handler.dart';
import '../../features/api/handlers/dashboard_handler.dart';
import '../../features/api/handlers/dashboard_payload_builder.dart';
import '../../features/api/handlers/device_api_handler.dart';
import '../../features/api/handlers/device_profile_api_handler.dart';
import '../../features/api/handlers/device_refresh_handler.dart';
import '../../features/api/handlers/file_list_handler.dart';
import '../../features/api/handlers/preview_handler.dart';
import '../../features/api/handlers/preview_hls_handler.dart';
import '../../features/api/handlers/thumbnail_handler.dart';
import '../../features/api/services/video_hls_session_service.dart';
import '../../features/relay/data/relay_realtime_publisher.dart';
import '../../features/relay/data/relay_service.dart';
import '../../features/relay/data/relay_temp_storage_manager.dart';
import '../../features/relay/data/relay_transfer_repository.dart';
import '../../features/relay/data/sqlite_relay_transfer_repository.dart';
import '../../features/relay/handlers/relay_api_handler.dart';
import '../../features/relay/handlers/relay_api_router.dart';
import '../../features/relay/handlers/relay_webdav_handler.dart';
import '../../features/relay/handlers/relay_webdav_router.dart';
import '../../features/relay/relay_contract.dart';
import '../../features/realtime/data/realtime_connection_registry.dart';
import '../../features/realtime/data/realtime_event_hub.dart';
import '../../features/realtime/data/realtime_presence_repository.dart';
import '../../features/realtime/data/realtime_snapshot_builder.dart';
import '../../features/realtime/data/realtime_status_publisher.dart';
import '../../features/realtime/data/unified_node_registry.dart';
import '../../features/realtime/handlers/realtime_ws_handler.dart';
import '../../features/realtime/realtime_contract.dart';
import '../../features/webdav/middleware/webdav_method_router.dart';
import '../../features/webdav/utils/content_type_resolver.dart';
import '../../features/webdav/resolvers/composite_dav_resource_resolver.dart';
import '../../features/webdav/resolvers/file_system_dav_resource_resolver.dart';
import '../../features/webdav/resolvers/media_library_dav_resource_resolver.dart';
import '../../features/webdav/readers/composite_content_reader.dart';
import '../../features/webdav/readers/file_system_content_reader.dart';
import '../../features/webdav/readers/media_store_content_reader.dart';
import '../../features/media_library/data/datasources/media_store_query_data_source.dart';
import '../../features/media_library/data/repositories/media_library_repository_impl.dart';
import '../../features/media_library/data/cache/media_library_cache.dart';
import '../../features/media_library/data/services/media_change_service.dart';
import '../../features/device_identity/domain/server_device_identity_service.dart';
import '../../features/server/data/datasources/foreground_service_data_source.dart';

class ServiceLocator {
  static late final SharedPreferences _prefs;
  static late final OwnerCredentialStore ownerCredentialStore;
  static late final DeviceStore deviceStore;
  static DeviceRegistryAdmin? _deviceRegistryAdmin;
  static AuthSessionStore? authSessionStore;
  static late final KeyValueStore keyValueStore;
  static late final FileSystemService fileSystemService;
  static late final SettingsLocalDataSource settingsLocalDataSource;
  static late final SettingsRepository settingsRepository;
  static late final LoadServerSettingsUseCase loadServerSettingsUseCase;
  static late final UpdateServerSettingsUseCase updateServerSettingsUseCase;
  static late final MediaStoreService mediaStoreService;
  static ThumbnailService? thumbnailService;
  static ThumbnailWarmupService? thumbnailWarmupService;
  static late final NetworkInfoHelper networkInfoHelper;
  static late final LocalNetworkAddressService localNetworkAddressService;
  static late final PermissionService permissionService;
  static late final BatteryOptimizationService batteryOptimizationService;
  static late final DeviceInfoService deviceInfoService;
  static late final SystemInfoService systemInfoService;
  static SystemStatusCache? systemStatusCache;
  static HttpServerDataSource? httpServerDataSource;
  static ServerActivityTracker? serverActivityTracker;
  static bool _areMinimalCoreServicesReady = false;
  static bool _areDeferredCoreServicesReady = false;
  static Completer<void>? _minimalCoreServicesCompleter;
  static Completer<void>? _deferredCoreServicesCompleter;
  static final ServerTlsManager serverTlsManager = ServerTlsManager();
  static ServerTlsMaterial? _serverTlsMaterial;
  static late final ForegroundServiceDataSource foregroundServiceDataSource;
  static late final MediaChangeService mediaChangeService;
  static MediaLibraryCache? mediaLibraryCache;
  static RealtimeConnectionRegistry? realtimeConnectionRegistry;
  static UnifiedNodeRegistry? realtimeNodeRegistry;
  static RealtimePresenceRepository? realtimePresenceRepository;
  static RealtimeEventHub? realtimeEventHub;
  static RealtimeStatusPublisher? realtimeStatusPublisher;
  static RelayTransferRepository? relayTransferRepository;
  static RelayTempStorageManager? relayTempStorageManager;
  static RelayRealtimePublisher? relayRealtimePublisher;
  static RelayService? relayService;
  static FileIndexService? fileIndexService;
  static BackupCatalogService? backupCatalogService;
  static final ValueNotifier<bool> localFileServicesReady = ValueNotifier(false);
  static final ValueNotifier<SettingsApplyStatus> settingsApplyStatus =
      ValueNotifier(SettingsApplyStatus.idle);
  static late final ServerRepository serverRepository;
  static late final StartServerUseCase startServerUseCase;
  static late final StopServerUseCase stopServerUseCase;
  static late final ServerCubitImpl serverCubit;
  static DeviceAvatarStore? _deviceAvatarStore;
  static ServerDeviceIdentityService? _serverDeviceIdentityService;

  static DeviceAvatarStore get deviceAvatarStore {
    final avatarDirectoryPath = AppStoragePaths.cachedDeviceAvatarDirectory;
    if (avatarDirectoryPath == null || avatarDirectoryPath.isEmpty) {
      throw StateError(
        'Device avatar directory is not initialized. Call ServiceLocator.setup() first.',
      );
    }
    return _deviceAvatarStore ??= DeviceAvatarStore(
      avatarDirectoryPath: avatarDirectoryPath,
    );
  }

  static ServerDeviceIdentityService get serverDeviceIdentityService {
    return _serverDeviceIdentityService ??= ServerDeviceIdentityService(
      deviceStore: deviceStore,
      avatarStore: deviceAvatarStore,
      identityStore: DeviceIdentityStore(keyValueStore: keyValueStore),
      deviceInfoService: deviceInfoService,
      presenceRepository: realtimePresenceRepository,
      onBroadcastNameChanged: _onBroadcastNameCandidate,
      onProfileChanged: () {
        realtimeStatusPublisher?.publishPresenceChanged();
      },
    );
  }

  static DeviceRegistryAdmin get deviceRegistryAdmin {
    return _deviceRegistryAdmin ??= DeviceRegistryAdmin(
      deviceStore: deviceStore,
      ownsServerRuntime: () => realtimeStatusPublisher != null,
      isForegroundServiceRunning: () async {
        if (!AppPlatform.supportsForegroundService) {
          return false;
        }
        return foregroundServiceDataSource.isForegroundServiceRunning();
      },
    );
  }

  static const String _defaultServerName = '铥棒文件S';
  static const String _serverVersion = RuntimeBuildInfo.appVersion;
  static const int _defaultServerPort = 8080;
  static const int _defaultBenchmarkHttpPort = 8081;
  static const int _thumbnailMaxConcurrent = 20;

  static ThumbnailConcurrencyLimiter? thumbnailConcurrencyLimiter;

  static String? _localIp;
  static DateTime? _startedAt;
  static bool _isSetupComplete = false;
  static bool _isServerRuntimeRunning = false;
  static Future<void>? _runtimeTransition;
  static bool _mdnsRegistered = false;
  static MdnsRuntimeStatus _mdnsRuntimeStatus = const MdnsRuntimeStatus.idle(
    summary: '未广播',
    details: '服务未启动',
  );
  static ServerSettingsEntity _currentServerSettings =
      const ServerSettingsEntity(
        port: _defaultServerPort,
        serverName: _defaultServerName,
        storagePath: '',
      );

  static Future<void> setup({
    bool initializeForegroundService = true,
    bool initializeHeavyServices = true,
    OwnerCredentialStore? ownerCredentialStoreOverride,
    DeviceStore? deviceStoreOverride,
    DeviceInfoService? deviceInfoServiceOverride,
    String? defaultStoragePathOverride,
    String? localHostnameOverride,
  }) async {
    _isSetupComplete = false;
    _setMdnsRuntimeStatus(
      const MdnsRuntimeStatus.idle(summary: '未广播', details: '服务未启动'),
    );
    _prefs = await SharedPreferences.getInstance();
    if (defaultStoragePathOverride != null) {
      AppStoragePaths.seedDefaultStoragePathForTests(defaultStoragePathOverride);
    }
    await AppStoragePaths.warmDefaultStoragePath();
    await AppStoragePaths.warmDeviceAvatarDirectory();
    _deviceAvatarStore = DeviceAvatarStore(
      avatarDirectoryPath: AppStoragePaths.cachedDeviceAvatarDirectory!,
    );

    ownerCredentialStore =
        ownerCredentialStoreOverride ?? OwnerCredentialStore();
    deviceStore = deviceStoreOverride ?? DeviceStore();

    keyValueStore = KeyValueStore(sharedPreferences: _prefs);
    fileSystemService = FileSystemService();

    settingsLocalDataSource = SettingsLocalDataSource(
      keyValueStore: keyValueStore,
    );
    settingsRepository = SettingsRepositoryImpl(
      localDataSource: settingsLocalDataSource,
    );
    loadServerSettingsUseCase = LoadServerSettingsUseCase(settingsRepository);
    updateServerSettingsUseCase = UpdateServerSettingsUseCase(
      settingsRepository,
      validateStoragePath: _validateConfiguredStoragePath,
      onSettingsSaved: (settings) async {
        await _applyServerSettingsAfterSave(settings);
      },
    );
    await _reloadServerSettings();
    await _syncBroadcastNameFromIdentity();

    // 文件迁移放到后台执行，避免阻塞窗口显示
    if (initializeHeavyServices) {
      try {
        await fileSystemService.migratePercentEncodedFilenames(
          rootPath: _currentServerSettings.storagePath,
        );
      } catch (_) {}
    }

    mediaStoreService = MediaStoreService();

    networkInfoHelper = NetworkInfoHelper();
    localNetworkAddressService = LocalNetworkAddressService(
      keyValueStore: keyValueStore,
      networkInfoHelper: networkInfoHelper,
    );
    await localNetworkAddressService.initialize();
    permissionService = PermissionService();
    batteryOptimizationService = const BatteryOptimizationService();
    deviceInfoService =
        deviceInfoServiceOverride ??
        DeviceInfoService(
          keyValueStore: keyValueStore,
          localHostnameOverride: localHostnameOverride,
        );
    systemInfoService = SystemInfoService(
      storagePathProvider: () => _currentServerSettings.storagePath,
    );

    systemStatusCache = SystemStatusCache(
      deviceInfoService: deviceInfoService,
      systemInfoService: systemInfoService,
      localNetworkAddressService: localNetworkAddressService,
    );

    foregroundServiceDataSource = ForegroundServiceDataSource();
    if (initializeForegroundService) {
      await foregroundServiceDataSource.initialize();
    }

    mediaChangeService = MediaChangeService();

    serverRepository = ServerRepositoryImpl();

    startServerUseCase = StartServerUseCase(serverRepository);
    stopServerUseCase = StopServerUseCase(serverRepository);

    serverCubit = ServerCubitImpl(
      startServerUseCase: startServerUseCase,
      stopServerUseCase: stopServerUseCase,
      repository: serverRepository,
      localNetworkAddressService: localNetworkAddressService,
    );
    _isSetupComplete = true;

    if (initializeHeavyServices) {
      await _startMinimalCoreServices();
      await _startDeferredCoreServices();
    }
  }

  /// Staged background startup: warm up resident stores & system metrics in
  /// parallel (they have no mutual dependency), then run heavy IO services.
  static Future<void> runDeferredStartup() async {
    await Future.wait<void>([
      StartupTelemetry.timedPhase('warmup_resident', warmupResidentStores),
      StartupTelemetry.timedPhase('warmup_metrics', warmupSystemMetrics),
    ]);
    await StartupTelemetry.timedPhase('heavy_services', startHeavyServices);
  }

  static Future<void> warmupResidentStores() async {
    await Future.wait<void>([
      _warmupStore(
        name: 'owner credential store',
        initializer: ownerCredentialStore.initialize,
      ),
      _warmupStore(name: 'device store', initializer: deviceStore.initialize),
    ]);
  }

  static Future<void> warmupSystemMetrics() async {
    final cache = systemStatusCache;
    if (cache == null) {
      return;
    }
    await _warmupStore(
      name: 'system status cache',
      initializer: cache.initialize,
    );
  }

  static Future<void> _warmupStore({
    required String name,
    required Future<void> Function() initializer,
  }) async {
    try {
      await initializer();
    } catch (error, stackTrace) {
      developer.log(
        'Deferred $name initialization failed',
        name: 'nas_server.startup',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 后台执行耗时的核心服务初始化（文件索引、缩略图等）。
  /// 应在 setup(initializeHeavyServices: false) 且窗口已显示后调用。
  static Future<void> startHeavyServices() async {
    await _startMinimalCoreServices();
    unawaited(_startDeferredCoreServices());
  }

  /// 本地备份目录索引是否已就绪（与 HTTP 服务启停无关）。
  static bool get areLocalFileServicesReady => fileIndexService != null;

  /// 确保文件页所需的本地 catalog / 索引服务已初始化。
  static Future<void> ensureMinimalCoreServices() {
    return _startMinimalCoreServices();
  }

  static void _syncLocalFileServicesReady() {
    localFileServicesReady.value = fileIndexService != null;
  }

  static Future<void> _startMinimalCoreServices() async {
    if (_areMinimalCoreServicesReady) {
      return;
    }

    if (_minimalCoreServicesCompleter != null) {
      await _minimalCoreServicesCompleter!.future;
      if (_areMinimalCoreServicesReady) {
        return;
      }
      // Previous run failed (e.g. empty storage path); fall through to retry.
    }

    _minimalCoreServicesCompleter = Completer<void>();

    try {
      final validatedRootPath = await _prepareCoreServicesRootPath();
      if (validatedRootPath == null) {
        return;
      }

      _setupMediaLibraryAndThumbnailStack(validatedRootPath);

      fileIndexService = FileIndexService(
        rootPath: validatedRootPath,
        databasePath: p.join(
          validatedRootPath,
          relayStorageDirectoryName,
          'file_index.db',
        ),
        recursiveScan: true,
        watchChanges: true,
      );
      await fileIndexService!.initialize(enableWatching: false);

      backupCatalogService = BackupCatalogService(
        rootPath: validatedRootPath,
        databasePath: p.join(
          validatedRootPath,
          relayStorageDirectoryName,
          'backup_catalog.db',
        ),
      );
      await backupCatalogService!.initialize();

      _areMinimalCoreServicesReady = true;
      _syncLocalFileServicesReady();
    } finally {
      _minimalCoreServicesCompleter?.complete();
      _minimalCoreServicesCompleter = null;
    }
  }

  static Future<void> _startDeferredCoreServices() async {
    if (_areDeferredCoreServicesReady) {
      return;
    }

    if (!_areMinimalCoreServicesReady) {
      await _startMinimalCoreServices();
    }

    if (_deferredCoreServicesCompleter != null) {
      await _deferredCoreServicesCompleter!.future;
      if (_areDeferredCoreServicesReady) {
        return;
      }
      // Previous run failed; fall through to retry.
    }

    _deferredCoreServicesCompleter = Completer<void>();

    try {
      final validatedRootPath = _currentServerSettings.storagePath;
      if (validatedRootPath.isEmpty) {
        _areDeferredCoreServicesReady = true;
        return;
      }

      try {
        await fileSystemService.migratePercentEncodedFilenames(
          rootPath: validatedRootPath,
        );
      } catch (_) {}

      final indexService = fileIndexService;
      if (indexService != null) {
        await indexService.enableWatching();
      }

      if (AppPlatform.supportsThumbnails &&
          thumbnailService != null &&
          indexService != null) {
        final warmupService = ThumbnailWarmupService(
          rootPath: validatedRootPath,
          databasePath: p.join(
            validatedRootPath,
            relayStorageDirectoryName,
            'thumbnail_warmup.db',
          ),
          thumbnailService: thumbnailService!,
          fileIndexService: indexService,
          realtimeConnectionRegistry: RealtimeConnectionRegistry(),
        );
        thumbnailWarmupService = warmupService;
        indexService.onPathChanged = (relativePath) {
          return warmupService.handlePathChanged(
            relativePath,
            reason: 'watcher_event',
          );
        };
        await warmupService.initialize(deferInitialScan: true);
      } else {
        thumbnailWarmupService = null;
        indexService?.onPathChanged = null;
      }

      _areDeferredCoreServicesReady = true;
    } finally {
      _deferredCoreServicesCompleter?.complete();
      _deferredCoreServicesCompleter = null;
    }
  }

  static Future<String?> _prepareCoreServicesRootPath() async {
    final rootPath = _currentServerSettings.storagePath;
    if (rootPath.isEmpty) {
      return null;
    }

    final validatedRootPath = await _validateConfiguredStoragePath(rootPath);
    _currentServerSettings = _currentServerSettings.copyWith(
      storagePath: validatedRootPath,
    );
    return validatedRootPath;
  }

  static void _setupMediaLibraryAndThumbnailStack(String validatedRootPath) {
    final mediaLibrarySupported = AppPlatform.supportsMediaLibrary;
    if (thumbnailService != null &&
        (mediaLibraryCache != null || !mediaLibrarySupported)) {
      return;
    }

    MediaLibraryCache? cache;
    if (mediaLibrarySupported) {
      final mediaLibraryQueryDataSource = MediaStoreQueryDataSource(
        mediaStoreService: mediaStoreService,
      );
      final mediaLibraryRepository = MediaLibraryRepositoryImpl(
        queryDataSource: mediaLibraryQueryDataSource,
      );
      cache = MediaLibraryCache(repository: mediaLibraryRepository);
      mediaLibraryCache = cache;
      mediaChangeService.onMediaChanged = () {
        final activeCache = mediaLibraryCache;
        if (activeCache == null) {
          return;
        }
        unawaited(activeCache.refresh());
      };
    }

    thumbnailService = ThumbnailService(
      rootPath: validatedRootPath,
      mediaLibraryLookup: cache,
    );

    thumbnailConcurrencyLimiter = ThumbnailConcurrencyLimiter(
      maxConcurrent: _thumbnailMaxConcurrent,
    );
  }

  static Future<void> _stopCoreServices() async {
    if (!_areMinimalCoreServicesReady && !_areDeferredCoreServicesReady) {
      return;
    }
    _minimalCoreServicesCompleter = null;
    _deferredCoreServicesCompleter = null;
    fileIndexService?.onPathChanged = null;
    final warmupService = thumbnailWarmupService;
    thumbnailWarmupService = null;
    await warmupService?.close();
    await backupCatalogService?.close();
    backupCatalogService = null;
    await fileIndexService?.close();
    fileIndexService = null;
    thumbnailService = null;
    mediaLibraryCache = null;
    thumbnailConcurrencyLimiter = null;
    _areMinimalCoreServicesReady = false;
    _areDeferredCoreServicesReady = false;
    _syncLocalFileServicesReady();
  }

  static Future<void> requestPermissions() async {
    if (!AppPlatform.requiresRuntimePermissions) {
      return;
    }
    await permissionService.requestAllPermissions();
  }

  static Future<void> startServer() async {
    await _syncBroadcastNameFromIdentity();
    final localIp = localNetworkAddressService.effectiveIp?.trim() ?? '';
    if (localIp.isEmpty) {
      throw StateError('未选择可用的局域网 IP 地址');
    }
    final currentSettings = _currentServerSettings;
    if (AppPlatform.supportsForegroundService) {
      await foregroundServiceDataSource.startForegroundService(
        serverName: currentSettings.serverName,
        ip: localIp,
        port: currentSettings.port,
      );

      if (!await batteryOptimizationService.isIgnoringBatteryOptimizations()) {
        await batteryOptimizationService.requestIgnoreBatteryOptimizations();
      }
    } else {
      await startServerRuntime(
        serverName: currentSettings.serverName,
        localIp: localIp,
        port: currentSettings.port,
      );
      return;
    }

    _localIp = localIp;
    _startedAt = DateTime.now();
    _isServerRuntimeRunning = true;
  }

  static Future<void> startServerRuntime({
    required String serverName,
    required String localIp,
    required int port,
  }) async {
    await _withRuntimeLock(() async {
      await _stopServerRuntimeInternal();
      await _startServerRuntimeInternal(
        serverName: serverName,
        localIp: localIp,
        port: port,
      );
    });
  }

  static Future<void> _startServerRuntimeInternal({
    required String serverName,
    required String localIp,
    required int port,
  }) async {
    _localIp = localIp;
    _startedAt = DateTime.now();
    _setMdnsRuntimeStatus(
      const MdnsRuntimeStatus.idle(summary: '未广播', details: '正在初始化广播'),
    );

    try {
      final currentSettings = _currentServerSettings;
      final rootPath = await _validateConfiguredStoragePath(
        currentSettings.storagePath,
      );
      _currentServerSettings = currentSettings.copyWith(storagePath: rootPath);
      final avatarStore = deviceAvatarStore;
      await avatarStore.migrateFromLegacyStorageRoot(rootPath);
      final rawServerId = systemStatusCache?.deviceId.trim() ?? '';
      final serverId = rawServerId.isNotEmpty
          ? rawServerId
          : await deviceInfoService.getDeviceId();
      _serverTlsMaterial = await serverTlsManager.ensureMaterial(
        serverId: serverId,
        serverName: serverName,
        localIp: localIp,
        port: port,
      );

      final contentTypeResolver = ContentTypeResolver();
      final mediaLibraryEnabled = AppPlatform.supportsMediaLibrary;
      final thumbnailsEnabled = AppPlatform.supportsThumbnails;
      final videoTranscodingEnabled =
          AppPlatform.supportsVideoTranscoding &&
          await const FfmpegLocator().find() != null;

      await _startMinimalCoreServices();
      unawaited(_startDeferredCoreServices());

      serverActivityTracker = ServerActivityTracker();
      authSessionStore = AuthSessionStore(
        ownerStateValidator: ownerCredentialStore.isOwnerSessionVersionValid,
        deviceStateValidator: deviceStore.isDeviceCredentialVersionValid,
        deviceTokenService: await deviceStore.requireTokenService(),
      );
      realtimeConnectionRegistry = RealtimeConnectionRegistry();
      realtimeNodeRegistry = UnifiedNodeRegistry(avatarStore: deviceAvatarStore);
      realtimePresenceRepository = RealtimePresenceRepository(
        nodeRegistry: realtimeNodeRegistry!,
      );
      await _ensureHostDeviceRegistered(
        serverId: serverId,
        serverName: serverName,
      );
      final enrolledDevices = await deviceStore.listDevices();
      final storedDevices = <StoredDeviceRecord>[];
      for (final summary in enrolledDevices) {
        final device = await deviceStore.findDeviceById(summary.deviceId);
        if (device != null) {
          storedDevices.add(device);
        }
      }
      realtimePresenceRepository!.seedDevices(storedDevices);
      realtimeEventHub = RealtimeEventHub(
        connectionRegistry: realtimeConnectionRegistry!,
      );
      relayTempStorageManager = RelayTempStorageManager(rootPath: rootPath);
      relayTransferRepository = SqliteRelayTransferRepository(
        databasePath: p.join(
          rootPath,
          relayStorageDirectoryName,
          'relay_transfers.db',
        ),
      );

      if (thumbnailsEnabled && thumbnailWarmupService != null) {
        thumbnailWarmupService!.realtimeConnectionRegistry =
            realtimeConnectionRegistry!;
      }

      relayRealtimePublisher = RelayRealtimePublisher(
        eventHub: realtimeEventHub!,
        presenceRepository: realtimePresenceRepository!,
      );
      relayService = RelayService(
        repository: relayTransferRepository!,
        storageManager: relayTempStorageManager!,
        deviceStore: deviceStore,
        realtimePublisher: relayRealtimePublisher!,
      );
      await relayService!.initialize();

      final dashboardPayloadBuilder = DashboardPayloadBuilder(
        systemStatusCache: systemStatusCache!,
        port: port,
        startedAt: _startedAt!,
      );
      final enrolledDeviceIdsProvider = () async {
        final devices =
            await serverDeviceIdentityService.listEnrolledClientDevices();
        return devices
            .where((device) => device.status == DeviceStatus.active)
            .map((device) => device.deviceId)
            .toList(growable: false);
      };
      final realtimeSnapshotBuilder = RealtimeSnapshotBuilder(
        dashboardPayloadBuilder: dashboardPayloadBuilder,
        presenceRepository: realtimePresenceRepository!,
        relayService: relayService,
        enrolledDeviceIdsProvider: enrolledDeviceIdsProvider,
      );
      realtimeStatusPublisher = RealtimeStatusPublisher(
        connectionRegistry: realtimeConnectionRegistry!,
        eventHub: realtimeEventHub!,
        dashboardPayloadBuilder: dashboardPayloadBuilder,
        presenceRepository: realtimePresenceRepository!,
        enrolledDeviceIdsProvider: enrolledDeviceIdsProvider,
      );
      realtimeStatusPublisher!.start();
      unawaited(
        RuntimePresenceBridge.instance.publishFromRuntime(
          presenceRepository: realtimePresenceRepository!,
          connectionRegistry: realtimeConnectionRegistry!,
        ),
      );
      deviceStore.addListener((device) {
        realtimeNodeRegistry?.upsertDevice(device);
        realtimeStatusPublisher?.publishPresenceChanged();
      });
      deviceStore.addDeletionListener((deviceId) {
        realtimeNodeRegistry?.removeDevice(deviceId);
        realtimeStatusPublisher?.publishPresenceChanged();
      });

      final videoHlsSessionService = videoTranscodingEnabled
          ? VideoHlsSessionService(rootPath: rootPath)
          : null;

      final bootstrapHandler = BootstrapHandler(
        serverName: currentSettings.serverName,
        serverId: serverId,
        serverVersion: _serverVersion,
        caSha256: _serverTlsMaterial!.caSha256,
        mediaLibraryEnabled: mediaLibraryEnabled,
        thumbnailEnabled: thumbnailsEnabled,
        batchThumbnailEnabled: thumbnailsEnabled,
        hlsVideoPreviewEnabled: videoTranscodingEnabled,
        transcodeVideoPreviewEnabled: videoTranscodingEnabled,
      );

      final dashboardHandler = DashboardHandler(
        payloadBuilder: dashboardPayloadBuilder,
      );
      final backupPreflightHandler = BackupPreflightHandler(
        backupCatalogService: backupCatalogService!,
      );

      final thumbnailHandler = ThumbnailHandler(
        thumbnailService: thumbnailService!,
        mediaLibraryEnabled: mediaLibraryEnabled,
        thumbnailsEnabled: thumbnailsEnabled,
      );

      final batchThumbnailHandler = BatchThumbnailHandler(
        thumbnailService: thumbnailService!,
        concurrencyLimiter: thumbnailConcurrencyLimiter!,
        mediaLibraryEnabled: mediaLibraryEnabled,
        thumbnailsEnabled: thumbnailsEnabled,
      );

      final batchDeleteHandler = BatchDeleteHandler(
        fileSystemService: fileSystemService,
        rootPath: rootPath,
        onFilesChanged: fileIndexService?.scheduleRefresh,
        onPathDeleted: thumbnailWarmupService?.deletePathState,
        backupCatalogService: backupCatalogService,
        thumbnailService: thumbnailService,
      );

      final fsResolver = FileSystemDavResourceResolver(
        rootPath: rootPath,
        contentTypeResolver: contentTypeResolver,
      );

      MediaLibraryDavResourceResolver? mediaLibraryResolver;
      if (mediaLibraryEnabled) {
        final mediaLibraryQueryDataSource = MediaStoreQueryDataSource(
          mediaStoreService: mediaStoreService,
        );
        final mediaLibraryRepository = MediaLibraryRepositoryImpl(
          queryDataSource: mediaLibraryQueryDataSource,
        );
        mediaLibraryResolver = MediaLibraryDavResourceResolver(
          repository: mediaLibraryRepository,
        );
      }

      final compositeResolver = CompositeDavResourceResolver(
        fileSystemResolver: fsResolver,
        mediaLibraryResolver: mediaLibraryResolver,
        mediaLibraryEnabled: mediaLibraryEnabled,
      );

      final fsContentReader = FileSystemContentReader();

      final mediaStoreContentReader = MediaStoreContentReader(
        mediaStoreService: mediaStoreService,
      );

      final compositeContentReader = CompositeContentReader(
        fileSystemReader: fsContentReader,
        mediaStoreReader: mediaStoreContentReader,
      );

      final previewHandler = PreviewHandler(
        resourceResolver: compositeResolver,
        contentTypeResolver: contentTypeResolver,
        mediaLibraryEnabled: mediaLibraryEnabled,
        thumbnailEnabled: thumbnailsEnabled,
        hlsVideoPreviewEnabled: videoTranscodingEnabled,
        transcodeVideoPreviewEnabled: videoTranscodingEnabled,
      );
      final previewHlsHandler = PreviewHlsHandler(
        resourceResolver: compositeResolver,
        sessionService: videoHlsSessionService,
      );
      final fileListHandler = FileListHandler(
        fileIndexService: fileIndexService!,
      );
      final authSessionHandler = AuthSessionHandler(
        ownerCredentialStore: ownerCredentialStore,
        authSessionStore: authSessionStore!,
      );
      final deviceRefreshHandler = DeviceRefreshHandler(
        deviceStore: deviceStore,
      );
      final credentialDeviceEnrollHandler = CredentialDeviceEnrollHandler(
        ownerCredentialStore: ownerCredentialStore,
        deviceStore: deviceStore,
        tlsMaterialProvider: () => serverTlsManager.ensureMaterial(
          serverId: serverId,
          serverName: serverName,
          localIp: localIp,
          port: port,
        ),
      );
      final deviceApiHandler = DeviceApiHandler(
        deviceStore: deviceStore,
        avatarStore: deviceAvatarStore,
        hostDeviceIdProvider: () async {
          final host = await serverDeviceIdentityService.resolveHostDevice();
          return host?.deviceId;
        },
        isOnlineProvider: (deviceId) =>
            realtimePresenceRepository?.isOnline(deviceId) ?? false,
      );
      final deviceProfileApiHandler = DeviceProfileApiHandler(
        deviceStore: deviceStore,
        avatarStore: deviceAvatarStore,
        onProfileChanged: () {
          realtimeStatusPublisher?.publishPresenceChanged();
        },
      );
      final authRouter = AuthRouter(
        authSessionHandler: authSessionHandler,
        deviceRefreshHandler: deviceRefreshHandler,
        credentialDeviceEnrollHandler: credentialDeviceEnrollHandler,
      );
      final realtimeWsHandler = RealtimeWsHandler(
        authSessionStore: authSessionStore!,
        connectionRegistry: realtimeConnectionRegistry!,
        presenceRepository: realtimePresenceRepository!,
        eventHub: realtimeEventHub!,
        snapshotBuilder: realtimeSnapshotBuilder,
        statusPublisher: realtimeStatusPublisher!,
        deviceStore: deviceStore,
      );
      final relayApiHandler = RelayApiHandler(relayService: relayService!);
      final relayApiRouter = RelayApiRouter(relayApiHandler: relayApiHandler);
      final relayWebdavHandler = RelayWebdavHandler(
        relayService: relayService!,
      );
      final relayWebdavRouter = RelayWebdavRouter(
        relayWebdavHandler: relayWebdavHandler,
      );
      final benchmarkFeatureBundle = await BenchmarkFeature.createBundle(
        rootPath: rootPath,
        httpPort: _defaultBenchmarkHttpPort,
      );

      final pairingService = PairingService(
        tlsManager: serverTlsManager,
        deviceStore: deviceStore,
        keyValueStore: keyValueStore,
      );
      final pairingHandler = PairingHandler(
        pairingService: pairingService,
        serverId: serverId,
        serverName: serverName,
        localIp: localIp,
        port: port,
      );

      final apiRouter = ApiRouter(
        bootstrapHandler: bootstrapHandler,
        dashboardHandler: dashboardHandler,
        backupPreflightHandler: backupPreflightHandler,
        fileListHandler: fileListHandler,
        previewHandler: previewHandler,
        previewHlsHandler: previewHlsHandler,
        thumbnailHandler: thumbnailHandler,
        batchThumbnailHandler: batchThumbnailHandler,
        batchDeleteHandler: batchDeleteHandler,
        realtimeWsHandler: realtimeWsHandler,
        relayApiRouter: relayApiRouter,
        deviceApiHandler: deviceApiHandler,
        deviceProfileApiHandler: deviceProfileApiHandler,
        benchmarkApiRouter: benchmarkFeatureBundle?.apiRouter,
      );

      final webdavRouter = WebdavMethodRouter(
        resolver: compositeResolver,
        contentReader: compositeContentReader,
        rootPath: rootPath,
        onFilesChanged: fileIndexService?.scheduleRefresh,
        onPathChanged: thumbnailWarmupService?.markPathDirty,
        onPathDeleted: thumbnailWarmupService?.deletePathState,
        backupCatalogService: backupCatalogService,
        thumbnailService: thumbnailService,
      );

      httpServerDataSource = HttpServerDataSource(
        authHandler: authRouter.handler,
        pairingHandler: pairingHandler.handler,
        apiHandler: bearerAuthMiddleware(
          authSessionStore!,
          deviceStore: deviceStore,
        )(apiRouter.handler),
        benchmarkWebdavHandler: benchmarkFeatureBundle == null
            ? null
            : bearerAuthMiddleware(authSessionStore!, deviceStore: deviceStore)(
                benchmarkFeatureBundle.webdavRouter.handler,
              ),
        relayWebdavHandler: bearerAuthMiddleware(
          authSessionStore!,
          deviceStore: deviceStore,
        )(relayWebdavRouter.handler),
        webdavHandler: bearerAuthMiddleware(
          authSessionStore!,
          deviceStore: deviceStore,
        )(webdavRouter.handler),
        activityTracker: serverActivityTracker,
      );

      await httpServerDataSource!.start(
        port: port,
        localIp: _localIp!,
        securityContext: _serverTlsMaterial!.createSecurityContext(),
      );
      if (benchmarkFeatureBundle != null) {
        unawaited(
          BenchmarkFeature.startHttpServer(port: _defaultBenchmarkHttpPort),
        );
      }

      await _registerMdnsService(
        serverId: serverId,
        serverName: serverName,
        port: port,
      );
      if (AppPlatform.supportsMediaChangeObserver) {
        await mediaChangeService.startObserving();
      }
      _isServerRuntimeRunning = true;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to start server runtime',
        name: 'nas_server.runtime',
        error: error,
        stackTrace: stackTrace,
      );
      await _stopServerRuntimeInternal();
      rethrow;
    }
  }

  static Future<void> _ensureHostDeviceRegistered({
    required String serverId,
    required String serverName,
  }) async {
    final normalizedServerId = serverId.trim();
    if (normalizedServerId.isEmpty) {
      return;
    }

    final existingHost =
        await deviceStore.findDeviceByPhysicalId(normalizedServerId);
    if (existingHost != null) {
      return;
    }

    final enrollResult = await deviceStore.enrollDevice(
      deviceId: normalizedServerId,
      deviceName: serverName.trim().isNotEmpty
          ? serverName.trim()
          : _defaultServerName,
      physicalDeviceId: normalizedServerId,
      platform: AppPlatform.identifier,
      brand: systemStatusCache?.brand,
      model: systemStatusCache?.model,
    );
    if (!enrollResult.isSuccess) {
      developer.log(
        'Host device auto-registration failed: ${enrollResult.failureMessage}',
        name: 'nas_server.runtime',
      );
    }
  }

  static Future<void> stopServer() async {
    if (AppPlatform.supportsForegroundService) {
      await foregroundServiceDataSource.stopForegroundService();
      _localIp = null;
      _startedAt = null;
      _isServerRuntimeRunning = false;
      return;
    }

    await stopServerRuntime();
  }

  static Future<void> stopServerRuntime() async {
    await _withRuntimeLock(_stopServerRuntimeInternal);
  }

  /// Serializes start/stop runtime transitions so rapid toggle does not cause
  /// concurrent init / teardown on the same state.
  static Future<void> _withRuntimeLock(Future<void> Function() body) async {
    final inFlight = _runtimeTransition;
    if (inFlight != null) {
      await inFlight;
    }
    final completer = Completer<void>();
    _runtimeTransition = completer.future;
    try {
      await body();
    } finally {
      completer.complete();
      if (_runtimeTransition == completer.future) {
        _runtimeTransition = null;
      }
    }
  }

  static Future<void> _shutdownRealtimeConnections() async {
    final eventHub = realtimeEventHub;
    final statusPublisher = realtimeStatusPublisher;
    if (eventHub == null && statusPublisher == null) {
      return;
    }

    statusPublisher?.dispose();

    if (eventHub != null && realtimeConnectionRegistry?.hasConnections == true) {
      eventHub.broadcast(
        type: RealtimeMessageType.serverStateChanged,
        payload: {
          'server': {'status': 'offline'},
          'reason': 'server_stopping',
        },
      );
      await eventHub.closeAllConnections(
        closeCode: realtimeCloseCodeServerShutdown,
        reason: 'server stopping',
      );
    }
  }

  static Future<void> _stopServerRuntimeInternal() async {
    if (!_isSetupComplete) {
      _localIp = null;
    _startedAt = null;
    _isServerRuntimeRunning = false;
    await RuntimePresenceBridge.instance.clear();
    _setMdnsRuntimeStatus(
        const MdnsRuntimeStatus.idle(summary: '未广播', details: '服务未启动'),
      );
      return;
    }

    // mDNS broadcast is kept alive across start/stop cycles; only released
    // when the app exits (DesktopRuntimeController.exitApplication).
    await _shutdownRealtimeConnections();
    await httpServerDataSource?.stop();
    await BenchmarkFeature.stopHttpServer();
    httpServerDataSource = null;
    authSessionStore?.clear();
    authSessionStore = null;
    await relayService?.close();
    relayService = null;
    relayRealtimePublisher = null;
    relayTransferRepository = null;
    relayTempStorageManager = null;
    realtimeStatusPublisher = null;
    realtimeConnectionRegistry?.dispose();
    realtimeConnectionRegistry = null;
    realtimeNodeRegistry?.clear();
    realtimeNodeRegistry = null;
    realtimePresenceRepository?.clear();
    realtimePresenceRepository = null;
    realtimeEventHub = null;
    serverActivityTracker?.reset();
    serverActivityTracker = null;
    _serverTlsMaterial = null;
    _localIp = null;
    _startedAt = null;

    await mediaChangeService.stopObserving();
    _isServerRuntimeRunning = false;
  }

  static SettingsCubit createSettingsCubit() {
    return SettingsCubit(
      loadServerSettingsUseCase: loadServerSettingsUseCase,
      updateServerSettingsUseCase: updateServerSettingsUseCase,
    );
  }

  static ServerSettingsEntity get currentServerSettings =>
      _currentServerSettings;
  static String get serverName => _currentServerSettings.serverName;
  static String get storageRootPath => _currentServerSettings.storagePath;

  static bool get isServerRunning => _isServerRuntimeRunning;
  static int get serverPort => _currentServerSettings.port;
  static String? get serverIp => _localIp;
  static DateTime? get serverStartedAt => _startedAt;
  static MdnsRuntimeStatus get mdnsRuntimeStatus => _mdnsRuntimeStatus;
  static ServerTlsMaterial? get serverTlsMaterial => _serverTlsMaterial;
  static Future<String?> loadServerPairingToken() async {
    final localIp = _localIp?.trim() ?? '';
    if (localIp.isEmpty) {
      return null;
    }

    final cachedDeviceId = systemStatusCache?.deviceId.trim() ?? '';
    final serverId = cachedDeviceId.isNotEmpty
        ? cachedDeviceId
        : (await deviceInfoService.getDeviceId()).trim();
    if (serverId.isEmpty) {
      return null;
    }

    final pairingService = PairingService(
      tlsManager: serverTlsManager,
      deviceStore: deviceStore,
      keyValueStore: keyValueStore,
    );
    return pairingService.generatePairingQrToken(
      serverId: serverId,
      serverName: _currentServerSettings.serverName,
      localIp: localIp,
      port: _currentServerSettings.port,
    );
  }

  static List<String> get serverLogs => httpServerDataSource?.requestLogs ?? [];

  static Future<void> _reloadServerSettings() async {
    _currentServerSettings = await settingsLocalDataSource.loadSettings();
  }

  static Future<void> _registerMdnsService({
    required String serverId,
    required String serverName,
    required int port,
  }) async {
    if (_mdnsRegistered) {
      await NsdManagerPlugin.unregisterService();
      _mdnsRegistered = false;
    }

    _setMdnsRuntimeStatus(
      const MdnsRuntimeStatus.active(summary: '广播启动中', details: '正在注册局域网广播'),
    );
    final physicalDeviceId = (await deviceInfoService.getDeviceId()).trim();
    final nsdRegistration = await NsdManagerPlugin.registerServiceWithDisambiguation(
      serviceName: serverName,
      physicalDeviceId: physicalDeviceId,
      serviceType: '_webdavs._tcp.',
      port: port,
      txtRecords: {
        'scheme': 'https',
        'platform': AppPlatform.identifier,
        'serverId': serverId,
        'caSha256': _serverTlsMaterial!.caSha256,
        'baseUrl': _serverTlsMaterial!.baseUrl,
        'hostLabel': _serverTlsMaterial!.hostLabel,
      },
    );

    final registeredName =
        (nsdRegistration['serviceName'] as String?)?.trim() ?? serverName;

    if (nsdRegistration['success'] == true) {
      _mdnsRegistered = true;
      await persistBroadcastServerName(registeredName);
      _setMdnsRuntimeStatus(
        const MdnsRuntimeStatus.active(summary: '已广播', details: '局域网发现已启用'),
      );
      return;
    }

    final error = '${nsdRegistration['error'] ?? 'unknown error'}';
    developer.log('mDNS registration failed: $error', name: 'nas_server.mdns');
    _setMdnsRuntimeStatus(
      MdnsRuntimeStatus.failed(
        summary: '广播异常',
        details: '服务已启动，但局域网广播不可用：$error',
      ),
    );
  }

  static Future<void> persistBroadcastServerName(String broadcastName) async {
    final normalized = broadcastName.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (_currentServerSettings.serverName == normalized) {
      return;
    }
    final updated = _currentServerSettings.copyWith(serverName: normalized);
    await settingsLocalDataSource.saveSettings(updated);
    _currentServerSettings = updated;
  }

  static Future<void> _syncBroadcastNameFromIdentity() async {
    try {
      final baseName =
          await serverDeviceIdentityService.resolveBroadcastBaseName();
      await persistBroadcastServerName(baseName);
    } catch (_) {}
  }

  static Future<void> _onBroadcastNameCandidate(String broadcastName) async {
    await persistBroadcastServerName(broadcastName);
    if (_isServerRuntimeRunning) {
      await _reregisterMdnsService();
    }
  }

  static Future<void> _reregisterMdnsService() async {
    if (!_isServerRuntimeRunning ||
        _localIp == null ||
        _serverTlsMaterial == null) {
      return;
    }
    final cachedDeviceId = systemStatusCache?.deviceId.trim() ?? '';
    final serverId = cachedDeviceId.isNotEmpty
        ? cachedDeviceId
        : await deviceInfoService.getDeviceId();
    await _registerMdnsService(
      serverId: serverId,
      serverName: _currentServerSettings.serverName,
      port: _currentServerSettings.port,
    );
  }

  static void _setMdnsRuntimeStatus(MdnsRuntimeStatus status) {
    _mdnsRuntimeStatus = status;
    systemStatusCache?.notifyRuntimeStateChanged();
  }

  static Future<void> _applyServerSettingsAfterSave(
    ServerSettingsEntity settings,
  ) async {
    final previousSettings = _currentServerSettings;
    final validatedStoragePath = await _validateConfiguredStoragePath(
      settings.storagePath,
    );
    final normalizedSettings = settings.copyWith(
      storagePath: validatedStoragePath,
    );
    final storagePathChanged =
        previousSettings.storagePath != validatedStoragePath;
    final shouldRestartServer =
        _isServerRuntimeRunning &&
        (previousSettings.port != normalizedSettings.port ||
            previousSettings.serverName != normalizedSettings.serverName ||
            storagePathChanged);

    _currentServerSettings = normalizedSettings;
    await systemStatusCache?.refreshStorageStats();
    await DesktopRuntimeController.instance.applySettings(normalizedSettings);

    if (!storagePathChanged && !shouldRestartServer) {
      return;
    }

    unawaited(
      _applyServerSettingsHeavy(
        storagePathChanged: storagePathChanged,
        shouldRestartServer: shouldRestartServer,
      ),
    );
  }

  static Future<void> _applyServerSettingsHeavy({
    required bool storagePathChanged,
    required bool shouldRestartServer,
  }) async {
    settingsApplyStatus.value = const SettingsApplyStatus(
      isApplying: true,
      message: '正在后台应用设置…',
    );

    try {
      if (storagePathChanged) {
        settingsApplyStatus.value = settingsApplyStatus.value.copyWith(
          message: '正在切换共享目录并重建文件服务…',
        );
        await _stopCoreServices();
        await _startMinimalCoreServices();
        unawaited(_startDeferredCoreServices());
      }

      if (shouldRestartServer) {
        settingsApplyStatus.value = settingsApplyStatus.value.copyWith(
          message: '正在重启服务以应用新设置…',
        );
        await stopServer();
        await startServer();
      }

      settingsApplyStatus.value = const SettingsApplyStatus(
        message: '设置已在后台应用完成',
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to apply server settings in background',
        name: 'nas_server.service_locator',
        error: error,
        stackTrace: stackTrace,
      );
      settingsApplyStatus.value = SettingsApplyStatus(
        errorMessage: '后台应用设置失败：$error',
      );
    } finally {
      settingsApplyStatus.value = settingsApplyStatus.value.copyWith(
        isApplying: false,
      );
    }
  }

  static Future<void> persistResidentSettings(
    ServerSettingsEntity settings,
  ) async {
    await settingsLocalDataSource.saveSettings(settings);
    _currentServerSettings = settings;
  }

  static Future<void> applyLocalNetworkAddressChange(String newIp) async {
    final normalized = newIp.trim();
    if (normalized.isEmpty) {
      return;
    }

    final previousIp = localNetworkAddressService.effectiveIp?.trim() ?? '';
    await localNetworkAddressService.setSelectedIp(normalized);
    systemStatusCache?.refreshIpAddress();

    if (_isServerRuntimeRunning && previousIp != normalized) {
      await stopServer();
      await startServer();
    }
  }

  static Future<String> _validateConfiguredStoragePath(String rawPath) async {
    final normalizedPath = fileSystemService.normalizeSharedRootPath(rawPath);
    final defaultStoragePath = fileSystemService.normalizeSharedRootPath(
      await AppStoragePaths.resolveDefaultStoragePath(),
    );
    return fileSystemService.validateSharedRootPath(
      normalizedPath,
      createIfMissing: fileSystemService.pathsEqual(
        normalizedPath,
        defaultStoragePath,
      ),
    );
  }
}
