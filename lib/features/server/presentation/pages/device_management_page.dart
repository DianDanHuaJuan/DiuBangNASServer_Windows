import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/device_registry/device_models.dart';
import '../../../../core/device_registry/device_registry_admin.dart';
import '../../../../core/runtime/runtime_presence_bridge.dart';

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({super.key});

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage>
    with AutomaticKeepAliveClientMixin {
  bool _isLoading = true;
  bool _isMutating = false;
  String? _errorMessage;
  List<_ManagedDevice> _devices = const [];
  Timer? _refreshTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _reload(showLoadingIndicator: false);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  DeviceRegistryAdmin get _deviceRegistryAdmin =>
      ServiceLocator.deviceRegistryAdmin;

  Future<void> _reload({bool showLoadingIndicator = true}) async {
    if (showLoadingIndicator) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final devices = await ServiceLocator.serverDeviceIdentityService
          .listEnrolledClientDevices();
      await RuntimePresenceBridge.instance.refresh();

      final serverRunning = ServiceLocator.isServerRunning;
      final managedDevices = devices.map((device) {
        final isOnline = serverRunning &&
            RuntimePresenceBridge.instance.isOnline(device.deviceId);
        return _ManagedDevice(device: device, isOnline: isOnline);
      }).toList()
        ..sort((left, right) {
          if (left.isOnline && !right.isOnline) return -1;
          if (!left.isOnline && right.isOnline) return 1;
          final leftSeen = left.device.lastSeenAt ?? DateTime(2000);
          final rightSeen = right.device.lastSeenAt ?? DateTime(2000);
          return rightSeen.compareTo(leftSeen);
        });

      if (!mounted) return;
      setState(() {
        _devices = managedDevices;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '加载设备列表失败：$error';
        _isLoading = false;
      });
    }
  }

  Future<T?> _runMutation<T>(Future<T> Function() action) async {
    if (_isMutating) {
      return null;
    }

    setState(() => _isMutating = true);
    try {
      return await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Future<void> _updateDeviceStatus(
    DeviceSummary device,
    DeviceStatus status,
  ) async {
    final targetLabel = switch (status) {
      DeviceStatus.active => '启用',
      DeviceStatus.disabled => '禁用',
      DeviceStatus.revoked => '撤销',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('$targetLabel设备'),
          content: Text('确认${targetLabel} ${device.deviceName} 吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(targetLabel),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final updated = await _runMutation(() async {
      await _deviceRegistryAdmin.updateDeviceStatus(
        deviceId: device.deviceId,
        status: status,
      );
      await _reload(showLoadingIndicator: false);
      return true;
    });
    if (updated == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('设备已$targetLabel')));
    }
  }

  Future<void> _deleteDevice(DeviceSummary device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除设备'),
          content: Text('确认删除 ${device.deviceName} 吗？删除后该设备需要重新扫码接入。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.errorColor,
              ),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final deleted = await _runMutation(() async {
      await _deviceRegistryAdmin.deleteDevice(device.deviceId);
      await _reload(showLoadingIndicator: false);
      return true;
    });
    if (deleted == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('设备已删除')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_errorMessage != null)
            _buildErrorCard()
          else if (_devices.isEmpty)
            _buildEmptyCard()
          else
            _buildDeviceGrid(),
        ],
      ),
    );
  }

  Widget _buildDeviceGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 860 ? 2 : 1;
        const spacing = 16.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (crossAxisCount - 1)) /
            crossAxisCount;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '接入设备',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.lightCardForeground,
                    ),
                  ),
                ),
                Text(
                  '共 ${_devices.length} 个',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.lightSecondaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '在线 ${_devices.where((device) => device.isOnline).length} 个 · 离线 ${_devices.where((device) => !device.isOnline).length} 个',
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.lightSecondaryText,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: _devices
                  .map(
                    (device) => SizedBox(
                      width: itemWidth,
                      child: _buildDeviceCard(device),
                    ),
                  )
                  .toList(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDeviceCard(_ManagedDevice deviceInfo) {
    final device = deviceInfo.device;
    final isOnline = deviceInfo.isOnline;
    final displayName = device.label?.trim().isNotEmpty == true
        ? device.label!.trim()
        : device.deviceName;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isOnline ? const Color(0xFFF0F9F0) : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOnline ? const Color(0xFF90D690) : AppTheme.lightDivider,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isOnline
                      ? const Color(0xFF90D690).withValues(alpha: 0.2)
                      : AppTheme.lightDivider.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isOnline
                      ? Icons.smartphone_rounded
                      : Icons.smartphone_outlined,
                  color: isOnline
                      ? const Color(0xFF2E7D32)
                      : AppTheme.lightSecondaryText,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.lightCardForeground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isOnline
                                ? AppTheme.successColor
                                : AppTheme.lightLabel,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isOnline ? '在线' : '离线',
                          style: TextStyle(
                            fontSize: 12,
                            color: isOnline
                                ? AppTheme.successColor
                                : AppTheme.lightLabel,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (displayName != device.deviceName) ...[
                      const SizedBox(height: 2),
                      Text(
                        device.deviceName,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.lightSecondaryText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _buildStatusBadge(device.status),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          _buildInfoRow('设备 ID', device.deviceId),
          const SizedBox(height: 6),
          _buildInfoRow('平台', device.platform ?? '--'),
          const SizedBox(height: 6),
          _buildInfoRow(
            '最近在线',
            device.lastSeenAt == null
                ? '--'
                : _formatDateTime(device.lastSeenAt!),
          ),
          const SizedBox(height: 6),
          _buildInfoRow('首次接入', _formatDateTime(device.firstPairedAt)),
          const SizedBox(height: 12),
          Row(
            children: [
              if (device.status == DeviceStatus.disabled)
                _buildDeviceActionButton(
                  onPressed: _isMutating
                      ? null
                      : () => _updateDeviceStatus(device, DeviceStatus.active),
                  icon: Icons.check_circle_outline,
                  label: '启用',
                  foregroundColor: AppTheme.successColor,
                )
              else if (device.status == DeviceStatus.active)
                _buildDeviceActionButton(
                  onPressed: _isMutating
                      ? null
                      : () => _updateDeviceStatus(device, DeviceStatus.disabled),
                  icon: Icons.pause_circle_outline,
                  label: '禁用',
                  foregroundColor: AppTheme.lightSecondaryText,
                ),
              const SizedBox(width: 8),
              _buildDeviceActionButton(
                onPressed: _isMutating ? null : () => _deleteDevice(device),
                icon: Icons.delete_outline,
                label: '删除',
                foregroundColor: AppTheme.lightSecondaryText,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required Color foregroundColor,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: foregroundColor,
        side: BorderSide(color: foregroundColor.withValues(alpha: 0.4), width: 1),
        minimumSize: const Size(80, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildEmptyCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.lightCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.lightDivider),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.devices_other_outlined,
            size: 48,
            color: AppTheme.lightLabel,
          ),
          SizedBox(height: 16),
          Text(
            '还没有接入的设备',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.lightCardForeground,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '客户端扫码配对成功后，设备会显示在这里。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.lightSecondaryText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.lightCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.lightDivider),
      ),
      child: Column(
        children: [
          Text(_errorMessage!),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _reload, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(DeviceStatus status) {
    final label = switch (status) {
      DeviceStatus.active => '正常',
      DeviceStatus.disabled => '已禁用',
      DeviceStatus.revoked => '已撤销',
    };
    final color = switch (status) {
      DeviceStatus.active => AppTheme.successColor,
      DeviceStatus.disabled => AppTheme.warningColor,
      DeviceStatus.revoked => AppTheme.errorColor,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppTheme.lightLabel),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.lightCardForeground,
            ),
          ),
        ),
      ],
    );
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }
}

class _ManagedDevice {
  const _ManagedDevice({required this.device, required this.isOnline});

  final DeviceSummary device;
  final bool isOnline;
}
