import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../../core/auth/auth_session_store.dart';
import '../../../core/auth/owner_credential_store.dart';

class AuthSessionHandler {
  AuthSessionHandler({
    required OwnerCredentialStore ownerCredentialStore,
    required AuthSessionStore authSessionStore,
  }) : _ownerCredentialStore = ownerCredentialStore,
       _authSessionStore = authSessionStore;

  final OwnerCredentialStore _ownerCredentialStore;
  final AuthSessionStore _authSessionStore;

  Handler get createSessionHandler {
    return (Request request) async {
      final authHeader = request.headers['Authorization'];
      if (authHeader == null || !authHeader.startsWith('Basic ')) {
        return _buildBasicAuthErrorResponse(
          code: 'AUTH_REQUIRED',
          message: 'Authorization header is required',
        );
      }

      final credentials = _ownerCredentialStore.decodeBasicAuth(authHeader);
      if (credentials == null) {
        return _buildBasicAuthErrorResponse(
          code: 'AUTH_INVALID',
          message: 'Invalid authorization header format',
        );
      }

      final (username, password) = credentials;
      final authentication = await _ownerCredentialStore.authenticate(
        username: username,
        password: password,
      );

      if (!authentication.isSuccess) {
        return _buildBasicAuthErrorResponse(
          code: authentication.failureCode ?? 'AUTH_INVALID',
          message:
              authentication.failureMessage ?? 'Invalid username or password',
        );
      }

      final issuedSession = await _authSessionStore.issueOwnerSession(
        owner: authentication.owner!,
      );

      return Response.ok(
        jsonEncode({
          'ownerId': issuedSession.context.ownerId,
          'role': issuedSession.context.role.name,
          'sessionId': issuedSession.context.sessionId,
          'accessToken': issuedSession.accessToken,
          'tokenType': 'Bearer',
          'issuedAt': issuedSession.issuedAt.toIso8601String(),
          'expiresAt': issuedSession.expiresAt.toIso8601String(),
          'serverTime': DateTime.now().toUtc().toIso8601String(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    };
  }

  Response _buildBasicAuthErrorResponse({
    required String code,
    required String message,
    int statusCode = 401,
  }) {
    return Response(
      statusCode,
      headers: {
        'Content-Type': 'application/json',
        'WWW-Authenticate': 'Basic realm="DiuBangFileS"',
      },
      body: jsonEncode({'code': code, 'message': message, 'details': {}}),
    );
  }
}
