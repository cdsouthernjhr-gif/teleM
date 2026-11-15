// Source ordering, bounded retry policy and alternative-channel search
// (spec §3, §4C, §4D, §6). Pure Dart.

import '../core/url_policy.dart';
import '../data/models.dart';
import 'stream_health_checker.dart';

enum SourceKind { primary, secondary }

class PlaybackSource {
  PlaybackSource(this.url, this.type, this.kind);
  final String url;
  final StreamType type;
  final SourceKind kind;
}

/// Builds the ordered list of playable, policy-approved sources:
/// 1. primary direct stream, 2. secondary verified stream.
/// The official platform is not "played"; it is offered as the last resort.
List<PlaybackSource> buildSources(Channel c, UrlPolicy policy) {
  if (!c.streamType.isPlayable) return const [];
  final out = <PlaybackSource>[];
  if (c.streamUrl.isNotEmpty && policy.isStreamAllowed(c.streamUrl)) {
    out.add(PlaybackSource(c.streamUrl, c.streamType, SourceKind.primary));
  }
  if (c.secondaryUrl.isNotEmpty && c.secondaryUrl != c.streamUrl && policy.isStreamAllowed(c.secondaryUrl)) {
    out.add(PlaybackSource(c.secondaryUrl, c.streamType, SourceKind.secondary));
  }
  return out;
}

/// Bounded exponential back-off. Never retries forever.
class RecoveryPolicy {
  RecoveryPolicy({this.maxRetriesPerSource = 2, this.baseDelay = const Duration(seconds: 2), this.maxDelay = const Duration(seconds: 15)});

  final int maxRetriesPerSource;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Delay before retry number [retry] (1-based) of the same source.
  Duration delayFor(int retry) {
    final ms = baseDelay.inMilliseconds * (1 << (retry - 1).clamp(0, 6));
    return Duration(milliseconds: ms.clamp(0, maxDelay.inMilliseconds));
  }

  bool canRetry(int retriesSoFar) => retriesSoFar < maxRetriesPerSource;

  /// Status codes where retrying the same URL is pointless.
  static bool isPermanent(StreamStatus s) =>
      s == StreamStatus.geoRestricted || s == StreamStatus.authRequired || s == StreamStatus.expired;
}

/// Extracts the HTTP status from an ExoPlayer error description such as
/// "Source error: ... InvalidResponseCodeException: Response code: 403".
int? httpCodeFromPlayerError(String? description) {
  if (description == null) return null;
  final m = RegExp(r'Response code:\s*(\d{3})').firstMatch(description) ??
      RegExp(r'\bHTTP\s*(\d{3})\b', caseSensitive: false).firstMatch(description);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Maps a player error to a status (best effort, before a health check).
StreamStatus statusFromPlayerError(String? description) {
  final code = httpCodeFromPlayerError(description);
  if (code == 401) return StreamStatus.authRequired;
  if (code == 451) return StreamStatus.geoRestricted;
  if (code == 410) return StreamStatus.expired;
  if (code == 404 || (code != null && code >= 500)) return StreamStatus.offline;
  final d = (description ?? '').toLowerCase();
  if (d.contains('timeout') || d.contains('timed out')) return StreamStatus.timeout;
  if (d.contains('unable to connect') || d.contains('unknownhost') || d.contains('unable to resolve')) {
    return StreamStatus.offline;
  }
  return StreamStatus.unknown;
}

/// Finds legitimate alternatives when a channel cannot be watched (§4C).
///
/// Order: explicit `alternatives` from the database → same country & same
/// category → same country news → other countries' channels of the same
/// category that the provider allows in the user's country.
/// Channels without a direct stream, disabled channels and channels known to
/// be failing for this user are skipped.
List<Channel> findAlternatives(
  Channel failed,
  List<Channel> all, {
  Map<String, HealthResult> statuses = const {},
  String? userCountry,
  int limit = 4,
}) {
  bool usable(Channel c) {
    if (c.id == failed.id || !c.enabled || !c.hasDirectStream) return false;
    final s = statuses[c.id]?.status ?? c.availability;
    if (s == StreamStatus.offline || s == StreamStatus.expired || s == StreamStatus.authRequired) return false;
    if (s == StreamStatus.geoRestricted) return false;
    if (userCountry != null && c.geoAllowed.isNotEmpty && !c.geoAllowed.contains(userCountry)) return false;
    return true;
  }

  int rank(Channel c) {
    final s = statuses[c.id]?.status ?? c.availability;
    return s == StreamStatus.online ? 0 : 1;
  }

  final out = <Channel>[];
  void addAll(Iterable<Channel> cs) {
    final sorted = cs.where(usable).where((c) => !out.contains(c)).toList()
      ..sort((a, b) => rank(a).compareTo(rank(b)));
    out.addAll(sorted);
  }

  final byId = {for (final c in all) c.id: c};
  addAll(failed.alternatives.map((id) => byId[id]).whereType<Channel>());
  addAll(all.where((c) => c.countryCode == failed.countryCode && c.category == failed.category));
  addAll(all.where((c) => c.countryCode == failed.countryCode && c.category == 'news'));
  addAll(all.where((c) => c.countryCode != failed.countryCode && c.category == failed.category));
  return out.take(limit).toList();
}
