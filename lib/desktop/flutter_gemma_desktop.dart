import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../flutter_gemma_interface.dart';
import '../model_file_manager_interface.dart';
import '../pigeon.g.dart';
import '../core/message.dart';
import '../core/model.dart';
import '../core/tool.dart';
import '../core/chat.dart';
import '../core/extensions.dart';
import '../core/model_management/constants/preferences_keys.dart';

import 'litertlm_native_client.dart';
import 'sentencepiece_tokenizer.dart';

// Import model management types from mobile (reuse for desktop)
// EmbeddingModelSpec is a `part of` flutter_gemma_mobile.dart,
// so it must be exported from there.
import '../mobile/flutter_gemma_mobile.dart'
    show
        InferenceModelSpec,
        EmbeddingModelSpec,
        MobileModelManager;

part 'desktop_inference_model.dart';
part 'desktop_embedding_model.dart';

/// Desktop implementation of FlutterGemma plugin
///
/// Uses native FFI to communicate directly with LiteRT-LM's C API.
/// No Java, no gRPC, no server process — just dart:ffi to native code.
class FlutterGemmaDesktop extends FlutterGemmaPlugin {
  FlutterGemmaDesktop._();

  static FlutterGemmaDesktop? _instance;

  /// Get the singleton instance
  static FlutterGemmaDesktop get instance => _instance ??= FlutterGemmaDesktop._();

  /// Register this implementation as the plugin instance
  ///
  /// This is called automatically by Flutter for dartPluginClass.
  /// No parameters needed for desktop platforms.
  static void registerWith() {
    FlutterGemmaPlugin.instance = instance;
    debugPrint('[FlutterGemmaDesktop] Plugin registered for desktop platform');
  }

  // Reuse MobileModelManager for desktop (same filesystem behavior)
  late final MobileModelManager _modelManager = MobileModelManager();

  // Inference model singleton
  Completer<InferenceModel>? _initCompleter;
  InferenceModel? _initializedModel;
  InferenceModelSpec? _lastActiveInferenceSpec;

  // Embedding model — loaded via tflite_flutter (desktop-specific)
  EmbeddingModel? _initializedEmbeddingModel;
  Completer<EmbeddingModel>? _initEmbeddingCompleter;
  EmbeddingModelSpec? _lastActiveEmbeddingSpec;

  @override
  ModelFileManager get modelManager => _modelManager;

  @override
  InferenceModel? get initializedModel => _initializedModel;

  @override
  EmbeddingModel? get initializedEmbeddingModel => _initializedEmbeddingModel;

