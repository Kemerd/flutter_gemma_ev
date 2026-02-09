// ============================================================================
// LiteRT-LM Native FFI Bindings
// ============================================================================
//
// Hand-written dart:ffi bindings for the LiteRT-LM C API.
// These map directly to the exported symbols in the native shared library
// (litert_lm.dll / liblitert_lm.so / liblitert_lm.dylib).
//
// Reference: native/litert_lm_engine.h (copied from google-ai-edge/LiteRT-LM)
//
// All opaque pointers are represented as Pointer<Void> since the structs
// are opaque (we never access their fields from Dart).
// ============================================================================

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ============================================================================
// Opaque handle typedefs — keeps the API readable without exposing internals
// ============================================================================

/// Opaque pointer to a LiteRT LM Engine instance
typedef LiteRtLmEngine = Void;

/// Opaque pointer to a LiteRT LM Session instance
typedef LiteRtLmSession = Void;

/// Opaque pointer to a LiteRT LM Responses object
typedef LiteRtLmResponses = Void;

/// Opaque pointer to a LiteRT LM Engine Settings object
typedef LiteRtLmEngineSettings = Void;

/// Opaque pointer to a LiteRT LM Benchmark Info object
typedef LiteRtLmBenchmarkInfo = Void;

/// Opaque pointer to a LiteRT LM Conversation instance
typedef LiteRtLmConversation = Void;

/// Opaque pointer to a LiteRT LM JSON Response object
typedef LiteRtLmJsonResponse = Void;

/// Opaque pointer to a LiteRT LM Session Config object
typedef LiteRtLmSessionConfig = Void;

/// Opaque pointer to a LiteRT LM Conversation Config object
typedef LiteRtLmConversationConfig = Void;

// ============================================================================
// Sampler type enum — mirrors the C enum `Type`
// ============================================================================

/// Sampler type constants matching the C API enum
abstract class SamplerType {
  static const int unspecified = 0;
  static const int topK = 1;
  static const int topP = 2;
  static const int greedy = 3;
}

// ============================================================================
// Input data type enum — mirrors the C enum `InputDataType`
// ============================================================================

/// Input data type constants matching the C API enum
abstract class InputDataType {
  static const int text = 0;
  static const int image = 1;
  static const int audio = 2;
  static const int audioEnd = 3;
}

// ============================================================================
// Struct definitions — these mirror the C structs exactly
// ============================================================================

/// Sampler parameters struct.
/// Layout: { int32 type, int32 top_k, float top_p, float temperature, int32 seed }
final class LiteRtLmSamplerParams extends Struct {
  /// Sampler type (see SamplerType constants)
  @Int32()
  external int type;

  /// Top-K value for sampling
  @Int32()
  external int topK;

  /// Top-P (nucleus) value for sampling
  @Float()
  external double topP;

  /// Temperature for sampling randomness
  @Float()
  external double temperature;

  /// Random seed for reproducibility
  @Int32()
  external int seed;
}

/// Input data struct for multimodal inputs.
/// Layout: { int32 type, pointer data, size_t size }
final class InputData extends Struct {
  /// Type of input (see InputDataType constants)
  @Int32()
  external int type;

  /// Pointer to the actual data (text string, image bytes, audio bytes)
  external Pointer<Void> data;

  /// Size of the data in bytes
  @Size()
  external int size;
}

// ============================================================================
// Stream callback type definition
// ============================================================================

/// Native callback signature for streaming responses.
/// void callback(void* callback_data, const char* chunk, bool is_final, const char* error_msg)
typedef LiteRtLmStreamCallbackNative = Void Function(
  Pointer<Void> callbackData,
  Pointer<Utf8> chunk,
  Bool isFinal,
  Pointer<Utf8> errorMsg,
);

/// Dart-side function pointer type for the stream callback
typedef LiteRtLmStreamCallbackPtr
    = Pointer<NativeFunction<LiteRtLmStreamCallbackNative>>;

// ============================================================================
// Native function typedefs (C signatures)
// ============================================================================

// --- Logging ---
typedef _SetMinLogLevelNative = Void Function(Int32 level);
typedef SetMinLogLevel = void Function(int level);

