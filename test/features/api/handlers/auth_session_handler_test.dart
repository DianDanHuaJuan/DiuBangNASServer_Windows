import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_server/core/auth/account_models.dart';
import 'package:nas_server/core/auth/auth_session_store.dart';
import 'package:nas_server/features/api/handlers/auth_session_handler.dart';
import 'package:shelf/shelf.dart';

import '../../../test_support/device_store_harness.dart';

void main() {
  group('AuthSessionHandler', () {
    test('creates a bearer session for valid owner credentials', () async {
      final harness = await TestDeviceStoreHarness.create();
      addTearDown(harness.dispose);
      final ownerCredentialStore = harness.createOwnerCredentialStore();
      await ownerCredentialStore.initialize();
      await ownerCredentialStore.updateOwnerCredential(
        username: 'owner-home',
        password: 'owner-secret',
      );
      final handler = AuthSessionHandler(
        ownerCredentialStore: ownerCredentialStore,
        authSessionStore: AuthSessionStore(
          ownerStateValidator: ownerCredentialStore.isOwnerSessionVersionValid,
        ),
      ).createSessionHandler;

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/auth/session'),
          headers: {
            'Authorization': ownerCredentialStore.encodeBasicAuth(
              'owner-home',
              'owner-secret',
            ),
          },
        ),
      );
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(body['role'], AccountRole.owner.name);
      expect(body['tokenType'], 'Bearer');
      expect(body['sessionId'], startsWith('sess_'));
      expect(body['accessToken'], isNotEmpty);
    });

    test(
      'allows remote session creation with default owner credentials',
      () async {
        final harness = await TestDeviceStoreHarness.create();
        addTearDown(harness.dispose);
        final ownerCredentialStore = harness.createOwnerCredentialStore();
        await ownerCredentialStore.initialize();
        final handler = AuthSessionHandler(
          ownerCredentialStore: ownerCredentialStore,
          authSessionStore: AuthSessionStore(
            ownerStateValidator: ownerCredentialStore.isOwnerSessionVersionValid,
          ),
        ).createSessionHandler;

        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/auth/session'),
            headers: {
              'Authorization': ownerCredentialStore.encodeBasicAuth(
                'admin',
                'admin',
              ),
            },
          ),
        );
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;

        expect(response.statusCode, 200);
        expect(body['role'], AccountRole.owner.name);
        expect(body['accessToken'], isNotEmpty);
      },
    );

    test('rejects invalid owner credentials', () async {
      final harness = await TestDeviceStoreHarness.create();
      addTearDown(harness.dispose);
      final ownerCredentialStore = harness.createOwnerCredentialStore();
      await ownerCredentialStore.initialize();
      await ownerCredentialStore.updateOwnerCredential(
        username: 'owner-home',
        password: 'owner-secret',
      );
      final handler = AuthSessionHandler(
        ownerCredentialStore: ownerCredentialStore,
        authSessionStore: AuthSessionStore(
          ownerStateValidator: ownerCredentialStore.isOwnerSessionVersionValid,
        ),
      ).createSessionHandler;

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/auth/session'),
          headers: {
            'Authorization': ownerCredentialStore.encodeBasicAuth(
              'owner-home',
              'wrong-password',
            ),
          },
        ),
      );
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, 401);
      expect(body['code'], 'AUTH_INVALID');
    });
  });
}
