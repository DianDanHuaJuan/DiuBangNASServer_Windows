import 'dart:io';

import '../../../core/device/broadcast_display_name_policy.dart';
import '../../../core/device/device_info_service.dart';
import '../../../core/device_registry/device_avatar_store.dart';
import '../../../core/device_registry/device_label_constraints.dart';
import '../../../core/device_registry/device_models.dart';
import '../../../core/device_registry/device_store.dart';
import '../../../core/profile/device_avatar_processor.dart';
import '../../../core/profile/device_identity_store.dart';
import '../../realtime/data/realtime_presence_repository.dart';

class ServerDeviceIdentityService {
  ServerDeviceIdentityService({
    required DeviceStore deviceStore,
    required DeviceAvatarStore avatarStore,
    required DeviceIdentityStore identityStore,
    required DeviceInfoService deviceInfoService,
    RealtimePresenceRepository? presenceRepository,
    Future<void> Function(String broadcastName)? onBroadcastNameChanged,
    void Function()? onProfileChanged,
  }) : _deviceStore = deviceStore,
       _avatarStore = avatarStore,
       _identityStore = identityStore,
       _deviceInfoService = deviceInfoService,
       _presenceRepository = presenceRepository,
       _onBroadcastNameChanged = onBroadcastNameChanged,
       _onProfileChanged = onProfileChanged;

  final DeviceStore _deviceStore;
  final DeviceAvatarStore _avatarStore;
  final DeviceIdentityStore _identityStore;
  final DeviceInfoService _deviceInfoService;
  final RealtimePresenceRepository? _presenceRepository;
  final Future<void> Function(String broadcastName)? _onBroadcastNameChanged;
  final void Function()? _onProfileChanged;

  String? get localAlias => _identityStore.displayAlias;

  String? get localAvatarPath => _identityStore.avatarPath;

  Future<StoredDeviceRecord?> resolveHostDevice() async {
    final physicalId = (await _deviceInfoService.getDeviceId()).trim();
    if (physicalId.isEmpty) {
      return null;
    }
    return _deviceStore.findDeviceByPhysicalId(physicalId);
  }

  /// Enrolled client devices for the connected-devices UI (excludes this host).
  Future<List<DeviceSummary>> listEnrolledClientDevices() async {
    final devices = await _deviceStore.listDevices();
    final host = await resolveHostDevice();
    if (host == null) {
      return devices;
    }
    return devices
        .where((device) => device.deviceId != host.deviceId)
        .toList(growable: false);
  }

  /// User-facing device name for UI cards (alias, label, system device name).
  Future<String> resolveUiDeviceName() async {
    final resolved = await resolveDisplayName();
    if (resolved.trim().isNotEmpty) {
      return resolved.trim();
    }
    return '本机';
  }

  Future<String> resolveDisplayName() async {
    final alias = _identityStore.displayAlias?.trim();
    if (alias != null && alias.isNotEmpty) {
      return alias;
    }
    final host = await resolveHostDevice();
    if (host?.label?.trim().isNotEmpty == true) {
      return host!.label!.trim();
    }
    if (host?.deviceName.trim().isNotEmpty == true) {
      return host!.deviceName.trim();
    }
    final info = await _deviceInfoService.getDeviceInfo();
    return info.deviceName;
  }

  /// Sanitized base name for mDNS / bootstrap before collision suffix.
  Future<String> resolveBroadcastBaseName() async {
    final rawName = await _resolveUiRawName();
    final physicalId = (await _deviceInfoService.getDeviceId()).trim();
    final sanitized = BroadcastDisplayNamePolicy.sanitizeForBroadcast(rawName);
    if (sanitized == 'NAS' && rawName.trim().isEmpty) {
      return BroadcastDisplayNamePolicy.fallbackBroadcastName(physicalId);
    }
    return sanitized;
  }

