import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_server/core/auth/auth_session_store.dart';
import 'package:nas_server/core/auth/bearer_auth_middleware.dart';
import 'package:nas_server/core/device_registry/device_avatar_store.dart';
import 'package:nas_server/core/device_registry/device_store.dart';
import 'package:nas_server/features/api/handlers/device_api_handler.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../../test_support/device_store_harness.dart';

void main() {
  group('DeviceApiHandler.getDeviceAvatar', () {
    late TestDeviceStoreHarness harness;
    late DeviceStore deviceStore;
    late AuthSessionStore authSessionStore;
    late DeviceAvatarStore avatarStore;
    late DeviceApiHandler handler;

    setUp(() async {
      harness = await TestDeviceStoreHarness.create();
      deviceStore = harness.createDeviceStore();
      await deviceStore.initialize();
      authSessionStore = AuthSessionStore(
        deviceStateValidator: deviceStore.isDeviceCredentialVersionValid,
        deviceTokenService: await deviceStore.requireTokenService(),
      );
      avatarStore = DeviceAvatarStore(
        avatarDirectoryPath: p.join(
          p.dirname(harness.deviceDatabasePath),
          'device_avatars',
        ),
      );
      handler = DeviceApiHandler(
        deviceStore: deviceStore,
        avatarStore: avatarStore,
        hostDeviceIdProvider: () async => 'host-01',
      );
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('serves no-cache headers with ETag from avatar mtime', () async {
      await deviceStore.enrollDevice(
        deviceId: 'phone-01',
        deviceName: 'Phone',
      );
      // Minimal JPEG SOI marker so handler picks image/jpeg.
      final jpegBytes = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
      final updatedAt = await avatarStore.saveAvatar(
        deviceId: 'phone-01',
        bytes: jpegBytes,
      );

      final enrolled = await deviceStore.enrollDevice(
        deviceId: 'reader-01',
        deviceName: 'Reader',
      );
      final auth = await authSessionStore.authenticateAccessToken(
        enrolled.tokens!.accessToken,
        deviceStore: deviceStore,
      );

      final response = await handler.getDeviceAvatar(
        Request(
          'GET',
          Uri.parse('http://localhost/devices/phone-01/avatar'),
          context: {authenticatedRequestContextKey: auth.context!},
        ),
        'phone-01',
      );

      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'private, no-cache, must-revalidate');
      expect(
        response.headers['etag'],
        '"${updatedAt.toUtc().millisecondsSinceEpoch}"',
      );
      expect(
        response.headers['x-avatar-updated-at'],
        updatedAt.toUtc().toIso8601String(),
      );
    });
  });
}
