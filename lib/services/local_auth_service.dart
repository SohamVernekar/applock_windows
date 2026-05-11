import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class LocalAuthService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isDeviceSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> canAuthenticate() async {
    try {
      final canCheckBiometrics = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheckBiometrics || isSupported;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> authenticateWithWindowsHello() async {
    try {
      final isAvailable = await canAuthenticate();
      if (!isAvailable) {
        return false;
      }

      return await _auth.authenticate(
        localizedReason:
            'Scan your fingerprint or enter your PIN to unlock the app',
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
