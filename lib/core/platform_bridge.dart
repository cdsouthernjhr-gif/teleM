// Thin wrapper over the Android MethodChannel implemented in MainActivity.kt.
// Every call fails safe (returns false/null) when the platform side is
// missing, e.g. in unit tests.

import 'package:flutter/services.dart';

import 'diagnostics.dart';
import 'url_policy.dart';

class PlatformBridge {
  const PlatformBridge();
  static const _ch = MethodChannel('my_asean_tv/platform');

  Future<T?> _call<T>(String m, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      diag.warn('platform', '$m failed: ${e.code}');
      return null;
    }
  }

  Future<bool> isTelevision() async => await _call<bool>('isTelevision') ?? false;

  /// True when Android reports an active VPN transport. The app never starts
  /// or configures a VPN itself.
  Future<bool> isVpnActive() async => await _call<bool>('isVpnActive') ?? false;

  /// Opens the system VPN settings so the user can manage their own VPN app.
  Future<bool> openVpnSettings() async => await _call<bool>('openVpnSettings') ?? false;

  /// Opens an official platform page in an external browser/app. Only HTTPS.
  Future<bool> openUrl(String url) async {
    if (UrlPolicy.basicProblem(url) != null) return false;
    return await _call<bool>('openUrl', {'url': url}) ?? false;
  }

  Future<void> setKeepScreenOn(bool on) async => _call<void>('setKeepScreenOn', {'on': on});

  Future<int> sdkInt() async => await _call<int>('sdkInt') ?? 0;
}
