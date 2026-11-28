import 'dart:io' show Platform;

/// The launch settings of 02-APP-SPEC.md §6, read before anything else.
///
/// Linux passes them as environment variables (`FM_RUN`, `FM_VARIANT`, ...).
/// Android passes intent extras, which `MainActivity` turns into Dart
/// entrypoint arguments (`--fmRun=...`): a method channel would need the
/// binding before `Traceway.run`, and the SDK then skips its zone and no
/// longer sees `print` lines.
class LaunchSettings {
  const LaunchSettings({
    required this.run,
    required this.variant,
    required this.scenario,
    required this.baseUrl,
    required this.fixtures,
    required this.token,
    required this.evidence,
    required this.fps,
    required this.remote,
    required this.autopilot,
    required this.target,
    required this.campaign,
    required this.journeyPath,
    required this.crashExit,
    required this.probeDir,
    this.sessionIdleMs,
    this.sessions = true,
  });

  final String run;
  final String variant;
  final String? scenario;
  final String baseUrl;
  final String fixtures;
  final String token;
  final bool evidence;
  final int? fps;
  final bool remote;
  final bool autopilot;

  /// `fm.target`, e.g. `linux-xvfb` or `android-emulator`.
  final String target;
  final String campaign;

  /// A journey file to read instead of the bundled asset (Linux only).
  final String? journeyPath;

  /// `fm-diag-unhandled` ends the process with `exit(1)` after the error.
  final bool crashExit;

  /// Where the probe writes its file; the platform default when null.
  final String? probeDir;

  /// The SDK's session inactivity timeout instead of 15 minutes, so a
  /// harness can let a killed app's session expire and launch the app
  /// again within a run.
  final int? sessionIdleMs;

  /// `fmSessions=0`: the SDK reports no session of this launch. The
  /// harness's launch after a kill uses it, so the run keeps one session.
  final bool sessions;

  static const _names = {
    'fmRun': 'FM_RUN',
    'fmVariant': 'FM_VARIANT',
    'fmScenario': 'FM_SCENARIO',
    'fmBaseUrl': 'FM_BASE_URL',
    'fmFixtures': 'FM_FIXTURES',
    'fmToken': 'FM_TOKEN',
    'fmEvidence': 'FM_EVIDENCE',
    'fmFps': 'FM_FPS',
    'fmRemote': 'FM_REMOTE',
    'fmAutopilot': 'FM_AUTOPILOT',
    'fmTarget': 'FM_TARGET',
    'fmCampaign': 'FM_CAMPAIGN',
    'fmJourney': 'FM_JOURNEY',
    'fmCrashExit': 'FM_CRASH_EXIT',
    'fmProbeDir': 'FM_PROBE_DIR',
    'fmSessionIdleMs': 'FM_SESSION_IDLE_MS',
    'fmSessions': 'FM_SESSIONS',
  };

  /// Reads `--fmX=value` arguments first, then `FM_X` environment variables.
  factory LaunchSettings.read(List<String> args,
      [Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final fromArgs = <String, String>{};
    for (final arg in args) {
      final m = RegExp(r'^--(fm[A-Za-z]+)=(.*)$').firstMatch(arg);
      if (m != null) fromArgs[m.group(1)!] = m.group(2)!;
    }
    String? get(String name) {
      final v = fromArgs[name] ?? env[_names[name]!];
      return (v == null || v.isEmpty) ? null : v;
    }

    final run = get('fmRun') ?? 'manual';
    return LaunchSettings(
      run: RegExp(r'^[A-Za-z0-9-]+$').hasMatch(run) ? run : 'manual',
      variant: get('fmVariant') ?? 'core',
      scenario: get('fmScenario'),
      baseUrl: get('fmBaseUrl') ?? 'http://127.0.0.1:18190',
      fixtures: get('fmFixtures') ?? 'http://127.0.0.1:18190/fx',
      token: get('fmToken') ?? 'flutter-dev-token',
      evidence: get('fmEvidence') == '1',
      fps: int.tryParse(get('fmFps') ?? ''),
      remote: get('fmRemote') == '1',
      autopilot: get('fmAutopilot') == '1',
      target: get('fmTarget') ?? _defaultTarget(),
      campaign: get('fmCampaign') ?? 'manual',
      journeyPath: get('fmJourney'),
      crashExit: get('fmCrashExit') == '1',
      probeDir: get('fmProbeDir'),
      sessionIdleMs: int.tryParse(get('fmSessionIdleMs') ?? ''),
      sessions: get('fmSessions') != '0',
    );
  }

  static String _defaultTarget() {
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    return Platform.operatingSystem;
  }

  /// The `fm.*` resource attributes the SDK is started with.
  Map<String, String> get attributes => {
        'fm.run': run,
        'fm.variant': variant,
        'fm.scenario': scenario ?? 'none',
        'fm.target': target,
        'fm.campaign': campaign,
      };

  @override
  String toString() =>
      'run=$run variant=$variant scenario=$scenario target=$target '
      'evidence=$evidence autopilot=$autopilot fps=$fps remote=$remote'
      '${sessionIdleMs == null ? '' : ' sessionIdleMs=$sessionIdleMs'}'
      '${sessions ? '' : ' sessions=off'}';
}
