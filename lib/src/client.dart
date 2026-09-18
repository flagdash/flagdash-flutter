import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class FlagDashClient with WidgetsBindingObserver {
  FlagDashClient({
    required String sdkKey,
    String baseUrl = 'https://flagdash.io',
    Duration timeout = const Duration(seconds: 5),
    Duration cacheTtl = const Duration(minutes: 1),
    String? region,
    bool realtime = true,
    http.Client? httpClient,
    FlagDashStorage? storage,
  })  : _sdkKey = sdkKey,
        _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _timeout = timeout,
        _cacheTtl = cacheTtl,
        _region = region,
        _realtimeEnabled = realtime,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _storage = storage ?? SharedPreferencesFlagDashStorage() {
    if (sdkKey.isEmpty) {
      throw ArgumentError.value(sdkKey, 'sdkKey', 'is required');
    }
  }

  static const _storageKey = 'flagdash.last_known.v1';
  final String _sdkKey;
  final String _baseUrl;
  final Duration _timeout;
  final Duration _cacheTtl;
  final String? _region;
  final bool _realtimeEnabled;
  final http.Client _http;
  final bool _ownsHttp;
  final FlagDashStorage _storage;
  final Map<String, _CacheEntry> _cache = {};
  final List<Map<String, dynamic>> _events = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<String>? _realtime;
  bool _closed = false;
  int _reconnectAttempt = 0;

  Stream<void> get changes => _changes.stream;

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    final stored = await _storage.getString(_storageKey);
    if (stored != null) {
      final decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic>) {
        final expires = DateTime.now().add(_cacheTtl);
        decoded
            .forEach((key, value) => _cache[key] = _CacheEntry(value, expires));
      }
    }
    await refresh();
    if (_realtimeEnabled) {
      unawaited(_connectRealtime());
    }
  }

  Future<T> flag<T>(String key, T defaultValue,
      {EvaluationContext? context}) async {
    if (context != null) {
      return (await flagDetail(key, defaultValue, context: context)).value;
    }
    final cached = _cached('flag:$key');
    if (cached is T) return cached;
    final fetched = (await allFlags())[key];
    return fetched is T ? fetched : defaultValue;
  }

  Future<FlagDetail<T>> flagDetail<T>(String key, T defaultValue,
      {EvaluationContext? context}) async {
    try {
      final data =
          await _get('/flags/${Uri.encodeComponent(key)}', context: context);
      final value = data['value'];
      return FlagDetail<T>(
          key: data['key'] as String? ?? key,
          value: value is T ? value : defaultValue,
          reason: data['reason'] as String? ?? 'default',
          variationKey: data['variation_key'] as String?);
    } catch (_) {
      return FlagDetail<T>(key: key, value: defaultValue, reason: 'default');
    }
  }

  Future<Map<String, dynamic>> allFlags({EvaluationContext? context}) async {
    try {
      final data = await _get('/flags', context: context);
      final flags =
          Map<String, dynamic>.from(data['flags'] as Map? ?? const {});
      if (context == null) {
        final expires = DateTime.now().add(_cacheTtl);
        flags.forEach(
            (key, value) => _cache['flag:$key'] = _CacheEntry(value, expires));
        await _persist();
      }
      return flags;
    } catch (_) {
      return {
        for (final item
            in _cache.entries.where((item) => item.key.startsWith('flag:')))
          item.key.substring(5): item.value.value
      };
    }
  }

  Future<T> config<T>(String key, T defaultValue) async {
    final cached = _cached('config:$key');
    if (cached != null && cached is T) return cached;
    try {
      final data = await _get('/configs/${Uri.encodeComponent(key)}');
      final value = data['value'];
      if (value is! T) return defaultValue;
      _cache['config:$key'] = _CacheEntry(value, DateTime.now().add(_cacheTtl));
      await _persist();
      return value;
    } catch (_) {
      return defaultValue;
    }
  }

  Future<List<Map<String, dynamic>>> listConfigs() async =>
      List<Map<String, dynamic>>.from(
          (await _get('/configs'))['configs'] as List? ?? const []);

  /// Evaluate without caching or resolving secret references.
  Future<Map<String, dynamic>?> aiConfigRelease(String key,
      {String userId = 'anonymous'}) async {
    try {
      final response = await _get('/ai-config-releases/${Uri.encodeComponent(key)}',
          context: EvaluationContext(userId: userId));
      return Map<String, dynamic>.from(response['ai_config'] as Map);
    } catch (_) {
      return null;
    }
  }

  Future<AiConfig?> aiConfig(String fileName) async {
    try {
      return AiConfig.fromJson(Map<String, dynamic>.from((await _get(
              '/ai-configs/${Uri.encodeComponent(fileName)}'))['ai_config']
          as Map));
    } catch (_) {
      return null;
    }
  }

  Future<List<AiConfig>> listAiConfigs(
      {String? fileType, Object? folder = _anyFolder}) async {
    final values =
        ((await _get('/ai-configs'))['ai_configs'] as List? ?? const []).map(
            (value) =>
                AiConfig.fromJson(Map<String, dynamic>.from(value as Map)));
    return values
        .where((value) =>
            (fileType == null || value.fileType == fileType) &&
            (identical(folder, _anyFolder) || value.folder == folder))
        .toList();
  }

  Future<String> translation(String key,
      {required String locale,
      String? defaultValue,
      Map<String, Object?> variables = const {}}) async {
    final parts = key.split('.');
    if (parts.length < 2) return defaultValue ?? key;
    final namespace = parts.first;
    final messageKey = parts.skip(1).join('.');
    try {
      final data = await _get(
          '/translations/${Uri.encodeComponent(locale)}/${Uri.encodeComponent(namespace)}');
      final messages =
          ((data['catalog'] as Map?)?['messages'] as Map?) ?? const {};
      final pattern = messages[messageKey];
      if (pattern is! String) return defaultValue ?? key;
      return pattern.replaceAllMapped(RegExp(r'\{([\w.]+)\}'),
          (match) => variables[match.group(1)]?.toString() ?? match.group(0)!);
    } catch (_) {
      return defaultValue ?? key;
    }
  }

  Future<ExperimentAssignment?> experiment(
      String key, EvaluationContext context) async {
    if (context.userId == null && context.unitId == null) return null;
    try {
      return ExperimentAssignment.fromJson(Map<String, dynamic>.from(
          (await _get('/experiments/${Uri.encodeComponent(key)}',
              context: context))['experiment'] as Map));
    } catch (_) {
      return null;
    }
  }

  void trackExperimentMetric(
      {required String experimentKey,
      required String eventName,
      required String userId,
      double? value,
      Map<String, Object?> properties = const {},
      String? eventId,
      DateTime? occurredAt}) {
    if (_events.length >= 1000) return;
    _events.add({
      'event_id': eventId ??
          'evt_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}',
      'experiment_key': experimentKey,
      'event_name': eventName,
      'user_id': userId,
      'value': value,
      'properties': properties,
      'occurred_at': (occurredAt ?? DateTime.now().toUtc()).toIso8601String()
    });
  }

  Future<bool> flush() async {
    try {
      while (_events.isNotEmpty) {
        final batch = _events.take(100).toList();
        await _post('/experiment-events/batch', {'events': batch});
        _events.removeRange(0, batch.length);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    await Future.wait([allFlags(), listConfigs(), listAiConfigs()]);
    if (!_closed) _changes.add(null);
  }

  Future<void> clearCache() async {
    _cache.clear();
    await _storage.remove(_storageKey);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _realtimeEnabled) {
      unawaited(_connectRealtime());
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_realtime?.cancel());
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _realtime?.cancel();
    await flush();
    await _changes.close();
    if (_ownsHttp) _http.close();
  }

  dynamic _cached(String key) {
    final item = _cache[key];
    if (item == null) return null;
    if (item.expires.isBefore(DateTime.now())) {
      _cache.remove(key);
      return null;
    }
    return item.value;
  }

  Future<Map<String, dynamic>> _get(String path,
      {EvaluationContext? context}) async {
    final query = {
      ...?context?.toQuery(),
      if (_region != null) 'region': _region
    };
    final uri = Uri.parse('$_baseUrl/api/v1$path')
        .replace(queryParameters: query.isEmpty ? null : query);
    final response = await _http.get(uri, headers: {
      'Authorization': 'Bearer $_sdkKey',
      'Accept': 'application/json'
    }).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('FlagDash HTTP ${response.statusCode}', uri);
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> _post(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$_baseUrl/api/v1$path');
    final response = await _http
        .post(uri,
            headers: {
              'Authorization': 'Bearer $_sdkKey',
              'Content-Type': 'application/json'
            },
            body: jsonEncode(body))
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('FlagDash HTTP ${response.statusCode}', uri);
    }
  }

  Future<void> _persist() async {
    final values = {
      for (final item in _cache.entries) item.key: item.value.value
    };
    await _storage.setString(_storageKey, jsonEncode(values));
  }

  Future<void> _connectRealtime() async {
    if (_closed || _realtime != null) return;
    try {
      final request =
          http.Request('GET', Uri.parse('$_baseUrl/api/v1/realtime'))
            ..headers['Authorization'] = 'Bearer $_sdkKey';
      final response = await _http.send(request);
      if (response.statusCode != 200) {
        throw http.ClientException(
            'FlagDash realtime HTTP ${response.statusCode}');
      }
      _reconnectAttempt = 0;
      _realtime = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('data:')) {
          unawaited(refresh());
        }
      },
              onDone: _scheduleReconnect,
              onError: (_) => _scheduleReconnect(),
              cancelOnError: true);
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _realtime = null;
    if (_closed || !_realtimeEnabled) return;
    final seconds = min(30, 1 << min(_reconnectAttempt++, 5));
    Timer(Duration(seconds: seconds, milliseconds: Random().nextInt(500)),
        () => unawaited(_connectRealtime()));
  }
}

class _CacheEntry {
  const _CacheEntry(this.value, this.expires);
  final dynamic value;
  final DateTime expires;
}

const Object _anyFolder = Object();

abstract interface class FlagDashStorage {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesFlagDashStorage implements FlagDashStorage {
  SharedPreferencesFlagDashStorage([SharedPreferencesAsync? preferences])
      : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _preferences.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _preferences.remove(key);
  }
}
