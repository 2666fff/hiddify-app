import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/account/data/account_api.dart';
import 'package:hiddify/features/account/model/account_session.dart';
import 'package:hiddify/features/account/service/managed_profile_sync_service.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final accountControllerProvider = ChangeNotifierProvider<AccountController>((ref) {
  return AccountController(
    api: ref.watch(accountApiProvider),
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    ref: ref,
  );
});

class AccountController extends ChangeNotifier {
  AccountController({required AccountApi api, required SharedPreferences preferences, required Ref ref})
    : _api = api,
      _preferences = preferences,
      _ref = ref {
    final token = _preferences.getString(_tokenKey) ?? '';
    final username = _preferences.getString(_usernameKey) ?? '';
    if (token.isNotEmpty) {
      _session = AccountSession(token: token, username: username);
    }
  }

  static const _tokenKey = 'huijia.account.token';
  static const _usernameKey = 'huijia.account.username';

  final AccountApi _api;
  final SharedPreferences _preferences;
  final Ref _ref;

  AccountSession? _session;
  bool _isLoading = false;
  String? _errorMessage;

  AccountSession? get session => _session;
  bool get isAuthenticated => _session?.isAuthenticated ?? false;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> login(String username, String password) async {
    await _authenticate(() => _api.login(username: username, password: password));
  }

  Future<void> logout() async {
    try {
      await _ref.read(connectionNotifierProvider.notifier).disconnect();
    } catch (error) {
      debugPrint('logout disconnect failed: $error');
    }
    _session = null;
    _errorMessage = null;
    await _preferences.remove(_tokenKey);
    await _preferences.remove(_usernameKey);
    notifyListeners();
  }

  Future<void> syncProfiles() async {
    final currentSession = _session;
    if (currentSession == null) return;
    try {
      await _ref.read(managedProfileSyncServiceProvider).sync(currentSession);
    } catch (error) {
      _errorMessage = _presentError(error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _authenticate(Future<AccountSession> Function() action) async {
    if (_isLoading) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final nextSession = await action();
      await _ref.read(managedProfileSyncServiceProvider).sync(nextSession);
      _session = nextSession;
      await _preferences.setString(_tokenKey, nextSession.token);
      await _preferences.setString(_usernameKey, nextSession.username);
    } catch (error) {
      _session = null;
      await _preferences.remove(_tokenKey);
      await _preferences.remove(_usernameKey);
      _errorMessage = _presentError(error);
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  String _presentError(Object error) {
    final message = error.toString();
    if (message.contains('SocketException') || message.contains('Connection refused')) {
      return '无法连接服务端，请确认服务端地址和网络。';
    }
    if (error case DioException(:final response?)) {
      final data = response.data;
      if (data is Map && data['error'] != null && data['error'].toString().isNotEmpty) {
        return data['error'].toString();
      }
      return switch (response.statusCode) {
        409 => '账号已存在，请直接登录。',
        401 => '账号或密码错误。',
        400 => '请求参数有误，请检查账号和密码。',
        final status? => '服务端返回错误：$status。',
        _ => '服务端请求失败。',
      };
    }
    if (error case ProfileInvalidConfigFailure(:final message?)) {
      return message;
    }
    if (message.contains('服务端暂无可用线路')) {
      return '服务端暂无可用线路，请联系管理员添加节点。';
    }
    return message.replaceFirst('Exception: ', '');
  }
}
