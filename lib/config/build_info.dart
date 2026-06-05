class MellonBuildInfo {
  static const appVersion = String.fromEnvironment(
    'MELLON_APP_VERSION',
    defaultValue: 'dev',
  );
  static const buildId = String.fromEnvironment(
    'MELLON_BUILD_ID',
    defaultValue: 'dev',
  );
  static const buildTime = String.fromEnvironment(
    'MELLON_BUILD_TIME',
    defaultValue: 'unknown',
  );
  static const gitSha = String.fromEnvironment(
    'MELLON_GIT_SHA',
    defaultValue: 'unknown',
  );
  static const gitDirty = bool.fromEnvironment('MELLON_GIT_DIRTY');

  static Map<String, Object?> get debugFields => const {
    'app_version': appVersion,
    'build_id': buildId,
    'build_time': buildTime,
    'git_sha': gitSha,
    'git_dirty': gitDirty,
  };
}
