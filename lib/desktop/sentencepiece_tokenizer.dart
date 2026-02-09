import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// =============================================================================
// SentencePiece Unigram Tokenizer — Pure Dart Implementation
// =============================================================================
// Parses a SentencePiece .model protobuf and implements the Unigram
// segmentation algorithm (Viterbi) for desktop platforms where the native
// SentencePiece C++ library is not available.
//
// This is intentionally minimal — it covers EmbeddingGemma / Gecko models
// and standard English text. Full Unicode normalization (NFKC) is omitted
// for simplicity; add it later if non-Latin scripts need support.
// =============================================================================

/// Represents a single piece in the SentencePiece vocabulary.
class _VocabPiece {
  final String piece;
  final double score;
  final int type;

  _VocabPiece(this.piece, this.score, this.type);

  // SentencePiece piece type enum values:
  //   1 = Normal, 2 = Unknown, 3 = Control, 4 = UserDefined, 6 = Byte
  static const int typeNormal = 1;
  static const int typeByte = 6;
}

// =============================================================================
// Minimal Protobuf Wire-Format Reader
// =============================================================================
// Just enough to parse SentencePiece ModelProto without generated classes.
// Wire types: 0=varint, 1=64-bit, 2=length-delimited, 5=32-bit.
// =============================================================================

class _ProtoReader {
  final Uint8List _data;
  int _pos = 0;

  _ProtoReader(this._data);

  /// Whether the reader has consumed all bytes.
  bool get isAtEnd => _pos >= _data.length;

