// ============================================================================
// LiteRT-LM Native Client — Direct FFI replacement for the gRPC client
// ============================================================================
//
// This is the high-level Dart wrapper around the LiteRT-LM C API.
// It replaces `LiteRtLmClient` (the old gRPC client) with zero-overhead
// native calls via dart:ffi. No Java, no server process, no gRPC.
//
// Public API surface matches the old client so `DesktopInferenceModel`
// can drop in with minimal changes:
//   - initialize(modelPath, backend, maxTokens, ...)
//   - createConversation(temperature, topK, topP, systemMessage)
//   - chat(text) → Stream<String>
//   - chatWithImage(text, imageBytes) → Stream<String>
//   - chatWithAudio(text, audioBytes) → Stream<String>
//   - closeConversation()
//   - shutdown()
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'litertlm_bindings.dart';

/// Native FFI client for LiteRT-LM — replaces the old gRPC client entirely.
///
/// Loads the LiteRT-LM shared library directly and calls the C API
/// functions via dart:ffi. No Java runtime, no server process, no gRPC.
///
/// Lifecycle:
///   1. Construct: `LiteRtLmNativeClient()`
///   2. Initialize: `await initialize(modelPath: ..., backend: ...)`
///   3. Create conversation: `await createConversation(...)`
///   4. Chat: `await for (final chunk in client.chat('Hello')) { ... }`
///   5. Close conversation: `await closeConversation()`
///   6. Shutdown: `await shutdown()`
class LiteRtLmNativeClient {
  LiteRtLmBindings? _bindings;
  Pointer<LiteRtLmEngine>? _engine;
  Pointer<LiteRtLmConversation>? _conversation;
  bool _isInitialized = false;

  /// Whether the engine has been initialized and is ready for use
  bool get isInitialized => _isInitialized;

  /// Whether a conversation is currently active
  bool get hasConversation => _conversation != null;

  // ==========================================================================
  // Windows DLL search path — ensure dependencies in litertlm/ are findable
  // ==========================================================================

  /// Adds [directory] to the Windows DLL search path via SetDllDirectoryW.
  ///
  /// When litert_lm_capi.dll is loaded from a litertlm/ subfolder, Windows
  /// won't automatically search that folder for dependent DLLs like
  /// libGemmaModelConstraintProvider.dll. This call tells the loader to
  /// include that directory when resolving implicit dependencies.
  static void _addDllDirectory(String directory) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');

      // BOOL SetDllDirectoryW(LPCWSTR lpPathName)
      final setDllDirectory = kernel32.lookupFunction<
          Int32 Function(Pointer<Utf16> lpPathName),
          int Function(Pointer<Utf16> lpPathName)>('SetDllDirectoryW');

      final dirPtr = directory.toNativeUtf16(allocator: calloc);
      final result = setDllDirectory(dirPtr);
      calloc.free(dirPtr);

