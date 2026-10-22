# llama-android

Run [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` locally on an
Android phone, with a native chat UI and an OpenAI-compatible API. Models and
inference stay on the device.

## Features

- Import any GGUF model through the Android file picker.
- Run the CPU backend on any arm64 device; optional Adreno (OpenCL) and Hexagon
  (HTP) backends on Qualcomm Snapdragon devices.
- Streaming chat with tokens/sec, token counts and prompt speed per reply.
- Multiple conversation tabs, persisted locally on the device.
- Built-in llama.cpp Web UI.
- OpenAI-compatible API with optional LAN access and a required API key.
- Foreground service so the server keeps running when the UI is backgrounded.

## Requirements

- Android 9 (API 28) or newer, arm64 device.
- About 300 MB free for the llama.cpp backend plus model size.
- A GGUF model file. Small models (for example 1B quantized) are a good start;
  large models need enough RAM and free storage.

## Install

Download the APK from the releases page, or build it yourself:

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

Build requirements: Flutter 3.47+, JDK 17+, Android SDK with NDK
`28.2.13676358`. The release build currently uses the local debug signing key
so sideloaded updates work without extra setup; generate a private keystore
before distributing builds to other people.

## Use

1. Open **Server**, choose **Model** and pick a `.gguf` file.
2. Download the **CPU** backend (or a Snapdragon backend on supported hardware).
3. Tap **Start server**.
4. Chat in the **Chat** tab, or use the **Web UI** tab.

The server listens on `127.0.0.1:8080` by default.

## OpenAI-compatible API

Enable **Allow LAN access** in the Server tab to listen on all interfaces. A key
of at least 8 characters is required, and one is generated automatically. Send
it as a Bearer token:

```bash
curl http://192.168.1.10:8080/v1/chat/completions \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

Endpoints:

- `POST /v1/chat/completions`
- `POST /v1/completions`
- `POST /v1/embeddings` (model dependent)
- `GET /v1/models`

Use `http://127.0.0.1:8080/v1` as the OpenAI base URL from apps on the same
phone, or the LAN URL shown in the app from other devices.

LAN traffic is plain HTTP. Only enable LAN access on a trusted network: anyone
who can sniff the connection can capture the API key. `/health` is intentionally
unauthenticated; all other endpoints require the key when one is set.

## Backends

| Backend | Hardware | Notes |
| --- | --- | --- |
| CPU | All arm64 devices | Default, most compatible |
| Adreno (OpenCL) | Qualcomm Snapdragon with Adreno GPU | Uses the snapdragon llama.cpp package |
| Hexagon (HTP) | Qualcomm Snapdragon with a recent HTP stack | Experimental |

Adreno and Hexagon entries are shown but disabled on non-Qualcomm devices.
A Vulkan backend is not included yet.

Backend archives are downloaded from pinned llama.cpp b11798 GitHub releases.
The download code restricts redirects to GitHub hosts, and the tar extractor
rejects absolute paths, `..`, links and oversized archives.

## Project layout

- `lib/` — Flutter UI, chat client, settings and conversation storage.
- `android/app/src/main/kotlin/.../LlamaEngine.kt` — backend install, model
  import, process lifecycle and chat persistence.
- `android/app/src/main/kotlin/.../TarExtract.kt` — minimal safe tar.gz reader.
- `android/app/src/main/kotlin/.../LlamaService.kt` — foreground service.

## Limitations

- Built for sideloading; `targetSdk` is 28 because executing a downloaded binary
  from app storage requires it on Android 10+. This also means the app misses
  newer Android hardening, and it is not Play Store ready.
- Only arm64 is built. 32-bit devices are not supported.
- No TLS for the LAN API. Use a trusted network or a tunnel.
- Release builds use the Android debug signing key.
- Backend downloads are not checksum-pinned yet.
- The Web UI stores the API key in WebView local storage for its origin.

## License

Apache License 2.0. See [LICENSE](LICENSE).

llama.cpp is a separate project by Georgi Gerganov and contributors, also under
the MIT license. This app downloads its official release binaries at runtime.
