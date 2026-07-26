import '../../../core/auth/account_models.dart';
import '../../../core/device_registry/device_avatar_store.dart';
import '../../../core/device_registry/device_models.dart';
import '../domain/unified_node.dart';
import 'realtime_connection_registry.dart';

class UnifiedNodeRegistry {
  UnifiedNodeRegistry({DeviceAvatarStore? avatarStore})
    : _avatarStore = avatarStore;

  final DeviceAvatarStore? _avatarStore;
  final Map<String, UnifiedNode> _byNodeId = <String, UnifiedNode>{};
  final Map<String, String> _nodeIdByDeviceId = <String, String>{};
  final Map<String, String> _nodeIdByServerId = <String, String>{};

  Iterable<UnifiedNode> get nodes => _byNodeId.values.toList(growable: false);

  UnifiedNode? findByDeviceId(String deviceId) {
    final nodeId = _nodeIdByDeviceId[deviceId];
    return nodeId == null ? null : _byNodeId[nodeId];
  }

  UnifiedNode? findByClientId(String clientId) => findByDeviceId(clientId);

  void seedDevices(Iterable<StoredDeviceRecord> devices) {
    for (final device in devices) {
      upsertDevice(device);
    }
  }

  void upsertDevice(StoredDeviceRecord device) {
    final nodeId = 'client-device:${device.deviceId}';
    final previous = _byNodeId[nodeId];
    final now = device.updatedAt.toUtc();
    final identity =
        (previous?.identity ??
                NodeIdentity(
                  deviceId: device.deviceId,
                  clientId: device.deviceId,
                  displayName: device.deviceName,
                  label: device.label,
                  deviceName: device.deviceName,
                  platform: device.platform,
                  brand: device.brand,
                  model: device.model,
                ))
            .copyWith(
              deviceId: device.deviceId,
              clientId: device.deviceId,
              displayName: _bestDisplayName(
                brand: device.brand,
                model: device.model,
                deviceName: device.deviceName,
                label: device.label,
                fallback: device.deviceName,
              ),
              label: device.label,
              deviceName: device.deviceName,
              platform: device.platform,
              brand: device.brand,
              model: device.model,
            );
    final nextNode =
        (previous ??
                UnifiedNode(
                  nodeId: nodeId,
                  kind: NodeKind.client,
                  relations: const <NodeRelation>{NodeRelation.managed},
                  identity: identity,
                  network: const NodeNetwork(),
                  presence: const NodePresence(),
                  runtime: const NodeRuntime(),
                  management: const NodeManagement(),
                  meta: NodeMeta(updatedAt: now),
                  client: ClientFacet(
                    deviceStatus: device.status,
                    role: AccountRole.device.name,
                    credentialVersion: device.credentialVersion,
                    boundDeviceId: device.deviceId,
                    boundDeviceName: device.deviceName,
                    boundAt: device.firstPairedAt,
                    createdAt: device.createdAt,
                    lastUsedAt: device.lastSeenAt,
                    lastBoundAt: device.firstPairedAt,
                  ),
                ))
            .copyWith(
              identity: identity,
              management: (previous?.management ?? const NodeManagement())
                  .copyWith(
                    adminState: _mapAdminState(device.status),
                    allowedActions: _allowedActionsForStatus(device.status),
                  ),
              meta: _nextMeta(previous?.meta, now, 'device'),
              client:
                  (previous?.client ??
                          ClientFacet(
                            deviceStatus: device.status,
                            role: AccountRole.device.name,
                            credentialVersion: device.credentialVersion,
                            boundDeviceId: device.deviceId,
                            boundDeviceName: device.deviceName,
                            boundAt: device.firstPairedAt,
                            createdAt: device.createdAt,
                            lastUsedAt: device.lastSeenAt,
                            lastBoundAt: device.firstPairedAt,
                          ))
                      .copyWith(
                        deviceStatus: device.status,
                        role: AccountRole.device.name,
                        credentialVersion: device.credentialVersion,
                        boundDeviceId: device.deviceId,
                        boundDeviceName: device.deviceName,
                        boundAt: device.firstPairedAt,
                        createdAt: device.createdAt,
                        lastUsedAt: device.lastSeenAt,
                        lastBoundAt: device.firstPairedAt,
                      ),
            );
    _storeNode(nextNode, previous: previous);
  }

