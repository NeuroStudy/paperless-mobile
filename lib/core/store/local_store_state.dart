part of 'local_store.dart';

@CopyWith()
@JsonSerializable()
class LocalStoreState {
  const LocalStoreState({
    this.version = 2,
    this.loggedInAppUserId,
    this.readHints = const [],
    required this.globalSettings,
    this.localUserData = const {},
  });
  final int version;
  final String? loggedInAppUserId;
  final List<String> readHints;
  final GlobalSettings globalSettings;
  final Map<String, LocalUserData> localUserData;

  Map<String, dynamic> toJson() => _$LocalStoreStateToJson(this);

  factory LocalStoreState.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 1;
    switch (version) {
      case 1:
        return convertLocalStoreStateV1ToV2(json);
      case 2:
      // v3 adds scan metadata without changing this envelope. Retain its version
      // and raw per-account document_scans for copy-based page recovery.
      case 3:
        return _$LocalStoreStateFromJson(json);
      default:
        throw Exception('Unsupported local store state version: $version');
    }
  }
}
