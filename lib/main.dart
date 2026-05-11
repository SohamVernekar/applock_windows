import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_lock_settings_store.dart';
import 'services/local_auth_service.dart';
import 'services/windows_app_picker_service.dart';
import 'services/windows_locked_app_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 840),
    minimumSize: Size(1040, 760),
    center: true,
    title: 'Windows Hello Vault',
    backgroundColor: Colors.transparent,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const canvas = Color(0xFF0F0C16);
    const panel = Color(0xFF17141F);
    const ink = Color(0xFFF4EEF8);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: canvas,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5FA8FF),
          secondary: Color(0xFF63F5D2),
          surface: panel,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: ink,
            letterSpacing: -0.8,
          ),
          bodyLarge: TextStyle(
            fontSize: 15,
            height: 1.5,
            color: Color(0xFFD3CBDD),
          ),
          bodyMedium: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: Color(0xFFB3A8C2),
          ),
        ),
      ),
      home: const AppLockDashboard(),
    );
  }
}

enum UnlockPhase { locked, authenticating, unlocked }

class AppLockDashboard extends StatefulWidget {
  const AppLockDashboard({super.key});

  @override
  State<AppLockDashboard> createState() => _AppLockDashboardState();
}

class _AppLockDashboardState extends State<AppLockDashboard>
    with WindowListener {
  final LocalAuthService _authService = LocalAuthService();
  final AppLockSettingsStore _settingsStore = AppLockSettingsStore();
  final WindowsAppPickerService _appPickerService = WindowsAppPickerService();
  final WindowsLockedAppService _lockedAppService = WindowsLockedAppService();

  bool _isHardwareSupported = false;
  bool _isEnrolled = false;
  bool _isLoading = true;
  bool _windowsHelloPassed = false;
  bool _ignoreBlurLockWhileProtectedAppIsActive = false;
  UnlockPhase _unlockPhase = UnlockPhase.locked;
  AppLockSettings _settings = const AppLockSettings.defaults();
  LockedAppMatch? _pendingLockedApp;

  String _authStatus =
      'Use Windows Hello to unlock your protected desktop workspace.';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final settings = await _settingsStore.load();
    final supported = await _authService.isDeviceSupported();
    final enrolled = await _authService.canAuthenticate();
    if (!mounted) return;

    setState(() {
      _settings = settings;
      _isHardwareSupported = supported;
      _isEnrolled = enrolled;
      _isLoading = false;
      _unlockPhase =
          settings.lockOnLaunch ? UnlockPhase.locked : UnlockPhase.unlocked;
      _windowsHelloPassed = !settings.lockOnLaunch;
      _authStatus = settings.onboardingCompleted
          ? 'Choose protected desktop apps and Windows Hello will guard them before access is handed over.'
          : 'Set up your lock preferences, then start adding desktop apps you want to protect.';
    });

    _syncWatcher();
  }

  Future<void> _checkHardware() async {
    final supported = await _authService.isDeviceSupported();
    final enrolled = await _authService.canAuthenticate();
    if (!mounted) return;

    setState(() {
      _isHardwareSupported = supported;
      _isEnrolled = enrolled;
    });
  }

  Future<void> _updateSettings(AppLockSettings settings) async {
    setState(() {
      _settings = settings;
    });
    await _settingsStore.save(settings);
    _syncWatcher();
  }

  Future<void> _completeOnboarding() async {
    final next = _settings.copyWith(
      onboardingCompleted: true,
      protectionEnabled: true,
    );
    await _updateSettings(next);
    if (!mounted) return;

    setState(() {
      _authStatus =
          'Setup complete. Add the apps you want protected, then Windows Hello will guard them before launch access.';
    });
  }

  Future<void> _pickAndAddLockedApplication() async {
    final path = await _appPickerService.pickExecutablePath();
    if (!mounted || path == null || path.isEmpty) {
      return;
    }

    final normalizedPath = _normalizePath(path);
    final exists = _settings.lockedApplications.any(
      (app) => _normalizePath(app.executablePath) == normalizedPath,
    );

    if (exists) {
      setState(() {
        _authStatus = 'That application is already protected.';
      });
      return;
    }

    final nextApps = [
      ..._settings.lockedApplications,
      LockedApplication(
        displayName: _displayNameFromPath(path),
        executablePath: path,
      ),
    ];

    await _updateSettings(_settings.copyWith(lockedApplications: nextApps));
    if (!mounted) return;

    setState(() {
      _authStatus =
          '${_displayNameFromPath(path)} is now protected. When it comes to the foreground while locked, this vault will step in first.';
    });
  }

  Future<void> _removeLockedApplication(LockedApplication app) async {
    final nextApps = _settings.lockedApplications
        .where((entry) => _normalizePath(entry.executablePath) !=
            _normalizePath(app.executablePath))
        .toList();

    await _updateSettings(_settings.copyWith(lockedApplications: nextApps));
    if (!mounted) return;

    setState(() {
      if (_pendingLockedApp?.application.executablePath == app.executablePath) {
        _pendingLockedApp = null;
      }
      _authStatus = '${app.displayName} was removed from protection.';
    });
  }

  Future<void> _triggerAuthentication() async {
    if (!_settings.protectionEnabled) {
      setState(() {
        _authStatus =
            'Finish setup first so the app knows how you want protection to behave.';
      });
      return;
    }

    if (!_isHardwareSupported || !_isEnrolled) {
      setState(() {
        _authStatus =
            'Windows Hello is not ready yet. Check device support and enrollment first.';
      });
      return;
    }

    setState(() {
      _unlockPhase = UnlockPhase.authenticating;
      _authStatus = _pendingLockedApp == null
          ? 'Authenticating with Windows Hello...'
          : 'Authenticating before opening ${_pendingLockedApp!.application.displayName}...';
    });

    final success = await _authService.authenticateWithWindowsHello();
    if (!mounted) return;

    if (!success) {
      setState(() {
        _unlockPhase = UnlockPhase.locked;
        _windowsHelloPassed = false;
        _authStatus = 'Windows Hello authentication failed or was cancelled.';
      });
      _syncWatcher();
      return;
    }

    final pendingMatch = _pendingLockedApp;

    setState(() {
      _unlockPhase = UnlockPhase.unlocked;
      _windowsHelloPassed = true;
      _authStatus = pendingMatch == null
          ? 'Access granted. Your identity has been verified.'
          : 'Access granted. ${pendingMatch.application.displayName} is ready to continue.';
      _pendingLockedApp = null;
    });

    _syncWatcher();

    if (pendingMatch != null) {
      await windowManager.setAlwaysOnTop(false);
      _ignoreBlurLockWhileProtectedAppIsActive = true;
      _lockedAppService.restoreWindow(pendingMatch.windowHandle);
    }
  }

  void _lockApp([String? reason]) {
    setState(() {
      _unlockPhase = UnlockPhase.locked;
      _windowsHelloPassed = false;
      _pendingLockedApp = null;
      _authStatus = reason ?? 'Workspace locked.';
    });
    _syncWatcher();
  }

  void _syncWatcher() {
    _lockedAppService.startWatching(
      applications: _settings.lockedApplications,
      enabled: _settings.protectionEnabled,
      sessionUnlocked: _unlockPhase == UnlockPhase.unlocked,
      onLockedAppDetected: _handleLockedAppDetected,
    );
  }

  Future<void> _handleLockedAppDetected(LockedAppMatch match) async {
    _lockedAppService.minimizeWindow(match.windowHandle);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
    if (!mounted) return;

    setState(() {
      _pendingLockedApp = match;
      _unlockPhase = UnlockPhase.locked;
      _windowsHelloPassed = false;
      _authStatus =
          '${match.application.displayName} was intercepted. Verify with Windows Hello to continue into that app.';
    });

    _syncWatcher();
  }

  @override
  void onWindowFocus() {
    _ignoreBlurLockWhileProtectedAppIsActive = false;
  }

  @override
  void onWindowBlur() {
    if (_ignoreBlurLockWhileProtectedAppIsActive) {
      return;
    }

    if (_settings.protectionEnabled &&
        _settings.autoLockOnBlur &&
        _unlockPhase == UnlockPhase.unlocked) {
      _lockApp('Workspace locked after the window lost focus.');
    }
  }

  @override
  void onWindowMinimize() {
    if (_settings.protectionEnabled &&
        _settings.autoLockOnMinimize &&
        _unlockPhase == UnlockPhase.unlocked) {
      _lockApp('Workspace locked after the window was minimized.');
    }
  }

  @override
  void dispose() {
    _lockedAppService.stopWatching();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Stack(
          children: [
            _Backdrop(),
            Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }

    final isUnlocked = _unlockPhase == UnlockPhase.unlocked;
    final isInterceptOverlayVisible = _pendingLockedApp != null;

    return Scaffold(
      body: Stack(
        children: [
          const _Backdrop(),
          SafeArea(
            child: isInterceptOverlayVisible
                ? _buildInterceptOverlay()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 1020;

                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1260),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildTopBar(isUnlocked),
                                const SizedBox(height: 28),
                                compact
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _buildHero(isUnlocked),
                                          const SizedBox(height: 20),
                                          if (!_settings.onboardingCompleted) ...[
                                            _buildSetupPanel(),
                                            const SizedBox(height: 20),
                                          ],
                                          _buildSystemSnapshot(),
                                          const SizedBox(height: 20),
                                          _buildProtectedAppsPanel(),
                                          const SizedBox(height: 20),
                                          isUnlocked
                                              ? _buildUnlockedView()
                                              : _buildLockedView(),
                                        ],
                                      )
                                    : Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            flex: 7,
                                            child: Column(
                                              children: [
                                                _buildHero(isUnlocked),
                                                const SizedBox(height: 20),
                                                if (!_settings
                                                    .onboardingCompleted) ...[
                                                  _buildSetupPanel(),
                                                  const SizedBox(height: 20),
                                                ],
                                                _buildProtectedAppsPanel(),
                                                const SizedBox(height: 20),
                                                isUnlocked
                                                    ? _buildUnlockedView()
                                                    : _buildLockedView(),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 20),
                                          Expanded(
                                            flex: 4,
                                            child: _buildSystemSnapshot(),
                                          ),
                                        ],
                                      ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInterceptOverlay() {
    final pendingApp = _pendingLockedApp!.application;
    final isAuthenticating = _unlockPhase == UnlockPhase.authenticating;
    final canUnlock = _settings.protectionEnabled &&
        _isHardwareSupported &&
        _isEnrolled &&
        !isAuthenticating;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Container(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
            decoration: BoxDecoration(
              color: const Color(0xF2141219),
              borderRadius: BorderRadius.circular(34),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 50,
                  offset: Offset(0, 24),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF5FA8FF).withValues(alpha: 0.14),
                    border: Border.all(
                      color: const Color(0xFF72A9FF).withValues(alpha: 0.24),
                    ),
                  ),
                  child: const Icon(
                    Icons.fingerprint_rounded,
                    size: 38,
                    color: Color(0xFF72A9FF),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  pendingApp.displayName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Use Windows Hello to continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFD5D0DE),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isAuthenticating
                      ? 'Waiting for Windows Hello...'
                      : 'This protected app is paused until your identity is verified.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Color(0xFFACA2BB),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.045),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isEnrolled
                            ? Icons.verified_user_rounded
                            : Icons.info_outline_rounded,
                        size: 18,
                        color: _isEnrolled
                            ? const Color(0xFF7BF7AE)
                            : const Color(0xFFFFC66D),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _isEnrolled
                              ? 'Fingerprint, face, or PIN can unlock this app.'
                              : 'Windows Hello needs to be configured first.',
                          style: const TextStyle(
                            color: Color(0xFFE6E0EE),
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: canUnlock ? _triggerAuthentication : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF5FA8FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Text(
                      isAuthenticating
                          ? 'Authenticating...'
                          : 'Continue with Windows Hello',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: isAuthenticating ? null : _lockApp,
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isUnlocked) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white10),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.security_rounded, color: Color(0xFF72A9FF)),
              SizedBox(width: 10),
              Text(
                'Windows Hello Vault',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        const Spacer(),
        _Pill(
          label: isUnlocked ? 'Session Open' : 'Session Locked',
          color: isUnlocked ? const Color(0xFF7BF7AE) : const Color(0xFF72A9FF),
        ),
        const SizedBox(width: 12),
        FilledButton.tonalIcon(
          onPressed: isUnlocked ? _lockApp : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
          ),
          icon: const Icon(Icons.lock_outline_rounded),
          label: const Text('Lock Now'),
        ),
      ],
    );
  }

  Widget _buildHero(bool isUnlocked) {
    final pendingName = _pendingLockedApp?.application.displayName;

    return _Panel(
      padding: const EdgeInsets.all(28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 94,
            height: 94,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isUnlocked
                    ? const [Color(0xFF1E6E47), Color(0xFF45C774)]
                    : const [Color(0xFF203554), Color(0xFF467DFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(
              isUnlocked ? Icons.lock_open_rounded : Icons.shield_rounded,
              size: 42,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pendingName == null
                      ? (isUnlocked
                          ? 'Workspace Verified'
                          : 'Biometric Desktop Lock')
                      : 'Protected Launch Intercepted',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(_authStatus, style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _Pill(
                      label: _settings.protectionEnabled
                          ? 'Protection Enabled'
                          : 'Setup Required',
                      color: _settings.protectionEnabled
                          ? const Color(0xFF63F5D2)
                          : const Color(0xFFFFC66D),
                    ),
                    _Pill(
                      label: _settings.lockedApplications.isEmpty
                          ? 'No Protected Apps Yet'
                          : '${_settings.lockedApplications.length} App${_settings.lockedApplications.length == 1 ? '' : 's'} Protected',
                      color: const Color(0xFF72A9FF),
                    ),
                    _Pill(
                      label: _windowsHelloPassed
                          ? 'Identity Verified'
                          : 'Identity Pending',
                      color: _windowsHelloPassed
                          ? const Color(0xFF7BF7AE)
                          : const Color(0xFF72A9FF),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupPanel() {
    return _Panel(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'First-Time Setup',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose how strict the lock should feel. After setup, you can add any desktop programs you want this vault to intercept.',
            style: TextStyle(color: Color(0xFFB5A9C5), height: 1.5),
          ),
          const SizedBox(height: 22),
          _buildToggleTile(
            title: 'Enable protection',
            subtitle:
                'Require Windows Hello before opening any protected application.',
            value: _settings.protectionEnabled,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(protectionEnabled: value));
            },
          ),
          _buildToggleTile(
            title: 'Auto-lock on minimize',
            subtitle: 'Lock the vault whenever this app is minimized.',
            value: _settings.autoLockOnMinimize,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(autoLockOnMinimize: value));
            },
          ),
          _buildToggleTile(
            title: 'Auto-lock on focus loss',
            subtitle:
                'Relock when you switch away from the vault after an unlocked session.',
            value: _settings.autoLockOnBlur,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(autoLockOnBlur: value));
            },
          ),
          _buildToggleTile(
            title: 'Start locked',
            subtitle: 'Open the vault in a locked state every launch.',
            value: _settings.lockOnLaunch,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(lockOnLaunch: value));
            },
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _completeOnboarding,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF467DFF),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            ),
            icon: const Icon(Icons.task_alt_rounded),
            label: const Text('Finish Setup'),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemSnapshot() {
    final watchedApp = _pendingLockedApp?.application.displayName ?? 'Standing by';

    return _Panel(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'System Snapshot',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'A quick read on your Windows Hello readiness and how the protection layer is behaving.',
            style: TextStyle(color: Color(0xFFAA9FB8), height: 1.5),
          ),
          const SizedBox(height: 22),
          _buildStatusCard(
            title: 'Windows Hello',
            accent: const Color(0xFF72A9FF),
            icon: Icons.fingerprint_rounded,
            rows: [
              _StatusLine(
                label: 'Hardware',
                value: _isHardwareSupported ? 'Ready' : 'Unavailable',
                isOk: _isHardwareSupported,
              ),
              _StatusLine(
                label: 'Enrollment',
                value: _isEnrolled ? 'Configured' : 'Not configured',
                isOk: _isEnrolled,
              ),
              _StatusLine(
                label: 'Verification',
                value: _windowsHelloPassed ? 'Passed' : 'Pending',
                isOk: _windowsHelloPassed,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildStatusCard(
            title: 'Protected Launches',
            accent: const Color(0xFF63F5D2),
            icon: Icons.apps_rounded,
            rows: [
              _StatusLine(
                label: 'Protected apps',
                value: '${_settings.lockedApplications.length}',
                isOk: _settings.lockedApplications.isNotEmpty,
              ),
              _StatusLine(
                label: 'Vault mode',
                value: _settings.protectionEnabled ? 'Armed' : 'Standby',
                isOk: _settings.protectionEnabled,
              ),
              _StatusLine(
                label: 'Current intercept',
                value: watchedApp,
                isOk: _pendingLockedApp != null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard({
    required String title,
    required Color accent,
    required IconData icon,
    required List<_StatusLine> rows,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF1C1825), Color(0xFF14111B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(
                    row.isOk
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: row.isOk ? const Color(0xFF7BF7AE) : Colors.white30,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      row.label,
                      style: const TextStyle(color: Color(0xFFBEB4C9)),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      row.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: row.isOk ? Colors.white : const Color(0xFF8E839C),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProtectedAppsPanel() {
    return _Panel(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Protected Apps',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Choose desktop programs to intercept. When a protected app opens while the vault is locked, this screen appears first.',
                      style: TextStyle(
                        color: Color(0xFFB5A9C5),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: _pickAndAddLockedApplication,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF467DFF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                ),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Application'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_settings.lockedApplications.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white10),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No protected apps yet',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Add an `.exe` from your PC and the vault will intercept it whenever the session is locked.',
                    style: TextStyle(color: Color(0xFFAA9FB8), height: 1.45),
                  ),
                ],
              ),
            )
          else
            Column(
              children: _settings.lockedApplications
                  .map(
                    (app) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ProtectedAppTile(
                        application: app,
                        isPending: _pendingLockedApp?.application.executablePath ==
                            app.executablePath,
                        onRemove: () => _removeLockedApplication(app),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildLockedView() {
    final canUnlock = _isHardwareSupported &&
        _settings.protectionEnabled &&
        _isEnrolled &&
        _unlockPhase != UnlockPhase.authenticating;

    return _Panel(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Unlock Console',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            _pendingLockedApp == null
                ? 'The vault is waiting. Protected apps stay behind this screen until Windows Hello succeeds.'
                : '${_pendingLockedApp!.application.displayName} is waiting behind the vault. Authenticate to continue into that app.',
            style: const TextStyle(color: Color(0xFFB5A9C5), height: 1.5),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 840;
              final timeline = _buildTimeline();
              final authPanel = _buildAuthPanel(canUnlock);

              if (stacked) {
                return Column(
                  children: [
                    timeline,
                    const SizedBox(height: 18),
                    authPanel,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 4, child: timeline),
                  const SizedBox(width: 18),
                  Expanded(flex: 5, child: authPanel),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Launch Sequence',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          const _TimelineStep(
            step: '01',
            title: 'Select protected apps',
            subtitle:
                'Choose the desktop programs that should be intercepted by the vault.',
          ),
          const SizedBox(height: 12),
          const _TimelineStep(
            step: '02',
            title: 'Intercept on launch',
            subtitle:
                'If a protected app comes forward while locked, the vault overlay appears first.',
          ),
          const SizedBox(height: 12),
          _TimelineStep(
            step: '03',
            title: _pendingLockedApp == null
                ? 'Verify with Windows Hello'
                : 'Release ${_pendingLockedApp!.application.displayName}',
            subtitle: _pendingLockedApp == null
                ? 'Fingerprint, face, or PIN opens the protected session.'
                : 'After authentication, the waiting app is restored and brought back to the front.',
          ),
        ],
      ),
    );
  }

  Widget _buildAuthPanel(bool canUnlock) {
    final hasProtectedApps = _settings.lockedApplications.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [Color(0xFF151A26), Color(0xFF14111B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: const Color(0xFF72A9FF).withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.fingerprint_rounded, color: Color(0xFF72A9FF)),
              SizedBox(width: 10),
              Text(
                'Windows Hello Access',
                style: TextStyle(
                  color: Color(0xFF72A9FF),
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            'Unlock method',
            style: TextStyle(
              color: Color(0xFF9EAAB5),
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _settings.protectionEnabled
                ? 'Windows Hello biometric or PIN'
                : 'Protection is currently disabled',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: _settings.protectionEnabled
                  ? Colors.white
                  : const Color(0xFFFFC66D),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'What happens after success',
                  style: TextStyle(
                    color: Color(0xFF9EAAB5),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _pendingLockedApp == null
                      ? 'The vault unlocks and will allow protected apps to come through for this session.'
                      : '${_pendingLockedApp!.application.displayName} is restored and handed back to you immediately after verification.',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (!hasProtectedApps)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Tip: add at least one desktop program so the vault has something to protect.',
                style: TextStyle(color: Color(0xFFAA9FB8), height: 1.45),
              ),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 240,
                child: FilledButton.icon(
                  onPressed: canUnlock ? _triggerAuthentication : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF467DFF),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 18,
                    ),
                  ),
                  icon: Icon(
                    _unlockPhase == UnlockPhase.authenticating
                        ? Icons.hourglass_top_rounded
                        : Icons.lock_open_rounded,
                  ),
                  label: Text(
                    _unlockPhase == UnlockPhase.authenticating
                        ? 'Authenticating...'
                        : (_pendingLockedApp == null
                            ? 'Unlock Session'
                            : 'Authenticate & Open'),
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: OutlinedButton.icon(
                  onPressed: _checkHardware,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 18,
                    ),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Refresh Status'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUnlockedView() {
    return _Panel(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: const Color(0xFF7BF7AE).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.verified_user_rounded,
                  color: Color(0xFF7BF7AE),
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  'Protected Session Active',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _settings.lockedApplications.isEmpty
                ? 'Your identity has been verified. Add a few desktop apps next, and the vault will begin intercepting them when the session is locked.'
                : 'Your identity has been verified. Protected desktop apps can now open normally until the session is locked again.',
            style: const TextStyle(color: Color(0xFFB5A9C5), height: 1.5),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              const _Pill(
                label: 'Session protected',
                color: Color(0xFF7BF7AE),
              ),
              const _Pill(
                label: 'Windows Hello verified',
                color: Color(0xFF72A9FF),
              ),
              _Pill(
                label: '${_settings.lockedApplications.length} protected app${_settings.lockedApplications.length == 1 ? '' : 's'}',
                color: const Color(0xFF63F5D2),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _lockApp,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E8B57),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                ),
                icon: const Icon(Icons.lock_outline_rounded),
                label: const Text('Lock Session'),
              ),
              OutlinedButton.icon(
                onPressed: _pickAndAddLockedApplication,
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Another App'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFAA9FB8),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  String _displayNameFromPath(String path) {
    final normalized = path.replaceAll('/', r'\');
    final segments = normalized.split(r'\');
    final rawName = segments.isEmpty ? path : segments.last;
    return rawName.toLowerCase().endsWith('.exe')
        ? rawName.substring(0, rawName.length - 4)
        : rawName;
  }

  String _normalizePath(String path) {
    return path.trim().replaceAll('/', r'\').toLowerCase();
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0E0A15), Color(0xFF130F1C), Color(0xFF0F141A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            left: -40,
            child: _GlowOrb(
              size: 320,
              color: const Color(0xFF2D64FF).withValues(alpha: 0.22),
            ),
          ),
          Positioned(
            right: -90,
            top: 80,
            child: _GlowOrb(
              size: 280,
              color: const Color(0xFF2CD7B8).withValues(alpha: 0.14),
            ),
          ),
          Positioned(
            bottom: -130,
            left: 180,
            child: _GlowOrb(
              size: 360,
              color: const Color(0xFFFF8A4C).withValues(alpha: 0.10),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: const Color(0xCC17141F),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 40,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.step,
    required this.title,
    required this.subtitle,
  });

  final String step;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10),
          ),
          child: Text(
            step,
            style: const TextStyle(
              color: Color(0xFF72A9FF),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFFA99DB8),
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ProtectedAppTile extends StatelessWidget {
  const _ProtectedAppTile({
    required this.application,
    required this.isPending,
    required this.onRemove,
  });

  final LockedApplication application;
  final bool isPending;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: 0.035),
        border: Border.all(
          color: isPending
              ? const Color(0xFF63F5D2).withValues(alpha: 0.45)
              : Colors.white10,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFF72A9FF).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              isPending ? Icons.lock_clock_rounded : Icons.desktop_windows_rounded,
              color: isPending
                  ? const Color(0xFF63F5D2)
                  : const Color(0xFF72A9FF),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        application.displayName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _Pill(
                      label: isPending ? 'Waiting now' : 'Protected',
                      color: isPending
                          ? const Color(0xFF63F5D2)
                          : const Color(0xFF72A9FF),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  application.executablePath,
                  style: const TextStyle(
                    color: Color(0xFFAA9FB8),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          IconButton(
            onPressed: onRemove,
            tooltip: 'Remove protection',
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}

class _StatusLine {
  const _StatusLine({
    required this.label,
    required this.value,
    required this.isOk,
  });

  final String label;
  final String value;
  final bool isOk;
}
