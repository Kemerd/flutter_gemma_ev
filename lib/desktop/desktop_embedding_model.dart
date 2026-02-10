part of 'flutter_gemma_desktop.dart';

// =============================================================================
// Desktop Embedding Model — ONNX Runtime + SentencePiece, Pure Dart
// =============================================================================
// Loads an EmbeddingGemma ONNX model via the onnxruntime package's FFI
// bindings and runs inference using ONNX Runtime's native C++ thread pool.
//
// The mobile platforms use MediaPipe's native TextEmbedder through Pigeon,
// but that native API isn't available on desktop.  This class replicates the
// same functionality using:
//   1. SentencePieceTokenizer  — pure Dart protobuf parser + Viterbi encoder
//   2. onnxruntime              — Dart FFI bindings to the ONNX Runtime C API
//
// Key advantages over the previous TFLite implementation:
//   - Multi-core parallel inference via ortParallel execution mode
//   - Hardware acceleration via DirectML (Windows GPU), CUDA, CoreML, etc.
//   - Non-blocking inference via runOnceAsync() (spawns isolates for FFI calls)
//   - External data file support (.onnx + .onnx_data) for large quantized models
//
// The ONNX model uses two files: model_q4.onnx (graph, ~519KB) and
// model_q4.onnx_data (weights, ~197MB). OrtSession.fromFile() automatically
// resolves the companion data file from the same directory.
// =============================================================================

class DesktopEmbeddingModel extends EmbeddingModel {
  // -------------------------------------------------------------------------
  // Fields
  // -------------------------------------------------------------------------

  /// The ONNX Runtime session — shared across all inference calls.
  /// ONNX Runtime's C++ thread pool handles multi-core distribution internally,
  /// so a single session can serve concurrent requests safely.
  final OrtSession _session;

  /// Session options — must be kept alive for the duration of the session.
  final OrtSessionOptions _sessionOptions;

  /// Run options — reusable across inference calls (stateless).
  final OrtRunOptions _runOptions;

  /// SentencePiece tokenizer — pure Dart, no native dependency.
  final SentencePieceTokenizer _tokenizer;

  /// Maximum input sequence length (detected from model input shape).
  final int _maxSeqLength;

  /// Output embedding dimensionality (detected from model output shape).
  final int _embeddingDim;

  /// Names of the model's input tensors (e.g. ['input_ids', 'attention_mask']).
  final List<String> _inputNames;

  /// Name of the model's output tensor (e.g. 'embeddings').
  final String _outputName;

  /// Callback invoked when the model is closed (clears plugin singleton refs).
  final VoidCallback onClose;

  /// Guard against use-after-close.
  bool _isClosed = false;

  DesktopEmbeddingModel._({
    required OrtSession session,
    required OrtSessionOptions sessionOptions,
    required OrtRunOptions runOptions,
    required SentencePieceTokenizer tokenizer,
    required int maxSeqLength,
    required int embeddingDim,
    required List<String> inputNames,
    required String outputName,
    required this.onClose,
  })  : _session = session,
        _sessionOptions = sessionOptions,
        _runOptions = runOptions,
        _tokenizer = tokenizer,
        _maxSeqLength = maxSeqLength,
        _embeddingDim = embeddingDim,
        _inputNames = inputNames,
        _outputName = outputName;

  // -------------------------------------------------------------------------
  // Factory constructor — loads model + tokenizer, configures ONNX session
  // -------------------------------------------------------------------------

