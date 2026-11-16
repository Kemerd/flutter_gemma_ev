// Stub for desktop implementation on web platform
//
// This file is used when the library is compiled for web.
// Desktop functionality is not available on web.

import 'package:flutter/foundation.dart' show VoidCallback;

import '../flutter_gemma_interface.dart';
import '../pigeon.g.dart';

/// Desktop plugin is not available on web
class FlutterGemmaDesktop extends FlutterGemmaPlugin {
  FlutterGemmaDesktop._() {
    throw UnsupportedError('Desktop is not supported on web platform');
  }

  static FlutterGemmaDesktop get instance =>
      throw UnsupportedError('Desktop is not supported on web platform');

  static void registerWith() {
    // No-op on web
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Desktop is not supported on web platform');
  }
}

/// Always false on web
bool get isDesktop => false;

/// Web has no ONNX Runtime FFI backend, so no path ever routes to it.
bool isOnnxEmbeddingModel(String modelPath) => false;

/// ONNX Runtime needs dart:ffi, which doesn't exist on web.
Future<EmbeddingModel> createOnnxEmbeddingModel({
  required String modelPath,
  required String tokenizerPath,
  PreferredBackend? preferredBackend,
  required VoidCallback onClose,
}) {
  throw UnsupportedError('ONNX embeddings are not supported on web platform');
}