  Future<void> syncFromHostRecord() async {
    final host = await resolveHostDevice();
    if (host == null) {
      return;
    }
    if (host.label?.trim().isNotEmpty == true) {
      await _identityStore.saveDisplayAlias(host.label!);
    }
    final avatarUpdatedAt = await _avatarStore.readUpdatedAt(host.deviceId);
    if (avatarUpdatedAt != null) {
      await _identityStore.markAvatarSynced(avatarUpdatedAt);
    }
    await _syncBroadcastServerName();
  }

  Future<void> updateDisplayAlias(String alias) async {
    final host = await _requireHostDevice();
    final normalized = BroadcastDisplayNamePolicy.normalizeForSave(alias);
    final labelError = BroadcastDisplayNamePolicy.validateForSave(normalized);
    if (labelError != null) {
      throw ArgumentError(labelError);
    }
    final updated = await _deviceStore.updateDeviceLabel(
      deviceId: host.deviceId,
      label: normalized,
    );
    if (normalized.isEmpty) {
      await _identityStore.clearDisplayAlias();
    } else {
      await _identityStore.saveDisplayAlias(normalized);
    }
    await _refreshPresence(updated);
    await _syncBroadcastServerName();
  }

  Future<void> setAvatarFromPath(String sourcePath) async {
    final host = await _requireHostDevice();
    final bytes = await DeviceAvatarProcessor.prepareFromFile(sourcePath);
    final savedPath = await _identityStore.saveAvatarBytes(bytes);
    if (savedPath == null) {
      return;
    }
    final updatedAt = await _avatarStore.saveAvatar(
      deviceId: host.deviceId,
      bytes: bytes,
    );
    await _identityStore.markAvatarSynced(updatedAt);
    await _refreshPresence(host);
    _onProfileChanged?.call();
  }

  Future<void> clearAvatar() async {
    final host = await resolveHostDevice();
    await _identityStore.clearAvatar();
    if (host != null) {
      await _avatarStore.deleteAvatar(host.deviceId);
      await _refreshPresence(host);
      _onProfileChanged?.call();
    }
  }

  Future<StoredDeviceRecord> _requireHostDevice() async {
    final host = await resolveHostDevice();
    if (host != null) {
      return host;
    }
    return _registerHostDevice();
  }

  Future<StoredDeviceRecord> _registerHostDevice() async {
    final physicalId = (await _deviceInfoService.getDeviceId()).trim();
    if (physicalId.isEmpty) {
      throw StateError('本机设备标识不可用，请重启应用后重试');
    }

    final info = await _deviceInfoService.getDeviceInfo();
    final deviceName = info.deviceName.trim().isNotEmpty
        ? info.deviceName.trim()
        : '铥棒文件S';
    final enrollResult = await _deviceStore.enrollDevice(
      deviceId: physicalId,
      deviceName: deviceName,
      physicalDeviceId: physicalId,
      platform: Platform.operatingSystem,
      brand: info.brand,
      model: info.model,
    );
    if (!enrollResult.isSuccess) {
      throw StateError(
        enrollResult.failureMessage ?? '本机设备身份初始化失败',
      );
    }
    return enrollResult.tokens!.device;
  }

  Future<String> _resolveUiRawName() async {
    final alias = _identityStore.displayAlias?.trim();
    if (alias != null && alias.isNotEmpty) {
      return alias;
    }
    final host = await resolveHostDevice();
    if (host?.label?.trim().isNotEmpty == true) {
      return host!.label!.trim();
    }
    if (host?.deviceName.trim().isNotEmpty == true) {
      return host!.deviceName.trim();
    }
    final info = await _deviceInfoService.getDeviceInfo();
    return info.deviceName.trim();
  }

  Future<void> _syncBroadcastServerName() async {
    final callback = _onBroadcastNameChanged;
    if (callback == null) {
      return;
    }
    final baseName = await resolveBroadcastBaseName();
    await callback(baseName);
  }

  Future<void> _refreshPresence(StoredDeviceRecord device) async {
    final repository = _presenceRepository;
    if (repository == null) {
      return;
    }
    repository.upsertDevice(device);
  }
}
