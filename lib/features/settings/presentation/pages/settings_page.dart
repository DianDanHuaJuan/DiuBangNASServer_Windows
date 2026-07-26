// 文件输入：无
// 文件职责：设置页面，展示和编辑服务器配置
// 文件对外接口：SettingsPage
// 文件包含：SettingsPage
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/state/view_status.dart';
import '../../domain/entities/server_settings_entity.dart';
import '../../domain/entities/settings_apply_status.dart';
import '../../../device_identity/presentation/widgets/server_device_identity_card.dart';
import '../widgets/network_settings_card.dart';
import '../cubit/settings_cubit.dart';
import '../cubit/settings_state.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settingsCubit,
    this.includeDeviceIdentityCard = true,
    this.loadOwnerCredentialInfo = true,
  });

  final SettingsCubit settingsCubit;
  final bool includeDeviceIdentityCard;
  final bool loadOwnerCredentialInfo;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _portController;
  late final TextEditingController _storagePathController;
  ServerSettingsEntity? _lastSyncedSettings;

  bool _launchAtStartupEnabled = false;
  bool _hideToTrayOnClose = true;
  bool _minimizeToTray = true;
  bool _launchMinimizedToTray = false;
  bool _isMutating = false;
  String? _ownerUsername;
  bool _isDefaultOwnerCredential = false;
  SettingsApplyStatus _settingsApplyStatus = SettingsApplyStatus.idle;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '8080');
    _storagePathController = TextEditingController();
    _settingsApplyStatus = ServiceLocator.settingsApplyStatus.value;
    ServiceLocator.settingsApplyStatus.addListener(_onSettingsApplyStatusChanged);
    widget.settingsCubit.loadSettings();
    if (widget.loadOwnerCredentialInfo) {
      _loadOwnerInfo();
    }
  }

  void _onSettingsApplyStatusChanged() {
    final status = ServiceLocator.settingsApplyStatus.value;
    if (!mounted) {
      return;
    }

    if (status.errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(status.errorMessage!)));
    } else if (!status.isApplying &&
        status.message != null &&
        status.message!.contains('完成')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(status.message!)));
    }

    setState(() {
      _settingsApplyStatus = status;
    });
  }

  Future<void> _loadOwnerInfo() async {
    final store = ServiceLocator.ownerCredentialStore;
    final username = await store.getOwnerUsername();
    final isDefault = await store.isUsingDefaultOwnerCredential();
    if (mounted) {
      setState(() {
        _ownerUsername = username;
        _isDefaultOwnerCredential = isDefault;
      });
    }
  }

  @override
  void dispose() {
    ServiceLocator.settingsApplyStatus.removeListener(
      _onSettingsApplyStatusChanged,
    );
    _portController.dispose();
    _storagePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: widget.settingsCubit,
      child: BlocConsumer<SettingsCubit, SettingsState>(
        listenWhen: (previous, current) {
          return previous.errorMessage != current.errorMessage ||
              previous.successMessage != current.successMessage ||
              previous.settings != current.settings;
        },
        listener: (context, state) {
          if (state.errorMessage != null) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(state.errorMessage!)));
            widget.settingsCubit.clearMessages();
          }
          if (state.successMessage != null) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(state.successMessage!)));
            widget.settingsCubit.clearMessages();
          }
          final settings = state.settings;
          if (settings != null && !identical(settings, _lastSyncedSettings)) {
            _applySettingsToForm(settings);
          }
        },
        builder: (context, state) {
          return _buildBody(state);
        },
      ),
    );
  }

  Widget _buildBody(SettingsState state) {
    if (state.viewStatus == ViewStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.settings == null) {
      return const Center(child: Text('设置加载失败'));
    }

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const maxContentWidth = 1080.0;
          const horizontalPadding = 24.0;
          const sectionSpacing = 24.0;
          final useTwoColumns = constraints.maxWidth >= 800;

          return Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                horizontalPadding,
                16,
                horizontalPadding,
                32,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPageIntro(),
                    if (_settingsApplyStatus.isApplying) ...[
                      const SizedBox(height: 16),
                      _buildSettingsApplyBanner(),
                    ],
                    const SizedBox(height: sectionSpacing),
                    if (widget.includeDeviceIdentityCard) ...[
                      const ServerDeviceIdentityCard(),
                      const SizedBox(height: sectionSpacing),
                    ],
                    _buildAccountManagementCard(),
                    const SizedBox(height: sectionSpacing),
                    if (useTwoColumns) ...[
                      _buildDesktopCardRow(
                        left: _buildSharedDirectoryCard(),
                        right: _buildDesktopBehaviorCard(),
                      ),
                      const SizedBox(height: sectionSpacing),
                      _buildDesktopCardRow(
                        left: _buildNetworkSettingsCard(),
                        right: _buildServiceSettingsCard(),
                      ),
                    ] else ...[
                      _buildSharedDirectoryCard(),
                      const SizedBox(height: sectionSpacing),
                      _buildDesktopBehaviorCard(),
                      const SizedBox(height: sectionSpacing),
                      const NetworkSettingsCard(),
                      const SizedBox(height: sectionSpacing),
                      _buildServiceSettingsCard(),
                    ],
                    const SizedBox(height: 28),
                    _buildSaveButton(
                      state.isSaving,
                      useTwoColumns: useTwoColumns,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSettingsApplyBanner() {
    final message =
        _settingsApplyStatus.message ?? '正在后台应用设置，请稍候…';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceBright,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.lightDivider),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppTheme.lightCardForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageIntro() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '设置',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: AppTheme.lightCardForeground,
          ),
        ),
        SizedBox(height: 8),
        Text(
          '配置桌面行为、服务参数、网络地址、共享目录与账户安全。',
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: AppTheme.lightSecondaryText,
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopCardRow({required Widget left, required Widget right}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: 24),
          Expanded(child: right),
        ],
      ),
    );
  }

  Widget _buildNetworkSettingsCard() {
    return const NetworkSettingsCard();
  }

  Widget _buildServiceSettingsCard() {
    return _buildSettingsCard(
      title: '服务设置',
      subtitle: '监听端口配置',
      icon: Icons.tune_rounded,
      iconColor: AppTheme.accentColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextFieldBlock(
            label: '监听端口',
            description: '桌面端默认使用 8080。修改后客户端需用新地址重新连接。',
            child: TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: '请输入端口号'),
            ),
          ),
          const SizedBox(height: 20),
          _buildInlineNote(
            icon: Icons.info_outline_rounded,
            text: '修改端口后，客户端需要用新的地址重新连接。',
            backgroundColor: AppTheme.surfaceBright,
            iconColor: AppTheme.infoColor,
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopBehaviorCard() {
    return _buildSettingsCard(
      title: '桌面行为',
      subtitle: '托盘行为与启动方式',
      icon: Icons.desktop_windows_rounded,
      iconColor: AppTheme.infoColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSwitchSetting(
            title: '开机自启',
            description: '登录 Windows 后自动启动铥棒文件S。',
            value: _launchAtStartupEnabled,
            onChanged: (value) {
              setState(() {
                _launchAtStartupEnabled = value;
                if (!value) {
                  _launchMinimizedToTray = false;
                }
              });
            },
          ),
          _buildCardDivider(),
          _buildSwitchSetting(
            title: '关闭窗口时隐藏到托盘',
            description: '点击关闭后继续在后台提供服务。',
            value: _hideToTrayOnClose,
            onChanged: (value) {
              setState(() => _hideToTrayOnClose = value);
            },
          ),
          _buildCardDivider(),
          _buildSwitchSetting(
            title: '最小化时隐藏到托盘',
            description: '从任务栏隐藏，仅保留托盘图标。',
            value: _minimizeToTray,
            onChanged: (value) {
              setState(() => _minimizeToTray = value);
            },
          ),
          _buildCardDivider(),
          _buildSwitchSetting(
            title: '随系统启动时最小化到托盘',
            description: '只在开机自启时生效。',
            value: _launchMinimizedToTray,
            enabled: _launchAtStartupEnabled,
            onChanged: (value) {
              setState(() => _launchMinimizedToTray = value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSharedDirectoryCard() {
    return _buildSettingsCard(
      title: '共享目录',
      subtitle: '所有上传和备份的文件都将保存在本目录',
      icon: Icons.folder_rounded,
      iconColor: AppTheme.accentColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextFieldBlock(
            label: '共享目录路径',
            description: '支持直接输入路径，或使用下方按钮浏览文件夹。',
            child: TextField(
              controller: _storagePathController,
              maxLines: 1,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: r'例如：D:\DiuBangShare',
              ),
            ),
          ),
          const SizedBox(height: 18),
          _buildInlineNote(
            icon: Icons.shield_outlined,
            text: '不支持盘符根目录、系统目录、用户主目录根或网络共享路径。',
            backgroundColor: AppTheme.successContainer,
            iconColor: AppTheme.accentColor,
          ),
          const SizedBox(height: 16),
          _buildInlineNote(
            icon: Icons.info_outline_rounded,
            text: '包含大量文件的目录可能使系统文件夹对话框响应较慢，也可直接输入路径。',
            backgroundColor: AppTheme.surfaceBright,
            iconColor: AppTheme.infoColor,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _pickStorageDirectory,
              icon: const Icon(Icons.folder_open),
              label: const Text('浏览文件夹'),
              style: _outlineActionButtonStyle(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountManagementCard() {
    return _buildSettingsCard(
      title: '账户管理',
      subtitle: '管理员登录凭据（用于客户端账密接入）',
      icon: Icons.admin_panel_settings_outlined,
      iconColor: AppTheme.accentColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('账号', _ownerUsername ?? '--'),
          const SizedBox(height: 8),
          _buildInfoRow(
            '默认凭据',
            _isDefaultOwnerCredential ? '未修改' : '已修改',
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _isMutating ? null : _showUpdateOwnerCredentialDialog,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('修改用户名和密码'),
            style: _outlineActionButtonStyle(),
          ),
        ],
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
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.lightCardForeground,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showUpdateOwnerCredentialDialog() async {
    if (_ownerUsername == null) {
      await _loadOwnerInfo();
    }
    if (!mounted) {
      return;
    }
    final ownerUsername = _ownerUsername;
    if (ownerUsername == null) {
      return;
    }

    final request = await showDialog<_OwnerCredentialUpdateRequest>(
      context: context,
      builder: (_) =>
          _OwnerCredentialUpdateDialog(initialUsername: ownerUsername),
    );
    if (request == null) {
      return;
    }

    setState(() => _isMutating = true);
    try {
      final store = ServiceLocator.ownerCredentialStore;
      final isCurrentCredentialValid = await store.verifyOwnerCredential(
        username: ownerUsername,
        password: request.currentPassword,
      );
      if (!isCurrentCredentialValid) {
        throw StateError('当前管理员密码不正确');
      }

      await store.updateOwnerCredential(
        username: request.newUsername,
        password: request.newPassword,
      );
      await _loadOwnerInfo();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('管理员账户已更新')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Widget _buildSaveButton(bool isSaving, {required bool useTwoColumns}) {
    final button = FilledButton.icon(
      onPressed: isSaving ? null : _saveSettings,
      icon: isSaving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.save_outlined, size: 18),
      label: Text(isSaving ? '保存中...' : '保存设置'),
      style: FilledButton.styleFrom(
        minimumSize: Size(useTwoColumns ? 220 : double.infinity, 48),
        backgroundColor: AppTheme.accentColor,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );

    if (useTwoColumns) {
      return Align(alignment: Alignment.center, child: button);
    }

    return SizedBox(width: double.infinity, child: button);
  }

  Widget _buildSettingsCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 312),
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      decoration: _moduleDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceBright,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 22, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.lightCardForeground,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: AppTheme.lightSecondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          child,
        ],
      ),
    );
  }

  Widget _buildTextFieldBlock({
    required String label,
    required String description,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.lightCardForeground,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          description,
          style: const TextStyle(
            fontSize: 12,
            height: 1.5,
            color: AppTheme.lightSecondaryText,
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildSwitchSetting({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? AppTheme.lightCardForeground
                        : AppTheme.lightSecondaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: enabled
                        ? AppTheme.lightSecondaryText
                        : AppTheme.lightDivider,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Transform.scale(
            scale: 0.92,
            child: Switch(
              value: value,
              activeThumbColor: Colors.white,
              activeTrackColor: AppTheme.successColor,
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: AppTheme.lightDivider,
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Divider(height: 1, color: AppTheme.surfaceContainerHigh),
    );
  }

  Widget _buildInlineNote({
    required IconData icon,
    required String text,
    required Color backgroundColor,
    required Color iconColor,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: AppTheme.lightCardForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle _outlineActionButtonStyle() {
    return OutlinedButton.styleFrom(
      foregroundColor: AppTheme.accentColor,
      side: const BorderSide(color: AppTheme.accentColor, width: 1),
      minimumSize: const Size(160, 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    );
  }

  BoxDecoration _moduleDecoration() {
    return BoxDecoration(
      color: AppTheme.lightCard,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppTheme.lightDivider, width: 1),
      boxShadow: const [
        BoxShadow(
          color: Color(0x08000000),
          blurRadius: 3,
          offset: Offset(0, 1),
        ),
      ],
    );
  }

  Future<void> _pickStorageDirectory() async {
    final initialDirectory = _storagePathController.text.trim();
    final selectedDirectory = await getDirectoryPath(
      confirmButtonText: '选择共享目录',
      initialDirectory:
          initialDirectory.isNotEmpty &&
              Directory(initialDirectory).existsSync()
          ? initialDirectory
          : null,
    );
    if (selectedDirectory == null || selectedDirectory.trim().isEmpty) {
      return;
    }
    setState(() {
      _storagePathController.text = selectedDirectory;
    });
  }

  void _applySettingsToForm(ServerSettingsEntity settings) {
    _lastSyncedSettings = settings;
    _portController.text = settings.port.toString();
    _storagePathController.text = settings.storagePath;
    if (!mounted) {
      return;
    }
    setState(() {
      _launchAtStartupEnabled = settings.launchAtStartupEnabled;
      _hideToTrayOnClose = settings.hideToTrayOnClose;
      _minimizeToTray = settings.minimizeToTray;
      _launchMinimizedToTray = settings.launchMinimizedToTray;
    });
  }

  void _saveSettings() {
    final port = int.tryParse(_portController.text.trim());
    if (port == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的端口号')));
      return;
    }

    widget.settingsCubit.updateSettings(
      port: port,
      storagePath: _storagePathController.text.trim(),
      launchAtStartupEnabled: _launchAtStartupEnabled,
      hideToTrayOnClose: _hideToTrayOnClose,
      minimizeToTray: _minimizeToTray,
      launchMinimizedToTray: _launchMinimizedToTray,
    );
  }
}

class _OwnerCredentialUpdateRequest {
  const _OwnerCredentialUpdateRequest({
    required this.currentPassword,
    required this.newUsername,
    required this.newPassword,
  });

  final String currentPassword;
  final String newUsername;
  final String newPassword;
}

class _OwnerCredentialUpdateDialog extends StatefulWidget {
  const _OwnerCredentialUpdateDialog({required this.initialUsername});

  final String initialUsername;

  @override
  State<_OwnerCredentialUpdateDialog> createState() =>
      _OwnerCredentialUpdateDialogState();
}

class _OwnerCredentialUpdateDialogState
    extends State<_OwnerCredentialUpdateDialog> {
  late final TextEditingController _usernameController = TextEditingController(
    text: widget.initialUsername,
  );
  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _submit() {
    final newUsername = _usernameController.text.trim();
    final currentPassword = _currentPasswordController.text;
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (newUsername.isEmpty) {
      setState(() => _errorMessage = '管理员用户名不能为空');
      return;
    }
    if (currentPassword.isEmpty) {
      setState(() => _errorMessage = '请输入当前管理员密码');
      return;
    }
    if (newPassword.isEmpty) {
      setState(() => _errorMessage = '请输入新的管理员密码');
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() => _errorMessage = '两次输入的新密码不一致');
      return;
    }

    Navigator.of(context).pop(
      _OwnerCredentialUpdateRequest(
        currentPassword: currentPassword,
        newUsername: newUsername,
        newPassword: newPassword,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改管理员用户名和密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: '新的管理员用户名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _currentPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '当前管理员密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '新的管理员密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '确认新的管理员密码',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.errorColor,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('更新')),
      ],
    );
  }
}
