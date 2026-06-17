import 'package:dio/dio.dart';
import 'package:hiddify/core/logger/huijia_debug_log.dart';
import 'package:hiddify/features/account/model/account_session.dart';
import 'package:hiddify/features/account/model/managed_client_config.dart';
import 'package:hiddify/features/account/model/managed_profile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final accountApiProvider = Provider<AccountApi>((ref) => AccountApi());

class AccountApi {
  AccountApi()
    : _dio = Dio(
        BaseOptions(
          baseUrl: ManagedClientConfig.apiBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 10),
          headers: const {'Accept': 'application/json', 'Content-Type': 'application/json'},
        ),
      );

  final Dio _dio;

  Future<AccountSession> login({required String username, required String password}) async {
    await HuijiaDebugLog.info('account login start', {'username': username, 'baseUrl': ManagedClientConfig.apiBaseUrl});
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/auth/login',
        data: {'username': username, 'password': password},
      );
      final session = _sessionFromResponse(response.data, fallbackUsername: username);
      await HuijiaDebugLog.info('account login success', {
        'statusCode': response.statusCode,
        'username': session.username,
        'tokenLength': session.token.length,
      });
      return session;
    } catch (error, stackTrace) {
      await HuijiaDebugLog.error('account login failed', error, stackTrace, {'username': username});
      rethrow;
    }
  }

  Future<List<ManagedProfile>> fetchProfiles(AccountSession session) async {
    await HuijiaDebugLog.info('fetch managed profiles start', {'username': session.username});
    try {
      final response = await _dio.get<Object?>(
        '/api/v1/client/profiles',
        options: Options(headers: {'Authorization': 'Bearer ${session.token}'}),
      );
      final data = response.data;
      final rawProfiles = _readProfiles(data);

      final profiles = rawProfiles
          .whereType<Map>()
          .map((profile) => ManagedProfile.fromJson(profile.cast<String, dynamic>()))
          .where((profile) => profile.url.isNotEmpty)
          .toList(growable: false);
      await HuijiaDebugLog.info('fetch managed profiles success', {
        'statusCode': response.statusCode,
        'rawCount': rawProfiles.length,
        'usableCount': profiles.length,
        'urls': profiles.map((profile) => _shapeUrl(profile.url)).join(','),
      });
      return profiles;
    } catch (error, stackTrace) {
      await HuijiaDebugLog.error('fetch managed profiles failed', error, stackTrace, {'username': session.username});
      rethrow;
    }
  }

  List _readProfiles(Object? data) {
    if (data is List) return data;
    if (data is! Map) return const [];

    final body = data.cast<String, dynamic>();
    final topLevelProfiles = _readProfileList(body);
    if (topLevelProfiles != null) return topLevelProfiles;

    final nested = body['data'];
    if (nested is Map) {
      final nestedBody = nested.cast<String, dynamic>();
      final nestedProfiles = _readProfileList(nestedBody);
      if (nestedProfiles != null) return nestedProfiles;
    }

    return const [];
  }

  List? _readProfileList(Map<String, dynamic> body) {
    const keys = [
      'profiles',
      'profileList',
      'profile_list',
      'subscriptions',
      'subscriptionList',
      'subscription_list',
      'nodes',
      'nodeList',
      'node_list',
      'lines',
      'lineList',
      'line_list',
      'routes',
      'routeList',
      'route_list',
      'servers',
      'serverList',
      'server_list',
      'items',
      'list',
    ];
    for (final key in keys) {
      final value = body[key];
      if (value is List) return value;
    }
    return null;
  }

  AccountSession _sessionFromResponse(Map<String, dynamic>? data, {required String fallbackUsername}) {
    final body = data ?? const {};
    final nestedData = body['data'] is Map ? (body['data'] as Map).cast<String, dynamic>() : body;
    final token = (nestedData['token'] ?? nestedData['accessToken'] ?? nestedData['access_token'] ?? '').toString();
    final user = nestedData['user'] is Map ? (nestedData['user'] as Map).cast<String, dynamic>() : null;
    final username = (nestedData['username'] ?? user?['username'] ?? user?['name'] ?? fallbackUsername).toString();

    if (token.isEmpty) {
      throw StateError('Server did not return an auth token');
    }
    return AccountSession(token: token, username: username);
  }

  String _shapeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '<invalid-url>';
    final path = uri.path.replaceFirst(RegExp('^/sub/.+'), '/sub/<redacted>');
    return '${uri.scheme}://${uri.host}$path';
  }
}
