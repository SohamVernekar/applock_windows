import 'dart:convert';
import 'dart:io';

class AppLockSettings {
  const AppLockSettings({
    required this.onboardingCompleted,
    required this.protectionEnabled,
    required this.autoLockOnBlur,
    required this.autoLockOnMinimize,
    required this.lockOnLaunch,
    required this.lockedApplications,
  });

  const AppLockSettings.defaults()
      : onboardingCompleted = false,
        protectionEnabled = false,
        autoLockOnBlur = false,
        autoLockOnMinimize = true,
        lockOnLaunch = true,
        lockedApplications = const [];

  final bool onboardingCompleted;
  final bool protectionEnabled;
  final bool autoLockOnBlur;
  final bool autoLockOnMinimize;
  final bool lockOnLaunch;
  final List<LockedApplication> lockedApplications;

  AppLockSettings copyWith({
    bool? onboardingCompleted,
    bool? protectionEnabled,
    bool? autoLockOnBlur,
    bool? autoLockOnMinimize,
    bool? lockOnLaunch,
    List<LockedApplication>? lockedApplications,
  }) {
    return AppLockSettings(
      onboardingCompleted:
          onboardingCompleted ?? this.onboardingCompleted,
      protectionEnabled: protectionEnabled ?? this.protectionEnabled,
      autoLockOnBlur: autoLockOnBlur ?? this.autoLockOnBlur,
      autoLockOnMinimize: autoLockOnMinimize ?? this.autoLockOnMinimize,
      lockOnLaunch: lockOnLaunch ?? this.lockOnLaunch,
      lockedApplications: lockedApplications ?? this.lockedApplications,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'onboardingCompleted': onboardingCompleted,
      'protectionEnabled': protectionEnabled,
      'autoLockOnBlur': autoLockOnBlur,
      'autoLockOnMinimize': autoLockOnMinimize,
      'lockOnLaunch': lockOnLaunch,
      'lockedApplications':
          lockedApplications.map((app) => app.toJson()).toList(),
    };
  }

  static AppLockSettings fromJson(Map<String, dynamic> json) {
    return AppLockSettings(
      onboardingCompleted: json['onboardingCompleted'] as bool? ?? false,
      protectionEnabled: json['protectionEnabled'] as bool? ?? false,
      autoLockOnBlur: json['autoLockOnBlur'] as bool? ?? false,
      autoLockOnMinimize: json['autoLockOnMinimize'] as bool? ?? true,
      lockOnLaunch: json['lockOnLaunch'] as bool? ?? true,
      lockedApplications:
          ((json['lockedApplications'] as List<dynamic>?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LockedApplication.fromJson)
              .toList(),
    );
  }
}

class LockedApplication {
  const LockedApplication({
    required this.displayName,
    required this.executablePath,
  });

  final String displayName;
  final String executablePath;

  Map<String, dynamic> toJson() {
    return {
      'displayName': displayName,
      'executablePath': executablePath,
    };
  }

  static LockedApplication fromJson(Map<String, dynamic> json) {
    return LockedApplication(
      displayName: json['displayName'] as String? ?? 'Protected app',
      executablePath: json['executablePath'] as String? ?? '',
    );
  }
}

class AppLockSettingsStore {
  Future<AppLockSettings> load() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) {
        return const AppLockSettings.defaults();
      }

      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return AppLockSettings.fromJson(data);
    } catch (_) {
      return const AppLockSettings.defaults();
    }
  }

  Future<void> save(AppLockSettings settings) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }

  Future<File> _settingsFile() async {
    final root = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return File('$root\\AppLockWin\\settings.json');
  }
}
