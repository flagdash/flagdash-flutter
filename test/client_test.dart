import 'package:flagdash/flagdash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reads typed client resources and context', () async {
    final requests = <http.Request>[];
    final httpClient = MockClient((request) async {
      requests.add(request);
      switch (request.url.path) {
        case '/api/v1/flags':
          return http.Response('{"flags":{"checkout":true}}', 200);
        case '/api/v1/flags/checkout':
          return http.Response(
              '{"key":"checkout","value":true,"reason":"rule_match","variation_key":"on"}',
              200);
        case '/api/v1/configs/theme':
          return http.Response('{"key":"theme","value":"violet"}', 200);
        case '/api/v1/ai-configs/agent.md':
          return http.Response(
              '{"ai_config":{"file_name":"agent.md","file_type":"agent","content":"Be useful"}}',
              200);
        default:
          return http.Response('{}', 200);
      }
    });
    final client = FlagDashClient(
        sdkKey: 'sk_test',
        baseUrl: 'https://example.test',
        region: 'eu',
        realtime: false,
        httpClient: httpClient,
        storage: _MemoryStorage());
    expect(await client.flag('checkout', false), isTrue);
    expect(
        (await client.flagDetail('checkout', false,
                context: const EvaluationContext(userId: 'alice')))
            .reason,
        'rule_match');
    expect(await client.config<dynamic>('theme', null), 'violet');
    expect(await client.config('theme', 'default'), 'violet');
    expect((await client.aiConfig('agent.md'))?.content, 'Be useful');
    expect(requests[1].url.queryParameters['user_id'], 'alice');
    await client.close();
  });
}

class _MemoryStorage implements FlagDashStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}
