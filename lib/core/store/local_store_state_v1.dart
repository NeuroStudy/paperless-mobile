import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:paperless_mobile/api/models/user.dart';
import 'package:paperless_mobile/core/store/local_store.dart';
import 'package:paperless_mobile/core/store/slices/global_settings.dart';
import 'package:paperless_mobile/core/store/slices/local_user_app_state.dart';
import 'package:paperless_mobile/core/store/slices/local_user_data.dart';

part 'local_store_state_v1.g.dart';

@Deprecated(
  'Used for migration purposes. Do not use in the app. Use LocalStoreState instead.',
)
@JsonSerializable(createToJson: false)
class _LocalStoreStateV1 {
  const _LocalStoreStateV1({
    this.loggedInAppUserId,
    this.readHints = const [],
    required this.globalSettings,
    this.localUserData = const {},
  });

  final String? loggedInAppUserId;
  final List<String> readHints;
  final GlobalSettings globalSettings;
  final Map<String, _LocalUserDataV1> localUserData;

  factory _LocalStoreStateV1.fromJson(Map<String, dynamic> json) =>
      _$LocalStoreStateV1FromJson(json);
}

@JsonSerializable(createToJson: false)
class _LocalUserDataV1 {
  final String userId;
  final _LocalUserAccountV1 localUser;
  final bool isBiometricAuthenticationEnabled;
  final LocalUserAppState appState;

  const _LocalUserDataV1({
    required this.userId,
    required this.localUser,
    this.isBiometricAuthenticationEnabled = false,
    this.appState = const LocalUserAppState(),
  });

  factory _LocalUserDataV1.fromJson(Map<String, dynamic> json) =>
      _$LocalUserDataV1FromJson(json);
}

@JsonSerializable(createToJson: false)
class _LocalUserAccountV1 {
  final String appUserId;
  final String serverUrl;
  final User paperlessUser;
  final int apiVersion;
  const _LocalUserAccountV1({
    required this.appUserId,
    required this.serverUrl,
    required this.paperlessUser,
    required this.apiVersion,
  });

  factory _LocalUserAccountV1.fromJson(Map<String, dynamic> json) =>
      _$LocalUserAccountV1FromJson(json);
}

LocalStoreState convertLocalStoreStateV1ToV2(Map<String, dynamic> json) {
  // This is the migration boundary where the deprecated schema is required.
  // ignore: deprecated_member_use_from_same_package
  final oldState = _LocalStoreStateV1.fromJson(json);
  return LocalStoreState(
    globalSettings: oldState.globalSettings,
    version: 2,
    loggedInAppUserId: oldState.loggedInAppUserId,
    readHints: oldState.readHints,
    localUserData: {
      for (final entry in oldState.localUserData.entries)
        entry.key: LocalUserData(
          userId: entry.value.userId,
          serverUrl: entry.value.localUser.serverUrl,
          username: entry.value.localUser.paperlessUser.username,
          firstName: entry.value.localUser.paperlessUser.firstName,
          lastName: entry.value.localUser.paperlessUser.lastName,
          isBiometricAuthenticationEnabled:
              entry.value.isBiometricAuthenticationEnabled,
          appState: entry.value.appState,
        ),
    },
  );
}
