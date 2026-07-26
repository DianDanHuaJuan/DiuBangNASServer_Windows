import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../../core/auth/account_models.dart';
import '../../../core/auth/request_authorization.dart';
import '../../../core/device_registry/device_avatar_store.dart';
import '../../../core/device_registry/device_label_constraints.dart';
import '../../../core/device_registry/device_models.dart';
import '../../../core/device_registry/device_store.dart';

class DeviceApiHandler {
  DeviceApiHandler({
    required DeviceStore deviceStore,
    required DeviceAvatarStore avatarStore,
    Future<String?> Function()? hostDeviceIdProvider,
    bool Function(String deviceId)? isOnlineProvider,
  }) : _deviceStore = deviceStore,
       _avatarStore = avatarStore,
       _hostDeviceIdProvider = hostDeviceIdProvider,
       _isOnlineProvider = isOnlineProvider;

  final DeviceStore _deviceStore;
  final DeviceAvatarStore _avatarStore;
  final Future<String?> Function()? _hostDeviceIdProvider;
  final bool Function(String deviceId)? _isOnlineProvider;

  Handler get handler {
    final router = Router();

    router.get('/', listDevices);
    router.get('/profiles', listProfiles);
    router.get('/roster', listRoster);
    router.get('/<deviceId>/avatar', getDeviceAvatar);
    router.get('/<deviceId>', getDevice);
    router.patch('/<deviceId>', updateDevice);
    router.post('/<deviceId>/rotate-credential', rotateCredential);
    router.delete('/<deviceId>', deleteDevice);

    return router.call;
  }

