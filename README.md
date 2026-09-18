# FlagDash Flutter SDK

Feature flags, remote config, AI configs, translations and experiments for
Flutter — with live updates, offline persistence and lifecycle awareness built
in.

## Installation

```yaml
dependencies:
  flagdash: ^0.1.0
```

Requires Dart 3.3+.

## Quick start

```dart
import 'package:flagdash/flagdash.dart';

final client = FlagDashClient(sdkKey: const String.fromEnvironment('FLAGDASH_SDK_KEY'));
await client.initialize();

final enabled = await client.flag<bool>(
  'checkout-v2',
  false,
  context: const EvaluationContext(userId: 'alice'),
);
```

**Call `initialize()` once** before reading. It restores the last known values
from storage, opens the realtime stream, and registers the lifecycle observer.

## What makes this different from a plain HTTP client

| | |
|---|---|
| **Live updates** | A change in the dashboard reaches the running app over SSE — no polling, no relaunch. |
| **Offline first** | The last known values are persisted, so the very first frame after a cold start with no network still gets real values instead of your defaults. |
| **Lifecycle aware** | Refreshes on foreground and drops the stream on background, so a backgrounded app is not holding a socket open. |

## API keys

Ship a **client key** (`pk_`). It carries the project and environment, which is
why no method takes an `environment` argument, and it never returns targeting
rules — an app cannot see who else you are targeting.

Never embed a server key (`sk_`) in a build. Translations and experiments below
need a server key, so call them from your backend when the app holds a client
key.

## Configuration

```dart
final client = FlagDashClient(
  sdkKey: key,
  baseUrl: 'https://flagdash.io',              // self-hosted? point it here
  timeout: const Duration(seconds: 5),
  cacheTtl: const Duration(minutes: 1),
  region: null,                                // null auto-detects
  realtime: true,                              // false disables the SSE stream
  httpClient: null,                            // share your own http.Client
  storage: null,                               // defaults to SharedPreferences
);
```

An empty `sdkKey` throws `ArgumentError` at construction — a missing key should
fail loudly rather than quietly serve defaults forever.

`storage` takes any `FlagDashStorage`, which is how you swap in secure storage
or a fake for tests.

## Feature flags

`flag<T>` is generic: the type you ask for is the type you get, and a value of
any other shape falls back to your default.

```dart
final enabled = await client.flag<bool>('checkout-v2', false, context: context);
final copy = await client.flag<String>('banner-copy', 'control', context: context);

// Every flag for this context, in one request.
final flags = await client.allFlags(context: context);

// Why did it resolve that way?
final detail = await client.flagDetail<bool>('checkout-v2', false, context: context);
detail.value;
detail.reason;        // 'rule_match', 'rollout', 'default', ...
detail.variationKey;
```

### Context

```dart
const context = EvaluationContext(
  userId: 'alice',
  attributes: {'country': 'GB', 'plan': 'premium'},
);
```

**Set `userId`** (or `unitId`) whenever you want a stable answer. Percentage
rollouts and A/B variations hash it, so a context without one re-rolls on every
call by design.

## Reacting to changes

```dart
late final StreamSubscription<void> _sub;

@override
void initState() {
  super.initState();
  _sub = client.changes.listen((_) => setState(() {}));
}

@override
void dispose() {
  _sub.cancel();
  super.dispose();
}
```

`changes` fires after a refresh has updated the cache — on a realtime event, on
foreground, and on an explicit `refresh()`.

## Remote config

```dart
final limit = await client.config<int>('rate_limit', 100);
final all = await client.listConfigs();
```

## AI configs

Prompts, agents, skills and rules, versioned per environment and editable
without an app store release.

```dart
final agent = await client.aiConfig('support-agent.md');
final files = await client.listAiConfigs(fileType: 'agent');
```

## Translations (server key)

```dart
final greeting = await client.translation(
  'checkout.greeting',
  locale: 'fr',
  defaultValue: 'Hello',
  variables: {'name': 'Alice'},
);
```

The key is `namespace.message`. `{placeholders}` come from `variables`, and the
default is returned whenever the catalogue, namespace or message is missing.

## Experiments (server key)

```dart
final assignment = await client.experiment(
  'checkout-redesign',
  context: context,
);

if (assignment?.variant == 'treatment') {
  // ...
}

client.trackExperimentMetric(
  experimentKey: 'checkout-redesign',
  eventName: 'purchase',
  userId: 'alice',
  value: 42.50,
  properties: {'currency': 'GBP'},
);
```

`experiment` returns `null` for a context with no identifier — an assignment
that cannot be stable is worse than none.

Metrics are buffered and sent by `flush()`. On mobile, flush when the app
backgrounds: a process killed with a full buffer loses what is in it.

```dart
await client.flush();
```

## Lifecycle

```dart
await client.refresh();      // re-read now and emit on `changes`
await client.clearCache();   // drop cached values and the persisted copy
await client.close();        // flush, close the stream, release the client
```

Call `close()` when tearing the app down, or in `dispose()` if the client is
owned by a widget.

## Failure behaviour

Every read returns the default you passed. Nothing on the read path throws, so a
flaky mobile network degrades to your fallback values — and with persistence,
usually to the *last real* values instead.

## License

MIT

## Session replay

Not available in the Flutter SDK yet. Every other FlagDash SDK ships a recorder —
browser DOM replay in JavaScript, React and Vue; explicit interaction timelines in
React Native, Android and Swift/iOS; explicit backend timelines in Node, Go, Python,
Ruby, PHP, Elixir, Lua and Rust.

To record around a Flutter app today, either drive the timeline from whichever server
SDK handles its requests, or call the Android and iOS recorders through a platform
channel.

## AI releases

Create a release in **Manage → AI Releases**, select the environment, then set
a baseline, candidate and rollout. With your initialized client, evaluate it using
an environment-bound key with `ai_configs:read`:

```dart
final release = await client.aiConfigRelease("support-agent", userId: "usr_123");
```

The result includes `key`, `version`, `config`, `reason`, `variation_key`, and
`rollout_percentage` (idiomatic field names for typed SDKs). Pass a stable user
identity. Decisions are fetched afresh; verify baseline, rollout and paused
behavior in development before ramping production. Your backend calls the AI
provider. Ordinary evaluation leaves secret references unresolved; never put
provider credentials in a configuration delivered to browsers or mobile apps.
See the [release guide](../../docs/ai-config-releases.md) for lifecycle and cleanup.

## Remote config value format

Remote config storage and server metadata use exactly one `{"value": ...}`
envelope. Convenience config reads return the inner application value, without
recursively unwrapping application fields named `value`. For example, stored
`{"value": {"value": 7, "enabled": false}}` reads as
`{"value": 7, "enabled": false}`. Metadata methods retain the envelope.

MCP and management writes accept the envelope and automatically wrap bare objects.
To store an application object whose only key is `value`, send
`{"value": {"value": 7}}`. Arrays and scalar values must be inside the envelope.
Existing bare stored objects are migrated, preserving secret-reference bindings.
Server SDK callers previously receiving the envelope should remove their extra
`.value` access when upgrading. Verify in a development environment first.