  /// Read a variable-length integer (LEB128).
  int readVarint() {
    int result = 0;
    int shift = 0;
    while (_pos < _data.length) {
      final byte = _data[_pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    throw FormatException('Truncated varint at position $_pos');
  }

  /// Read a length-delimited field and return its raw bytes.
  Uint8List readBytes() {
    final length = readVarint();
    if (_pos + length > _data.length) {
      throw FormatException('Truncated bytes at position $_pos');
    }
    final bytes = Uint8List.sublistView(_data, _pos, _pos + length);
    _pos += length;
    return bytes;
  }

  /// Read a length-delimited field as a UTF-8 string.
  String readString() => utf8.decode(readBytes());

  /// Read a 32-bit float (little-endian, wire type 5).
  double readFloat() {
    if (_pos + 4 > _data.length) {
      throw FormatException('Truncated float at position $_pos');
    }
    final byteData = ByteData.sublistView(_data, _pos, _pos + 4);
    _pos += 4;
    return byteData.getFloat32(0, Endian.little);
  }

  /// Skip over a field based on its wire type.
  void skip(int wireType) {
    switch (wireType) {
      case 0: // varint
        readVarint();
        break;
      case 1: // 64-bit
        _pos += 8;
        break;
      case 2: // length-delimited
        final length = readVarint();
        _pos += length;
        break;
      case 5: // 32-bit
        _pos += 4;
        break;
      default:
        throw FormatException('Unknown wire type $wireType at position $_pos');
    }
  }
}

// =============================================================================
// SentencePiece Tokenizer
// =============================================================================

class SentencePieceTokenizer {
  /// The full vocabulary: index = token ID.
  final List<_VocabPiece> _vocab;

  /// Fast lookup: piece string → token ID.
  final Map<String, int> _pieceToId;

  /// Length of the longest piece in the vocabulary (for Viterbi bounds).
  final int _maxPieceLength;

  // -------------------------------------------------------------------------
  // Special token IDs (resolved once at load time)
  // -------------------------------------------------------------------------
  final int unkId;
  final int bosId;
  final int eosId;
  final int padId;

  SentencePieceTokenizer._({
    required List<_VocabPiece> vocab,
    required Map<String, int> pieceToId,
    required int maxPieceLength,
    required this.unkId,
    required this.bosId,
    required this.eosId,
    required this.padId,
  })  : _vocab = vocab,
        _pieceToId = pieceToId,
        _maxPieceLength = maxPieceLength;

  // -------------------------------------------------------------------------
  // Factory: load from a .model file
  // -------------------------------------------------------------------------

  /// Parse a SentencePiece .model protobuf and build the tokenizer.
  static Future<SentencePieceTokenizer> load(String modelPath) async {
    final bytes = await File(modelPath).readAsBytes();
    return _parseModelProto(Uint8List.fromList(bytes));
  }

  /// Parse the top-level ModelProto message.
  ///
  /// Structure we care about:
  ///   field 1 (repeated, length-delimited) = SentencePiece sub-message
  ///     field 1 (string)  = piece text
  ///     field 2 (float32) = score
  ///     field 3 (varint)  = type enum
  static SentencePieceTokenizer _parseModelProto(Uint8List data) {
    final reader = _ProtoReader(data);
    final vocab = <_VocabPiece>[];
    final pieceToId = <String, int>{};
    int maxLen = 0;

    // Special token IDs — defaults if we don't find them
    int unkId = 0;
    int bosId = 1;
    int eosId = 2;
    int padId = 0; // 0 is typically <pad> or <unk> depending on model

    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x7;

      if (fieldNumber == 1 && wireType == 2) {
        // ---------------------------------------------------------------
        // SentencePiece sub-message
        // ---------------------------------------------------------------
        final subBytes = reader.readBytes();
        final subReader = _ProtoReader(subBytes);

        String piece = '';
        double score = 0.0;
        int type = _VocabPiece.typeNormal;

        while (!subReader.isAtEnd) {
          final subTag = subReader.readVarint();
          final subField = subTag >> 3;
          final subWire = subTag & 0x7;

          if (subField == 1 && subWire == 2) {
            // piece string
            piece = subReader.readString();
          } else if (subField == 2 && subWire == 5) {
            // score (float32)
            score = subReader.readFloat();
          } else if (subField == 3 && subWire == 0) {
            // type (varint enum)
            type = subReader.readVarint();
          } else {
            subReader.skip(subWire);
          }
        }

        final id = vocab.length;
        vocab.add(_VocabPiece(piece, score, type));
        pieceToId[piece] = id;

        // Track longest normal/byte piece for Viterbi loop bound
        if (type == _VocabPiece.typeNormal || type == _VocabPiece.typeByte) {
          if (piece.length > maxLen) maxLen = piece.length;
        }

        // Resolve special tokens by piece string
        if (piece == '<unk>') unkId = id;
        if (piece == '<s>') bosId = id;
        if (piece == '</s>') eosId = id;
        if (piece == '<pad>') padId = id;
      } else {
        // Skip fields we don't care about (trainer_spec, normalizer_spec, etc.)
        reader.skip(wireType);
      }
    }

    return SentencePieceTokenizer._(
      vocab: vocab,
      pieceToId: pieceToId,
      maxPieceLength: maxLen,
      unkId: unkId,
      bosId: bosId,
      eosId: eosId,
      padId: padId,
    );
  }

  // -------------------------------------------------------------------------
  // Encode: text → token IDs
  // -------------------------------------------------------------------------

  /// Tokenize [text] into a list of token IDs.
  ///
  /// The output is padded/truncated to exactly [maxLength] tokens.
  /// A BOS token is prepended.  Remaining slots are filled with [padId].
  List<int> encode(String text, {int maxLength = 256}) {
    // -----------------------------------------------------------------
    // 1. SentencePiece convention: prepend ▁ and replace spaces with ▁
    // -----------------------------------------------------------------
    final processed = '\u2581${text.replaceAll(' ', '\u2581')}';

    // -----------------------------------------------------------------
    // 2. Viterbi forward pass — find best segmentation
    // -----------------------------------------------------------------
    final n = processed.length;
    final bestScore = List.filled(n + 1, double.negativeInfinity);
    final bestPrev = List.filled(n + 1, -1);
    bestScore[0] = 0.0;

    for (int i = 0; i < n; i++) {
      if (bestScore[i] == double.negativeInfinity) continue;

      // Try all vocabulary pieces starting at position i
      final maxLen = (i + _maxPieceLength <= n) ? _maxPieceLength : n - i;
      for (int len = 1; len <= maxLen; len++) {
        final piece = processed.substring(i, i + len);
        final id = _pieceToId[piece];
        if (id == null) continue;

        // Only use NORMAL and BYTE pieces for segmentation
        final pieceType = _vocab[id].type;
        if (pieceType != _VocabPiece.typeNormal &&
            pieceType != _VocabPiece.typeByte &&
            pieceType != 0) {
          continue;
        }

        final score = bestScore[i] + _vocab[id].score;
        if (score > bestScore[i + len]) {
          bestScore[i + len] = score;
          bestPrev[i + len] = i;
        }
      }

      // Byte fallback: encode individual UTF-8 bytes if no piece matched
      if (i + 1 <= n && bestScore[i + 1] == double.negativeInfinity) {
        final utf8Bytes = utf8.encode(processed[i]);
        for (final byte in utf8Bytes) {
          final hexStr =
              '<0x${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}>';
          final byteId = _pieceToId[hexStr];
          if (byteId != null) {
            final score = bestScore[i] + _vocab[byteId].score;
            if (score > bestScore[i + 1]) {
              bestScore[i + 1] = score;
              bestPrev[i + 1] = i;
            }
          }
        }

        // Ultimate fallback: use <unk> if nothing matched at all
        if (bestScore[i + 1] == double.negativeInfinity) {
          bestScore[i + 1] = bestScore[i] + -100.0; // heavy penalty
          bestPrev[i + 1] = i;
        }
      }
    }

    // -----------------------------------------------------------------
    // 3. Backtrack to collect token IDs
    // -----------------------------------------------------------------
    final tokenIds = <int>[];
    int pos = n;
    while (pos > 0) {
      final prev = bestPrev[pos];
      if (prev == -1) {
        // Shouldn't happen, but safety net
        tokenIds.add(unkId);
        pos--;
        continue;
      }
      final piece = processed.substring(prev, pos);
      tokenIds.add(_pieceToId[piece] ?? unkId);
      pos = prev;
    }
    // Backtracking gives us tokens in reverse order
    final reversed = tokenIds.reversed.toList();

    // -----------------------------------------------------------------
    // 4. Prepend BOS, truncate, pad to maxLength
    // -----------------------------------------------------------------
    final result = <int>[bosId];
    final available = maxLength - 1; // reserve 1 slot for BOS
    if (reversed.length > available) {
      result.addAll(reversed.sublist(0, available));
    } else {
      result.addAll(reversed);
      // Pad remaining slots
      while (result.length < maxLength) {
        result.add(padId);
      }
    }

    return result;
  }

  /// Vocabulary size.
  int get vocabSize => _vocab.length;
}