  @override
  Future<InferenceModel> createModel({
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
    int maxTokens = 1024,
    PreferredBackend? preferredBackend,
    List<int>? loraRanks,
    int? maxNumImages,
    bool supportImage = false,
    bool supportAudio = false,
  }) async {
    // Check active model
    final activeModel = _modelManager.activeInferenceModel;
    if (activeModel == null) {
      throw StateError(
        'No active inference model set. Use `FlutterGemma.installModel()` or `modelManager.setActiveModel()` first',
      );
    }

    // Check if singleton exists and matches active model + runtime params
    if (_initCompleter != null &&
        _initializedModel != null &&
        _lastActiveInferenceSpec != null) {
      final currentSpec = _lastActiveInferenceSpec!;
      final requestedSpec = activeModel as InferenceModelSpec;
      final currentModel = _initializedModel as DesktopInferenceModel?;

      final modelChanged = currentSpec.name != requestedSpec.name;
      final paramsChanged = currentModel != null &&
          (currentModel.supportImage != supportImage ||
           currentModel.supportAudio != supportAudio ||
           currentModel.maxTokens != maxTokens);

      if (modelChanged || paramsChanged) {
        // Active model or runtime params changed - close old and create new
        debugPrint('Model recreation: modelChanged=$modelChanged, paramsChanged=$paramsChanged');
        await _initializedModel?.close();
        // Explicitly null these out (onClose callback also does this, but be safe)
        _initCompleter = null;
        _initializedModel = null;
        _lastActiveInferenceSpec = null;
      } else {
        // Same model and params - return existing
        debugPrint('Reusing existing model instance for ${requestedSpec.name}');
        return _initCompleter!.future;
      }
    }

    // Return existing completer if initialization in progress (re-check after potential close)
    if (_initCompleter case Completer<InferenceModel> completer) {
      return completer.future;
    }

    final completer = _initCompleter = Completer<InferenceModel>();

    try {
      // Verify model is installed
      final isInstalled = await _modelManager.isModelInstalled(activeModel);
      if (!isInstalled) {
        throw Exception('Active model is no longer installed');
      }

      // Get model file path
      final modelFilePaths = await _modelManager.getModelFilePaths(activeModel);
      if (modelFilePaths == null || modelFilePaths.isEmpty) {
        throw Exception('Model file paths not found');
      }

      final modelPath = modelFilePaths.values.first;
      debugPrint('[FlutterGemmaDesktop] Using model: $modelPath');

      // Create native FFI client and initialize engine directly
      final nativeClient = LiteRtLmNativeClient();

      try {
        await nativeClient.initialize(
          modelPath: modelPath,
          backend: preferredBackend == PreferredBackend.cpu ? 'cpu' : 'gpu',
          maxTokens: maxTokens,
          enableVision: supportImage,
          maxNumImages: supportImage ? (maxNumImages ?? 1) : 0,
          enableAudio: supportAudio,
        );
      } catch (e) {
        // Provide clearer error message for file-related issues
        final errorMsg = e.toString();
        if (errorMsg.contains('FileNotFoundException') ||
            errorMsg.contains('No such file') ||
            errorMsg.contains('not found')) {
          throw Exception('Model file not found or inaccessible: $modelPath');
        }
        rethrow;
      }

      // Create model instance
      final model = _initializedModel = DesktopInferenceModel(
        nativeClient: nativeClient,
        maxTokens: maxTokens,
        modelType: modelType,
        fileType: fileType,
        supportImage: supportImage,
        supportAudio: supportAudio,
        onClose: () {
          _initializedModel = null;
          _initCompleter = null;
          _lastActiveInferenceSpec = null;
        },
      );

      _lastActiveInferenceSpec = activeModel as InferenceModelSpec;

      completer.complete(model);
      return model;
    } catch (e, st) {
      completer.completeError(e, st);
      _initCompleter = null;
      rethrow;
    }
  }

