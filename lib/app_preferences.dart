import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centralized persistent configuration for the application.
///
/// Keep small user preferences here (theme, chart defaults, decoder options,
/// UI choices, etc.). Large files or DLOG data should not be stored in
/// SharedPreferences.
class AppPreferences {
  AppPreferences._();

  static const String _themeModeKey = 'theme_mode';

  // Keys reserved for future application preferences can be added here.
  // Example:
  // static const String _defaultChartModeKey = 'default_chart_mode';
  // static const String _topAlarmCountKey = 'top_alarm_count';

  static Future<SharedPreferences> get _prefs async =>
      SharedPreferences.getInstance();

  /// Saves the selected Flutter ThemeMode.
  static Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await _prefs;
    await prefs.setString(_themeModeKey, mode.name);
  }

  /// Returns the persisted theme.
  ///
  /// If no preference has been stored yet, the application follows the
  /// operating system theme.
  static Future<ThemeMode> getThemeMode() async {
    final prefs = await _prefs;
    final saved = prefs.getString(_themeModeKey);

    switch (saved) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  /// Removes only the saved theme selection.
  static Future<void> clearThemeMode() async {
    final prefs = await _prefs;
    await prefs.remove(_themeModeKey);
  }

  /// Generic helpers for the next settings we add.
  static Future<void> setBool(String key, bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(key, value);
  }

  static Future<bool?> getBool(String key) async {
    final prefs = await _prefs;
    return prefs.getBool(key);
  }

  static Future<void> setInt(String key, int value) async {
    final prefs = await _prefs;
    await prefs.setInt(key, value);
  }

  static Future<int?> getInt(String key) async {
    final prefs = await _prefs;
    return prefs.getInt(key);
  }

  static Future<void> setDouble(String key, double value) async {
    final prefs = await _prefs;
    await prefs.setDouble(key, value);
  }

  static Future<double?> getDouble(String key) async {
    final prefs = await _prefs;
    return prefs.getDouble(key);
  }

  static Future<void> setString(String key, String value) async {
    final prefs = await _prefs;
    await prefs.setString(key, value);
  }

  static Future<String?> getString(String key) async {
    final prefs = await _prefs;
    return prefs.getString(key);
  }

  static Future<void> remove(String key) async {
    final prefs = await _prefs;
    await prefs.remove(key);
  }
}