// --- Engine Settings ---
typedef _EngineSettingsCreateNative = Pointer<LiteRtLmEngineSettings> Function(
  Pointer<Utf8> modelPath,
  Pointer<Utf8> backendStr,
  Pointer<Utf8> visionBackendStr,
  Pointer<Utf8> audioBackendStr,
);
typedef EngineSettingsCreate = Pointer<LiteRtLmEngineSettings> Function(
  Pointer<Utf8> modelPath,
  Pointer<Utf8> backendStr,
  Pointer<Utf8> visionBackendStr,
  Pointer<Utf8> audioBackendStr,
);

typedef _EngineSettingsDeleteNative = Void Function(
  Pointer<LiteRtLmEngineSettings> settings,
);
typedef EngineSettingsDelete = void Function(
  Pointer<LiteRtLmEngineSettings> settings,
);

typedef _EngineSettingsSetMaxNumTokensNative = Void Function(
  Pointer<LiteRtLmEngineSettings> settings,
  Int32 maxNumTokens,
);
typedef EngineSettingsSetMaxNumTokens = void Function(
  Pointer<LiteRtLmEngineSettings> settings,
  int maxNumTokens,
);

typedef _EngineSettingsSetCacheDirNative = Void Function(
  Pointer<LiteRtLmEngineSettings> settings,
  Pointer<Utf8> cacheDir,
);
typedef EngineSettingsSetCacheDir = void Function(
  Pointer<LiteRtLmEngineSettings> settings,
  Pointer<Utf8> cacheDir,
);

typedef _EngineSettingsSetActivationDataTypeNative = Void Function(
  Pointer<LiteRtLmEngineSettings> settings,
  Int32 activationDataTypeInt,
);
typedef EngineSettingsSetActivationDataType = void Function(
  Pointer<LiteRtLmEngineSettings> settings,
  int activationDataTypeInt,
);

typedef _EngineSettingsEnableBenchmarkNative = Void Function(
  Pointer<LiteRtLmEngineSettings> settings,
);
typedef EngineSettingsEnableBenchmark = void Function(
  Pointer<LiteRtLmEngineSettings> settings,
);

// --- Engine ---
typedef _EngineCreateNative = Pointer<LiteRtLmEngine> Function(
  Pointer<LiteRtLmEngineSettings> settings,
);
typedef EngineCreate = Pointer<LiteRtLmEngine> Function(
  Pointer<LiteRtLmEngineSettings> settings,
);

typedef _EngineDeleteNative = Void Function(Pointer<LiteRtLmEngine> engine);
typedef EngineDelete = void Function(Pointer<LiteRtLmEngine> engine);

// --- Session Config ---
typedef _SessionConfigCreateNative = Pointer<LiteRtLmSessionConfig> Function();
typedef SessionConfigCreate = Pointer<LiteRtLmSessionConfig> Function();

typedef _SessionConfigSetMaxOutputTokensNative = Void Function(
  Pointer<LiteRtLmSessionConfig> config,
  Int32 maxOutputTokens,
);
typedef SessionConfigSetMaxOutputTokens = void Function(
  Pointer<LiteRtLmSessionConfig> config,
  int maxOutputTokens,
);

typedef _SessionConfigSetSamplerParamsNative = Void Function(
  Pointer<LiteRtLmSessionConfig> config,
  Pointer<LiteRtLmSamplerParams> samplerParams,
);
typedef SessionConfigSetSamplerParams = void Function(
  Pointer<LiteRtLmSessionConfig> config,
  Pointer<LiteRtLmSamplerParams> samplerParams,
);

typedef _SessionConfigDeleteNative = Void Function(
  Pointer<LiteRtLmSessionConfig> config,
);
typedef SessionConfigDelete = void Function(
  Pointer<LiteRtLmSessionConfig> config,
);

// --- Session ---
typedef _EngineCreateSessionNative = Pointer<LiteRtLmSession> Function(
  Pointer<LiteRtLmEngine> engine,
  Pointer<LiteRtLmSessionConfig> config,
);
typedef EngineCreateSession = Pointer<LiteRtLmSession> Function(
  Pointer<LiteRtLmEngine> engine,
  Pointer<LiteRtLmSessionConfig> config,
);

