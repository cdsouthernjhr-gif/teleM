/// Semantic version `MAJOR.MINOR.PATCH[-prerelease]` (build metadata after `+`
/// is accepted and ignored for ordering, as SemVer requires).
class AssetVersion implements Comparable<AssetVersion> {
  const AssetVersion(this.major, this.minor, this.patch, [this.preRelease = '']);

  final int major;
  final int minor;
  final int patch;
  final String preRelease;

  static final RegExp _re = RegExp(
      r'^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$');

  static AssetVersion? tryParse(String? s) {
    if (s == null) return null;
    final m = _re.firstMatch(s.trim());
    if (m == null) return null;
    return AssetVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4] ?? '');
  }

  static AssetVersion parse(String s) {
    final v = tryParse(s);
    if (v == null) throw FormatException('Not a semantic version: "$s"');
    return v;
  }

  static bool isValid(String? s) => tryParse(s) != null;

  @override
  int compareTo(AssetVersion other) {
    final o = other;
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    if (patch != o.patch) return patch.compareTo(o.patch);
    if (preRelease == o.preRelease) return 0;
    // A version without pre-release is higher than one with it.
    if (preRelease.isEmpty) return 1;
    if (o.preRelease.isEmpty) return -1;
    final a = preRelease.split('.');
    final b = o.preRelease.split('.');
    for (var i = 0; i < a.length && i < b.length; i++) {
      final ai = int.tryParse(a[i]);
      final bi = int.tryParse(b[i]);
      int c;
      if (ai != null && bi != null) {
        c = ai.compareTo(bi);
      } else if (ai != null) {
        c = -1;
      } else if (bi != null) {
        c = 1;
      } else {
        c = a[i].compareTo(b[i]);
      }
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  bool operator <(AssetVersion o) => compareTo(o) < 0;
  bool operator >(AssetVersion o) => compareTo(o) > 0;
  bool operator <=(AssetVersion o) => compareTo(o) <= 0;
  bool operator >=(AssetVersion o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) => other is AssetVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() => '$major.$minor.$patch${preRelease.isEmpty ? '' : '-$preRelease'}';
}

/// Compares two version strings; invalid strings sort lowest.
int compareVersionStrings(String a, String b) {
  final va = AssetVersion.tryParse(a);
  final vb = AssetVersion.tryParse(b);
  if (va == null && vb == null) return a.compareTo(b);
  if (va == null) return -1;
  if (vb == null) return 1;
  return va.compareTo(vb);
}