      if (result != 0) {
        debugPrint('[LiteRtLmNative] Added DLL search path: $directory');
      } else {
        debugPrint('[LiteRtLmNative] WARNING: SetDllDirectoryW failed');
      }
    } catch (e) {
      // Non-fatal — the DLL may still load if deps are on PATH
      debugPrint('[LiteRtLmNative] Could not set DLL directory: $e');
    }
  }

  // ==========================================================================
  // Library Loading — finds the right .dll/.so/.dylib for the current platform
  // ==========================================================================

  /// Resolve the path to the LiteRT-LM shared library for the current platform.
  ///
  /// The library is built from LiteRT-LM source (see native/build_litert_lm_dll.*)
  /// and bundled by the platform-specific CMake/setup scripts.
  ///
  /// Search order:
  ///   1. litertlm/ subdirectory next to the executable (bundled by CMake)
  ///   2. Directly next to the executable (development fallback)
  static String _resolveLibraryPath() {
    final executableDir = path.dirname(Platform.resolvedExecutable);

    // Library name per platform — built from LiteRT-LM source via Bazel
    // (see native/build_litert_lm_dll.ps1 / .sh)
    final String libName;
    if (Platform.isWindows) {
      libName = 'litert_lm_capi.dll';
    } else if (Platform.isMacOS) {
      libName = 'liblitert_lm_capi.dylib';
    } else {
      libName = 'liblitert_lm_capi.so';
    }

    // Search paths in priority order
    final searchPaths = <String>[];

    if (Platform.isWindows) {
      // Windows: litertlm/ subdirectory next to .exe
      searchPaths.add(path.join(executableDir, 'litertlm', libName));
      searchPaths.add(path.join(executableDir, libName));
    } else if (Platform.isMacOS) {
      // macOS: Frameworks/litertlm/ inside app bundle
      searchPaths.add(path.join(
        executableDir, '..', 'Frameworks', 'litertlm', libName,
      ));
      searchPaths.add(path.join(executableDir, libName));
    } else {
      // Linux: lib/litertlm/ next to executable
      searchPaths.add(path.join(
        executableDir, 'lib', 'litertlm', libName,
      ));
      searchPaths.add(path.join(executableDir, libName));
    }

    // Return the first path that exists, or the first path (for error msg)
    for (final p in searchPaths) {
      if (File(p).existsSync()) return p;
    }

    return searchPaths.first;
  }

  // ==========================================================================
  // Initialization — load library, create engine settings, create engine
  // ==========================================================================

  /// Initialize the LiteRT-LM engine with the given model.
  ///
  /// This loads the native shared library, creates engine settings,
  /// and creates the engine instance. Must be called before any other method.
  ///
  /// [modelPath] — absolute path to the .task / .litertlm model file
  /// [backend] — compute backend: "cpu" or "gpu" (default: "gpu")
  /// [maxTokens] — maximum token context window (default: 2048)
  /// [enableVision] — enable vision/image input support
  /// [maxNumImages] — max number of images per turn (only if enableVision)
  /// [enableAudio] — enable audio input support
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 2048,
    bool enableVision = false,
    int maxNumImages = 1,
    bool enableAudio = false,
  }) async {
    if (_isInitialized) {
      debugPrint('[LiteRtLmNative] Already initialized, shutting down first');
      await shutdown();
    }

    debugPrint('[LiteRtLmNative] Initializing...');
    debugPrint('[LiteRtLmNative]   modelPath: $modelPath');
    debugPrint('[LiteRtLmNative]   backend: $backend');
    debugPrint('[LiteRtLmNative]   maxTokens: $maxTokens');
    debugPrint('[LiteRtLmNative]   enableVision: $enableVision');
    debugPrint('[LiteRtLmNative]   enableAudio: $enableAudio');

    // Load the native shared library
    final libraryPath = _resolveLibraryPath();
    debugPrint('[LiteRtLmNative] Loading library: $libraryPath');

    // On Windows, the DLL lives in a litertlm/ subfolder alongside its
    // dependencies (accelerator DLLs, DXC, etc.). Windows only searches
    // the application directory for dependent DLLs, not the loaded DLL's
    // own directory. We temporarily add the DLL's directory to the DLL
    // search path so Windows can find libGemmaModelConstraintProvider.dll
    // and friends when loading litert_lm_capi.dll.
    if (Platform.isWindows) {
      _addDllDirectory(path.dirname(libraryPath));
    }

    try {
      _bindings = LiteRtLmBindings.open(libraryPath);
    } catch (e) {
      throw Exception(
        'Failed to load LiteRT-LM native library at: $libraryPath\n'
        'Make sure the native library is bundled with the app.\n'
        'Error: $e',
      );
    }

    // Set log level to WARNING to reduce noise
    _bindings!.setMinLogLevel(1);

    // Run the heavy engine creation on an isolate to avoid blocking the UI.
    // Pointer can't be sent across isolates, so we pass the raw address as int.
    final engineAddress = await compute(_createEngineIsolate, _EngineCreateParams(
      libraryPath: libraryPath,
      modelPath: modelPath,
      backend: backend,
      enableVision: enableVision,
      enableAudio: enableAudio,
      maxTokens: maxTokens,
    ));

    if (engineAddress == 0) {
      throw Exception(
        'Failed to create LiteRT-LM engine. Check model path and backend.\n'
        'Model: $modelPath\n'
        'Backend: $backend',
      );
    }

    _engine = Pointer.fromAddress(engineAddress);

    if (_engine == nullptr) {
      throw Exception(
        'Failed to create LiteRT-LM engine. Check model path and backend.\n'
        'Model: $modelPath\n'
        'Backend: $backend',
      );
    }

    _isInitialized = true;
    debugPrint('[LiteRtLmNative] Engine initialized successfully');
  }

  // ==========================================================================
  // Conversation Management
  // ==========================================================================

  /// Create a new conversation with the given sampler configuration.
  ///
  /// Must be called after [initialize]. Only one conversation can be active
  /// at a time — creating a new one automatically closes the previous.
  ///
  /// [temperature] — sampling temperature (higher = more random)
  /// [topK] — top-K sampling parameter
  /// [topP] — nucleus (top-P) sampling parameter
  /// [systemMessage] — optional system message to set the AI's behavior
  Future<void> createConversation({
    double? temperature,
    int? topK,
    double? topP,
    String? systemMessage,
  }) async {
    _assertInitialized();

    // Close any existing conversation first
    if (_conversation != null) {
      await closeConversation();
    }

    final bindings = _bindings!;

    // Create session config with sampler parameters
    final sessionConfig = bindings.sessionConfigCreate();
    if (sessionConfig == nullptr) {
      throw Exception('Failed to create session config');
    }

    try {
      // Set sampler parameters if any were provided
      if (temperature != null || topK != null || topP != null) {
        final samplerParams = calloc<LiteRtLmSamplerParams>();
        try {
          // Determine sampler type based on provided parameters
          if (topP != null) {
            samplerParams.ref.type = SamplerType.topP;
          } else if (topK != null && topK > 1) {
            samplerParams.ref.type = SamplerType.topK;
          } else {
            samplerParams.ref.type = SamplerType.topK;
          }

          samplerParams.ref.topK = topK ?? 40;
          samplerParams.ref.topP = topP ?? 0.95;
          samplerParams.ref.temperature = temperature ?? 0.8;
          samplerParams.ref.seed = 1;

          bindings.sessionConfigSetSamplerParams(sessionConfig, samplerParams);
        } finally {
          calloc.free(samplerParams);
        }
      }

      // Create conversation config (with optional system message)
      final systemMsgPtr = systemMessage != null
          ? systemMessage.toNativeUtf8()
          : nullptr;

      final convConfig = bindings.conversationConfigCreate(
        _engine!,
        sessionConfig,
        systemMsgPtr.cast<Utf8>(),
        nullptr.cast<Utf8>(), // tools_json — not used yet
        nullptr.cast<Utf8>(), // messages_json — not used yet
        false, // enable_constrained_decoding
      );

      // Free the system message string if we allocated one
      if (systemMsgPtr != nullptr) {
        calloc.free(systemMsgPtr);
      }

      if (convConfig == nullptr) {
        throw Exception('Failed to create conversation config');
      }

      // Create the actual conversation
      _conversation = bindings.conversationCreate(_engine!, convConfig);

      // Clean up the config — the conversation has its own copy
      bindings.conversationConfigDelete(convConfig);

      if (_conversation == null || _conversation == nullptr) {
        _conversation = null;
        throw Exception('Failed to create conversation');
      }

      debugPrint('[LiteRtLmNative] Conversation created');
    } finally {
      // Always clean up the session config
      bindings.sessionConfigDelete(sessionConfig);
    }
  }

  // ==========================================================================
  // Chat — streaming text generation via native callbacks
  // ==========================================================================

  /// Timeout for streaming responses (5 minutes for long generation)
  static const _streamTimeout = Duration(minutes: 5);

  /// Send a text message and get streaming response chunks.
  ///
  /// Returns a [Stream<String>] that yields response text chunks as they
  /// are generated by the model. The stream completes when generation
  /// finishes or when an error occurs.
  Stream<String> chat(String text) async* {
    _assertConversation();

    // Build the message JSON in the format LiteRT-LM expects
    final messageJson = _buildTextMessageJson(text);
    yield* _streamConversationMessage(messageJson);
  }

  /// Send a text + image message and get streaming response chunks.
  ///
  /// The image bytes should be raw image data (PNG/JPEG).
  Stream<String> chatWithImage(String text, Uint8List imageBytes) async* {
    _assertConversation();

    // Build multimodal message JSON with base64-encoded image
    final messageJson = _buildImageMessageJson(text, imageBytes);
    yield* _streamConversationMessage(messageJson);
  }

  /// Send a text + audio message and get streaming response chunks.
  ///
  /// Audio should be WAV format (16kHz, mono, 16-bit PCM).
  Stream<String> chatWithAudio(String text, Uint8List audioBytes) async* {
    _assertConversation();

    // Build multimodal message JSON with base64-encoded audio
    final messageJson = _buildAudioMessageJson(text, audioBytes);
    yield* _streamConversationMessage(messageJson);
  }

  /// Internal: stream a conversation message using the native callback API.
  ///
  /// Uses [NativeCallable.listener] to receive callbacks from the native
  /// library's background thread and forward them to the Dart event loop.
  Stream<String> _streamConversationMessage(String messageJson) async* {
    final bindings = _bindings!;

    // Controller to bridge native callbacks → Dart stream
    final controller = StreamController<String>();

    // Create the native-callable wrapper that forwards callbacks to Dart.
    // NativeCallable.listener is safe to call from any thread — it posts
    // the invocation to the Dart isolate's event loop.
    final nativeCallback = NativeCallable<LiteRtLmStreamCallbackNative>.listener(
      (Pointer<Void> callbackData, Pointer<Utf8> chunk, bool isFinal,
          Pointer<Utf8> errorMsg) {
        // Check for errors
        if (errorMsg != nullptr) {
          final error = errorMsg.toDartString();
          if (error.isNotEmpty) {
            controller.addError(Exception('LiteRT-LM error: $error'));
          }
        }

        // Emit the chunk text if present
        if (chunk != nullptr) {
          final text = chunk.toDartString();
          if (text.isNotEmpty) {
            controller.add(text);
          }
        }

        // Close the stream when we receive the final marker
        if (isFinal) {
          controller.close();
        }
      },
    );

    // Convert the message to a native string
    final messagePtr = messageJson.toNativeUtf8();

    try {
      // Start the streaming call (non-blocking — returns immediately)
      final result = bindings.conversationSendMessageStream(
        _conversation!,
        messagePtr.cast<Utf8>(),
        nativeCallback.nativeFunction,
        nullptr, // callback_data — not needed, closure captures everything
      );

      if (result != 0) {
        controller.addError(
          Exception('Failed to start streaming (error code: $result)'),
        );
        controller.close();
      }

      // Yield chunks as they arrive from the native callback
      await for (final chunk in controller.stream.timeout(
        _streamTimeout,
        onTimeout: (sink) {
          sink.addError(TimeoutException(
            'Response timed out after ${_streamTimeout.inMinutes} minutes',
          ));
          sink.close();
        },
      )) {
        yield chunk;
      }
    } finally {
      // Clean up native resources
      calloc.free(messagePtr);
      nativeCallback.close();
    }
  }

  // ==========================================================================
  // Cleanup
  // ==========================================================================

  /// Close the current conversation, releasing its native resources.
  Future<void> closeConversation() async {
    if (_conversation != null && _conversation != nullptr) {
      _bindings?.conversationDelete(_conversation!);
      debugPrint('[LiteRtLmNative] Conversation closed');
    }
    _conversation = null;
  }

  /// Shut down the engine and release all native resources.
  ///
  /// After calling this, [initialize] must be called again before using
  /// any other methods.
  Future<void> shutdown() async {
    // Close conversation first if still active
    if (_conversation != null) {
      await closeConversation();
    }

    // Destroy the engine
    if (_engine != null && _engine != nullptr) {
      _bindings?.engineDelete(_engine!);
      debugPrint('[LiteRtLmNative] Engine destroyed');
    }
    _engine = null;
    _isInitialized = false;

    // Note: we don't close the DynamicLibrary — Dart doesn't support that,
    // and it's fine since the process owns it until exit
    _bindings = null;
  }

  /// Cancel any ongoing inference (streaming generation).
  void cancelGeneration() {
    if (_conversation != null && _conversation != nullptr) {
      _bindings?.conversationCancelProcess(_conversation!);
      debugPrint('[LiteRtLmNative] Generation cancelled');
    }
  }

  // ==========================================================================
  // Message JSON builders — format messages for the LiteRT-LM Conversation API
  // ==========================================================================

  /// Build a text-only user message JSON string.
  String _buildTextMessageJson(String text) {
    final message = {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
    };
    return jsonEncode(message);
  }

  /// Build a multimodal user message with text + image.
  /// Image is base64-encoded inline (the LiteRT-LM conversation API
  /// expects the image data in the content array).
  String _buildImageMessageJson(String text, Uint8List imageBytes) {
    final imageBase64 = base64Encode(imageBytes);
    final message = {
      'role': 'user',
      'content': [
        {
          'type': 'image',
          'image': imageBase64,
        },
        {'type': 'text', 'text': text},
      ],
    };
    return jsonEncode(message);
  }

  /// Build a multimodal user message with text + audio.
  /// Audio is base64-encoded inline.
  String _buildAudioMessageJson(String text, Uint8List audioBytes) {
    final audioBase64 = base64Encode(audioBytes);
    final message = {
      'role': 'user',
      'content': [
        {
          'type': 'audio',
          'audio': audioBase64,
        },
        {'type': 'text', 'text': text},
      ],
    };
    return jsonEncode(message);
  }

  // ==========================================================================
  // Assertions
  // ==========================================================================

  void _assertInitialized() {
    if (!_isInitialized || _bindings == null || _engine == null) {
      throw StateError(
        'Engine not initialized. Call initialize() first.',
      );
    }
  }

  void _assertConversation() {
    _assertInitialized();
    if (_conversation == null || _conversation == nullptr) {
      throw StateError(
        'No active conversation. Call createConversation() first.',
      );
    }
  }
}