typedef _SessionDeleteNative = Void Function(
  Pointer<LiteRtLmSession> session,
);
typedef SessionDelete = void Function(Pointer<LiteRtLmSession> session);

// --- Content Generation ---
typedef _SessionGenerateContentNative = Pointer<LiteRtLmResponses> Function(
  Pointer<LiteRtLmSession> session,
  Pointer<InputData> inputs,
  Size numInputs,
);
typedef SessionGenerateContent = Pointer<LiteRtLmResponses> Function(
  Pointer<LiteRtLmSession> session,
  Pointer<InputData> inputs,
  int numInputs,
);

typedef _SessionGenerateContentStreamNative = Int32 Function(
  Pointer<LiteRtLmSession> session,
  Pointer<InputData> inputs,
  Size numInputs,
  LiteRtLmStreamCallbackPtr callback,
  Pointer<Void> callbackData,
);
typedef SessionGenerateContentStream = int Function(
  Pointer<LiteRtLmSession> session,
  Pointer<InputData> inputs,
  int numInputs,
  LiteRtLmStreamCallbackPtr callback,
  Pointer<Void> callbackData,
);

// --- Responses ---
typedef _ResponsesDeleteNative = Void Function(
  Pointer<LiteRtLmResponses> responses,
);
typedef ResponsesDelete = void Function(
  Pointer<LiteRtLmResponses> responses,
);

typedef _ResponsesGetNumCandidatesNative = Int32 Function(
  Pointer<LiteRtLmResponses> responses,
);
typedef ResponsesGetNumCandidates = int Function(
  Pointer<LiteRtLmResponses> responses,
);

typedef _ResponsesGetResponseTextAtNative = Pointer<Utf8> Function(
  Pointer<LiteRtLmResponses> responses,
  Int32 index,
);
typedef ResponsesGetResponseTextAt = Pointer<Utf8> Function(
  Pointer<LiteRtLmResponses> responses,
  int index,
);

// --- Conversation Config ---
typedef _ConversationConfigCreateNative
    = Pointer<LiteRtLmConversationConfig> Function(
  Pointer<LiteRtLmEngine> engine,
  Pointer<LiteRtLmSessionConfig> sessionConfig,
  Pointer<Utf8> systemMessageJson,
  Pointer<Utf8> toolsJson,
  Pointer<Utf8> messagesJson,
  Bool enableConstrainedDecoding,
);
typedef ConversationConfigCreate
    = Pointer<LiteRtLmConversationConfig> Function(
  Pointer<LiteRtLmEngine> engine,
  Pointer<LiteRtLmSessionConfig> sessionConfig,
  Pointer<Utf8> systemMessageJson,
  Pointer<Utf8> toolsJson,
  Pointer<Utf8> messagesJson,
  bool enableConstrainedDecoding,
);

typedef _ConversationConfigDeleteNative = Void Function(
  Pointer<LiteRtLmConversationConfig> config,
);
typedef ConversationConfigDelete = void Function(
  Pointer<LiteRtLmConversationConfig> config,
);

// --- Conversation ---
typedef _ConversationCreateNative = Pointer<LiteRtLmConversation> Function(
  Pointer<LiteRtLmEngine> engine,
  Pointer<LiteRtLmConversationConfig> config,
);
typedef ConversationCreate = Pointer<LiteRtLmConversation> Function(
  Pointer<LiteRtLmEngine> engine,
  Pointer<LiteRtLmConversationConfig> config,
);

typedef _ConversationDeleteNative = Void Function(
  Pointer<LiteRtLmConversation> conversation,
);
typedef ConversationDelete = void Function(
  Pointer<LiteRtLmConversation> conversation,
);

typedef _ConversationSendMessageNative = Pointer<LiteRtLmJsonResponse> Function(
  Pointer<LiteRtLmConversation> conversation,
  Pointer<Utf8> messageJson,
);
typedef ConversationSendMessage = Pointer<LiteRtLmJsonResponse> Function(
  Pointer<LiteRtLmConversation> conversation,
  Pointer<Utf8> messageJson,
);

