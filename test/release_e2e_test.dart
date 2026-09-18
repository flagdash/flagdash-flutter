import 'dart:convert';
import 'dart:io';
import 'package:flagdash/flagdash.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements FlagDashStorage {
  final Map<String, String> values = {};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These are live contract tests, so disable the widget test HTTP stub.
  HttpOverrides.global = null;
  test('live AI releases', () async {
  final cases = jsonDecode(File(Platform.environment['FLAGDASH_RELEASE_CASES']!).readAsStringSync()) as List<dynamic>;
  final results = <dynamic>[];
  for (final raw in cases) {
   final item = Map<String, dynamic>.from(raw as Map);
   final client = FlagDashClient(sdkKey: item['sdk_key'] as String, baseUrl: item['base_url'] as String,
       storage: _MemoryStorage(), realtime: false);
   results.add(item['mode'] == 'config' ? await client.config<dynamic>(item['key'] as String, null) : await client.aiConfigRelease(item['key'] as String, userId: item['user_id'] as String));
   await client.close();
  }
  File(Platform.environment['FLAGDASH_RELEASE_OUTPUT']!).writeAsStringSync(jsonEncode(results));
 }, skip: !Platform.environment.containsKey('FLAGDASH_RELEASE_CASES'));
}
