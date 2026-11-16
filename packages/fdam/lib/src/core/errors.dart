// Error codes and the single exception type used by FDAM.

/// Stable error codes. [FdamErrorCode.wireName] is what is written to logs
/// and to the `last_error` column, so do not rename these.
enum FdamErrorCode {
  networkUnavailable('NETWORK_UNAVAILABLE'),
  httpError('HTTP_ERROR'),
  manifestInvalid('MANIFEST_INVALID'),
  manifestNotFound('MANIFEST_NOT_FOUND'),
  fileNotFound('FILE_NOT_FOUND'),
  diskSpaceInsufficient('DISK_SPACE_INSUFFICIENT'),
  downloadInterrupted('DOWNLOAD_INTERRUPTED'),
  checksumMismatch('CHECKSUM_MISMATCH'),
  zipExtractionFailed('ZIP_EXTRACTION_FAILED'),
  invalidAssetPath('INVALID_ASSET_PATH'),
  databaseError('DATABASE_ERROR'),
  versionConflict('VERSION_CONFLICT'),
  cancelled('CANCELLED'),
  unknown('UNKNOWN');

  const FdamErrorCode(this.wireName);
  final String wireName;

  static FdamErrorCode fromWire(String? s) =>
      FdamErrorCode.values.firstWhere((e) => e.wireName == s, orElse: () => FdamErrorCode.unknown);
}

class FdamException implements Exception {
  FdamException(this.code, this.detail, {this.retryable = false, this.httpStatus});

  final FdamErrorCode code;

  /// Technical detail for logs. Never contains tokens or full signed URLs.
  final String detail;

  /// True when trying again later can succeed (network drop, 5xx, ...).
  final bool retryable;

  final int? httpStatus;

  /// Message a user can understand, in Malay (`ms`) or English (`en`).
  String userMessage([String lang = 'ms']) => fdamErrorMessage(code, lang);

  @override
  String toString() => 'FdamException(${code.wireName}${httpStatus != null ? ' $httpStatus' : ''}): $detail';
}

String fdamErrorMessage(FdamErrorCode code, [String lang = 'ms']) {
  final en = lang == 'en';
  switch (code) {
    case FdamErrorCode.networkUnavailable:
      return en
          ? 'No internet connection. Files already on the device can still be used.'
          : 'Tiada sambungan internet. Fail yang sudah ada dalam peranti masih boleh digunakan.';
    case FdamErrorCode.httpError:
      return en
          ? 'The download server returned an error. Please try again later.'
          : 'Pelayan muat turun memulangkan ralat. Sila cuba lagi nanti.';
    case FdamErrorCode.manifestInvalid:
      return en
          ? 'The asset list from the server is invalid. The previous valid list is kept.'
          : 'Senarai aset daripada pelayan tidak sah. Senarai sah yang terdahulu dikekalkan.';
    case FdamErrorCode.manifestNotFound:
      return en
          ? 'The asset list could not be found on the server.'
          : 'Senarai aset tidak dijumpai di pelayan.';
    case FdamErrorCode.fileNotFound:
      return en
          ? 'A file is not available on the server (release missing or removed).'
          : 'Fail tidak tersedia di pelayan (release tiada atau telah dibuang).';
    case FdamErrorCode.diskSpaceInsufficient:
      return en
          ? 'Not enough free storage. Free some space and try again.'
          : 'Ruang storan tidak mencukupi. Kosongkan sedikit ruang dan cuba lagi.';
    case FdamErrorCode.downloadInterrupted:
      return en
          ? 'The download was interrupted. It will continue from where it stopped.'
          : 'Muat turun terganggu. Ia akan disambung dari titik ia berhenti.';
    case FdamErrorCode.checksumMismatch:
      return en
          ? 'A downloaded file failed verification and was discarded.'
          : 'Fail yang dimuat turun gagal pengesahan dan telah dibuang.';
    case FdamErrorCode.zipExtractionFailed:
      return en
          ? 'A package could not be unpacked safely. The previous version is kept.'
          : 'Pakej tidak dapat dibuka dengan selamat. Versi terdahulu dikekalkan.';
    case FdamErrorCode.invalidAssetPath:
      return en
          ? 'A file has an unsafe location and was rejected.'
          : 'Fail mempunyai lokasi yang tidak selamat dan telah ditolak.';
    case FdamErrorCode.databaseError:
      return en
          ? 'Local asset records could not be saved.'
          : 'Rekod aset tempatan tidak dapat disimpan.';
    case FdamErrorCode.versionConflict:
      return en
          ? 'This asset list needs a newer version of the app.'
          : 'Senarai aset ini memerlukan versi aplikasi yang lebih baharu.';
    case FdamErrorCode.cancelled:
      return en ? 'Cancelled.' : 'Dibatalkan.';
    case FdamErrorCode.unknown:
      return en ? 'An unexpected error occurred.' : 'Ralat yang tidak dijangka berlaku.';
  }
}