typedef _ConversationSendMessageStreamNative = Int32 Function(
  Pointer<LiteRtLmConversation> conversation,
  Pointer<Utf8> messageJson,
  LiteRtLmStreamCallbackPtr callback,
  Pointer<Void> callbackData,
);
typedef ConversationSendMessageStream = int Function(
  Pointer<LiteRtLmConversation> conversation,
  Pointer<Utf8> messageJson,
  LiteRtLmStreamCallbackPtr callback,
  Pointer<Void> callbackData,
);

typedef _ConversationCancelProcessNative = Void Function(
  Pointer<LiteRtLmConversation> conversation,
);
typedef ConversationCancelProcess = void Function(
  Pointer<LiteRtLmConversation> conversation,
);

// --- JSON Response ---
typedef _JsonResponseDeleteNative = Void Function(
  Pointer<LiteRtLmJsonResponse> response,
);
typedef JsonResponseDelete = void Function(
  Pointer<LiteRtLmJsonResponse> response,
);

typedef _JsonResponseGetStringNative = Pointer<Utf8> Function(
  Pointer<LiteRtLmJsonResponse> response,
);
typedef JsonResponseGetString = Pointer<Utf8> Function(
  Pointer<LiteRtLmJsonResponse> response,
);

// --- Benchmark Info ---
typedef _BenchmarkInfoDeleteNative = Void Function(
  Pointer<LiteRtLmBenchmarkInfo> benchmarkInfo,
);
typedef BenchmarkInfoDelete = void Function(
  Pointer<LiteRtLmBenchmarkInfo> benchmarkInfo,
);

typedef _SessionGetBenchmarkInfoNative
    = Pointer<LiteRtLmBenchmarkInfo> Function(
  Pointer<LiteRtLmSession> session,
);
typedef SessionGetBenchmarkInfo = Pointer<LiteRtLmBenchmarkInfo> Function(
  Pointer<LiteRtLmSession> session,
);

typedef _ConversationGetBenchmarkInfoNative
    = Pointer<LiteRtLmBenchmarkInfo> Function(
  Pointer<LiteRtLmConversation> conversation,
);
typedef ConversationGetBenchmarkInfo = Pointer<LiteRtLmBenchmarkInfo> Function(
  Pointer<LiteRtLmConversation> conversation,
);

typedef _BenchmarkInfoGetTimeToFirstTokenNative = Double Function(
  Pointer<LiteRtLmBenchmarkInfo> benchmarkInfo,
);
typedef BenchmarkInfoGetTimeToFirstToken = double Function(
  Pointer<LiteRtLmBenchmarkInfo> benchmarkInfo,
);

// ============================================================================
// LiteRtLmBindings — loads the shared library and resolves all symbols
// ============================================================================

/// Resolved FFI bindings for the LiteRT-LM native C API.
///
/// Call [LiteRtLmBindings.open] to load the shared library and resolve
/// all function pointers. This class holds every symbol needed to drive
/// the engine, sessions, conversations, and streaming from Dart.
class LiteRtLmBindings {
  LiteRtLmBindings._(this._lib);

  final DynamicLibrary _lib;

  /// Load the native LiteRT-LM shared library and resolve all symbols.
  ///
  /// [libraryPath] is the full path to the .dll / .so / .dylib file.
  factory LiteRtLmBindings.open(String libraryPath) {
    final lib = DynamicLibrary.open(libraryPath);
    return LiteRtLmBindings._(lib).._resolveAll();
  }

  // ======================== Resolved function pointers ========================

  // --- Logging ---
  late final SetMinLogLevel setMinLogLevel;

  // --- Engine Settings ---
  late final EngineSettingsCreate engineSettingsCreate;
  late final EngineSettingsDelete engineSettingsDelete;
  late final EngineSettingsSetMaxNumTokens engineSettingsSetMaxNumTokens;
  late final EngineSettingsSetCacheDir engineSettingsSetCacheDir;
  late final EngineSettingsSetActivationDataType
      engineSettingsSetActivationDataType;
  late final EngineSettingsEnableBenchmark engineSettingsEnableBenchmark;

  // --- Engine ---
  late final EngineCreate engineCreate;
  late final EngineDelete engineDelete;

  // --- Session Config ---
  late final SessionConfigCreate sessionConfigCreate;
  late final SessionConfigSetMaxOutputTokens sessionConfigSetMaxOutputTokens;
  late final SessionConfigSetSamplerParams sessionConfigSetSamplerParams;
  late final SessionConfigDelete sessionConfigDelete;

