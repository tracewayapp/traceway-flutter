const String eventException = 'exception';
const String eventMessage = 'traceway.message';
const String eventAction = 'traceway.action';
const String eventNavigation = 'browser.navigation';

/// A tap, under the browser SDK's name so the dashboard shows it the same.
const String eventClick = 'browser.user_action.click';
const String eventSessionStart = 'session.start';
const String eventSessionEnd = 'session.end';
const String eventSessionUpdate = 'traceway.session.update';
const String eventTriggerFired = 'traceway.trigger.fired';
const String eventCaptureStarted = 'traceway.capture.started';
const String eventConfigApplied = 'traceway.config.applied';

const String attrSessionId = 'session.id';
const String attrSessionStartedAt = 'traceway.session.started_at';
const String attrExceptionId = 'traceway.exception.id';
const String attrReplayStatus = 'traceway.replay.status';

/// `control` records describe the SDK itself (sessions, triggers, config) and
/// are always sent.
const String signalControl = 'control';

const Set<String> _controlEvents = {
  eventSessionStart,
  eventSessionEnd,
  eventSessionUpdate,
  eventTriggerFired,
  eventCaptureStarted,
  eventConfigApplied,
  'traceway.collection.health',
};

/// Maps a log record's event name to the signal whose settings govern it.
/// Event names are shared with the browser SDK so the backend and the
/// settings schema treat both the same.
String classifyLog(String? eventName) {
  switch (eventName) {
    case eventException:
      return 'errors';
    case eventMessage:
      return 'messages';
    case 'browser.console':
    case null:
    case '':
      return 'console';
    case eventNavigation:
      return 'navigation';
    case eventClick:
      return 'userActions';
    case 'browser.web_vital':
      return 'webVitals';
    case 'browser.resource_timing':
    case 'browser.navigation_timing':
      return 'resourceTiming';
  }
  return _controlEvents.contains(eventName) ? signalControl : 'custom';
}

const Map<String, int> _severityNumbers = {
  'trace': 1,
  'debug': 5,
  'info': 9,
  'warn': 13,
  'error': 17,
  'fatal': 21,
};

int severityNumberOf(String severity) => _severityNumbers[severity] ?? 0;
