import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

class DevLogSink {
  static const _path = '/__mellon_debug_logs';
  static const _verboseQueryKeys = {
    'debug_logs',
    'mellon_debug_logs',
    'mellon_logs',
  };
  static const _alwaysEmitEvents = {
    'mellon.chat.send_text',
    'mellon.subchat.create_root_sent',
    'mellon.subchat.enter',
    'mellon.subchat.open_route',
    'mellon.subchat.send_ack',
    'mellon.subchat.send_error',
    'mellon.subchat.send_text',
    'mellon.subchat.thread_hydrate_error',
    'mellon.subchat_timing.edit_hydrate_done',
    'mellon.subchat_timing.hydration_cache_restore',
    'mellon.subchat_timing.hydration_cache_store',
    'mellon.subchat_timing.open_cache_refresh_skip_fresh',
    'mellon.subchat_timing.open_done',
    'mellon.subchat_timing.open_error',
    'mellon.subchat_timing.open_initial_hydrate_skip_cache',
    'mellon.subchat_timing.thread_hydrate_end',
  };
  static final _sessionId = DateTime.now()
      .toUtc()
      .microsecondsSinceEpoch
      .toRadixString(36);

  static bool _disabled = false;
  static bool _matrixLogForwarderInstalled = false;

  static void event(String event, Map<String, Object?> fields) {
    if (!_shouldEmit(event)) return;

    final payload = <String, Object?>{
      'source': 'mellon-web',
      'event': event,
      'session_id': _sessionId,
      'time': DateTime.now().toUtc().toIso8601String(),
      ...fields,
    };
    Logs().i('[MELLON-DEBUG] ${jsonEncode(payload)}');

    if (!kIsWeb || _disabled) return;
    unawaited(_post(payload));
  }

  static bool _shouldEmit(String event) {
    if (_verboseLogsEnabled) return true;
    if (_alwaysEmitEvents.contains(event)) return true;
    if (event.contains('_error') || event.endsWith('.error_builder')) {
      return true;
    }
    return false;
  }

  static bool get _verboseLogsEnabled {
    if (!kIsWeb) return false;
    final params = Uri.base.queryParameters;
    for (final key in _verboseQueryKeys) {
      final value = params[key]?.toLowerCase();
      if (value == '1' || value == 'true' || value == 'verbose') return true;
    }
    return false;
  }

  static void subchatRoute(String event, Map<String, Object?> fields) {
    DevLogSink.event(event, fields);
  }

  static void subchatTiming(String event, Map<String, Object?> fields) {
    DevLogSink.event(event, {'log_group': 'subchat_timing', ...fields});
  }

  static void installMatrixLogForwarder() {
    if (_matrixLogForwarderInstalled) return;
    _matrixLogForwarderInstalled = true;

    final previousOnLog = Logs().onLog;
    Logs().onLog = (logEvent) {
      try {
        previousOnLog?.call(logEvent);
      } catch (_) {
        // Logging hooks must not prevent later debug forwarding.
      }

      if (!kIsWeb || _disabled) return;
      if (logEvent.title.startsWith('[MELLON-DEBUG]')) return;
      if (logEvent.level.index > Level.warning.index) return;

      final payload = <String, Object?>{
        'source': 'mellon-web',
        'event': 'mellon.matrix_log',
        'session_id': _sessionId,
        'time': DateTime.now().toUtc().toIso8601String(),
        'level': logEvent.level.name,
        'title': logEvent.title,
      };
      final exception = logEvent.exception;
      if (exception != null) payload['exception'] = exception.toString();
      final stackTrace = logEvent.stackTrace;
      if (stackTrace != null) {
        payload['stack'] = stackTrace
            .toString()
            .split('\n')
            .take(12)
            .join('\n');
      }

      unawaited(_post(payload));
    };
  }

  static void startup(String event, Map<String, Object?> fields) {
    DevLogSink.event(event, fields);
  }

  static Future<void> _post(Map<String, Object?> payload) async {
    try {
      final response = await http
          .post(
            Uri.base.resolve(_path),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 2));

      if (response.statusCode == 404 || response.statusCode == 405) {
        _disabled = true;
      }
    } catch (_) {
      // Logging must never change chat behavior.
    }
  }
}