  // --- Session ---
  late final EngineCreateSession engineCreateSession;
  late final SessionDelete sessionDelete;

  // --- Content Generation ---
  late final SessionGenerateContent sessionGenerateContent;
  late final SessionGenerateContentStream sessionGenerateContentStream;

  // --- Responses ---
  late final ResponsesDelete responsesDelete;
  late final ResponsesGetNumCandidates responsesGetNumCandidates;
  late final ResponsesGetResponseTextAt responsesGetResponseTextAt;

  // --- Conversation Config ---
  late final ConversationConfigCreate conversationConfigCreate;
  late final ConversationConfigDelete conversationConfigDelete;

  // --- Conversation ---
  late final ConversationCreate conversationCreate;
  late final ConversationDelete conversationDelete;
  late final ConversationSendMessage conversationSendMessage;
  late final ConversationSendMessageStream conversationSendMessageStream;
  late final ConversationCancelProcess conversationCancelProcess;

  // --- JSON Response ---
  late final JsonResponseDelete jsonResponseDelete;
  late final JsonResponseGetString jsonResponseGetString;

  // --- Benchmark Info ---
  late final BenchmarkInfoDelete benchmarkInfoDelete;
  late final SessionGetBenchmarkInfo sessionGetBenchmarkInfo;
  late final ConversationGetBenchmarkInfo conversationGetBenchmarkInfo;
  late final BenchmarkInfoGetTimeToFirstToken benchmarkInfoGetTimeToFirstToken;

  // ======================== Symbol resolution ========================