  Future<Response> listDevices(Request request) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner},
      message: 'Only the server owner can list devices',
    );
    if (authError != null) {
      return authError;
    }

    final devices = await _deviceStore.listDevices();
    return Response.ok(
      jsonEncode({
        'devices': devices.map(_deviceSummaryJson).toList(growable: false),
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> listProfiles(Request request) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner, AccountRole.device},
      message: 'Authentication required to read device profiles',
    );
    if (authError != null) {
      return authError;
    }

    final idsParam = request.url.queryParameters['ids']?.trim() ?? '';
    if (idsParam.isEmpty) {
      return Response.ok(
        jsonEncode({'profiles': const <Map<String, dynamic>>[]}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final requestedIds = idsParam
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    final profiles = <Map<String, dynamic>>[];
    for (final deviceId in requestedIds) {
      final device = await _deviceStore.findDeviceById(deviceId);
      if (device == null || device.status != DeviceStatus.active) {
        continue;
      }
      profiles.add(await _profileJson(device));
    }

    return Response.ok(
      jsonEncode({'profiles': profiles}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// Full enrolled client roster for device navigation (excludes host).
  Future<Response> listRoster(Request request) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner, AccountRole.device},
      message: 'Authentication required to read device roster',
    );
    if (authError != null) {
      return authError;
    }

    final hostDeviceId = (await _hostDeviceIdProvider?.call())?.trim();
    final devices = await _deviceStore.listDevices();
    final entries = <Map<String, dynamic>>[];
    for (final summary in devices) {
      if (summary.status != DeviceStatus.active) {
        continue;
      }
      if (hostDeviceId != null &&
          hostDeviceId.isNotEmpty &&
          summary.deviceId == hostDeviceId) {
        continue;
      }
      final device = await _deviceStore.findDeviceById(summary.deviceId);
      if (device == null || device.status != DeviceStatus.active) {
        continue;
      }
      entries.add(await _rosterEntryJson(device));
    }

    return Response.ok(
      jsonEncode({'devices': entries}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> getDeviceAvatar(Request request, String deviceId) async {
    final authError = ensureAuthenticatedRequestContext(request);
    if (authError != null) {
      return authError;
    }

    final bytes = await _avatarStore.readAvatarBytes(deviceId);
    if (bytes == null || bytes.isEmpty) {
      return _error(404, 'AVATAR_NOT_FOUND', 'Device avatar was not found');
    }

    final updatedAt = await _avatarStore.readUpdatedAt(deviceId);
    final etag = updatedAt == null
        ? null
        : '"${updatedAt.toUtc().millisecondsSinceEpoch}"';
    final ifNoneMatch = request.headers['if-none-match']?.trim();
    if (etag != null && ifNoneMatch != null && ifNoneMatch == etag) {
      return Response.notModified(
        headers: <String, String>{
          'ETag': etag,
          'Cache-Control': 'private, no-cache, must-revalidate',
          if (updatedAt != null)
            'Last-Modified': HttpDate.format(updatedAt.toUtc()),
          if (updatedAt != null)
            'X-Avatar-Updated-At': updatedAt.toUtc().toIso8601String(),
        },
      );
    }

    final contentType = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
        ? 'image/jpeg'
        : 'image/png';
    return Response.ok(
      bytes,
      headers: <String, String>{
        'Content-Type': contentType,
        // Diagnostic/fix: do not allow 5-minute stale avatar caches.
        // Clients should also pass ?v={avatarUpdatedAt} as a cache buster.
        'Cache-Control': 'private, no-cache, must-revalidate',
        if (etag != null) 'ETag': etag,
        if (updatedAt != null)
          'Last-Modified': HttpDate.format(updatedAt.toUtc()),
        if (updatedAt != null)
          'X-Avatar-Updated-At': updatedAt.toUtc().toIso8601String(),
      },
    );
  }

  Future<Response> getDevice(Request request, String deviceId) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner},
      message: 'Only the server owner can view device details',
    );
    if (authError != null) {
      return authError;
    }

    final device = await _deviceStore.findDeviceById(deviceId);
    if (device == null) {
      return _error(404, 'DEVICE_NOT_FOUND', 'Device was not found');
    }

    return Response.ok(
      jsonEncode(_deviceRecordJson(device)),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> updateDevice(Request request, String deviceId) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner},
      message: 'Only the server owner can update devices',
    );
    if (authError != null) {
      return authError;
    }

    try {
      final payload = jsonDecode(await request.readAsString());
      if (payload is! Map) {
        return _error(400, 'INVALID_BODY', 'Request body must be JSON');
      }

      final label = payload['label'] as String?;
      final statusRaw = payload['status'] as String?;
      StoredDeviceRecord? updated;

      if (label != null) {
        final labelError = DeviceLabelConstraints.validate(label);
        if (labelError != null) {
          return _error(400, 'INVALID_LABEL', labelError);
        }
        updated = await _deviceStore.updateDeviceLabel(
          deviceId: deviceId,
          label: label,
        );
      }

      if (statusRaw != null) {
        final status = _parseStatus(statusRaw);
        if (status == null) {
          return _error(
            400,
            'INVALID_PARAMS',
            'status must be one of active, disabled, revoked',
          );
        }
        updated = await _deviceStore.updateDeviceStatus(
          deviceId: deviceId,
          status: status,
        );
      }

      if (updated == null) {
        return _error(
          400,
          'INVALID_PARAMS',
          'Provide label and/or status to update a device',
        );
      }

      return Response.ok(
        jsonEncode(_deviceRecordJson(updated)),
        headers: {'Content-Type': 'application/json'},
      );
    } on StateError catch (error) {
      return _error(404, 'DEVICE_NOT_FOUND', error.message);
    } on ArgumentError catch (error) {
      return _error(400, 'INVALID_LABEL', error.message?.toString() ?? 'Invalid label');
    } on FormatException catch (error) {
      return _error(400, 'INVALID_BODY', error.message);
    }
  }

  Future<Response> rotateCredential(Request request, String deviceId) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner},
      message: 'Only the server owner can rotate device credentials',
    );
    if (authError != null) {
      return authError;
    }

    try {
      final device = await _deviceStore.rotateDeviceCredential(deviceId);
      return Response.ok(
        jsonEncode(_deviceRecordJson(device)),
        headers: {'Content-Type': 'application/json'},
      );
    } on StateError catch (error) {
      return _error(404, 'DEVICE_NOT_FOUND', error.message);
    }
  }

  Future<Response> deleteDevice(Request request, String deviceId) async {
    final authError = ensureRequestHasAnyRole(
      request,
      allowedRoles: {AccountRole.owner},
      message: 'Only the server owner can delete devices',
    );
    if (authError != null) {
      return authError;
    }

    try {
      await _deviceStore.deleteDevice(deviceId);
      return Response(
        204,
        headers: {'Content-Type': 'application/json'},
      );
    } on StateError catch (error) {
      return _error(404, 'DEVICE_NOT_FOUND', error.message);
    }
  }

  DeviceStatus? _parseStatus(String rawValue) {
    return switch (rawValue.trim().toLowerCase()) {
      'active' => DeviceStatus.active,
      'disabled' => DeviceStatus.disabled,
      'revoked' => DeviceStatus.revoked,
      _ => null,
    };
  }

  Map<String, dynamic> _deviceSummaryJson(DeviceSummary device) {
    return {
      'deviceId': device.deviceId,
      'deviceName': device.deviceName,
      'label': device.label,
      'platform': device.platform,
      'brand': device.brand,
      'model': device.model,
      'status': device.status.name,
      'credentialVersion': device.credentialVersion,
      'firstPairedAt': device.firstPairedAt.toUtc().toIso8601String(),
      'lastSeenAt': device.lastSeenAt?.toUtc().toIso8601String(),
      'createdAt': device.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> _deviceRecordJson(StoredDeviceRecord device) {
    return {
      'deviceId': device.deviceId,
      'deviceName': device.deviceName,
      'label': device.label,
      'platform': device.platform,
      'brand': device.brand,
      'model': device.model,
      'status': device.status.name,
      'credentialVersion': device.credentialVersion,
      'firstPairedAt': device.firstPairedAt.toUtc().toIso8601String(),
      'lastSeenAt': device.lastSeenAt?.toUtc().toIso8601String(),
      'createdAt': device.createdAt.toUtc().toIso8601String(),
      'updatedAt': device.updatedAt.toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _profileJson(StoredDeviceRecord device) async {
    final avatarUpdatedAt = await _avatarStore.readUpdatedAt(device.deviceId);
    return {
      'deviceId': device.deviceId,
      'physicalDeviceId': device.physicalDeviceId,
      'deviceName': device.deviceName,
      'label': device.label,
      'platform': device.platform,
      'brand': device.brand,
      'model': device.model,
      if (avatarUpdatedAt != null)
        'avatarUpdatedAt': avatarUpdatedAt.toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _rosterEntryJson(StoredDeviceRecord device) async {
    final avatarUpdatedAt = await _avatarStore.readUpdatedAt(device.deviceId);
    final online = _isOnlineProvider?.call(device.deviceId) ?? false;
    return {
      'deviceId': device.deviceId,
      'deviceName': device.deviceName,
      'label': device.label,
      'platform': device.platform,
      'brand': device.brand,
      'model': device.model,
      'displayName': _bestDisplayName(
        label: device.label,
        brand: device.brand,
        model: device.model,
        deviceName: device.deviceName,
        fallback: device.deviceId,
      ),
      'online': online,
      'lastSeenAt': device.lastSeenAt?.toUtc().toIso8601String(),
      if (avatarUpdatedAt != null)
        'avatarUpdatedAt': avatarUpdatedAt.toUtc().toIso8601String(),
    };
  }

  String _bestDisplayName({
    String? label,
    String? brand,
    String? model,
    String? deviceName,
    required String fallback,
  }) {
    final trimmedLabel = label?.trim();
    if (trimmedLabel != null && trimmedLabel.isNotEmpty) {
      return trimmedLabel;
    }
    final parts = <String>[
      if (brand != null && brand.trim().isNotEmpty) brand.trim(),
      if (model != null && model.trim().isNotEmpty) model.trim(),
    ];
    if (parts.isNotEmpty) {
      return parts.join(' ');
    }
    final trimmedDeviceName = deviceName?.trim();
    if (trimmedDeviceName != null && trimmedDeviceName.isNotEmpty) {
      return trimmedDeviceName;
    }
    return fallback.trim();
  }

  Response _error(int statusCode, String code, String message) {
    return Response(
      statusCode,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code, 'message': message, 'details': {}}),
    );
  }
}
