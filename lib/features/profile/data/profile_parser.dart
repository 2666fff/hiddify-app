import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/logger/huijia_debug_log.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

/// parse profile subscription url and headers for data
///
/// ***name parser hierarchy:***
/// - UserOverride.name
/// - `profile-title` header
/// - `content-disposition` header
/// - url fragment (example: `https://example.com/config#user`) -> name=`user`
/// - url filename extension (example: `https://example.com/config.json`) -> name=`config`
/// - if none of these methods return a non-blank string, switch(profileType)
/// - remote:  fallback to `Remote Profile`
/// - local: fallback to protocol, extracted from content by protocol()

class ProfileParser {
  static const infiniteTrafficThreshold = 920_233_720_368;
  static const infiniteTimeThreshold = 92_233_720_368;
  static const allowedOverrideConfigs = [
    'connection-test-url',
    'direct-dns-address',
    'remote-dns-address',
    'tls-tricks',
    'chain-status',
    'extra-security',
  ];
  static const allowedProfileHeaders = [
    'profile-title',
    'content-disposition',
    'subscription-userinfo',
    'profile-update-interval',
    'support-url',
    'profile-web-page-url',
    'enable-warp',
    'enable-fragment',
  ];

  final Ref _ref;
  final DioHttpClient _httpClient;

  ProfileParser({required Ref ref, required DioHttpClient httpClient}) : _ref = ref, _httpClient = httpClient;
  TaskEither<ProfileFailure, ProfileEntriesCompanion> addLocal({
    required String id,
    required String content,
    required String tempFilePath,
    required UserOverride? userOverride,
  }) {
    return TaskEither.tryCatch(() async {
          await expandRemoteLinesInParallel(
            tempFilePath: tempFilePath,
            httpClient: _httpClient,
            cancelToken: CancelToken(),
            ref: _ref,
          );
          await sortProfileLinesByTcpDelay(tempFilePath: tempFilePath);
        }, (_, _) => const ProfileFailure.unexpected())
        .flatMap((_) => TaskEither.fromEither(populateHeaders(content: content)))
        .flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.local(
                id: id,
                active: true,
                name: '',
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        );
  }

