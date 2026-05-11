import 'dart:ffi';
import 'dart:async';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'app_lock_settings_store.dart';

class LockedAppMatch {
  const LockedAppMatch({
    required this.application,
    required this.processId,
    required this.windowHandle,
    required this.executablePath,
  });

  final LockedApplication application;
  final int processId;
  final int windowHandle;
  final String executablePath;
}

class WindowsLockedAppService {
  Timer? _timer;
  String? _lastMatchKey;

  void startWatching({
    required List<LockedApplication> applications,
    required bool enabled,
    required bool sessionUnlocked,
    required Future<void> Function(LockedAppMatch match) onLockedAppDetected,
  }) {
    _timer?.cancel();
    if (!enabled || applications.isEmpty) {
      _lastMatchKey = null;
      return;
    }

    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) async {
      if (sessionUnlocked) {
        _lastMatchKey = null;
        return;
      }

      final match = detectForegroundLockedApp(applications);
      if (match == null) {
        _lastMatchKey = null;
        return;
      }

      final key = '${match.processId}:${match.executablePath.toLowerCase()}';
      if (_lastMatchKey == key) {
        return;
      }

      _lastMatchKey = key;
      await onLockedAppDetected(match);
    });
  }

  void stopWatching() {
    _timer?.cancel();
    _timer = null;
    _lastMatchKey = null;
  }

  LockedAppMatch? detectForegroundLockedApp(
    List<LockedApplication> applications,
  ) {
    if (!Platform.isWindows || applications.isEmpty) {
      return null;
    }

    final hwnd = GetForegroundWindow();
    if (hwnd == 0 || IsWindowVisible(hwnd) == 0) {
      return null;
    }

    final processIdPointer = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, processIdPointer);
      final processId = processIdPointer.value;
      if (processId == 0) {
        return null;
      }

      final executablePath = _queryProcessPath(processId);
      if (executablePath == null || executablePath.isEmpty) {
        return null;
      }

      final ownProcessPath = Platform.resolvedExecutable.toLowerCase();
      if (executablePath.toLowerCase() == ownProcessPath) {
        return null;
      }

      for (final app in applications) {
        if (_normalizePath(app.executablePath) == _normalizePath(executablePath)) {
          return LockedAppMatch(
            application: app,
            processId: processId,
            windowHandle: hwnd,
            executablePath: executablePath,
          );
        }
      }

      return null;
    } finally {
      calloc.free(processIdPointer);
    }
  }

  void minimizeWindow(int hwnd) {
    ShowWindowAsync(hwnd, SW_MINIMIZE);
  }

  void restoreWindow(int hwnd) {
    ShowWindowAsync(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
  }

  String? _queryProcessPath(int processId) {
    final processHandle = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      FALSE,
      processId,
    );
    if (processHandle == 0) {
      return null;
    }

    final pathBuffer = calloc<Uint16>(MAX_PATH * 4).cast<Utf16>();
    final sizePointer = calloc<Uint32>()..value = MAX_PATH * 4;

    try {
      final result = QueryFullProcessImageName(
        processHandle,
        0,
        pathBuffer,
        sizePointer,
      );
      if (result == 0) {
        return null;
      }

      return pathBuffer.toDartString(length: sizePointer.value);
    } finally {
      calloc.free(pathBuffer);
      calloc.free(sizePointer);
      CloseHandle(processHandle);
    }
  }

  String _normalizePath(String path) {
    return path.trim().replaceAll('/', r'\').toLowerCase();
  }
}
