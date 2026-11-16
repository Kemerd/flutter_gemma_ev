part of 'flutter_gemma_desktop.dart';

// =============================================================================
// ONNX Embedding Model — ONNX Runtime + SentencePiece, Pure Dart
// =============================================================================
// Loads an EmbeddingGemma ONNX model via the onnxruntime package's FFI
// bindings and runs inference using ONNX Runtime's native C++ thread pool.
//
// Born on desktop (hence the name), now shared with iOS: nothing in here is
// desktop-bound. The fork's loader resolves the ONNX Runtime C API from
// libonnxruntime.dylib/.dll/.so on desktop and from the app executable
// (DynamicLibrary.process(), statically linked onnxruntime-c pod) on iOS.
//
// Built from:
//   1. SentencePieceTokenizer  — pure Dart protobuf parser + Viterbi encoder
//   2. onnxruntime              — Dart FFI bindings to the ONNX Runtime C API
//
// What it buys over the native TFLite path:
//   - Multi-core parallel inference via ortParallel execution mode
//   - Hardware acceleration: CoreML (Apple Neural Engine / GPU) on iOS and
//     macOS, DirectML / CUDA on Windows — unsupported ops (e.g. the Q4
//     MatMulNBits kernels) fall back to ONNX Runtime's optimized CPU EP
//   - Non-blocking inference via runOnceAsync() (spawns isolates for FFI calls)
//   - Session build + warm-up on a helper isolate, so CoreML partition
//     compiles never freeze the UI (on iOS the UI isolate IS the main thread)
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
  ///
  /// Built on a helper isolate and adopted here by native address. Its
  /// session options were released on that isolate right after creation —
  /// ONNX Runtime copies everything it needs into the session.
  final OrtSession _session;

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

  // -------------------------------------------------------------------------
  // Run-slot limiter
  // -------------------------------------------------------------------------
  // Every in-flight Run() allocates its own activation buffers from the ORT
  // arena, so peak memory scales with concurrency. Desktop has RAM to spare
  // and stays unbounded (null). Phones get a small cap so a 16-chunk indexing
  // burst can't balloon the arena into jetsam territory.

  /// Max simultaneous Run() calls, or null for no limit.
  final int? _maxConcurrentRuns;

  /// Run() calls currently holding a slot.
  int _activeRuns = 0;

  /// Callers parked until a slot frees up (FIFO, so order is preserved).
  final Queue<Completer<void>> _runWaiters = Queue<Completer<void>>();

  /// Completed once the last in-flight run lets go — close() waits on it so
  /// the native session is never freed under a running inference.
  Completer<void>? _drained;

  DesktopEmbeddingModel._({
    required OrtSession session,
    required OrtRunOptions runOptions,
    required SentencePieceTokenizer tokenizer,
    required int maxSeqLength,
    required int embeddingDim,
    required List<String> inputNames,
    required String outputName,
    required int? maxConcurrentRuns,
    required this.onClose,
  })  : _session = session,
        _runOptions = runOptions,
        _tokenizer = tokenizer,
        _maxSeqLength = maxSeqLength,
        _embeddingDim = embeddingDim,
        _inputNames = inputNames,
        _outputName = outputName,
        _maxConcurrentRuns = maxConcurrentRuns;

  // -------------------------------------------------------------------------
  // Factory constructor — loads model + tokenizer, configures ONNX session
  // -------------------------------------------------------------------------

  /// Create a new desktop embedding model from file paths.
  ///
  /// [modelPath]      — path to the .onnx embedding model file
  /// [tokenizerPath]  — path to the sentencepiece.model tokenizer file
  /// [preferredBackend] — [PreferredBackend.cpu] pins the session to the
  ///                      ONNX Runtime CPU EP; anything else (gpu / null)
  ///                      auto-detects accelerators via appendDefaultProviders
  /// [onClose]        — callback when the model is closed
  static Future<DesktopEmbeddingModel> create({
    required String modelPath,
    required String tokenizerPath,
    PreferredBackend? preferredBackend,
    required VoidCallback onClose,
  }) async {
    // -----------------------------------------------------------------
    // Validate inputs up front — cheap checks beat a cryptic ORT error
    // -----------------------------------------------------------------
    if (modelPath.trim().isEmpty || tokenizerPath.trim().isEmpty) {
      throw ArgumentError(
        'Model and tokenizer paths must be non-empty '
        '(model: "$modelPath", tokenizer: "$tokenizerPath")',
      );
    }
    final modelFile = File(modelPath);
    if (!modelFile.existsSync()) {
      throw FileSystemException('Model file not found', modelPath);
    }
    debugPrint('[DesktopEmbedding] Loading ONNX model from: $modelPath '
        '(${modelFile.lengthSync()} bytes)');

    // Companion .onnx_data must sit next to the graph for ONNX Runtime to
    // resolve the external weights. Missing is only a warning: small models
    // can embed their weights in the .onnx itself.
    final dataFile = File('${modelPath}_data');
    if (dataFile.existsSync()) {
      debugPrint('[DesktopEmbedding] Companion data file found: '
          '${dataFile.path} '
          '(${(dataFile.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB)');
    } else {
      debugPrint('[DesktopEmbedding] WARNING: No companion data file at: '
          '${dataFile.path} — model may fail if it references external data');
    }

    // -----------------------------------------------------------------
    // Load the SentencePiece tokenizer (pure Dart, no FFI needed).
    // Parsing ~262k vocab pieces is real work, so it happens on a helper
    // isolate; Isolate.exit hands the finished object back without a copy.
    // -----------------------------------------------------------------
    debugPrint('[DesktopEmbedding] Loading tokenizer from: $tokenizerPath');
    final tokenizer = await _loadTokenizer(tokenizerPath);
    debugPrint('[DesktopEmbedding] Tokenizer loaded — '
        '${tokenizer.vocabSize} pieces');

    // -----------------------------------------------------------------
    // Initialize ONNX Runtime environment on this (UI) isolate. ORT keeps
    // one native env per process, so the loader isolate below attaches to
    // this very same env — tensors and run options made here stay valid.
    // -----------------------------------------------------------------
    OrtEnv.instance.init();
    debugPrint('[DesktopEmbedding] ONNX Runtime v${OrtEnv.version} initialized');

    // -----------------------------------------------------------------
    // Platform tuning
    // -----------------------------------------------------------------
    // Desktop: every core, exactly as before (0 = let ONNX Runtime decide),
    // and no cap on concurrent runs.
    //
    // Mobile: phones pair a couple of performance cores with a cluster of
    // efficiency cores. "All cores" drags the slow cluster into every matmul
    // and keeps spin-waiting threads hot, which costs battery and thermals.
    // Half the cores (clamped to 2..4) keeps the P-cores fed, leaves room
    // for the UI, and two concurrent runs keep peak arena memory bounded.
    final isMobile = Platform.isIOS || Platform.isAndroid;
    final intraOpThreads =
        isMobile ? (Platform.numberOfProcessors ~/ 2).clamp(2, 4) : 0;
    final interOpThreads = isMobile ? 2 : 0;
    final int? maxConcurrentRuns = isMobile ? 2 : null;

    // CPU hint = skip accelerator probing entirely. Default (gpu / null)
    // keeps the auto-detect path: CoreML on Apple, DirectML / CUDA on PC.
    final useAccelerators = preferredBackend != PreferredBackend.cpu;

    debugPrint('[DesktopEmbedding] Session config: ortParallel, all '
        'optimizations, intra=$intraOpThreads inter=$interOpThreads '
        '(0 = auto), accelerators=$useAccelerators, '
        'maxConcurrentRuns=${maxConcurrentRuns ?? 'unbounded'}');

    // -----------------------------------------------------------------
    // Build session + warm-up probe on a helper isolate
    // -----------------------------------------------------------------
    // OrtSession.fromFile() and the first Run() are synchronous FFI calls:
    // they read ~200 MB of weights, run graph optimization, and (with
    // CoreML) compile every accelerated partition. Doing that here would
    // freeze the UI — and on iOS the UI isolate is the platform main thread.
    const probeSeqLength = 256;
    final stopwatch = Stopwatch()..start();
    final loaded = await _loadSession(
      modelPath: modelPath,
      useAccelerators: useAccelerators,
      intraOpThreads: intraOpThreads,
      interOpThreads: interOpThreads,
      bosId: tokenizer.bosId,
      probeSeqLength: probeSeqLength,
    );
    debugPrint('[DesktopEmbedding] Session built + warmed up off the UI '
        'thread in ${stopwatch.elapsedMilliseconds} ms');

    // Adopt the native session by address (no copy, same process memory)
    final session = OrtSession.fromAddress(loaded.sessionAddress);
    final inputNames = session.inputNames;

    debugPrint('[DesktopEmbedding] Input tensors: $inputNames');
    debugPrint('[DesktopEmbedding] Output tensors: ${session.outputNames}');
    debugPrint('[DesktopEmbedding] Using output tensor: '
        '"${loaded.outputName}"');
    debugPrint('[DesktopEmbedding] Sequence length: $probeSeqLength, '
        'Embedding dim: ${loaded.embeddingDim}');
    debugPrint('[DesktopEmbedding] Ready — inference will NOT block '
        'the UI thread (runOnceAsync)');

    return DesktopEmbeddingModel._(
      session: session,
      runOptions: OrtRunOptions(),
      tokenizer: tokenizer,
      maxSeqLength: probeSeqLength,
      embeddingDim: loaded.embeddingDim,
      inputNames: inputNames,
      outputName: loaded.outputName,
      maxConcurrentRuns: maxConcurrentRuns,
      onClose: onClose,
    );
  }

  // -------------------------------------------------------------------------
  // Helper-isolate loaders
  // -------------------------------------------------------------------------

  /// Parses the SentencePiece model on a helper isolate.
  ///
  /// Static with a single String parameter so the [Isolate.run] closure
  /// captures nothing but the path.
  static Future<SentencePieceTokenizer> _loadTokenizer(String tokenizerPath) {
    return Isolate.run(
      () => SentencePieceTokenizer.load(tokenizerPath),
      debugName: 'SentencePieceLoader',
    );
  }

  /// Creates the ONNX session and runs one probe inference on a helper
  /// isolate, handing back only plain values (native address + metadata).
  ///
  /// Kept static with primitive parameters on purpose: the closure passed
  /// to [Isolate.run] must not capture anything that can't cross isolates.
  /// No finalizers are attached to ORT handles in the onnxruntime fork, so
  /// the session survives this isolate exiting; the UI isolate owns it from
  /// here on and frees it in [close].
  static Future<({int sessionAddress, String outputName, int embeddingDim})>
      _loadSession({
    required String modelPath,
    required bool useAccelerators,
    required int intraOpThreads,
    required int interOpThreads,
    required int bosId,
    required int probeSeqLength,
  }) {
    return Isolate.run(() async {
      // Attaches to the process-wide native env the UI isolate created
      OrtEnv.instance.init();

      final sessionOptions = OrtSessionOptions();
      final runOptions = OrtRunOptions();
      OrtSession? session;

      try {
        // ---------------------------------------------------------------
        // Configure session options for maximum throughput
        // ---------------------------------------------------------------
        // Inter-op: parallel operator execution. Intra-op: parallelism
        // within a single operator (e.g. a big matmul). 0 = all cores.
        sessionOptions.setInterOpNumThreads(interOpThreads);
        sessionOptions.setIntraOpNumThreads(intraOpThreads);

        // Enable all graph optimizations (constant folding, node fusion, etc.)
        sessionOptions.setSessionGraphOptimizationLevel(
          GraphOptimizationLevel.ortEnableAll,
        );

        // Parallel execution mode — independent operators in the graph
        // (e.g. the Q/K/V projections) run concurrently on the pool.
        sessionOptions.setSessionExecutionMode(
          OrtSessionExecutionMode.ortParallel,
        );

        // ---------------------------------------------------------------
        // Append hardware acceleration providers (auto-detect best)
        // ---------------------------------------------------------------
        // Tries CoreML (Apple), NNAPI, CUDA, DirectML, ... then XNNPACK,
        // with the CPU EP always last. Providers a build doesn't ship are
        // skipped inside. Any leftover failure (e.g. a stripped symbol on
        // a static iOS link) must never cost us the model: ONNX Runtime
        // always registers its CPU EP implicitly, so we log and carry on.
        if (useAccelerators) {
          try {
            await sessionOptions.appendDefaultProviders();
            debugPrint('[DesktopEmbedding] Execution providers appended '
                '(auto-detected best available hardware)');
          } catch (e) {
            debugPrint('[DesktopEmbedding] Accelerator setup incomplete, '
                'continuing with CPU fallback: $e');
          }
        }

        // ---------------------------------------------------------------
        // Create the ONNX session from file
        // ---------------------------------------------------------------
        // fromFile() (not fromBuffer) so ONNX Runtime can resolve the
        // external .onnx_data weights from the same directory.
        session = OrtSession.fromFile(File(modelPath), sessionOptions);
        final inputNames = session.inputNames;
        final outputNames = session.outputNames;
        if (inputNames.isEmpty || outputNames.isEmpty) {
          throw StateError('ONNX model exposes no inputs/outputs: '
              'inputs=$inputNames outputs=$outputNames');
        }

        // Determine which output tensor to use for the embedding vector.
        // EmbeddingGemma ONNX has two outputs:
        //   - "last_hidden_state"   [1, seq_len, 768] — full transformer output
        //   - "sentence_embedding"  [1, 768]           — pooled embedding (wanted)
        // Prefer "sentence_embedding"; fall back to the first output.
        const preferredOutputName = 'sentence_embedding';
        final outputName = outputNames.contains(preferredOutputName)
            ? preferredOutputName
            : outputNames.first;

        // ---------------------------------------------------------------
        // Probe inference: discovers the embedding dimension (dynamic axes
        // hide it statically) and pays the first-run warm-up cost here
        // instead of on the user's first search.
        // ---------------------------------------------------------------
        final probeTensors = <OrtValue>[];
        final probeInputs = <String, OrtValue>{};
        List<OrtValue?> probeOutputs = const <OrtValue?>[];
        try {
          // Token IDs: BOS then zero padding
          final probeTokens = Int64List(probeSeqLength);
          probeTokens[0] = bosId;
          final idsTensor = OrtValueTensor.createTensorWithDataList(
            probeTokens,
            [1, probeSeqLength],
          );
          probeTensors.add(idsTensor);
          probeInputs[inputNames.first] = idsTensor;

          // Attention mask (1 for BOS, 0 for padding) when the model wants it
          if (inputNames.length >= 2) {
            final attentionMask = Int64List(probeSeqLength);
            attentionMask[0] = 1;
            final maskTensor = OrtValueTensor.createTensorWithDataList(
              attentionMask,
              [1, probeSeqLength],
            );
            probeTensors.add(maskTensor);
            probeInputs[inputNames[1]] = maskTensor;
          }

          // Token type IDs (all zeros) for three-input models
          if (inputNames.length >= 3) {
            final typeTensor = OrtValueTensor.createTensorWithDataList(
              Int64List(probeSeqLength),
              [1, probeSeqLength],
            );
            probeTensors.add(typeTensor);
            probeInputs[inputNames[2]] = typeTensor;
          }

          // Only request our chosen output tensor (not all of them)
          probeOutputs = session.run(runOptions, probeInputs, [outputName]);
          if (probeOutputs.isEmpty || probeOutputs.first == null) {
            throw StateError('Probe inference returned no output tensor');
          }

          // Walk into nested lists to find the innermost dimension.
          // Shape is [1, embeddingDim] for sentence_embedding.
          dynamic inner = (probeOutputs.first as OrtValueTensor).value;
          while (inner is List && inner.isNotEmpty && inner.first is List) {
            inner = inner.first;
          }
          final embeddingDim = (inner is List) ? inner.length : 0;
          if (embeddingDim <= 0) {
            throw StateError('Probe inference produced an empty embedding');
          }

          return (
            sessionAddress: session.address,
            outputName: outputName,
            embeddingDim: embeddingDim,
          );
        } finally {
          // Probe tensors are native memory — always free them
          for (final tensor in probeTensors) {
            tensor.release();
          }
          for (final output in probeOutputs) {
            output?.release();
          }
        }
      } catch (_) {
        // Never leak a half-initialized ~200 MB session
        await session?.release();
        rethrow;
      } finally {
        // ONNX Runtime copied what it needs into the session; options and
        // the probe's run options can go right away.
        sessionOptions.release();
        runOptions.release();
      }
    }, debugName: 'OnnxEmbeddingLoader');
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

    // Wait for a run slot (instant on desktop, capped on mobile)
    await _acquireRunSlot();
    try {
      // The model may have been closed while we were parked in the queue
      _assertNotClosed();
      return await _runInference(text);
    } finally {
      _releaseRunSlot();
    }
  }

  /// One tokenize → Run() → unwrap round trip. Caller holds a run slot.
  Future<List<double>> _runInference(String text) async {
    // Build input tensors from tokenized text
    final (:inputs, :tensors) = _buildInputs(text);
    List<OrtValue?> outputs = const <OrtValue?>[];

    try {
      // Run inference on a background isolate via runOnceAsync().
      // This spawns a fresh Dart isolate that calls into the shared native
      // ONNX Runtime session via FFI, keeping the UI thread completely free.
      outputs = await _session.runOnceAsync(
        _runOptions,
        inputs,
        [_outputName],
      );
      if (outputs.isEmpty || outputs.first == null) {
        throw StateError('ONNX inference returned no output tensor');
      }

      // Extract the float embedding vector from the output tensor.
      // The ONNX output is typically nested: [1, embeddingDim] comes back
      // as List<List<num>>. We need to unwrap to a flat List<double>.
      final outputTensor = outputs.first as OrtValueTensor;
      final rawValue = outputTensor.value;

      // Walk into nested lists until we reach the innermost vector.
      // sentence_embedding shape [1, 768] → [[0.1, 0.2, ...]]
      // We want the inner [0.1, 0.2, ...] as List<double>.
      dynamic inner = rawValue;
      while (inner is List && inner.isNotEmpty && inner.first is List) {
        inner = inner.first;
      }

      // Convert from List<num> (which ONNX returns) to List<double>
      if (inner is List) {
        return inner.map<double>((e) => (e as num).toDouble()).toList();
      }
      throw StateError(
        'Unexpected ONNX output shape: ${rawValue.runtimeType}',
      );
    } finally {
      // Always release native tensors regardless of success/failure
      for (final output in outputs) {
        output?.release();
      }
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
    // SharedSessionManager.runBatchInference(). On mobile the run-slot
    // limiter meters these out so the arena stays small.
    final futures = texts.map((text) => generateEmbedding(text));
    return Future.wait(futures);
  }

  // -------------------------------------------------------------------------
  // Run-slot limiter internals
  // -------------------------------------------------------------------------

  /// Claims a run slot, parking the caller FIFO when the cap is reached.
  Future<void> _acquireRunSlot() async {
    final limit = _maxConcurrentRuns;
    if (limit == null || _activeRuns < limit) {
      _activeRuns++;
      return;
    }

    // Full — wait until _releaseRunSlot hands this caller a slot directly
    final waiter = Completer<void>();
    _runWaiters.add(waiter);
    await waiter.future;
  }

  /// Returns a run slot: hands it straight to the next waiter if there is
  /// one, otherwise frees it (and wakes close() once everything drained).
  void _releaseRunSlot() {
    if (_runWaiters.isNotEmpty) {
      // Ownership transfer — the active count doesn't change
      _runWaiters.removeFirst().complete();
      return;
    }

    _activeRuns--;
    if (_activeRuns <= 0) {
      _activeRuns = 0;
      final drained = _drained;
      _drained = null;
      if (drained != null && !drained.isCompleted) drained.complete();
    }
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

    // Let in-flight runs finish first: freeing the session under a running
    // Run() is a native use-after-free. Parked callers wake up, see
    // _isClosed and bail without touching the session, so this drains fast.
    if (_activeRuns > 0) {
      final drained = _drained ??= Completer<void>();
      await drained.future;
    }

    // Release ONNX Runtime resources in dependency order:
    // 1. Kill all isolates (stops background inference workers)
    // 2. Release the session (frees native model memory)
    // 3. Release run options (session options were freed at load time)
    await _session.release();
    _runOptions.release();

    // Notify the plugin singleton that this model is gone
    onClose();

    debugPrint('[DesktopEmbedding] Model closed — all native resources freed');
  }
}