  TaskEither<ProfileFailure, ProfileEntriesCompanion> addRemote({
    required String id,
    required String url,
    required String tempFilePath,
    required UserOverride? userOverride,
    CancelToken? cancelToken,
  }) => _downloadProfile(url, tempFilePath, cancelToken).flatMap(
    (remoteHeaders) =>
        TaskEither.fromEither(
          populateHeaders(content: File(tempFilePath).readAsStringSync(), remoteHeaders: remoteHeaders),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.remote(
                id: id,
                active: true,
                name: '',
                url: url,
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        ),
  );

  TaskEither<ProfileFailure, ProfileEntriesCompanion> updateRemote({
    required RemoteProfileEntity rp,
    required String tempFilePath,
    CancelToken? cancelToken,
  }) => _downloadProfile(rp.url, tempFilePath, cancelToken).flatMap(
    (remoteHeaders) =>
        TaskEither.fromEither(
          populateHeaders(content: File(tempFilePath).readAsStringSync(), remoteHeaders: remoteHeaders),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: rp.copyWith(populatedHeaders: populatedHeaders),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected)),
          ),
        ),
  );

  Either<ProfileFailure, ProfileEntriesCompanion> offlineUpdate({
    required ProfileEntity profile,
    required String tempFilePath,
  }) => profile
      .map(
        remote: (rp) => parse(profile: rp, tempFilePath: tempFilePath),
        local: (lp) => parse(tempFilePath: tempFilePath, profile: lp),
      )
      .flatMap((profEntity) => Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected));

  TaskEither<ProfileFailure, Map<String, dynamic>> _downloadProfile(
    String url,
    String tempFilePath,
    CancelToken? cancelToken,
  ) => TaskEither.tryCatch(() async {
    // if (url.startsWith("http://"))
    //   throw const ProfileFailure.invalidUrl('HTTP is not supported. Please use HTTPS for secure connection.');

    await HuijiaDebugLog.info('profile download start', {
      'url': url.replaceFirst(RegExp('(/sub/).+'), r'$1<redacted>'),
      'tempFilePath': tempFilePath,
    });

    final rs = await _httpClient
        .download(
          url.trim(),
          tempFilePath,
          cancelToken: cancelToken,
          userAgent: _ref.read(ConfigOptions.useXrayCoreWhenPossible)
              ? _httpClient.userAgent.replaceAll("HiddifyNext", "HiddifyNextX")
              : null,
        )
        .catchError((err) {
          if (CancelToken.isCancel(err as DioException)) {
            throw const ProfileFailure.cancelByUser('HTTP request for getting profile content canceled by user.');
          }
          throw err;
        });
    final content = await File(tempFilePath).readAsString();
    final decoded = safeDecodeBase64(content);
    final decodedLines = decoded.split('\n').where((line) => line.trim().isNotEmpty).toList(growable: false);
    await HuijiaDebugLog.info('profile download success', {
      'statusCode': rs.statusCode,
      'contentLength': content.length,
      'decodedLineCount': decodedLines.length,
      'firstLineShape': decodedLines.isEmpty ? '<empty>' : _shapeConfigLine(decodedLines.first),
      'headers': rs.headers.map.keys.join(','),
    });
    if (content.trim().isEmpty || decodedLines.isEmpty) {
      throw const ProfileFailure.invalidConfig('服务端暂无可用线路，请联系管理员添加节点');
    }
    await expandRemoteLinesInParallel(
      tempFilePath: tempFilePath,
      httpClient: _httpClient,
      cancelToken: cancelToken ?? CancelToken(),
      ref: _ref,
    );
    await sortProfileLinesByTcpDelay(tempFilePath: tempFilePath);
    // fixing headers before return
    return rs.headers.map.map((key, value) {
      if (value.length == 1) return MapEntry(key, value.first);
      return MapEntry(key, value);
    });
  }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st));
  Future<void> expandRemoteLinesInParallel({
    required String tempFilePath,
    required DioHttpClient httpClient,
    required CancelToken cancelToken,
    required Ref ref,
    int parallelism = 4,
  }) async {
    final content = await File(tempFilePath).readAsString();
    final lines = _profileContentLines(content);

    final results = List<String?>.filled(lines.length, null);

    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken.isCancelled) return;

        final currentIndex = index++;
        if (currentIndex >= lines.length) return;

        final line = lines[currentIndex].trim();

        // Non-URL
        if (!line.startsWith('http://') && !line.startsWith('https://')) {
          results[currentIndex] = line;
          continue;
        }

        final tmpPath = '$tempFilePath.$currentIndex';
        try {
          await httpClient.download(
            line,
            tmpPath,
            cancelToken: cancelToken,
            userAgent: ref.read(ConfigOptions.useXrayCoreWhenPossible)
                ? httpClient.userAgent.replaceAll('HiddifyNext', 'HiddifyNextX')
                : null,
          );

          results[currentIndex] = safeDecodeBase64(await File(tmpPath).readAsString()).trim();
        } catch (err) {
          if (err is DioException && CancelToken.isCancel(err)) {
            return;
          }
          results[currentIndex] = '';
        } finally {
          final tmpFile = File(tmpPath);
          if (await tmpFile.exists()) await tmpFile.delete();
        }
      }
    }

    // Start workers
    await Future.wait(List.generate(parallelism, (_) => worker()));

    if (results.any((e) => e != null)) {
      final newContent = results.join("\n");
      await File(tempFilePath).writeAsString(newContent);
    }
  }

  Future<void> sortProfileLinesByTcpDelay({
    required String tempFilePath,
    Duration timeout = const Duration(seconds: 2),
    int parallelism = 8,
  }) async {
    try {
      final content = await File(tempFilePath).readAsString();
      final lines = _profileContentLines(content);
      final headerLines = <String>[];
      final otherLines = <String>[];
      final proxyLines = <_ProfileLine>[];

      for (final indexed in lines.indexed) {
        final line = indexed.$2.trim();
        if (line.isEmpty) continue;
        final target = _extractTcpTarget(line);
        if (target != null) {
          proxyLines.add(_ProfileLine(index: indexed.$1, line: line, target: target));
        } else if (proxyLines.isEmpty && _isProfileHeaderLine(line)) {
          headerLines.add(line);
        } else {
          otherLines.add(line);
        }
      }

      if (proxyLines.length < 2) {
        await File(
          tempFilePath,
        ).writeAsString([...headerLines, ...proxyLines.map((e) => e.line), ...otherLines].join('\n'));
        await HuijiaDebugLog.info('profile tcp sort skipped', {
          'lineCount': lines.length,
          'proxyCount': proxyLines.length,
        });
        return;
      }

      int cursor = 0;
      Future<void> worker() async {
        while (true) {
          final current = cursor++;
          if (current >= proxyLines.length) return;
          final item = proxyLines[current];
          item.delayMs = await _tcpConnectDelay(item.target, timeout);
        }
      }

      final workerCount = parallelism < proxyLines.length ? parallelism : proxyLines.length;
      await Future.wait(List.generate(workerCount, (_) => worker()));

      proxyLines.sort((a, b) {
        final ad = a.delayMs;
        final bd = b.delayMs;
        if (ad == null && bd == null) return a.index.compareTo(b.index);
        if (ad == null) return 1;
        if (bd == null) return -1;
        final delayCompare = ad.compareTo(bd);
        return delayCompare == 0 ? a.index.compareTo(b.index) : delayCompare;
      });

      final sortedLines = [...headerLines, ...proxyLines.map((e) => e.line), ...otherLines];
      await File(tempFilePath).writeAsString(sortedLines.join('\n'));
      await HuijiaDebugLog.info('profile tcp sort done', {
        'proxyCount': proxyLines.length,
        'testedCount': proxyLines.where((e) => e.delayMs != null).length,
        'timeoutCount': proxyLines.where((e) => e.delayMs == null).length,
        'fastestMs': proxyLines.first.delayMs?.toString() ?? '<timeout>',
      });
    } catch (error, stackTrace) {
      await HuijiaDebugLog.error('profile tcp sort failed', error, stackTrace, {'tempFilePath': tempFilePath});
    }
  }

  static Either<ProfileFailure, Map<String, dynamic>> populateHeaders({
    required String content,
    Map<String, dynamic>? remoteHeaders,
  }) => Either.tryCatch(() {
    final contentHeaders = _parseHeadersFromContent(content);
    return _mergeAndValidateHeaders(contentHeaders, remoteHeaders ?? {});
  }, ProfileFailure.unexpected);

  static Map<String, dynamic> _mergeAndValidateHeaders(
    Map<String, dynamic> contentHeaders,
    Map<String, dynamic> remoteHeaders,
  ) {
    for (final entry in contentHeaders.entries) {
      if (!remoteHeaders.keys.contains(entry.key)) {
        remoteHeaders[entry.key] = entry.value;
      }
    }
    final headers = <String, dynamic>{};
    for (final entry in remoteHeaders.entries) {
      if (allowedProfileHeaders.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        headers[entry.key] = entry.value;
      }
    }
    return headers;
  }

  static Map<String, dynamic> _parseHeadersFromContent(String content) {
    final headers = <String, dynamic>{};
    final content_ = safeDecodeBase64(content);
    final lines = content_.split("\n");
    final linesToProcess = lines.length < 10 ? lines.length : 10;
    for (int i = 0; i < linesToProcess; i++) {
      final line = lines[i];
      if (line.startsWith("#") || line.startsWith("//")) {
        final index = line.indexOf(':');
        if (index == -1) continue;
        final key = line.substring(0, index).replaceFirst(RegExp("^#|//"), "").trim().toLowerCase();
        final value = line.substring(index + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }

  static SubscriptionInfo? _parseSubscriptionInfo(String subInfoStr) {
    final values = subInfoStr.split(';');
    final map = {for (final v in values) v.split('=').first.trim(): num.tryParse(v.split('=').second.trim())?.toInt()};
    if (map case {"upload": final upload?, "download": final download?, "total": final total, "expire": var expire}) {
      final total1 = (total == null || total == 0) ? infiniteTrafficThreshold + 1 : total;
      expire = (expire == null || expire == 0) ? infiniteTimeThreshold : expire;
      return SubscriptionInfo(
        upload: upload,
        download: download,
        total: total1,
        expire: DateTime.fromMillisecondsSinceEpoch(expire * 1000),
      );
    }
    return null;
  }

  @visibleForTesting
  static Either<ProfileFailure, ProfileEntity> parse({required String tempFilePath, required ProfileEntity profile}) =>
      Either.tryCatch(() {
        final headers = Map<String, dynamic>.from(profile.populatedHeaders ?? {});
        var name = '';
        if (profile.userOverride?.name case final String oName when oName.isNotEmpty) {
          name = oName;
        }

        if (headers['profile-title'] case final String titleHeader when name.isEmpty) {
          if (titleHeader.startsWith("base64:")) {
            name = utf8.decode(base64.decode(titleHeader.replaceFirst("base64:", "")));
          } else {
            name = titleHeader.trim();
          }
        }
        if (headers['content-disposition'] case final String contentDispositionHeader when name.isEmpty) {
          final regExp = RegExp('filename="([^"]*)"');
          final match = regExp.firstMatch(contentDispositionHeader);
          if (match != null && match.groupCount >= 1) {
            name = match.group(1) ?? '';
          }
        }
        if (profile case RemoteProfileEntity(:final url)) {
          if (Uri.parse(url).fragment case final fragment when name.isEmpty) {
            name = fragment;
          }
          if (url.split("/").lastOrNull case final part? when name.isEmpty) {
            final pattern = RegExp(r"\.(json|yaml|yml|txt)[\s\S]*");
            name = part.replaceFirst(pattern, "");
          }
        }
        if (name.isBlank) {
          switch (profile) {
            case RemoteProfileEntity():
              name = "Remote Profile";

            case LocalProfileEntity():
              name = protocol(File(tempFilePath).readAsStringSync());
          }
        }

        final isAutoUpdateDisable = profile.userOverride?.isAutoUpdateDisable ?? false;
        ProfileOptions? options;
        if (profile.userOverride?.updateInterval case final int updateInterval
            when updateInterval > 0 && !isAutoUpdateDisable) {
          options = ProfileOptions(updateInterval: Duration(hours: updateInterval));
        }
        if (headers['profile-update-interval'] case final String updateIntervalStr
            when options == null && !isAutoUpdateDisable) {
          final updateInterval = Duration(hours: int.parse(updateIntervalStr));
          options = ProfileOptions(updateInterval: updateInterval);
        }

        SubscriptionInfo? subInfo;
        if (headers['subscription-userinfo'] case final String subInfoStr) {
          subInfo = _parseSubscriptionInfo(subInfoStr);
        }

        if (subInfo != null) {
          if (headers['profile-web-page-url'] case final String profileWebPageUrl when isUrl(profileWebPageUrl)) {
            subInfo = subInfo.copyWith(webPageUrl: profileWebPageUrl);
          }
          if (headers['support-url'] case final String profileSupportUrl when isUrl(profileSupportUrl)) {
            subInfo = subInfo.copyWith(supportUrl: profileSupportUrl);
          }
        }

        return profile.map(
          remote: (rp) => rp.copyWith(name: name, lastUpdate: DateTime.now(), options: options, subInfo: subInfo),
          local: (lp) => lp.copyWith(name: name, lastUpdate: DateTime.now()),
        );
      }, ProfileFailure.unexpected);

  static String protocol(String content) {
    if (content.contains("[Interface]")) {
      return ProxyType.wireguard.label;
    }
    final lines = content.split('\n');
    String? name;
    for (final line in lines) {
      final uri = Uri.tryParse(line);
      if (uri == null) continue;
      final fragment = uri.hasFragment ? Uri.decodeComponent(uri.fragment.split(" -> ")[0]) : null;
      name ??= switch (uri.scheme) {
        'ss' => fragment ?? ProxyType.shadowsocks.label,
        'ssconf' => fragment ?? ProxyType.shadowsocks.label,
        'vmess' => ProxyType.vmess.label,
        'vless' => fragment ?? ProxyType.vless.label,
        'trojan' => fragment ?? ProxyType.trojan.label,
        'tuic' => fragment ?? ProxyType.tuic.label,
        'hy2' || 'hysteria2' => fragment ?? ProxyType.hysteria2.label,
        'hy' || 'hysteria' => fragment ?? ProxyType.hysteria.label,
        'ssh' => fragment ?? ProxyType.ssh.label,
        'wg' => fragment ?? ProxyType.wireguard.label,
        'awg' => fragment ?? ProxyType.awg.label,
        'shadowtls' => fragment ?? ProxyType.shadowtls.label,
        'mieru' => fragment ?? ProxyType.mieru.label,
        'warp' => fragment ?? ProxyType.warp.label,
        _ => null,
      };
    }
    return name ?? ProxyType.unknown.label;
  }

  static String profileOverrideHelper({required ProfileEntriesCompanion profile}) {
    final populatedHeaders = profile.populatedHeaders.value;

    Map<String, dynamic>? mPopulatedHeaders;
    if (populatedHeaders != null) {
      final m = jsonDecode(populatedHeaders) as Map;
      mPopulatedHeaders = m.cast<String, dynamic>();
    }

    return ProfileParser.profileOverride(
      populatedHeaders: mPopulatedHeaders,
      userOverride: UserOverride.fromStr(profile.userOverride.value),
    );
  }

  static String profileOverride({
    required Map<String, dynamic>? populatedHeaders,
    required UserOverride? userOverride,
  }) {
    final headers = Map<String, dynamic>.from(populatedHeaders ?? {});

    if (headers['enable-warp'].toString() == 'true' || userOverride?.enableWarp == true) {
      headers['chain-status'] = 'extra_security';
      headers['extra-security'] = {'mode': 'warp'};
    }

    if (headers['enable-fragment'].toString() == 'true' || userOverride?.enableFragment == true) {
      headers['tls-tricks'] = {'enable-fragment': true};
    }

    headers.removeWhere(
      (key, value) => !allowedOverrideConfigs.contains(key) || value == null || value.toString().isEmpty,
    );

    final profileOverrideStr = jsonEncode({for (final key in headers.keys) key: headers[key]});
    return profileOverrideStr;
  }

  static Map<String, dynamic> applyProfileOverride(Map<String, dynamic> main, String? profileOverride) {
    if (profileOverride == null) return main;
    if (profileOverride.contains("{")) {
      final profileOverrideMap = jsonDecode(profileOverride) as Map<String, dynamic>;
      return _mergeJson(main, profileOverrideMap);
    } else {
      return main;
    }
  }

  static Map<String, dynamic> _mergeJson(Map<String, dynamic> main, Map<String, dynamic> override) {
    override.forEach((key, value) {
      if (main.containsKey(key)) {
        if (main[key] is Map<String, dynamic> && value is Map<String, dynamic>) {
          main[key] = _mergeJson(main[key] as Map<String, dynamic>, value);
        } else {
          main[key] = value;
        }
      } else {
        main[key] = value;
      }
    });
    return main;
  }

  static String _shapeConfigLine(String line) {
    final uri = Uri.tryParse(line.trim());
    if (uri == null) return line.length > 120 ? '${line.substring(0, 120)}...' : line;
    return '${uri.scheme}://<redacted>${uri.hasFragment ? '#<fragment>' : ''}';
  }
}

List<String> _profileContentLines(String content) {
  return safeDecodeBase64(content).split(RegExp(r'\r?\n')).where((line) => line.trim().isNotEmpty).toList();
}

bool _isProfileHeaderLine(String line) {
  return line.startsWith('#') || line.startsWith('//');
}

Future<int?> _tcpConnectDelay(_TcpTarget target, Duration timeout) async {
  Socket? socket;
  final stopwatch = Stopwatch()..start();
  try {
    socket = await Socket.connect(target.host, target.port, timeout: timeout);
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds == 0 ? 1 : stopwatch.elapsedMilliseconds;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

_TcpTarget? _extractTcpTarget(String line) {
  final trimmed = line.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return null;

  final directTarget = _tcpTargetFromUri(uri);
  if (directTarget != null) return directTarget;

  return switch (uri.scheme.toLowerCase()) {
    'ss' || 'ssconf' => _extractShadowsocksTcpTarget(trimmed),
    'vmess' => _extractVmessTcpTarget(trimmed),
    _ => null,
  };
}

_TcpTarget? _tcpTargetFromUri(Uri uri) {
  if (!uri.hasAuthority || uri.host.isEmpty || !uri.hasPort || uri.port <= 0) return null;
  return _TcpTarget(host: uri.host, port: uri.port);
}

_TcpTarget? _extractShadowsocksTcpTarget(String line) {
  final body = _uriBody(line);
  if (body == null || body.isEmpty) return null;
  final decoded = _decodeBase64Value(body) ?? body;
  final uri = Uri.tryParse(decoded.contains('://') ? decoded : 'ss://$decoded');
  return uri == null ? null : _tcpTargetFromUri(uri);
}

_TcpTarget? _extractVmessTcpTarget(String line) {
  try {
    final body = _uriBody(line);
    if (body == null || body.isEmpty) return null;
    final decoded = _decodeBase64Value(body);
    if (decoded == null) return null;
    final json = jsonDecode(decoded);
    if (json is! Map) return null;
    final host = (json['add'] ?? json['address'] ?? json['host'] ?? '').toString();
    final port = int.tryParse((json['port'] ?? '').toString()) ?? 0;
    if (host.isEmpty || port <= 0) return null;
    return _TcpTarget(host: host, port: port);
  } catch (_) {
    return null;
  }
}

String? _uriBody(String line) {
  final separator = line.indexOf('://');
  if (separator < 0) return null;
  final bodyStart = separator + 3;
  final queryStart = line.indexOf(RegExp('[?#]'), bodyStart);
  if (queryStart < 0) return line.substring(bodyStart).trim();
  return line.substring(bodyStart, queryStart).trim();
}

String? _decodeBase64Value(String value) {
  try {
    var normalized = value.trim().replaceAll('-', '+').replaceAll('_', '/');
    final padding = normalized.length % 4;
    if (padding > 0) {
      normalized = normalized.padRight(normalized.length + (4 - padding), '=');
    }
    return utf8.decode(base64Decode(normalized));
  } catch (_) {
    return null;
  }
}

class _TcpTarget {
  const _TcpTarget({required this.host, required this.port});

  final String host;
  final int port;
}

class _ProfileLine {
  _ProfileLine({required this.index, required this.line, required this.target});

  final int index;
  final String line;
  final _TcpTarget target;
  int? delayMs;
}
