import 'package:flutter/material.dart' show IconData, Icons;

/// Modelo de dados de um arquivo/pasta do sistema de arquivos.
///
/// DTO puro para o gerenciador de arquivos completo.
enum FileType {
  directory,
  audio,
  video,
  image,
  pdf,
  document,
  archive,
  apk,
  code,
  text,
  spreadsheet,
  presentation,
  other,
}

/// Extensões conhecidas por tipo
class FileTypeMap {
  static const Map<String, FileType> _map = {
    // Áudio
    'mp3': FileType.audio,
    'm4a': FileType.audio,
    'flac': FileType.audio,
    'wav': FileType.audio,
    'ogg': FileType.audio,
    'aac': FileType.audio,
    'opus': FileType.audio,
    'wma': FileType.audio,
    // Vídeo
    'mp4': FileType.video,
    'mkv': FileType.video,
    'avi': FileType.video,
    'mov': FileType.video,
    'wmv': FileType.video,
    'flv': FileType.video,
    'webm': FileType.video,
    '3gp': FileType.video,
    'ts': FileType.video,
    // Imagem
    'jpg': FileType.image,
    'jpeg': FileType.image,
    'png': FileType.image,
    'gif': FileType.image,
    'webp': FileType.image,
    'bmp': FileType.image,
    'heic': FileType.image,
    'heif': FileType.image,
    'tiff': FileType.image,
    'raw': FileType.image,
    // PDF
    'pdf': FileType.pdf,
    // Documentos
    'doc': FileType.document,
    'docx': FileType.document,
    'txt': FileType.text,
    'rtf': FileType.document,
    'odt': FileType.document,
    // Planilhas
    'xls': FileType.spreadsheet,
    'xlsx': FileType.spreadsheet,
    'csv': FileType.spreadsheet,
    'ods': FileType.spreadsheet,
    // Apresentações
    'ppt': FileType.presentation,
    'pptx': FileType.presentation,
    'odp': FileType.presentation,
    // Código
    'dart': FileType.code,
    'js': FileType.code,
    'java': FileType.code,
    'kt': FileType.code,
    'py': FileType.code,
    'html': FileType.code,
    'css': FileType.code,
    'json': FileType.code,
    'xml': FileType.code,
    'yaml': FileType.code,
    'yml': FileType.code,
    'sql': FileType.code,
    'sh': FileType.code,
    // Compactados
    'zip': FileType.archive,
    'rar': FileType.archive,
    '7z': FileType.archive,
    'tar': FileType.archive,
    'gz': FileType.archive,
    'bz2': FileType.archive,
    'xz': FileType.archive,
    // APK
    'apk': FileType.apk,
  };

  static FileType fromExtension(String extension) {
    return _map[extension.toLowerCase()] ?? FileType.other;
  }

  static IconData iconForType(FileType type) {
    switch (type) {
      case FileType.directory:
        return Icons.folder;
      case FileType.audio:
        return Icons.music_note;
      case FileType.video:
        return Icons.videocam;
      case FileType.image:
        return Icons.image;
      case FileType.pdf:
        return Icons.picture_as_pdf;
      case FileType.document:
        return Icons.description;
      case FileType.archive:
        return Icons.archive;
      case FileType.apk:
        return Icons.android;
      case FileType.code:
        return Icons.code;
      case FileType.text:
        return Icons.text_snippet;
      case FileType.spreadsheet:
        return Icons.table_chart;
      case FileType.presentation:
        return Icons.slideshow;
      case FileType.other:
        return Icons.insert_drive_file;
    }
  }
}

class FileItem {
  final String path;
  final String name;
  final FileType type;
  final int size;
  final int dateModified;
  final int dateCreated;
  final bool isDirectory;
  final String? parentPath;
  final String extension;

  const FileItem({
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    required this.dateModified,
    required this.dateCreated,
    required this.isDirectory,
    this.parentPath,
    required this.extension,
  });

  factory FileItem.fromChannel(Map<dynamic, dynamic> map) {
    final String path = map['path'] as String;
    final String name = map['name'] as String;
    final bool isDir = map['isDirectory'] as bool? ?? false;
    final int size = (map['size'] as num?)?.toInt() ?? 0;
    final int dateModified = (map['dateModified'] as num?)?.toInt() ?? 0;
    final int dateCreated = (map['dateCreated'] as num?)?.toInt() ?? 0;
    final String extension = isDir ? '' : _extractExtension(name);

    return FileItem(
      path: path,
      name: name,
      type: isDir ? FileType.directory : FileTypeMap.fromExtension(extension),
      size: size,
      dateModified: dateModified,
      dateCreated: dateCreated,
      isDirectory: isDir,
      parentPath: map['parentPath'] as String?,
      extension: extension,
    );
  }

  /// Constrói a partir de uma entidade real do sistema de arquivos
  /// (dart:io). Timestamps em SEGUNDOS (convenção dos demais campos).
  factory FileItem.fromStat({
    required String path,
    required bool isDirectory,
    required int size,
    required int modifiedSeconds,
    required int createdSeconds,
  }) {
    final String name = path.split('/').where((s) => s.isNotEmpty).last;
    final String extension =
        isDirectory ? '' : _extractExtension(name);
    return FileItem(
      path: path,
      name: name,
      type: isDirectory ? FileType.directory : FileTypeMap.fromExtension(extension),
      size: size,
      dateModified: modifiedSeconds,
      dateCreated: createdSeconds,
      isDirectory: isDirectory,
      parentPath: _parentOf(path),
      extension: extension,
    );
  }

  static String _parentOf(String path) {
    final int idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  static String _extractExtension(String name) {
    final int dotIndex = name.lastIndexOf('.');
    if (dotIndex <= 0) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  String get displaySize {
    if (isDirectory) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get displayDateModified {
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(dateModified * 1000);
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String get displayDateCreated {
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(dateCreated * 1000);
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  IconData get icon => FileTypeMap.iconForType(type);

  @override
  bool operator ==(Object other) =>
      other is FileItem && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'FileItem(path: $path, name: $name, type: $type, size: $size)';
}

/// Atalhos rápidos para pastas do sistema
class SystemFolders {
  static const List<SystemFolder> shortcuts = [
    SystemFolder(
      name: 'Armazenamento Interno',
      path: '/storage/emulated/0',
      icon: Icons.sd_storage,
    ),
    SystemFolder(
      name: 'Download',
      path: '/storage/emulated/0/Download',
      icon: Icons.download,
    ),
    SystemFolder(
      name: 'DCIM (Câmera)',
      path: '/storage/emulated/0/DCIM',
      icon: Icons.camera_alt,
    ),
    SystemFolder(
      name: 'Imagens',
      path: '/storage/emulated/0/Pictures',
      icon: Icons.photo_library,
    ),
    SystemFolder(
      name: 'Filmes/Vídeos',
      path: '/storage/emulated/0/Movies',
      icon: Icons.movie,
    ),
    SystemFolder(
      name: 'Música',
      path: '/storage/emulated/0/Music',
      icon: Icons.music_note,
    ),
    SystemFolder(
      name: 'Documentos',
      path: '/storage/emulated/0/Documents',
      icon: Icons.folder_open,
    ),
    SystemFolder(
      name: 'Android/data',
      path: '/storage/emulated/0/Android/data',
      icon: Icons.android,
    ),
    SystemFolder(
      name: 'Android/obb',
      path: '/storage/emulated/0/Android/obb',
      icon: Icons.archive,
    ),
  ];
}

class SystemFolder {
  final String name;
  final String path;
  final IconData icon;

  const SystemFolder({
    required this.name,
    required this.path,
    required this.icon,
  });
}