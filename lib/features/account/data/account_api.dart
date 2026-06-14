import 'package:dio/dio.dart';
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
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
        ),
      );

  final Dio _dio;

  Future<AccountSession> login({required String username, required String password}) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/auth/login',
      data: {'username': username, 'password': password},
    );
    return _sessionFromResponse(response.data, fallbackUsername: username);
  }

  Future<AccountSession> register({required String username, required String password}) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/auth/register',
      data: {'username': username, 'password': password},
    );
    return _sessionFromResponse(response.data, fallbackUsername: username);
  }

  Future<List<ManagedProfile>> fetchProfiles(AccountSession session) async {
    final response = await _dio.get<Object?>(
      '/api/v1/client/profiles',
      options: Options(headers: {'Authorization': 'Bearer ${session.token}'}),
    );
    final data = response.data;
    final rawProfiles = _readProfiles(data);

    return rawProfiles
        .whereType<Map>()
        .map((profile) => ManagedProfile.fromJson(profile.cast<String, dynamic>()))
        .where((profile) => profile.url.isNotEmpty)
        .toList(growable: false);
  }

  List _readProfiles(Object? data) {
    if (data is List) return data;
    if (data is! Map) return const [];

    final body = data.cast<String, dynamic>();
    if (body['profiles'] is List) return body['profiles'] as List;
    if (body['nodes'] is List) return body['nodes'] as List;

    final nested = body['data'];
    if (nested is Map) {
      final nestedBody = nested.cast<String, dynamic>();
      if (nestedBody['profiles'] is List) return nestedBody['profiles'] as List;
      if (nestedBody['nodes'] is List) return nestedBody['nodes'] as List;
    }

    return const [];
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
}