// ============================================================================
// Isolate helper — runs heavy engine creation off the main thread
// ============================================================================

/// Parameters for creating the engine on an isolate
class _EngineCreateParams {
  final String libraryPath;
  final String modelPath;
  final String backend;
  final bool enableVision;
  final bool enableAudio;
  final int maxTokens;

  _EngineCreateParams({
    required this.libraryPath,
    required this.modelPath,
    required this.backend,
    required this.enableVision,
    required this.enableAudio,
    required this.maxTokens,
  });
}

/// Create the engine on a background isolate to avoid blocking the UI.
///
/// Engine creation can take several seconds (loading model weights,
/// compiling GPU shaders, etc.) so we run it in a separate isolate.
///
/// Returns the raw pointer address as an int (Pointer can't cross isolates).
int _createEngineIsolate(_EngineCreateParams params) {
  // Load the library in this isolate
  final bindings = LiteRtLmBindings.open(params.libraryPath);

  // Suppress info-level logs during initialization
  bindings.setMinLogLevel(1);

  // Convert Dart strings to native UTF-8 strings for the C API
  final modelPathPtr = params.modelPath.toNativeUtf8();
  final backendPtr = params.backend.toNativeUtf8();

  // Vision and audio backends: pass nullptr if not enabled
  final visionBackendPtr = params.enableVision
      ? params.backend.toNativeUtf8()
      : nullptr;
  final audioBackendPtr = params.enableAudio
      ? 'cpu'.toNativeUtf8() // Audio always runs on CPU
      : nullptr;

  try {
    // Create engine settings
    final settings = bindings.engineSettingsCreate(
      modelPathPtr.cast<Utf8>(),
      backendPtr.cast<Utf8>(),
      visionBackendPtr.cast<Utf8>(),
      audioBackendPtr.cast<Utf8>(),
    );

    if (settings == nullptr) {
      throw Exception('Failed to create engine settings');
    }

    // Set max tokens
    bindings.engineSettingsSetMaxNumTokens(settings, params.maxTokens);

    // Create the engine (this is the heavy part — loads model, compiles shaders)
    final engine = bindings.engineCreate(settings);

    // Clean up settings — the engine has its own copy
    bindings.engineSettingsDelete(settings);

    // Return the raw address — Pointer can't be sent across isolates
    return engine.address;
  } finally {
    // Free native strings
    calloc.free(modelPathPtr);
    calloc.free(backendPtr);
    if (visionBackendPtr != nullptr) calloc.free(visionBackendPtr);
    if (audioBackendPtr != nullptr) calloc.free(audioBackendPtr);
  }
}