  /// Create a new desktop embedding model from file paths.
  ///
  /// [modelPath]      — path to the .onnx embedding model file
  /// [tokenizerPath]  — path to the sentencepiece.model tokenizer file
  /// [preferredBackend] — CPU or GPU hint (auto-detected via appendDefaultProviders)
  /// [onClose]        — callback when the model is closed
  static Future<DesktopEmbeddingModel> create({
    required String modelPath,
    required String tokenizerPath,
    PreferredBackend? preferredBackend,
    required VoidCallback onClose,
  }) async {
    // -----------------------------------------------------------------
    // Load the SentencePiece tokenizer (pure Dart, no FFI needed)
    // -----------------------------------------------------------------
    debugPrint('[DesktopEmbedding] Loading tokenizer from: $tokenizerPath');
    final tokenizer = await SentencePieceTokenizer.load(tokenizerPath);
    debugPrint('[DesktopEmbedding] Tokenizer loaded — '
        '${tokenizer.vocabSize} pieces');

    // -----------------------------------------------------------------
    // Initialize ONNX Runtime environment (singleton, safe to call multiple
    // times — subsequent calls are no-ops if already initialized)
    // -----------------------------------------------------------------
    OrtEnv.instance.init();
    debugPrint('[DesktopEmbedding] ONNX Runtime v${OrtEnv.version} initialized');

    // -----------------------------------------------------------------
    // Configure session options for maximum throughput
    // -----------------------------------------------------------------
    final sessionOptions = OrtSessionOptions();

    // Let ONNX Runtime use all available CPU cores for both inter-op
    // (parallel operator execution) and intra-op (parallelism within
    // individual operators like matrix multiplications).
    // 0 = "let ONNX Runtime decide" (uses all cores).
    sessionOptions.setInterOpNumThreads(0);
    sessionOptions.setIntraOpNumThreads(0);

    // Enable all graph optimizations (constant folding, node fusion, etc.)
    sessionOptions.setSessionGraphOptimizationLevel(
      GraphOptimizationLevel.ortEnableAll,
    );

    // Parallel execution mode — allows independent operators in the
    // computation graph to run concurrently on the C++ thread pool.
    sessionOptions.setSessionExecutionMode(
      OrtSessionExecutionMode.ortParallel,
    );

    debugPrint('[DesktopEmbedding] Session options configured '
        '(ortParallel, all optimizations, auto threads)');

    // -----------------------------------------------------------------
    // Append hardware acceleration providers (auto-detect best available)
    // -----------------------------------------------------------------
    // This tries DirectML (Windows GPU), CUDA (NVIDIA), CoreML (Apple),
    // NNAPI (Android), etc. in priority order, with CPU as final fallback.
    await sessionOptions.appendDefaultProviders();
    debugPrint('[DesktopEmbedding] Execution providers appended '
        '(auto-detected best available hardware)');

    // -----------------------------------------------------------------
    // Create the ONNX session from file
    // -----------------------------------------------------------------
    // IMPORTANT: We use fromFile() (not fromBuffer) because the ONNX model
    // has external data (model_q4.onnx_data). fromFile() lets the runtime
    // auto-resolve the companion .onnx_data file from the same directory.
    debugPrint('[DesktopEmbedding] Loading ONNX model from: $modelPath');
    final modelFile = File(modelPath);
    if (!modelFile.existsSync()) {
      throw FileSystemException('Model file not found', modelPath);
    }
    debugPrint('[DesktopEmbedding] Model file size: '
        '${modelFile.lengthSync()} bytes');

    final session = OrtSession.fromFile(modelFile, sessionOptions);
    debugPrint('[DesktopEmbedding] OrtSession created successfully');

    // -----------------------------------------------------------------
    // Inspect input/output tensor names and shapes
    // -----------------------------------------------------------------
    final inputNames = session.inputNames;
    final outputNames = session.outputNames;

    debugPrint('[DesktopEmbedding] Input tensors: $inputNames');
    debugPrint('[DesktopEmbedding] Output tensors: $outputNames');

    // Determine sequence length and embedding dimension by running a
    // probe inference with a dummy input. ONNX models with dynamic axes
    // don't expose shapes statically, so we infer them from actual output.
    // We use a sequence length of 256 (EmbeddingGemma's standard) and
    // detect the embedding dimension from the output shape.
    const probeSeqLength = 256;
    final outputName = outputNames.first;

    // Run a quick probe to discover the embedding dimension
    final probeTokens = Int64List(probeSeqLength);
    probeTokens[0] = tokenizer.bosId; // BOS token, rest are zeros (padding)
    final probeInput = OrtValueTensor.createTensorWithDataList(
      probeTokens,
      [1, probeSeqLength],
    );

    // Build probe inputs map — handle models with attention_mask input
    final probeInputs = <String, OrtValue>{};
    probeInputs[inputNames.first] = probeInput;

    // If model expects attention_mask, provide it (1 for BOS, 0 for padding)
    if (inputNames.length >= 2) {
      final attentionMask = Int64List(probeSeqLength);
      attentionMask[0] = 1; // Only BOS token is "real"
      final maskTensor = OrtValueTensor.createTensorWithDataList(
        attentionMask,
        [1, probeSeqLength],
      );
      probeInputs[inputNames[1]] = maskTensor;
    }

    // If model expects token_type_ids, provide all zeros
    if (inputNames.length >= 3) {
      final tokenTypeIds = Int64List(probeSeqLength);
      final typeTensor = OrtValueTensor.createTensorWithDataList(
        tokenTypeIds,
        [1, probeSeqLength],
      );
      probeInputs[inputNames[2]] = typeTensor;
    }

    final runOptions = OrtRunOptions();
    final probeOutputs = session.run(runOptions, probeInputs);

    // Extract embedding dimension from the probe output
    final probeOutput = probeOutputs.first as OrtValueTensor;
    final probeValue = probeOutput.value;
    final probeList = probeValue as List;
    final embeddingDim = probeList.first is List
        ? (probeList.first as List).length
        : probeList.length;

    // Release probe tensors to free native memory
    probeInput.release();
    for (final entry in probeInputs.values) {
      if (entry != probeInput) entry.release();
    }
    for (final output in probeOutputs) {
      output?.release();
    }

    debugPrint('[DesktopEmbedding] Sequence length: $probeSeqLength, '
        'Embedding dim: $embeddingDim');
    debugPrint('[DesktopEmbedding] Model has ${inputNames.length} '
        'input tensor(s)');
    debugPrint('[DesktopEmbedding] Ready — inference will NOT block '
        'the UI thread (runOnceAsync)');

    return DesktopEmbeddingModel._(
      session: session,
      sessionOptions: sessionOptions,
      runOptions: runOptions,
      tokenizer: tokenizer,
      maxSeqLength: probeSeqLength,
      embeddingDim: embeddingDim,
      inputNames: inputNames,
      outputName: outputName,
      onClose: onClose,
    );
  }