  void removeDevice(String deviceId) {
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      return;
    }
    final nodeId = _nodeIdByDeviceId[normalized];
    if (nodeId == null) {
      return;
    }
    final previous = _byNodeId.remove(nodeId);
    _nodeIdByDeviceId.remove(normalized);
    final serverId = previous?.identity.serverId;
    if (_hasText(serverId) && _nodeIdByServerId[serverId!] == nodeId) {
      _nodeIdByServerId.remove(serverId);
    }
  }

  void markClientOnline(RealtimeConnection connection) {
    final node = _resolveDeviceNode(
      deviceId: connection.clientId,
      deviceName: connection.deviceName,
      label: connection.label,
    );
    final now = connection.connectedAt.toUtc();
    final nextNode = node.copyWith(
      identity: node.identity.copyWith(
        deviceId: connection.clientId,
        clientId: connection.clientId,
        displayName: _bestDisplayName(
          brand: connection.brand ?? node.identity.brand,
          model: connection.model ?? node.identity.model,
          deviceName: connection.deviceName,
          label: node.identity.label ?? connection.label,
          fallback: connection.deviceName,
        ),
        label: connection.label,
        deviceName: connection.deviceName,
        platform: connection.platform,
        brand: connection.brand,
        manufacturer: connection.brand,
        model: connection.model,
        appVersion: connection.appVersion,
      ),
      network: node.network.copyWith(
        reportedRouteIp: connection.reportedRouteIp,
        observedRemoteIp: connection.observedRemoteIp,
      ),
      presence: node.presence.copyWith(
        status: PresenceStatus.online,
        connectionId: connection.connectionId,
        sessionId: connection.sessionId,
        connectedAt: connection.connectedAt.toUtc(),
        lastHeartbeatAt: now,
        lastSeenAt: now,
      ),
      meta: _nextMeta(node.meta, now, 'hello'),
      client:
          (node.client ??
                  ClientFacet(
                    deviceStatus: DeviceStatus.active,
                    role: connection.role.name,
                  ))
              .copyWith(role: connection.role.name),
    );
    _storeNode(nextNode, previous: node);
  }

  void touchClient(RealtimeConnection connection) {
    final node = findByDeviceId(connection.clientId);
    if (node == null || node.presence.connectionId != connection.connectionId) {
      return;
    }
    final now = connection.lastSeenAt.toUtc();
    _storeNode(
      node.copyWith(
        presence: node.presence.copyWith(
          status: PresenceStatus.online,
          lastHeartbeatAt: now,
          lastSeenAt: now,
        ),
        meta: _nextMeta(node.meta, now, 'heartbeat'),
      ),
      previous: node,
    );
  }

  void markClientOffline({
    required String clientId,
    required String connectionId,
    DateTime? lastSeenAt,
  }) {
    final node = findByDeviceId(clientId);
    if (node == null || node.presence.connectionId != connectionId) {
      return;
    }
    final now = (lastSeenAt ?? DateTime.now()).toUtc();
    _storeNode(
      node.copyWith(
        presence: node.presence.copyWith(
          status: PresenceStatus.offline,
          connectionId: null,
          sessionId: null,
          lastSeenAt: now,
        ),
        meta: _nextMeta(node.meta, now, 'disconnect'),
      ),
      previous: node,
    );
  }

  List<Map<String, dynamic>> presenceSnapshot() {
    return _onlineClientNodes().map(_toPresenceJson).toList(growable: false);
  }

  List<Map<String, dynamic>> managementSnapshot() {
    final clients =
        _byNodeId.values
            .where((node) => node.kind == NodeKind.client)
            .toList(growable: false)
          ..sort((left, right) {
            final leftKey = left.identity.deviceId ?? '';
            final rightKey = right.identity.deviceId ?? '';
            return leftKey.compareTo(rightKey);
          });
    return clients.map(_toManagementJson).toList(growable: false);
  }

  List<Map<String, dynamic>> peerSnapshot() {
    return _onlineClientNodes().map(_toPeerJson).toList(growable: false);
  }

  bool isOnline(String deviceId) {
    final node = findByDeviceId(deviceId);
    return node?.presence.status == PresenceStatus.online;
  }

  void clear() {
    _byNodeId.clear();
    _nodeIdByDeviceId.clear();
    _nodeIdByServerId.clear();
  }

  UnifiedNode _resolveDeviceNode({
    required String deviceId,
    required String deviceName,
    required String label,
  }) {
    final deviceNodeId = _nodeIdByDeviceId[deviceId];
    if (deviceNodeId != null) {
      final existing = _byNodeId[deviceNodeId];
      if (existing != null) {
        return existing;
      }
    }
    final node = UnifiedNode(
      nodeId: 'client-device:$deviceId',
      kind: NodeKind.client,
      relations: const <NodeRelation>{NodeRelation.managed, NodeRelation.peer},
      identity: NodeIdentity(
        deviceId: deviceId,
        clientId: deviceId,
        displayName: deviceName,
        label: label,
        deviceName: deviceName,
      ),
      network: const NodeNetwork(),
      presence: const NodePresence(),
      runtime: const NodeRuntime(),
      management: const NodeManagement(),
      meta: NodeMeta(updatedAt: DateTime.now().toUtc()),
      client: const ClientFacet(
        deviceStatus: DeviceStatus.active,
        role: 'device',
      ),
    );
    _storeNode(node);
    return node;
  }

  Iterable<UnifiedNode> _onlineClientNodes() sync* {
    final clients =
        _byNodeId.values
            .where(
              (node) =>
                  node.kind == NodeKind.client &&
                  node.presence.status == PresenceStatus.online,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final leftId = left.identity.deviceId ?? '';
            final rightId = right.identity.deviceId ?? '';
            return leftId.compareTo(rightId);
          });
    yield* clients;
  }

  Map<String, dynamic> _toPresenceJson(UnifiedNode node) {
    return <String, dynamic>{
      if (_hasText(node.identity.deviceId)) 'deviceId': node.identity.deviceId,
      if (_hasText(node.identity.label)) 'label': node.identity.label,
      if (node.client != null) 'role': node.client!.role,
      if (_hasText(node.identity.deviceName))
        'deviceName': node.identity.deviceName,
      if (_hasText(node.identity.platform)) 'platform': node.identity.platform,
      if (_hasText(node.identity.brand)) 'brand': node.identity.brand,
      if (_hasText(node.identity.model)) 'model': node.identity.model,
      if (_hasText(node.network.reportedRouteIp))
        'reportedRouteIp': node.network.reportedRouteIp,
      if (_hasText(node.network.observedRemoteIp))
        'observedRemoteIp': node.network.observedRemoteIp,
      if (_hasText(node.identity.appVersion))
        'appVersion': node.identity.appVersion,
      if (_hasText(node.presence.connectionId))
        'connectionId': node.presence.connectionId,
      if (_hasText(node.presence.sessionId))
        'sessionId': node.presence.sessionId,
      'status': node.presence.status.name,
      if (node.presence.connectedAt != null)
        'connectedAt': node.presence.connectedAt!.toUtc().toIso8601String(),
      if (node.presence.lastSeenAt != null)
        'lastSeenAt': node.presence.lastSeenAt!.toUtc().toIso8601String(),
      ..._avatarUpdatedAtJson(node.identity.deviceId),
    };
  }

  Map<String, dynamic> _avatarUpdatedAtJson(String? deviceId) {
    final store = _avatarStore;
    final normalized = deviceId?.trim();
    if (store == null || normalized == null || normalized.isEmpty) {
      return const <String, dynamic>{};
    }
    final updatedAt = store.readUpdatedAtSync(normalized);
    if (updatedAt == null) {
      return const <String, dynamic>{};
    }
    return {'avatarUpdatedAt': updatedAt.toIso8601String()};
  }

  Map<String, dynamic> _toPeerJson(UnifiedNode node) {
    return <String, dynamic>{
      if (_hasText(node.identity.deviceId)) 'deviceId': node.identity.deviceId,
      if (_hasText(node.identity.label)) 'label': node.identity.label,
      if (_hasText(node.identity.deviceName))
        'deviceName': node.identity.deviceName,
      if (_hasText(node.identity.platform)) 'platform': node.identity.platform,
      if (_hasText(node.identity.brand)) 'brand': node.identity.brand,
      if (_hasText(node.identity.model)) 'model': node.identity.model,
      if (_hasText(node.network.reportedRouteIp))
        'reportedRouteIp': node.network.reportedRouteIp,
      if (_hasText(node.network.observedRemoteIp))
        'observedRemoteIp': node.network.observedRemoteIp,
      'status': node.presence.status.name,
      if (node.presence.connectedAt != null)
        'connectedAt': node.presence.connectedAt!.toUtc().toIso8601String(),
      if (node.presence.lastSeenAt != null)
        'lastSeenAt': node.presence.lastSeenAt!.toUtc().toIso8601String(),
      ..._avatarUpdatedAtJson(node.identity.deviceId),
    };
  }

  Map<String, dynamic> _toManagementJson(UnifiedNode node) {
    return <String, dynamic>{
      'nodeId': node.nodeId,
      if (_hasText(node.identity.deviceId)) 'deviceId': node.identity.deviceId,
      'displayName': node.identity.displayName,
      if (_hasText(node.identity.label)) 'label': node.identity.label,
      if (node.client != null) 'deviceStatus': node.client!.deviceStatus.name,
      'adminState': node.management.adminState.name,
      'status': node.presence.status.name,
      'allowedActions': node.management.allowedActions.toList(growable: false),
      if (_hasText(node.network.reportedRouteIp))
        'reportedRouteIp': node.network.reportedRouteIp,
      if (_hasText(node.network.observedRemoteIp))
        'observedRemoteIp': node.network.observedRemoteIp,
      if (node.meta.updatedFrom.isNotEmpty)
        'updatedFrom': node.meta.updatedFrom.toList(growable: false),
      'revision': node.meta.revision,
      'updatedAt': node.meta.updatedAt.toUtc().toIso8601String(),
    };
  }

  void _storeNode(UnifiedNode node, {UnifiedNode? previous}) {
    _byNodeId[node.nodeId] = node;
    _reindexNode(node, previous: previous);
  }

  void _reindexNode(UnifiedNode node, {UnifiedNode? previous}) {
    final previousDeviceId = previous?.identity.deviceId;
    if (_hasText(previousDeviceId) &&
        previousDeviceId != node.identity.deviceId &&
        _nodeIdByDeviceId[previousDeviceId!] == previous!.nodeId) {
      _nodeIdByDeviceId.remove(previousDeviceId);
    }
    final previousServerId = previous?.identity.serverId;
    if (_hasText(previousServerId) &&
        previousServerId != node.identity.serverId &&
        _nodeIdByServerId[previousServerId!] == previous!.nodeId) {
      _nodeIdByServerId.remove(previousServerId);
    }
    if (_hasText(node.identity.deviceId)) {
      _nodeIdByDeviceId[node.identity.deviceId!] = node.nodeId;
    }
    if (_hasText(node.identity.serverId)) {
      _nodeIdByServerId[node.identity.serverId!] = node.nodeId;
    }
  }

  NodeMeta _nextMeta(NodeMeta? current, DateTime updatedAt, String source) {
    return NodeMeta(
      updatedAt: updatedAt.toUtc(),
      updatedFrom: <String>{...?current?.updatedFrom, source},
      revision: (current?.revision ?? 0) + 1,
    );
  }

  NodeAdminState _mapAdminState(DeviceStatus status) {
    switch (status) {
      case DeviceStatus.active:
        return NodeAdminState.active;
      case DeviceStatus.disabled:
        return NodeAdminState.disabled;
      case DeviceStatus.revoked:
        return NodeAdminState.deleted;
    }
  }

  Set<String> _allowedActionsForStatus(DeviceStatus status) {
    switch (status) {
      case DeviceStatus.active:
        return const <String>{'relay', 'disable', 'delete', 'rotate'};
      case DeviceStatus.disabled:
        return const <String>{'delete', 'enable', 'rotate'};
      case DeviceStatus.revoked:
        return const <String>{'delete'};
    }
  }

  String _bestDisplayName({
    String? brand,
    String? model,
    String? deviceName,
    String? label,
    required String fallback,
  }) {
    if (_hasText(label)) {
      return label!.trim();
    }
    final parts = <String>[
      if (_hasText(brand)) brand!.trim(),
      if (_hasText(model)) model!.trim(),
    ];
    if (parts.isNotEmpty) {
      return parts.join(' ');
    }
    if (_hasText(deviceName)) {
      return deviceName!.trim();
    }
    return fallback.trim();
  }

  bool _hasText(String? value) => value != null && value.trim().isNotEmpty;
}