  @override
  Future<EmbeddingModel> createEmbeddingModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
  }) async {
    // -----------------------------------------------------------------
    // Check if the active embedding model changed since last creation
    // -----------------------------------------------------------------
    if (_initEmbeddingCompleter != null &&
        _initializedEmbeddingModel != null &&
        _lastActiveEmbeddingSpec != null) {
      final activeModel = _modelManager.activeEmbeddingModel;
      if (activeModel is EmbeddingModelSpec &&
          _lastActiveEmbeddingSpec!.name != activeModel.name) {
        // Active model changed — close old one and create new
        debugPrint('[FlutterGemmaDesktop] Embedding model changed, recreating');
        await _initializedEmbeddingModel?.close();
        _initEmbeddingCompleter = null;
        _initializedEmbeddingModel = null;
        _lastActiveEmbeddingSpec = null;
      } else {
        // Same model — return existing instance
        debugPrint('[FlutterGemmaDesktop] Reusing existing embedding model');
        return _initEmbeddingCompleter!.future;
      }
    }

    // -----------------------------------------------------------------
    // Modern API: resolve paths from the active EmbeddingModelSpec
    // -----------------------------------------------------------------
    if (modelPath == null || tokenizerPath == null) {
      final activeModel = _modelManager.activeEmbeddingModel;

      if (activeModel == null) {
        throw StateError(
          'No active embedding model set. '
          'Use `FlutterGemma.installEmbedder()` or '
          '`modelManager.setActiveModel()` to set a model first',
        );
      }

      // Get the actual file paths through the unified model manager
      final modelFilePaths =
          await _modelManager.getModelFilePaths(activeModel);
      if (modelFilePaths == null || modelFilePaths.isEmpty) {
        throw StateError(
          'Embedding model file paths not found. '
          'Use the `modelManager` to install the model first',
        );
      }

      // Extract model and tokenizer paths from the spec
      final activeModelPath =
          modelFilePaths[PreferencesKeys.embeddingModelFile];
      final activeTokenizerPath =
          modelFilePaths[PreferencesKeys.embeddingTokenizerFile];

      if (activeModelPath == null || activeTokenizerPath == null) {
        throw StateError(
          'Could not find model or tokenizer path in active embedding model. '
          'Model files: $modelFilePaths',
        );
      }

      modelPath = activeModelPath;
      tokenizerPath = activeTokenizerPath;

      debugPrint('[FlutterGemmaDesktop] Using active embedding model: '
          '$modelPath, tokenizer: $tokenizerPath');
    } else {
      // Legacy API with explicit paths — check if singleton exists
      if (_initEmbeddingCompleter case Completer<EmbeddingModel> completer) {
        debugPrint(
            '[FlutterGemmaDesktop] Reusing existing embedding model (Legacy)');
        return completer.future;
      }
    }

    // Return existing completer if initialization is in progress
    if (_initEmbeddingCompleter != null && _initializedEmbeddingModel != null) {
      return _initEmbeddingCompleter!.future;
    }

    final completer = _initEmbeddingCompleter = Completer<EmbeddingModel>();

    // Verify installation if using Modern API
    final activeModel = _modelManager.activeEmbeddingModel;
    if (activeModel != null) {
      final isInstalled = await _modelManager.isModelInstalled(activeModel);
      if (!isInstalled) {
        completer.completeError(Exception(
          'Active embedding model is no longer installed. '
          'Use the `modelManager` to install the model first',
        ));
        return completer.future;
      }
    }

    try {
      // -----------------------------------------------------------------
      // Create DesktopEmbeddingModel (tflite_flutter + SentencePiece)
      // -----------------------------------------------------------------
      final model =
          _initializedEmbeddingModel = await DesktopEmbeddingModel.create(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preferredBackend: preferredBackend,
        onClose: () {
          _initializedEmbeddingModel = null;
          _initEmbeddingCompleter = null;
          _lastActiveEmbeddingSpec = null;
        },
      );

      // Track which spec was used (Modern API only)
      if (activeModel != null && activeModel is EmbeddingModelSpec) {
        _lastActiveEmbeddingSpec = activeModel;
      }

      completer.complete(model);
      return model;
    } catch (e, st) {
      _initEmbeddingCompleter = null;
      _initializedEmbeddingModel = null;
      _lastActiveEmbeddingSpec = null;
      completer.completeError(e, st);
      Error.throwWithStackTrace(e, st);
    }
  }

  // === RAG Methods (not supported in MVP) ===

  @override
  Future<void> initializeVectorStore(String databasePath) async {
    throw UnsupportedError('VectorStore not yet supported on desktop');
  }

  @override
  Future<void> addDocumentWithEmbedding({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    throw UnsupportedError('VectorStore not yet supported on desktop');
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    String? metadata,
  }) async {
    throw UnsupportedError('VectorStore not yet supported on desktop');
  }

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required String query,
    int topK = 5,
    double threshold = 0.0,
  }) async {
    throw UnsupportedError('VectorStore not yet supported on desktop');
  }

  @override
  Future<VectorStoreStats> getVectorStoreStats() async {
    throw UnsupportedError('VectorStore not yet supported on desktop');
  }

  @override
  Future<void> clearVectorStore() async {
    throw UnsupportedError('VectorStore not yet supported on desktop');
  }
}

/// Check if current platform is desktop
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
