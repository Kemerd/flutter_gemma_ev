part of 'flutter_gemma_desktop.dart';

// =============================================================================
// Desktop Embedding Model — TFLite + SentencePiece, Pure Dart
// =============================================================================
// Loads an EmbeddingGemma / Gecko .tflite model via tflite_flutter's FFI
// Interpreter and runs inference entirely on the CPU (XNNPack-accelerated).
//
// The mobile platforms use MediaPipe's native TextEmbedder through Pigeon,
// but that native API isn't available on desktop.  This class replicates the
// same functionality using:
//   1. SentencePieceTokenizer  — pure Dart protobuf parser + Viterbi encoder
//   2. tflite_flutter           — Dart FFI bindings to the TFLite C library
//
// Input/output tensor shapes are detected at runtime so this works with any
// EmbeddingGemma or Gecko variant regardless of sequence length.
// =============================================================================

class DesktopEmbeddingModel extends EmbeddingModel {
  // -------------------------------------------------------------------------
  // Fields
  // -------------------------------------------------------------------------
  final Interpreter _interpreter;

  /// IsolateInterpreter runs TFLite inference in a background isolate,
  /// preventing the main (UI) thread from blocking during the FFI call.
  /// Without this, every _interpreter.run() freezes the UI for the
  /// duration of model inference (~50-200ms per page on desktop CPU).
  final IsolateInterpreter _isolateInterpreter;

  final SentencePieceTokenizer _tokenizer;
  final int _maxSeqLength;
  final int _embeddingDim;
  final int _inputCount;
  final VoidCallback onClose;
  bool _isClosed = false;

  DesktopEmbeddingModel._({
    required Interpreter interpreter,
    required IsolateInterpreter isolateInterpreter,
    required SentencePieceTokenizer tokenizer,
    required int maxSeqLength,
    required int embeddingDim,
    required int inputCount,
    required this.onClose,
  })  : _interpreter = interpreter,
        _isolateInterpreter = isolateInterpreter,
        _tokenizer = tokenizer,
        _maxSeqLength = maxSeqLength,
        _embeddingDim = embeddingDim,
        _inputCount = inputCount;

  // -------------------------------------------------------------------------
  // Factory constructor — loads model + tokenizer, inspects tensor shapes
  // -------------------------------------------------------------------------

  /// Create a new desktop embedding model from file paths.
  ///
  /// [modelPath]      — path to the .tflite embedding model file
  /// [tokenizerPath]  — path to the sentencepiece.model tokenizer file
  /// [preferredBackend] — CPU or GPU hint (only CPU/XNNPack on desktop)
  /// [onClose]        — callback when the model is closed
  static Future<DesktopEmbeddingModel> create({
    required String modelPath,
    required String tokenizerPath,
    PreferredBackend? preferredBackend,
    required VoidCallback onClose,
  }) async {
    // -----------------------------------------------------------------
    // Load the SentencePiece tokenizer
    // -----------------------------------------------------------------
    debugPrint('[DesktopEmbedding] Loading tokenizer from: $tokenizerPath');
    final tokenizer = await SentencePieceTokenizer.load(tokenizerPath);
    debugPrint('[DesktopEmbedding] Tokenizer loaded — '
        '${tokenizer.vocabSize} pieces');

    // -----------------------------------------------------------------
    // Configure TFLite interpreter options
    // -----------------------------------------------------------------
    final cpuCount = Platform.numberOfProcessors;
    final options = InterpreterOptions()..threads = cpuCount;
    debugPrint('[DesktopEmbedding] InterpreterOptions created '
        '(threads: $cpuCount)');

    // XNNPack is disabled for now — the delegate constructor crashes on
    // Windows with certain TFLite C library builds.  Plain CPU with
    // multi-threading still gives decent performance.
    // TODO(desktop): Re-enable once a compatible TFLite build is confirmed.
    const bool useXnnpack = false;
    debugPrint('[DesktopEmbedding] Using plain CPU backend (XNNPack disabled)');

    // -----------------------------------------------------------------
    // Load the TFLite model (with XNNPack fallback)
    // -----------------------------------------------------------------
    debugPrint('[DesktopEmbedding] Loading model from: $modelPath');
    final modelFile = File(modelPath);
    if (!modelFile.existsSync()) {
      throw FileSystemException('Model file not found', modelPath);
    }
    debugPrint('[DesktopEmbedding] Model file size: '
        '${modelFile.lengthSync()} bytes');

    // Read model into memory first — avoids potential file-handle issues
    // in the native C library on Windows
    debugPrint('[DesktopEmbedding] Reading model into memory...');
    final modelBytes = await modelFile.readAsBytes();
    debugPrint('[DesktopEmbedding] Model bytes read: ${modelBytes.length}');

    late Interpreter interpreter;
    try {
      debugPrint('[DesktopEmbedding] Creating interpreter (XNNPack=$useXnnpack)...');
      interpreter = Interpreter.fromBuffer(modelBytes, options: options);
      debugPrint('[DesktopEmbedding] Interpreter created OK');
    } catch (e) {
      // If XNNPack was on and it crashed, retry without it
      if (useXnnpack) {
        debugPrint('[DesktopEmbedding] Interpreter failed with XNNPack, '
            'retrying without delegate: $e');
        final fallbackOptions = InterpreterOptions()..threads = cpuCount;
        interpreter =
            Interpreter.fromBuffer(modelBytes, options: fallbackOptions);
        debugPrint('[DesktopEmbedding] Interpreter created OK (no delegate)');
      } else {
        rethrow;
      }
    }

    debugPrint('[DesktopEmbedding] Allocating tensors...');
    interpreter.allocateTensors();
    debugPrint('[DesktopEmbedding] Tensors allocated');

    // -----------------------------------------------------------------
    // Inspect tensor shapes so we work with any EmbeddingGemma variant
    // -----------------------------------------------------------------
    final inputCount = interpreter.getInputTensors().length;
    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);

