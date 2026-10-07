# DeepSeek Hint Preview

This service is separate from the existing Wanx image service. It accepts only adult or synthetic rehearsal summaries for the mixing and pressure modules. The iPad never receives the DeepSeek API key.

## Start

Requires Node 22+. The key file may contain other provider keys, but the DeepSeek key must follow a `DeepSeek API KEY:` label. The service reads only that labelled credential and sends it only to `https://api.deepseek.com/chat/completions`.

```sh
node Bridge/hints-cli.mjs configure --runtime /absolute/private/runtime --key-file /absolute/credentials.md --daily-limit 30
node Bridge/hints-cli.mjs serve --runtime /absolute/private/runtime --host 0.0.0.0 --port 8788
node Bridge/hints-cli.mjs pair --runtime /absolute/private/runtime
```

In the separate `绘画提示测试` app, open `连接设置`, enter the trusted LAN address and one-use code, then enable adult/synthetic rehearsal consent. Keep the Mac service running. HTTP is restricted by the app to local/private addresses and is for trusted adult testing only; no public tunnel or router forwarding is configured. Use authenticated HTTPS and an approved data protocol before any participant deployment.

The API identifier is `deepseek-flash`, which the official September 10, 2026 documentation identifies as V4.1 Flash. The API alias can change upstream, so the requested identifier, returned identifier, strategy and library version are recorded. This is not an immutable model snapshot.

## Boundaries

- Only task, target enum, stroke count and whitelisted numerical metrics are sent. No participant identifiers, artwork, audio, free text, drawing IDs, coordinates or raw touch streams leave the iPad.
- The model selects one approved strategy. It does not generate displayed prose, animations, scores, diagnoses or drawing changes.
- B and C share the same visual/voice interface, first-attempt gate, three-hint limit and 15-second cooldown. B follows a fixed per-task sequence. C uses model selection constrained by local evidence; cloud failure uses the first local eligible action and is labelled/logged as a fallback.
- Mixing thresholds (0.65 mixed fraction, 0.08 ratio variance, 2:1 load ratio) and pressure thresholds (0.10 signed error, 0.12 standard deviation) are engineering heuristics for rehearsal, not calibrated child learning measures.
- Requests are bounded to 96 output tokens, non-thinking JSON, eight-second upstream timeout, two concurrent calls and a persistent daily request cap. The cap is not a dollar-budget guarantee.
- Request UUIDs are persisted before submission. Concurrent retries share one call; completed retries return the prior result; failed/uncertain requests are not resubmitted automatically.
- Pairing codes expire after ten minutes and are single use. Pairing is rate-limited; device tokens are stored in the iPad Keychain and hashed on the server. Browser-origin requests and redirects are rejected.
- The private runtime contains key-file paths, token hashes and request receipts, not copied API keys or input summaries. Do not include this directory or the credential document in source/release archives.

## Tests

```sh
node --test Bridge/hints.test.mjs
node Bridge/hints-live-smoke.mjs /absolute/credentials.md /absolute/report.json
```

The live smoke test makes at most four paid requests with synthetic summaries. UI live tests are separately opt-in using `INKSTUDY_LIVE_HINT_TEST=1` on the test runner. The app's `--hint-bootstrap` launch argument, compiled only in the preview target, consumes `Documents/HintPreviewBootstrap.json`, pairs the device, and removes that one-use file. It contains no API key.

## Research Logs

Preview records use `hintProtocolVersion=multimodal-preview-v1-20260917`; legacy records retain their original support logic. Export includes `hints.csv` (strategy, source, model, timing, fallback and local evidence) and `hint-delivery.csv` (display/audio lifecycle). Audio completion indicates playback, not comprehension. Overlay marks and demonstration animations are never saved into the artwork.

Official references: [DeepSeek changelog](https://api-docs.deepseek.com/updates/), [Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion/).
