import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_gemma/core/services/file_system_service.dart';

/// Platform-specific file system implementation using dart:io
///
/// Features:
/// - Uses path_provider for platform directories
/// - Supports Android and iOS
/// - Automatic parent directory creation
/// - External file registration tracking
/// - Optional custom base directory (e.g. external NVMe on macOS)
class PlatformFileSystemService implements FileSystemService {
  // Cache for app documents directory
  Directory? _documentsDirectory;

  // ---------------------------------------------------------------------------
  // Custom Model Storage Directory
  // ---------------------------------------------------------------------------
  // Mirrors ModelFileSystemManager._customModelStorageDir — when set, model
  // downloads land here instead of getApplicationDocumentsDirectory(). This
  // is the path that NetworkSourceHandler / SmartDownloader will actually use.
  // ---------------------------------------------------------------------------

  static String? _customBaseDirectory;

  /// Override the default base directory for model file storage.
  ///
  /// Must be kept in sync with [ModelFileSystemManager.setModelStorageDirectory].
  /// Both are set together from [FlutterGemma.initialize].
  static void setCustomBaseDirectory(String? directory) {
    _customBaseDirectory = directory;
  }

  @override
  Future<void> writeFile(String filePath, Uint8List data) async {
    final file = File(filePath);

    // Create parent directories if they don't exist
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    await file.writeAsBytes(data);
  }

  @override
  Future<Uint8List> readFile(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    return await file.readAsBytes();
  }

  @override
  Future<void> deleteFile(String filePath) async {
    final file = File(filePath);

    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<bool> fileExists(String filePath) async {
    final file = File(filePath);
    return await file.exists();
  }

  @override
  Future<int> getFileSize(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      return 0;
    }

    final stat = await file.stat();
    return stat.size;
  }

  @override
  Future<String> getTargetPath(String filename) async {
    final dir = await _getDocumentsDirectory();
    return path.join(dir.path, filename);
  }

  @override
  Future<String> getBundledResourcePath(String resourceName) async {
    // Web doesn't support bundled resources via this service
    if (kIsWeb) {
      throw UnsupportedError('Bundled resources not supported on web platform');
    }

    // Platform-specific bundled resource handling
    if (Platform.isAndroid) {
      // Android: Copy from native assets to filesDir (MediaPipe can't read from APK directly)
      final dir = await _getDocumentsDirectory();
      final destPath = path.join(dir.path, resourceName);
      final destFile = File(destPath);

      // Check if already copied
      if (await destFile.exists()) {
        return destPath;
      }

      // Copy from native assets via platform channel
      const platform = MethodChannel('flutter_gemma_bundled');
      final result = await platform.invokeMethod<String>(
        'copyAssetToFile',
        {
          'assetPath': 'models/$resourceName',
          'destPath': destPath,
        },
      );

      if (result == null || result != 'success') {
        throw Exception('Failed to copy asset from Android assets');
      }

      return destPath;
    } else if (Platform.isIOS) {
      // On iOS, MediaPipe CAN read directly from Bundle (after iOS native fix)
      // Simply get the bundle path and return it - no copying needed!
      const platform = MethodChannel('flutter_gemma_bundled');
      final bundlePath = await platform.invokeMethod<String>(
        'getBundledResourcePath',
        {'resourceName': resourceName},
      );

      if (bundlePath == null) {
        throw Exception('Bundled resource not found: $resourceName');
      }

      return bundlePath;
    } else {
      throw UnsupportedError('Bundled resources not supported on ${Platform.operatingSystem}');
    }
  }

  @override
  Future<void> registerExternalFile(String filename, String externalPath) async {
    // External file registration is handled by ProtectedFilesRegistry
    // This method is a no-op here since file system doesn't track registrations
    // The actual tracking is done in ProtectedFilesRegistry.registerExternalPath()
  }

  /// Gets the base directory for model file storage.
  ///
  /// Returns the custom override if set, otherwise falls back to the
  /// platform's application documents directory. Result is cached.
  Future<Directory> _getDocumentsDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('Local file system not supported on web platform');
    }

    // Invalidate cache when custom dir changes (e.g. hot-restart in dev)
    if (_customBaseDirectory != null) {
      final customDir = Directory(_customBaseDirectory!);
      if (!await customDir.exists()) {
        await customDir.create(recursive: true);
      }
      _documentsDirectory = customDir;
      return customDir;
    }

    if (_documentsDirectory != null) {
      return _documentsDirectory!;
    }

    _documentsDirectory = await getApplicationDocumentsDirectory();
    return _documentsDirectory!;
  }
}