    final inputShape = inputTensor.shape; // e.g. [1, 256]
    final outputShape = outputTensor.shape; // e.g. [1, 768]

    final maxSeqLength = inputShape.length >= 2 ? inputShape[1] : inputShape[0];
    final embeddingDim =
        outputShape.length >= 2 ? outputShape[1] : outputShape[0];

    debugPrint('[DesktopEmbedding] Input  shape: $inputShape '
        '(${inputTensor.type})');
    debugPrint('[DesktopEmbedding] Output shape: $outputShape '
        '(${outputTensor.type})');
    debugPrint('[DesktopEmbedding] Sequence length: $maxSeqLength, '
        'Embedding dim: $embeddingDim');
    debugPrint('[DesktopEmbedding] Model has $inputCount input tensor(s)');

    // ---------------------------------------------------------------
    // Wrap the interpreter in an IsolateInterpreter so inference runs
    // on a background isolate instead of blocking the UI thread.
    // The address is the raw pointer to the underlying TFLite C struct.
    // ---------------------------------------------------------------
    debugPrint('[DesktopEmbedding] Creating IsolateInterpreter for '
        'non-blocking inference...');
    final isolateInterpreter = await IsolateInterpreter.create(
      address: interpreter.address,
    );
    debugPrint('[DesktopEmbedding] IsolateInterpreter ready — '
        'inference will NOT block the UI thread');

    return DesktopEmbeddingModel._(
      interpreter: interpreter,
      isolateInterpreter: isolateInterpreter,
      tokenizer: tokenizer,
      maxSeqLength: maxSeqLength,
      embeddingDim: embeddingDim,
      inputCount: inputCount,
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
  // EmbeddingModel interface implementation
  // -------------------------------------------------------------------------

  @override
  Future<List<double>> generateEmbedding(String text) async {
    _assertNotClosed();

    // Tokenize the input text to fixed-length token IDs
    final tokenIds = _tokenizer.encode(text, maxLength: _maxSeqLength);

    // Build the input tensor(s).
    // Most EmbeddingGemma models have 1 input (token_ids).
    // Some have 2 (token_ids + attention_mask) or 3 (+ token_type_ids).
    final inputIds = [tokenIds]; // shape [1, seq_len]

    if (_inputCount == 1) {
      // Single input: just token IDs
      // Uses IsolateInterpreter so inference runs on a background isolate,
      // keeping the UI thread completely free to render frames.
      final output = [List<double>.filled(_embeddingDim, 0.0)];
      await _isolateInterpreter.run(inputIds, output);
      return output[0];
    } else {
      // Multiple inputs: token_ids + attention_mask (+ token_type_ids)
      // Attention mask: 1 for real tokens, 0 for padding
      final attentionMask = [
        tokenIds
            .map((id) => id != _tokenizer.padId ? 1 : 0)
            .toList(),
      ];

      final inputs = <Object>[inputIds, attentionMask];

      // Third input (token_type_ids) if the model expects it — all zeros
      if (_inputCount >= 3) {
        inputs.add([List<int>.filled(_maxSeqLength, 0)]);
      }

      // Run with multiple inputs via IsolateInterpreter (non-blocking).
      // The actual TFLite FFI call happens on a background isolate.
      final outputs = <int, Object>{
        0: [List<double>.filled(_embeddingDim, 0.0)],
      };
      await _isolateInterpreter.runForMultipleInputs(inputs, outputs);

      return (outputs[0]! as List<List<double>>)[0];
    }
  }

  @override
  Future<List<List<double>>> generateEmbeddings(List<String> texts) async {
    _assertNotClosed();

    // Process texts one by one (batch inference is possible but adds
    // complexity with tensor reshaping — fine for desktop perf)
    final results = <List<double>>[];
    for (final text in texts) {
      results.add(await generateEmbedding(text));
    }
    return results;
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

    // Close the isolate interpreter first (stops the background isolate),
    // then close the underlying interpreter (frees native TFLite resources).
    await _isolateInterpreter.close();
    _interpreter.close();
    onClose();

    debugPrint('[DesktopEmbedding] Model closed');
  }
}
