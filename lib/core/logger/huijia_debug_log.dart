import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract final class HuijiaDebugLog {
  static const enabled = bool.fromEnvironment('HUIJIA_DEBUG_LOG');

  static final _lock = _AsyncLock();
  static File? _file;

  static Future<void> clear() async {
    if (!enabled) return;
    await _lock.run(() async {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      await file.writeAsString('');
      await _writeLine(file, '=== Huijia debug log started ===');
      await _writeLine(file, 'path=${file.path}');
      await _writeLine(
        file,
        "apiBaseUrl=${const String.fromEnvironment('HUIJIA_API_BASE_URL', defaultValue: 'https://api.huijia.xyz')}",
      );
    });
  }

  static Future<void> info(String message, [Map<String, Object?> context = const {}]) async {
    if (!enabled) return;
    await _write('INFO', message, context);
  }

  static Future<void> error(
    String message,
    Object error,
    StackTrace stackTrace, [
    Map<String, Object?> context = const {},
  ]) async {
    if (!enabled) return;
    await _write('ERROR', message, {
      ...context,
      'error': _sanitize(error.toString()),
      'stack': _sanitize(stackTrace.toString()),
    });
  }

  static Future<String> path() async => (await _resolveFile()).path;

  static Future<void> _write(String level, String message, Map<String, Object?> context) async {
    await _lock.run(() async {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      await _writeLine(file, '$level ${_sanitize(message)}');
      for (final entry in context.entries) {
        await _writeLine(file, '  ${entry.key}=${_sanitize(entry.value?.toString() ?? 'null')}');
      }
    });
  }

  static Future<void> _writeLine(File file, String line) async {
    final timestamp = DateTime.now().toIso8601String();
    await file.writeAsString('[$timestamp] $line\n', mode: FileMode.append, flush: true);
  }

  static Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;

    final Directory baseDir;
    if (PlatformUtils.isWindows && Environment.isPortable) {
      baseDir = AppDirectories.getPortableDirectory();
    } else {
      baseDir = await getApplicationSupportDirectory();
    }
    return _file = File(p.join(baseDir.path, 'huijia-debug.log'));
  }

  static String _sanitize(String value) {
    var output = value;
    output = output.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false), 'Bearer <redacted>');
    output = output.replaceAll(
      RegExp(r'([?&](?:token|access_token|password)=)[^&\s]+', caseSensitive: false),
      r'$1<redacted>',
    );
    output = output.replaceAll(RegExp(r'(/sub/)[A-Za-z0-9._~+/=-]+'), r'$1<redacted>');
    output = output.replaceAll(RegExp(r'(ss://)[^@\s]+@'), r'$1<userinfo>@');
    if (output.length > 4000) {
      output = '${output.substring(0, 4000)}...<truncated>';
    }
    return output;
  }
}

class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }
}
