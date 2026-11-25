/// Official iOS release versions, following RepoPocket's AppVersion rules.
///
/// Components are padded to four entries, so 2.0.9 and 2.0.9.0 compare equally.
/// Parsing retains prereleases; the official-update comparison rejects them.
class OfficialAppVersion {
  OfficialAppVersion._(
    this.components,
    this.normalized,
    this.core,
    this.isPrerelease,
    this.build,
  );

  final List<int> components;
  final String normalized;
  final String core;
  final bool isPrerelease;
  final int? build;

  static OfficialAppVersion? tryParse(String value) {
    final raw = value.startsWith('ios-v')
        ? value.substring(5)
        : value.startsWith('v') || value.startsWith('V')
        ? value.substring(1)
        : value;
    final metadata = raw.split('+');
    if (metadata.length > 2) return null;
    final separator = metadata.first.indexOf('-');
    final core = separator < 0
        ? metadata.first
        : metadata.first.substring(0, separator);
    final numbers = core.split('.');
    if (numbers.length < 3 || numbers.length > 4) return null;
    final components = <int>[];
    for (final number in numbers) {
      if (!_matches(r'[0-9]+', number) ||
          (number.length > 1 && number.startsWith('0'))) {
        return null;
      }
      // Swift Int on the reference iOS target is a signed 64-bit integer.
      final component = int.tryParse(number, radix: 10);
      if (component == null || component < 0) return null;
      components.add(component);
    }
    final prerelease = separator < 0
        ? <String>[]
        : metadata.first.substring(separator + 1).split('.');
    final identifiers = [
      ...prerelease,
      if (metadata.length == 2) ...metadata[1].split('.'),
    ];
    if (identifiers.any((part) => !_matches(r'[0-9A-Za-z-]+', part))) {
      return null;
    }
    for (final part in prerelease) {
      if (_integer(part) != null &&
          part.length > 1 &&
          part.startsWith('0')) {
        return null;
      }
    }
    final build = metadata.length == 2 ? _integer(metadata[1]) : null;
    if (build != null && build < 0) return null;
    return OfficialAppVersion._(
      List<int>.unmodifiable([
        ...components,
        if (components.length == 3) 0,
      ]),
      raw,
      core,
      prerelease.isNotEmpty,
      build,
    );
  }
}

/// Compares official releases without treating missing build data as an update.
///
/// Numeric version metadata takes priority over the separate build fields.
/// Invalid version strings, prereleases and negative explicit builds throw.
/// An unparseable installed bundle build is unknown, not build zero.
bool isNewerOfficialVersion({
  required String remoteVersion,
  int? remoteBuild,
  required String installedVersion,
  required String installedBuild,
}) {
  final remote = OfficialAppVersion.tryParse(remoteVersion);
  final installed = OfficialAppVersion.tryParse(installedVersion);
  if (remote == null ||
      installed == null ||
      remote.isPrerelease ||
      installed.isPrerelease ||
      (remoteBuild != null && remoteBuild < 0)) {
    throw const FormatException('Invalid or non-official release version');
  }
  for (var i = 0; i < 4; i++) {
    if (remote.components[i] != installed.components[i]) {
      return remote.components[i] > installed.components[i];
    }
  }
  final remoteRevision = remote.build ?? remoteBuild;
  final localRevision = installed.build ?? _integer(installedBuild);
  if (remoteRevision == null || localRevision == null || localRevision < 0) {
    return false;
  }
  return remoteRevision > localRevision;
}

bool _matches(String pattern, String value) {
  final match = RegExp(pattern).matchAsPrefix(value);
  return match != null && match.end == value.length;
}

int? _integer(String value) => _matches(r'[+-]?[0-9]+', value)
    ? int.tryParse(value, radix: 10)
    : null;