  // -------------------------------------------------------------------------
  // Assertion helper
  // -------------------------------------------------------------------------
  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'EmbeddingModel is closed. Create a new instance to use it again',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Build input tensors for a given text
  // -------------------------------------------------------------------------

  /// Tokenizes [text] and creates the ORT input tensor map.
  /// Returns both the map and a list of all created tensors for cleanup.
  ({Map<String, OrtValue> inputs, List<OrtValue> tensors}) _buildInputs(
    String text,
  ) {
    // Tokenize the input text to fixed-length token IDs
    final tokenIds = _tokenizer.encode(text, maxLength: _maxSeqLength);
    final int64TokenIds = Int64List.fromList(tokenIds);

    // Create the primary input tensor (token IDs)
    final inputIdsTensor = OrtValueTensor.createTensorWithDataList(
      int64TokenIds,
      [1, _maxSeqLength],
    );

    final inputs = <String, OrtValue>{};
    final tensors = <OrtValue>[inputIdsTensor];

    // First input is always token IDs
    inputs[_inputNames.first] = inputIdsTensor;

    // Second input: attention mask (1 for real tokens, 0 for padding)
    if (_inputNames.length >= 2) {
      final attentionMask = Int64List(_maxSeqLength);
      for (int i = 0; i < _maxSeqLength; i++) {
        attentionMask[i] = tokenIds[i] != _tokenizer.padId ? 1 : 0;
      }
      final maskTensor = OrtValueTensor.createTensorWithDataList(
        attentionMask,
        [1, _maxSeqLength],
      );
      inputs[_inputNames[1]] = maskTensor;
      tensors.add(maskTensor);
    }

    // Third input: token type IDs (all zeros for single-segment models)
    if (_inputNames.length >= 3) {
      final tokenTypeIds = Int64List(_maxSeqLength);
      final typeTensor = OrtValueTensor.createTensorWithDataList(
        tokenTypeIds,
        [1, _maxSeqLength],
      );
      inputs[_inputNames[2]] = typeTensor;
      tensors.add(typeTensor);
    }

    return (inputs: inputs, tensors: tensors);
  }

  // -------------------------------------------------------------------------
  // EmbeddingModel interface implementation
  // -------------------------------------------------------------------------

  @override
  Future<List<double>> generateEmbedding(String text) async {
    _assertNotClosed();

    // Build input tensors from tokenized text
    final (:inputs, :tensors) = _buildInputs(text);

    try {
      // Run inference on a background isolate via runOnceAsync().
      // This spawns a fresh Dart isolate that calls into the shared native
      // ONNX Runtime session via FFI, keeping the UI thread completely free.
      final outputs = await _session.runOnceAsync(
        _runOptions,
        inputs,
        [_outputName],
      );

      // Extract the float embedding vector from the output tensor
      final outputTensor = outputs.first as OrtValueTensor;
      final rawValue = outputTensor.value;

      // Output shape is typically [1, embeddingDim] — extract the inner list
      final List<double> embedding;
      if (rawValue is List && rawValue.first is List) {
        // Shape [1, N] — take the first (and only) row
        embedding = (rawValue.first as List).cast<double>();
      } else {
        // Shape [N] — flat output
        embedding = (rawValue as List).cast<double>();
      }

      // Release output tensors to free native memory
      for (final output in outputs) {
        output?.release();
      }

      return embedding;
    } finally {
      // Always release input tensors regardless of success/failure
      for (final tensor in tensors) {
        tensor.release();
      }
    }
  }

  @override
  Future<List<List<double>>> generateEmbeddings(List<String> texts) async {
    _assertNotClosed();

    // Fire all inference requests concurrently via Future.wait().
    // Each runOnceAsync() call spawns its own isolate, allowing true parallel
    // inference — ONNX Runtime's C++ thread pool handles the native-level
    // concurrency. This is the same ortParallel pattern used in nihon_dojo's
    // SharedSessionManager.runBatchInference().
    final futures = texts.map((text) => generateEmbedding(text));
    return Future.wait(futures);
  }

  @override
  Future<int> getDimension() async {
    _assertNotClosed();
    return _embeddingDim;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    // Release ONNX Runtime resources in dependency order:
    // 1. Kill all isolates (stops background inference workers)
    // 2. Release the session (frees native model memory)
    // 3. Release options objects (frees native config memory)
    await _session.release();
    _sessionOptions.release();
    _runOptions.release();

    // Notify the plugin singleton that this model is gone
    onClose();

    debugPrint('[DesktopEmbedding] Model closed — all native resources freed');
  }
}
