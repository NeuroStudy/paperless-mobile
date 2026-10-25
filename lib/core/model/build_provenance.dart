/// Populated by scripts/build_alpha2_apk.ps1 for traceable verification APKs.
const buildGitRevision = String.fromEnvironment('BUILD_GIT_SHA');
const buildSourceBranch = String.fromEnvironment('BUILD_SOURCE_BRANCH');

String get buildRevisionLabel => buildGitRevision.isEmpty
    ? 'unrecorded build'
    : buildGitRevision.substring(0, buildGitRevision.length.clamp(0, 10));
