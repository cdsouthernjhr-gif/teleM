// Path checks used for manifest `localPath` values and ZIP entry names.

import 'package:path/path.dart' as p;

const int kMaxRelativePathLength = 512;
const int kMaxPathSegmentLength = 255;

final RegExp _driveLetter = RegExp(r'^[A-Za-z]:');
final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');

/// Returns null when [path] is a safe *relative* POSIX path, otherwise a short
/// reason. Rejects absolute paths, drive letters, backslashes, `..`, `.`,
/// empty segments, control characters and over-long names.
String? relativePathProblem(String path) {
  if (path.isEmpty) return 'empty';
  if (path.length > kMaxRelativePathLength) return 'too_long';
  if (_controlChars.hasMatch(path)) return 'control_chars';
  if (path.contains('\\')) return 'backslash';
  if (path.startsWith('/')) return 'absolute';
  if (_driveLetter.hasMatch(path)) return 'drive_letter';
  if (path.startsWith('~')) return 'home_reference';
  final segs = path.split('/');
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    // A single trailing slash (directory entry in a ZIP) is allowed.
    if (s.isEmpty && i == segs.length - 1 && i > 0) continue;
    if (s.isEmpty) return 'empty_segment';
    if (s == '..') return 'traversal';
    if (s == '.') return 'dot_segment';
    if (s.length > kMaxPathSegmentLength) return 'segment_too_long';
  }
  return null;
}

bool isSafeRelativePath(String path) => relativePathProblem(path) == null;

/// Joins [relative] onto [root] and returns the absolute result, or null when
/// the relative path is unsafe or the result would escape [root].
String? safeJoin(String root, String relative) {
  if (!isSafeRelativePath(relative)) return null;
  final normRoot = p.normalize(p.absolute(root));
  final joined = p.normalize(p.join(normRoot, relative));
  if (!p.isWithin(normRoot, joined)) return null;
  return joined;
}

/// A safe single file name (no directory part).
bool isSafeFileName(String name) =>
    isSafeRelativePath(name) && !name.contains('/') && name.trim() == name && name.isNotEmpty;