  /// Resolve every exported symbol from the loaded shared library.
  /// Called once during construction.
  void _resolveAll() {
    // --- Logging ---
    setMinLogLevel = _lib.lookupFunction<_SetMinLogLevelNative, SetMinLogLevel>(
      'litert_lm_set_min_log_level',
    );

    // --- Engine Settings ---
    engineSettingsCreate =
        _lib.lookupFunction<_EngineSettingsCreateNative, EngineSettingsCreate>(
      'litert_lm_engine_settings_create',
    );
    engineSettingsDelete =
        _lib.lookupFunction<_EngineSettingsDeleteNative, EngineSettingsDelete>(
      'litert_lm_engine_settings_delete',
    );
    engineSettingsSetMaxNumTokens = _lib.lookupFunction<
        _EngineSettingsSetMaxNumTokensNative, EngineSettingsSetMaxNumTokens>(
      'litert_lm_engine_settings_set_max_num_tokens',
    );
    engineSettingsSetCacheDir = _lib.lookupFunction<
        _EngineSettingsSetCacheDirNative, EngineSettingsSetCacheDir>(
      'litert_lm_engine_settings_set_cache_dir',
    );
    engineSettingsSetActivationDataType = _lib.lookupFunction<
        _EngineSettingsSetActivationDataTypeNative,
        EngineSettingsSetActivationDataType>(
      'litert_lm_engine_settings_set_activation_data_type',
    );
    engineSettingsEnableBenchmark = _lib.lookupFunction<
        _EngineSettingsEnableBenchmarkNative, EngineSettingsEnableBenchmark>(
      'litert_lm_engine_settings_enable_benchmark',
    );

    // --- Engine ---
    engineCreate =
        _lib.lookupFunction<_EngineCreateNative, EngineCreate>(
      'litert_lm_engine_create',
    );
    engineDelete =
        _lib.lookupFunction<_EngineDeleteNative, EngineDelete>(
      'litert_lm_engine_delete',
    );

    // --- Session Config ---
    sessionConfigCreate =
        _lib.lookupFunction<_SessionConfigCreateNative, SessionConfigCreate>(
      'litert_lm_session_config_create',
    );
    sessionConfigSetMaxOutputTokens = _lib.lookupFunction<
        _SessionConfigSetMaxOutputTokensNative,
        SessionConfigSetMaxOutputTokens>(
      'litert_lm_session_config_set_max_output_tokens',
    );
    sessionConfigSetSamplerParams = _lib.lookupFunction<
        _SessionConfigSetSamplerParamsNative, SessionConfigSetSamplerParams>(
      'litert_lm_session_config_set_sampler_params',
    );
    sessionConfigDelete =
        _lib.lookupFunction<_SessionConfigDeleteNative, SessionConfigDelete>(
      'litert_lm_session_config_delete',
    );

    // --- Session ---
    engineCreateSession =
        _lib.lookupFunction<_EngineCreateSessionNative, EngineCreateSession>(
      'litert_lm_engine_create_session',
    );
    sessionDelete =
        _lib.lookupFunction<_SessionDeleteNative, SessionDelete>(
      'litert_lm_session_delete',
    );

    // --- Content Generation ---
    sessionGenerateContent = _lib.lookupFunction<
        _SessionGenerateContentNative, SessionGenerateContent>(
      'litert_lm_session_generate_content',
    );
    sessionGenerateContentStream = _lib.lookupFunction<
        _SessionGenerateContentStreamNative, SessionGenerateContentStream>(
      'litert_lm_session_generate_content_stream',
    );

    // --- Responses ---
    responsesDelete =
        _lib.lookupFunction<_ResponsesDeleteNative, ResponsesDelete>(
      'litert_lm_responses_delete',
    );
    responsesGetNumCandidates = _lib.lookupFunction<
        _ResponsesGetNumCandidatesNative, ResponsesGetNumCandidates>(
      'litert_lm_responses_get_num_candidates',
    );
    responsesGetResponseTextAt = _lib.lookupFunction<
        _ResponsesGetResponseTextAtNative, ResponsesGetResponseTextAt>(
      'litert_lm_responses_get_response_text_at',
    );

    // --- Conversation Config ---
    conversationConfigCreate = _lib.lookupFunction<
        _ConversationConfigCreateNative, ConversationConfigCreate>(
      'litert_lm_conversation_config_create',
    );
    conversationConfigDelete = _lib.lookupFunction<
        _ConversationConfigDeleteNative, ConversationConfigDelete>(
      'litert_lm_conversation_config_delete',
    );

    // --- Conversation ---
    conversationCreate =
        _lib.lookupFunction<_ConversationCreateNative, ConversationCreate>(
      'litert_lm_conversation_create',
    );
    conversationDelete =
        _lib.lookupFunction<_ConversationDeleteNative, ConversationDelete>(
      'litert_lm_conversation_delete',
    );
    conversationSendMessage = _lib.lookupFunction<
        _ConversationSendMessageNative, ConversationSendMessage>(
      'litert_lm_conversation_send_message',
    );
    conversationSendMessageStream = _lib.lookupFunction<
        _ConversationSendMessageStreamNative, ConversationSendMessageStream>(
      'litert_lm_conversation_send_message_stream',
    );
    conversationCancelProcess = _lib.lookupFunction<
        _ConversationCancelProcessNative, ConversationCancelProcess>(
      'litert_lm_conversation_cancel_process',
    );

    // --- JSON Response ---
    jsonResponseDelete =
        _lib.lookupFunction<_JsonResponseDeleteNative, JsonResponseDelete>(
      'litert_lm_json_response_delete',
    );
    jsonResponseGetString =
        _lib.lookupFunction<_JsonResponseGetStringNative, JsonResponseGetString>(
      'litert_lm_json_response_get_string',
    );

    // --- Benchmark Info ---
    benchmarkInfoDelete =
        _lib.lookupFunction<_BenchmarkInfoDeleteNative, BenchmarkInfoDelete>(
      'litert_lm_benchmark_info_delete',
    );
    sessionGetBenchmarkInfo = _lib.lookupFunction<
        _SessionGetBenchmarkInfoNative, SessionGetBenchmarkInfo>(
      'litert_lm_session_get_benchmark_info',
    );
    conversationGetBenchmarkInfo = _lib.lookupFunction<
        _ConversationGetBenchmarkInfoNative, ConversationGetBenchmarkInfo>(
      'litert_lm_conversation_get_benchmark_info',
    );
    benchmarkInfoGetTimeToFirstToken = _lib.lookupFunction<
        _BenchmarkInfoGetTimeToFirstTokenNative,
        BenchmarkInfoGetTimeToFirstToken>(
      'litert_lm_benchmark_info_get_time_to_first_token',
    );
  }
}
