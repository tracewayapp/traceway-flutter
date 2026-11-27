#!/usr/bin/env python3
"""End-to-end check of the SDK against a running Traceway server.

Starts the scripted example app (example/lib/e2e_main.dart), follows its
E2E_PHASE lines and asserts through the dashboard API what the server holds
at each point:

  1. before the exception: breadcrumbs, taps included, are NOT on the server
     (ring buffer); the session is
  2. after it: the issue, its breadcrumbs, the tap with the selector of the
     widget, the HTTP span, the session and a replay clip no longer than the
     recorder's frame buffer
  3. a recording trigger from the app's local settings (navigation
     /users/{id}, a tap on #open-profile, a log line) starts a capture:
     the session lists the trigger as a recording reason, logs stream while
     it runs and not after, and the session gets consecutive video segments
  4. a capture started from the dashboard API: its lookback comes up, logs
     and video stream, and cancelling it stops both
  5. a remote rule whose click step is the selector the server recorded for
     a tap: the server accepts it and the app matches it on the next tap
  6. the app saves its buffer going to the background and is killed; the
     next start resumes the session and its first error brings up what the
     killed run had buffered
  8. (with --otelcol) Traceway plus another OpenTelemetry backend: an
     OpenTelemetry Collector receives the logs, taps, request span and
     metrics; Traceway keeps the issue, its replay clip and the session, and
     none of the breadcrumbs
  9. (with --otelcol) standalone, without a connection string: the
     collector receives everything, the exception included, and Traceway
     nothing
  7. (checked before 6) the app's performance arrives as client metrics:
     cold start, screen display times, slow and frozen frames, a hang, the
     unhandled error, session, user, requests and app-defined metrics; the
     project's default Flutter Performance dashboard exists and its widgets
     chart them

  python3 tool/e2e/run.py --base http://127.0.0.1:8082 --email .. --password .. \\
      [--storage <backend STORAGE_PATH>] [--otelcol <otelcol binary>] -- <app command>

On Android install a profile APK built from lib/e2e_main.dart with the DSN
pointing to 127.0.0.1 on the backend port. Use --android SERIAL in place of
the app command. The harness clears the example app's data for fresh installs,
preserves it across restart scenarios and forwards the local test ports.

The app must be built with TRACEWAY_DSN pointing at a Flutter project of that
account. Needs ffprobe on PATH to inspect the clips. With --storage (a local
storage backend) every stored segment is checked on its own.
"""
import argparse, base64, datetime, glob, json, os, shutil, subprocess, sys, tempfile, threading, time
import urllib.error, urllib.parse, urllib.request

from android import AndroidApp

FPS = 15
MAX_CLIP_SECONDS = 10.5  # 150 frames at 15 fps, plus rounding
JOURNEY_CAPTURE_SECONDS = 30
DEFAULT_STATE_DIR = os.path.expanduser('~/.local/share/com.example.traceway_example/traceway_v2')


class Api:
    def __init__(self, base, email, password, project_name):
        self.base = base.rstrip('/')
        self.jwt = None
        _, body = self.call('POST', '/api/login', {'email': email, 'password': password}, project=False)
        self.jwt = body['token']
        flutter = [p for p in body['projects'] if p['framework'] == 'flutter'
                   and (not project_name or p['name'] == project_name)]
        if not flutter:
            sys.exit('no flutter project in this account')
        self.project = flutter[0]

    def call(self, method, path, body=None, project=True):
        url = self.base + path
        if project:
            url += ('&' if '?' in url else '?') + 'projectId=' + self.project['id']
        headers = {'Content-Type': 'application/json'}
        if self.jwt:
            headers['Authorization'] = 'Bearer ' + self.jwt
        req = urllib.request.Request(url, method=method, headers=headers,
                                     data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors='replace')[:400]

    def page(self, path, since, extra=None):
        now = datetime.datetime.now(datetime.timezone.utc)
        size = 500 if path == '/api/logs' else 100
        body = {'fromDate': since.isoformat(), 'toDate': (now + datetime.timedelta(minutes=5)).isoformat(),
                'pagination': {'page': 1, 'pageSize': size}}
        body.update(extra or {})
        status, data = self.call('POST', path, body)
        if status != 200:
            sys.exit(f'{path} -> {status} {data}')
        return data['data'] or []


class Check:
    def __init__(self):
        self.failed = 0

    def __call__(self, ok, what, detail=''):
        print(('  PASS  ' if ok else '  FAIL  ') + what + (f'   [{detail}]' if detail else ''))
        if not ok:
            self.failed += 1
        return ok


def event_name(record):
    return (record.get('logAttributes') or {}).get('event.name') or ''


def attrs(record):
    return record.get('logAttributes') or {}


def snapshot(api, since, instance):
    logs = [r for r in api.page('/api/logs', since)
            if (r.get('resourceAttributes') or {}).get('service.instance.id') == instance]
    names = {}
    for r in logs:
        names.setdefault(event_name(r) or '(console)', []).append(r)
    spans = api.page('/api/spans/search', since)
    issues = api.page('/api/exception-stack-traces', since, {'orderBy': 'last_seen'})
    sessions = [s for s in api.page('/api/sessions', since)
                if (s.get('attributes') or {}).get('service.instance.id') == instance]
    return names, spans, issues, sessions


def bodies(names):
    return [r.get('body') for r in names.get('(console)', [])]


def parse_time(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))


def probe(data_b64):
    path = os.path.join(tempfile.mkdtemp(prefix='traceway-e2e-'), 'clip.mp4')
    with open(path, 'wb') as f:
        f.write(base64.b64decode(data_b64))
    out = json.loads(subprocess.run(
        ['ffprobe', '-v', 'error', '-count_frames', '-show_entries',
         'format=duration:stream=codec_name,width,height,nb_read_frames', '-of', 'json', path],
        capture_output=True, text=True).stdout or '{}')
    stream = (out.get('streams') or [{}])[0]
    return path, stream.get('codec_name'), int(stream.get('nb_read_frames') or 0), \
        float((out.get('format') or {}).get('duration') or 0), stream


def stored_segments(storage, project_id, session_id):
    """Every segment the server stored for a session, by index."""
    if not storage:
        return None
    out = {}
    for path in glob.glob(os.path.join(storage, '**', 'sessions', session_id, '*.json'), recursive=True):
        if project_id not in path:
            continue
        with open(path) as f:
            out[int(os.path.basename(path)[:-5])] = json.load(f)
    return dict(sorted(out.items()))


COLLECTOR_PORT = 4318


class Echo:
    """An HTTP server that answers 200 and keeps the traceparent of every request, by path and query."""

    def __init__(self):
        import http.server
        seen = self.seen = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen[self.path] = self.headers.get('traceparent')
                self.send_response(200)
                self.send_header('Content-Length', '2')
                self.end_headers()
                self.wfile.write(b'ok')

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}'

    def stop(self):
        self.server.shutdown()


class Collector:
    """A real OpenTelemetry Collector (otelcol) with an OTLP/HTTP receiver
    that writes what it receives to JSON-lines files, one per signal."""

    def __init__(self, binary):
        self.dir = tempfile.mkdtemp(prefix='traceway-e2e-otelcol-')
        config = os.path.join(self.dir, 'config.yaml')
        with open(config, 'w') as f:
            f.write(f'''receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:{COLLECTOR_PORT}
exporters:
''' + ''.join(f'''  file/{k}:
    path: {self.dir}/{k}.jsonl
    flush_interval: 100ms
''' for k in ('logs', 'traces', 'metrics')) + '''service:
  telemetry:
    metrics:
      level: none
  pipelines:
''' + ''.join(f'''    {k}:
      receivers: [otlp]
      exporters: [file/{k}]
''' for k in ('logs', 'traces', 'metrics')))
        self.log = open(os.path.join(self.dir, 'otelcol.log'), 'w')
        self.proc = subprocess.Popen([binary, '--config', config], stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                urllib.request.urlopen(urllib.request.Request(
                    f'http://127.0.0.1:{COLLECTOR_PORT}/v1/logs', data=b'{}',
                    headers={'Content-Type': 'application/json'}), timeout=2)
                break
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.3)
        else:
            sys.exit('otelcol did not start: ' + open(self.log.name).read()[-2000:])

    @property
    def url(self):
        return f'http://127.0.0.1:{COLLECTOR_PORT}'

    def read(self, kind):
        path = os.path.join(self.dir, f'{kind}.jsonl')
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]

    @staticmethod
    def _attrs(items):
        out = {}
        for a in items or []:
            v = a.get('value') or {}
            out[a['key']] = next(iter(v.values()), None) if v else None
        return out

    def logs(self):
        """(resource attributes, record attributes, event name, body) of every log record."""
        return [(self._attrs(rl.get('resource', {}).get('attributes')), self._attrs(r.get('attributes')),
                 r.get('eventName') or '', (r.get('body') or {}).get('stringValue'))
                for req in self.read('logs') for rl in req.get('resourceLogs', [])
                for sl in rl.get('scopeLogs', []) for r in sl.get('logRecords', [])]

    def spans(self):
        return [(self._attrs(rs.get('resource', {}).get('attributes')), self._attrs(sp.get('attributes')), sp.get('name'),
                 sp.get('traceId'), sp.get('spanId'))
                for req in self.read('traces') for rs in req.get('resourceSpans', [])
                for ss in rs.get('scopeSpans', []) for sp in ss.get('spans', [])]

    def metrics(self, skip=0):
        """(resource attributes, name) of every metric, past the first [skip] requests. Metric
        resources name no installation, by design, so a run is told apart by when they arrived."""
        return [(self._attrs(rm.get('resource', {}).get('attributes')), m.get('name'))
                for req in self.read('metrics')[skip:] for rm in req.get('resourceMetrics', [])
                for sm in rm.get('scopeMetrics', []) for m in sm.get('metrics', [])]

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()


def check_other_backend(api, check, collector, echo, launch, wait_phase, state_dir, scenario):
    """Phases 8 and 9: telemetry to an OpenTelemetry Collector. Each runs as a
    fresh installation, so its records are told apart by its instance id."""
    if state_dir and os.path.isdir(state_dir):
        shutil.rmtree(state_dir)
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=2)
    issues_before = {i.get('id') or i.get('exceptionHash') for i in
                     api.page('/api/exception-stack-traces', since - datetime.timedelta(hours=1), {'orderBy': 'last_seen'})}
    metric_requests_before = len(collector.read('metrics'))
    launch(scenario, {'E2E_COLLECTOR': collector.url, 'E2E_ECHO': echo.url})
    instance = wait_phase('start', 90).split('instance=')[1]
    session = wait_phase('telemetry_sent', 90).split('session=')[1]
    wait_phase('done', 90)
    time.sleep(8)  # the collector flushes its files, the server writes in batches
    mine = lambda rows: [r for r in rows if r[0].get('service.instance.id') == instance]
    logs, spans = mine(collector.logs()), mine(collector.spans())
    metrics = collector.metrics(metric_requests_before)
    names, tw_spans, issues, sessions = snapshot(api, since, instance)
    log_line = f'e2e {scenario} log'
    event = f'e2e_{scenario}_event'
    boom = f'StateError: Bad state: e2e {scenario} boom'
    # Each scenario runs as a fresh installation: every log record of this instance belongs to this run, so the
    # checks below look at all of them, not only the ones that name the session.
    run_logs = logs
    collector_events = {r[2] for r in run_logs}

    check(any(r[3] == log_line for r in run_logs), 'the collector received the print() line')
    check(event in collector_events, 'the collector received the tracked event')
    check('browser.user_action.click' in collector_events, 'the collector received the tap')
    without = [r[2] or r[3] for r in run_logs if r[1].get('session.id') != session]
    check(run_logs and not without, 'every record in the collector carries the session id',
          f'{len(run_logs)} records, without: {without[:5]}')
    request = [s for s in spans if s[2] == 'GET' and f'has-organizations?{scenario}' in str(s[1].get('url.full'))]
    check(len(request) == 1, 'the collector received the HTTP client span', f'{len(spans)} spans')
    metric_names = {m[1] for m in metrics}
    check({f'e2e.{scenario}', 'app.session', 'app.crash', 'app.start.duration'} <= metric_names,
          'the collector received the metrics: the cold start, the session, the unhandled error', f'{sorted(metric_names)}')
    check(all(m[0].get('traceway.metrics') == 'aggregated' and 'service.instance.id' not in m[0] for m in metrics),
          'metric resources carry no installation id')
    now = datetime.datetime.now(datetime.timezone.utc)
    status, body = api.call('POST', '/api/metrics/query', {
        'queries': [{'name': f'e2e.{scenario}', 'aggregation': 'sum'}],
        'from': since.replace(second=0, microsecond=0).isoformat(),
        'to': (now + datetime.timedelta(minutes=2)).isoformat(), 'wholeRange': True})
    series = ((body or {}).get('results') or [{}])[0].get('series') or {} if isinstance(body, dict) else {}
    check(status == 200 and not any(series.values()), 'Traceway received none of these metrics', f'{status} {series}')
    header = echo.seen.get(f'/checkout?{scenario}') or ''
    echoed = [s for s in spans if s[1].get('url.full') == f'{echo.url}/checkout?{scenario}']
    check(len(echoed) == 1 and header == f'00-{echoed[0][3]}-{echoed[0][4]}-01',
          'the request carried a traceparent naming the span the collector received', header)
    check(f'/other?{scenario}' in echo.seen and echo.seen[f'/other?{scenario}'] is None,
          'a request to a URL that is not selected got no traceparent')
    check(not [s for s in spans if str(s[1].get('url.full', '')).startswith(collector.url)],
          'the SDK did not record its requests to the collector')
    check(log_line not in bodies(names) and event not in names, 'Traceway received none of these breadcrumbs')
    check(not [s for s in tw_spans if f'has-organizations?{scenario}' in json.dumps(s)],
          'Traceway received no request span')

    new_issues = [i for i in issues if (i.get('id') or i.get('exceptionHash')) not in issues_before]
    in_collector = [r for r in run_logs if r[2] == 'exception']
    if scenario == 'external':
        leaked = collector_events & {'exception', 'traceway.message', 'session.start', 'session.end',
                                     'traceway.session.update', 'traceway.trigger.fired',
                                     'traceway.capture.started', 'traceway.config.applied'}
        check(not leaked, 'the exception, session and control records did not go to the collector',
              f'{sorted(leaked)}')
        exceptions = [r for r in names.get('exception', []) if attrs(r).get('session.id') == session]
        check(len(exceptions) == 1, 'Traceway received the exception', f'{len(exceptions)}')
        check(any(s['id'] == session for s in sessions), 'Traceway has the session')
        exception_id = attrs(exceptions[0]).get('traceway.exception.id') if exceptions else None
        status, detail = api.call('POST', f'/api/exception-stack-traces/by-id/{exception_id}', {})
        detail = detail if isinstance(detail, dict) else {}
        check(status == 200 and (detail.get('exception') or {}).get('stackTrace', '').startswith(boom),
              'the issue has its stack trace', f'{status}')
        events = (detail.get('sessionRecording') or {}).get('events') or []
        check(len(events) == 1 and events[0].get('type') == 'flutter_video',
              'the replay clip went to Traceway\'s recordings endpoint')
        if events:
            _, codec, frames, duration, _ = probe(events[0]['data'])
            check(codec == 'h264' and frames > 0, 'the clip is a playable H.264 MP4', f'{codec} {frames} frames')
        return {'session': session, 'issue': exception_id}
    check(len(in_collector) == 1 and str(in_collector[0][1].get('exception.stacktrace', '')).startswith(boom),
          'the collector received the exception with its stack trace')
    check(not {'session.start', 'session.end', 'traceway.session.update'} & collector_events,
          'no Traceway session records were sent')
    check(not new_issues and not [r for r in names.get('exception', []) if attrs(r).get('session.id') == session],
          'Traceway received no issue', f'{len(new_issues)} new')
    check(not any(s['id'] == session for s in sessions), 'Traceway has no session for the standalone run')
    check(not names, 'Traceway received no record at all from the standalone run', f'{sorted(names)}')
    return {'session': session}


def check_metrics(api, since, check):
    """Phase 7: the app's performance as client metrics, and the project's default dashboard."""
    print('\n[7] performance metrics and the Flutter Performance dashboard')
    time.sleep(12)  # the server writes client metrics every 10 s

    # The server keeps client metrics per minute, stamped at its start:
    # the range starts on the minute the run began in.
    metrics_since = since.replace(second=0, microsecond=0)

    def metric(query):
        now = datetime.datetime.now(datetime.timezone.utc)
        status, body = api.call('POST', '/api/metrics/query', {
            'queries': [query], 'from': metrics_since.isoformat(),
            'to': (now + datetime.timedelta(minutes=2)).isoformat(), 'wholeRange': True})
        if status != 200:
            return {'_error': f'{status} {body}'}
        series = ((body or {}).get('results') or [{}])[0].get('series') or {}
        return {k: sum(p.get('value') or 0 for p in v) for k, v in series.items() if v}

    def one(name, aggregation, group_by=None):
        q = {'name': name, 'aggregation': aggregation}
        if group_by:
            q['groupBy'] = group_by
        return metric(q)

    def total(series):
        # An ungrouped series is keyed `__all__`.
        return sum(v for k, v in series.items() if k != '_error')

    starts = one('app.start.duration', 'p75', 'start_type')
    cold = starts.get('cold', 0)
    check(100 <= cold <= 20000, 'a cold start was measured, process start to first frame', f'{starts}')
    ttid = one('app.screen.ttid', 'count', 'screen')
    check({'/', '/e2e-detail', '/users/:id'} <= set(ttid), 'time to initial display per screen, ids normalized',
          f'{ttid}')
    ttfd = one('app.screen.ttfd', 'p75', 'screen')
    check(800 <= ttfd.get('/users/:id', 0) <= 3000, 'time to full display of the user page (reported after ~1 s)',
          f'{ttfd}')
    frames = total(one('app.frames.slow.total', 'sum'))
    frozen = total(one('app.frames.frozen', 'sum'))
    check(frames >= 100 and frozen >= 1, 'frames counted, the 800 ms frame among the frozen ones',
          f'{frames:.0f} frames, {frozen:.0f} frozen')
    hangs = total(one('app.hang', 'sum'))
    hang_ms = total(one('app.hang.duration', 'p75'))
    check(hangs >= 1 and 2000 <= hang_ms <= 4000, 'the 2.6 s block is a hang', f'{hangs:.0f} hangs, p75 {hang_ms:.0f} ms')
    crashes = total(one('app.crash', 'sum'))
    check(crashes >= 1, 'the uncaught error counts as an unhandled error', f'{crashes:.0f}')
    sessions_n = total(one('app.session', 'sum'))
    users = total(one('app.user', 'sum'))
    check(sessions_n == 1 and users == 1, 'one session and one user', f'{sessions_n:.0f} sessions, {users:.0f} users')
    affected = one('app.user.affected', 'sum', 'issue')
    check({'crash', 'hang', 'frozen_frames'} <= set(affected), 'the user is counted as affected by each problem',
          f'{affected}')
    hosts = one('app.request.duration', 'count', 'host')
    check(any(h.startswith('127.0.0.1') for h in hosts), 'request durations by host', f'{hosts}')
    checkout = total(one('e2e.checkout', 'p75'))
    cart = total(one('e2e.cart_add', 'sum'))
    check(1100 <= checkout <= 1350 and cart == 3, 'app-defined metrics arrive', f'p75 {checkout:.0f}, count {cart:.0f}')

    status, listing = api.call('GET', '/api/dashboards')
    boards = (listing or {}).get('dashboards') or [] if isinstance(listing, dict) else []
    flutter_board = [b for b in boards if b.get('templateKey') == 'flutter-performance']
    check(len(flutter_board) == 1, 'the project came with the Flutter Performance dashboard',
          f'{[b.get("name") for b in boards]}')
    if flutter_board:
        status, board = api.call('GET', f"/api/dashboards/{flutter_board[0]['id']}")
        widgets = (board or {}).get('widgets') or [] if isinstance(board, dict) else []
        # No session ended (its peak memory is observed then) and a local
        # address has no country.
        expected_empty = {'Peak Memory per Session', 'App Start by Country'}
        empty = []
        for w in widgets:
            config = json.loads(w['config']) if isinstance(w['config'], str) else w['config']
            values = [total(metric({k: v for k, v in src.items() if k in ('name', 'aggregation', 'groupBy')}))
                      for src in config.get('sources', [])]
            if not any(values):
                empty.append(w['title'])
        print(f'        {len(widgets)} widgets, without data: {empty}')
        check(widgets and set(empty) <= expected_empty, 'every widget of the dashboard charts what the app sent',
              f'empty: {sorted(set(empty) - expected_empty)}')



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--email', required=True)
    ap.add_argument('--password', required=True)
    ap.add_argument('--project', default='')
    ap.add_argument('--storage', default='')
    ap.add_argument('--otelcol', default='', help='an otelcol binary: runs phases 8 and 9')
    ap.add_argument('--android', metavar='SERIAL', help='run the installed example E2E APK via adb')
    ap.add_argument('--state-dir', default=DEFAULT_STATE_DIR,
                    help='the app\'s SDK state, cleared so each run starts fresh')
    ap.add_argument('app', nargs=argparse.REMAINDER)
    args = ap.parse_args()
    app_cmd = [a for a in args.app if a != '--']
    if bool(args.android) == bool(app_cmd):
        ap.error('supply either --android SERIAL or an app command after --')
    android = AndroidApp(args.android, args.base) if args.android else None
    if android:
        args.state_dir = None

    api = Api(args.base, args.email, args.password, args.project)
    check = Check()
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=5)
    for rule in (api.call('GET', '/api/sdk-config/rules')[1] or {}).get('data') or []:
        api.call('DELETE', f"/api/sdk-config/rules/{rule['id']}")
    if args.state_dir and os.path.isdir(args.state_dir):
        shutil.rmtree(args.state_dir)

    phases, lines = {}, []
    proc = None
    log_dir = tempfile.mkdtemp(prefix='traceway-e2e-app-')

    def launch(scenario=None, extra_env=None):
        nonlocal proc
        phases.clear()
        env = dict(os.environ)
        env.update(extra_env or {})
        if scenario:
            env['E2E_SCENARIO'] = scenario
        command = android.launch(scenario, extra_env or {}) if android else app_cmd
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                errors='replace', env=env)

        def pump(stream, log):
            for line in stream:
                lines.append(line.rstrip())
                log.write(line)
                log.flush()
                if 'E2E_PHASE ' in line:
                    name = line.split('E2E_PHASE ', 1)[1].strip()
                    phases[name.split(' ')[0]] = (time.time(), name)
                    print('app: ' + name)

        log = open(os.path.join(log_dir, f"app-{scenario or 'main'}.log"), 'a')
        threading.Thread(target=pump, args=(proc.stdout, log), daemon=True).start()

    def stop():
        nonlocal proc
        if proc is not None:
            if android:
                android.force_stop()
            proc.kill()
            proc.wait()
            proc = None

    def wait_phase(name, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if name in phases:
                return phases[name][1]
            if proc.poll() is not None:
                break
            time.sleep(0.2)
        print('\n'.join(lines[-40:]))
        sys.exit(f'app never reached phase {name}')

    try:
        launch()
        instance = wait_phase('start', 90).split('instance=')[1]

        # ---- 1. quiet phase ------------------------------------------------
        wait_phase('breadcrumbs_done', 60)
        time.sleep(6)
        print('\n[1] before the exception: breadcrumbs must still be on the device')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check('exception' not in phases, 'snapshot taken before the exception was thrown')
        check('session.start' in names, 'session.start was sent (control records always stream)')
        for breadcrumb in ('(console)', 'browser.navigation', 'traceway.action', 'e2e_event',
                           'browser.user_action.click'):
            check(breadcrumb not in names, f'no {breadcrumb} record on the server yet')
        check(not spans, 'no HTTP span on the server yet', f'{len(spans)} spans')
        check(not issues, 'no issue yet')
        check(len(sessions) == 1, 'the session exists', f'{len(sessions)} sessions')
        check(not any(s.get('hasRecording') for s in sessions), 'no replay uploaded without an exception')

        # ---- 2. the exception ----------------------------------------------
        wait_phase('exception_sent', 120)
        time.sleep(6)  # the server writes recording rows in 2 s batches
        print('\n[2] after the exception: issue, breadcrumbs, tap, span, session and clip')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check(len(names.get('exception', [])) == 1, 'one exception record')
        check('e2e breadcrumb log' in bodies(names), 'print() breadcrumb flushed')
        nav = [(attrs(r).get('navigation.action'), attrs(r).get('url.full')) for r in names.get('browser.navigation', [])]
        check(('push', '/e2e-detail') in nav and ('pop', '/') in nav, 'navigation breadcrumbs flushed', str(nav))
        clicks = names.get('browser.user_action.click', [])
        pay = [attrs(r) for r in clicks if attrs(r).get('app.widget.id') == 'pay']
        check(len(pay) == 1, 'the tap was flushed with the breadcrumbs', f'{len(clicks)} clicks')
        pay = pay[0] if pay else {}
        check(pay.get('browser.css_selector') == 'ElevatedButton#pay' and pay.get('browser.tag_name') == 'ElevatedButton',
              'the tap names the widget', f"{pay.get('browser.css_selector')}")
        check(pay.get('app.widget.text') == 'Pay now' and pay.get('app.screen.name') == '/',
              'the tap carries the shown text and the screen')
        actions = names.get('traceway.action', [])
        check(len(actions) == 1 and attrs(actions[0]).get('traceway.action.data') == '{"step":1}', 'custom action flushed')
        check(len(names.get('e2e_event', [])) == 1, 'tracked event flushed')
        check(len(spans) == 1 and spans[0]['spanKind'] == 3 and spans[0]['name'] == 'GET',
              'HTTP client span flushed', f'{len(spans)} spans')
        check(not [s for s in spans if '/api/otel/' in json.dumps(s) or '/api/recordings' in json.dumps(s)],
              'the SDK did not record its own requests')

        check(len(issues) == 1, 'one issue', f'{len(issues)} issues')
        record = attrs(names['exception'][0]) if names.get('exception') else {}
        exception_id = record.get('traceway.exception.id')
        session_id = record.get('session.id')
        status, detail = api.call('POST', f'/api/exception-stack-traces/by-id/{exception_id}', {})
        check(status == 200, 'the issue is addressable by the SDK-generated exception id', f'{status}')
        detail = detail if isinstance(detail, dict) else {}
        exc = detail.get('exception') or {}
        stack = exc.get('stackTrace', '')
        check(stack.startswith('StateError: Bad state: e2e boom\n') and 'e2e_main.dart' in stack,
              'stack trace has the error line and app frames')
        issue_attrs = exc.get('attributes') or {}
        check(issue_attrs.get('os.name') and issue_attrs.get('user.id') == 'e2e-user'
              and issue_attrs.get('service.instance.id') == instance, 'issue carries device, user and instance attributes')
        check(exc.get('appVersion') == 'e2e-1.0.0', 'issue carries the app version')
        check(detail.get('sessionId') == session_id and sessions and session_id == sessions[0]['id'],
              'issue is linked to the session')
        check(issue_attrs.get('traceway.replay.status') == 'requested', 'replay status is requested')
        recording = detail.get('sessionRecording') or {}
        events = recording.get('events') or []
        check(len(events) == 1 and events[0].get('type') == 'flutter_video', 'the issue has one flutter_video clip')
        if events:
            clip, codec, frames, duration, stream = probe(events[0]['data'])
            print(f"        clip: {clip}  {codec} {stream.get('width')}x{stream.get('height')}  {frames} frames  {duration:.2f}s")
            check(codec == 'h264', 'clip is a playable H.264 MP4')
            # A frame stays on screen until the next one is captured, so a ring of 150 frames taken slower than
            # 15 fps encodes to more video frames: the bound is the clip's length, not the ring's size.
            check(30 <= frames <= MAX_CLIP_SECONDS * FPS, f'clip holds real frames, at most {MAX_CLIP_SECONDS:.1f}s at {FPS} fps',
                  f'{frames}')
            check(0 < duration <= MAX_CLIP_SECONDS, f'clip is not longer than {MAX_CLIP_SECONDS:.1f}s', f'{duration:.2f}s')

        until = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)).isoformat()
        status, timeline = api.call('GET', f"/api/sessions/{session_id}/timeline?from={urllib.parse.quote(since.isoformat())}"
                                           f"&to={urllib.parse.quote(until)}")
        text = json.dumps(timeline)
        check(status == 200 and 'e2e breadcrumb log' in text and '/e2e-detail' in text and 'has-organizations' in text,
              'session timeline shows the log, navigation and network breadcrumbs', f'{status}')
        check('"selector": "ElevatedButton#pay"' in text, 'session timeline shows the tap with its selector')

        # ---- 3. a recording trigger from local settings --------------------
        wait_phase('journey_started', 60)
        journey_started = phases['journey_started'][0]
        time.sleep(12)
        print('\n[3] recording trigger: navigation /users/{id} -> tap #open-profile -> log')
        names, spans, issues, sessions = snapshot(api, since, instance)
        fired = [attrs(r) for r in names.get('traceway.trigger.fired', [])
                 if attrs(r).get('traceway.trigger.id') == 'e2e-open-profile']
        check(len(fired) == 1, 'the trigger fired once', f'{len(fired)}')
        fired = fired[0] if fired else {}
        check(fired.get('traceway.trigger.replay') == 'true' and fired.get('traceway.trigger.name') == 'Open profile',
              'the fired record asks for replay and names the trigger')
        started = [attrs(r) for r in names.get('traceway.capture.started', [])
                   if attrs(r).get('traceway.capture.source') == 'trigger']
        check(len(started) == 1 and started[0].get('traceway.trigger.id') == 'e2e-open-profile',
              'a capture started on the device')
        profile = [attrs(r) for r in names.get('browser.user_action.click', [])
                   if attrs(r).get('app.widget.id') == 'open-profile']
        check(len(profile) == 1 and profile[0].get('browser.css_selector') == 'ElevatedButton#open-profile'
              and profile[0].get('app.screen.name') == '/users/42', 'the journey tap was uploaded with the lookback')
        check(any(b and 'Profile loaded for 42' in b for b in bodies(names)), 'the journey log line was uploaded')
        ticks = [b for b in bodies(names) if b and b.startswith('e2e journey tick')]
        check(not any(str(body).startswith('[FQVE]') for body in bodies(names)),
              'native video encoder diagnostics stay out of app console telemetry')
        check(len(ticks) >= 5, 'logs stream while the capture runs, without an error', f'{len(ticks)} ticks')
        status, session_detail = api.call('POST', f'/api/sessions/{session_id}', {})
        reasons = ((session_detail or {}).get('session') or {}).get('recordingReasons') or [] if isinstance(session_detail, dict) else []
        journey_reason = [r for r in reasons if r.get('triggerId') == 'e2e-open-profile']
        check(bool(journey_reason) and journey_reason[0].get('sequence') ==
              'navigation(/users/{id}) \u2192 click(#open-profile) \u2192 log(Profile loaded)',
              'the session lists the trigger as a recording reason, with its sequence',
              journey_reason[0].get('sequence') if journey_reason else json.dumps(reasons)[:300])

        wait_phase('journey_done', 120)
        time.sleep(8)
        names, spans, issues, sessions = snapshot(api, since, instance)
        ticks = [b for b in bodies(names) if b and b.startswith('e2e journey tick')]
        last_streamed = max([int(t.rsplit(' ', 1)[1]) for t in ticks] or [-1])
        check(JOURNEY_CAPTURE_SECONDS - 6 <= last_streamed <= JOURNEY_CAPTURE_SECONDS + 1,
              'streaming ended with the capture', f'last streamed tick {last_streamed}')
        check('e2e after journey' not in bodies(names), 'logs are buffered again after the capture')
        segments = stored_segments(args.storage, api.project['id'], session_id)
        status, rec = api.call('GET', f"/api/sessions/{session_id}/recording?startedAt={urllib.parse.quote(sessions[0]['startedAt'])}")
        videos = (rec or {}).get('events') or [] if isinstance(rec, dict) else []
        check(len(videos) >= 4, 'the session has the error clip and the streamed segments', f'{len(videos)} videos')
        total = 0.0
        for video in videos:
            _, codec, frames, duration, _ = probe(video['data'])
            total += duration
            if codec != 'h264' or frames == 0:
                check(False, 'every segment is a playable H.264 MP4', f'{codec} {frames}')
                break
        else:
            check(bool(videos), 'every segment is a playable H.264 MP4', f'{total:.1f}s of video')
        if segments is not None:
            journey = [s for i, s in segments.items() if i > 0]
            print(f'        stored segments: {list(segments)}')
            check(all(not s.get('exceptionId') for s in journey), 'streamed segments are not exception clips')
            gaps = [(parse_time(b['startedAt']) - parse_time(a['endedAt'])).total_seconds()
                    for a, b in zip(journey, journey[1:])]
            check(gaps and all(-0.01 <= g <= 0.5 for g in gaps), 'consecutive segments follow each other',
                  ', '.join(f'{g:.2f}s' for g in gaps))
            span = (parse_time(journey[-1]['endedAt']) - parse_time(journey[0]['startedAt'])).total_seconds() if journey else 0
            check(JOURNEY_CAPTURE_SECONDS - 2 <= span <= JOURNEY_CAPTURE_SECONDS + MAX_CLIP_SECONDS + 3,
                  'the segments cover the lookback and the capture', f'{span:.1f}s')

        # ---- 4. a capture from the dashboard -------------------------------
        wait_phase('await_capture', 60)
        print('\n[4] a capture started from the dashboard, then cancelled')
        status, capture = api.call('POST', '/api/sdk-config/captures', {
            'target': {'kind': 'instance', 'value': instance}, 'durationMinutes': 5,
            'lookbackSeconds': 60, 'replay': True, 'label': 'e2e'})
        check(status in (200, 201), 'capture created through the dashboard API', f'{status} {capture if status >= 300 else ""}')
        capture_id = (capture or {}).get('id') if isinstance(capture, dict) else None
        created = time.time()
        time.sleep(20)
        names, spans, issues, sessions = snapshot(api, since, instance)
        remote = [attrs(r) for r in names.get('traceway.capture.started', [])
                  if attrs(r).get('traceway.capture.source') == 'remote']
        check(len(remote) == 1 and remote[0].get('traceway.capture.id') == capture_id, 'the app started the capture',
              f'{len(remote)}')
        check(all(f'e2e pre-capture tick {i}' in bodies(names) for i in range(3)) and 'e2e after journey' in bodies(names),
              'the lookback brought up what was buffered')
        remote_ticks = [b for b in bodies(names) if b and b.startswith('e2e remote tick')]
        check(len(remote_ticks) >= 10, 'logs stream during the capture', f'{len(remote_ticks)}')
        tagged = [r for r in names.get('(console)', []) if capture_id and capture_id in attrs(r).get('traceway.capture.ids', '')]
        check(len(tagged) >= 10, 'streamed records carry the capture id', f'{len(tagged)}')
        status, listing = api.call('GET', '/api/sdk-config/captures')
        mine = [c for c in ((listing or {}).get('data') or []) if c.get('id') == capture_id] if isinstance(listing, dict) else []
        check(bool(mine) and (mine[0].get('status') or '').lower() == 'collecting', 'the dashboard sees the capture collecting',
              mine[0].get('status') if mine else listing)
        status, rec = api.call('GET', f"/api/sessions/{session_id}/recording?startedAt={urllib.parse.quote(sessions[0]['startedAt'])}")
        videos_during = len((rec or {}).get('events') or []) if isinstance(rec, dict) else 0
        check(videos_during >= len(videos) + 2, 'video streams during the capture', f'{len(videos)} -> {videos_during}')

        status, _ = api.call('DELETE', f'/api/sdk-config/captures/{capture_id}')
        check(status in (200, 204), 'capture cancelled', f'{status}')
        cancelled = time.time()
        wait_phase('capture_done', 120)
        time.sleep(8)
        names, spans, issues, sessions = snapshot(api, since, instance)
        remote_ticks = sorted(int(b.rsplit(' ', 1)[1]) for b in bodies(names) if b and b.startswith('e2e remote tick'))
        stopped_at = remote_ticks[-1] if remote_ticks else -1
        print(f'        capture created at t+0, cancelled at t+{cancelled - created:.0f}s, last streamed tick {stopped_at}')
        check(0 < stopped_at < 55, 'streaming stopped after the cancel', f'last tick {stopped_at}')
        status, rec = api.call('GET', f"/api/sessions/{session_id}/recording?startedAt={urllib.parse.quote(sessions[0]['startedAt'])}")
        videos_after = len((rec or {}).get('events') or []) if isinstance(rec, dict) else 0
        time.sleep(12)
        status, rec = api.call('GET', f"/api/sessions/{session_id}/recording?startedAt={urllib.parse.quote(sessions[0]['startedAt'])}")
        videos_later = len((rec or {}).get('events') or []) if isinstance(rec, dict) else 0
        check(videos_later == videos_after, 'no more video after the cancel', f'{videos_after} -> {videos_later}')

        # ---- 5. a rule built from the selector the server recorded ---------
        print('\n[5] a remote rule whose click step is the selector the server recorded')
        selector = pay.get('browser.css_selector') or 'ElevatedButton#pay'
        status, body = api.call('POST', '/api/sdk-config/rules', {
            'name': 'e2e remote click', 'enabled': True, 'conditions': {},
            'settings': {'signals': {'custom': {'mode': 'stream', 'sampleRate': 1}},
                         'triggers': [{'id': 'e2e-remote-pay', 'name': 'Pay tapped',
                                       'steps': [{'match': {'event': {'type': 'click', 'value': selector}}}],
                                       'actions': [{'type': 'emit', 'eventName': 'e2e_paid'}]}]},
        })
        check(status in (200, 201), f'the server accepts the recorded selector {selector!r} in a rule',
              f'{status} {body if status >= 300 else ""}')
        wait_phase('done', 120)
        time.sleep(6)
        names, spans, issues, sessions = snapshot(api, since, instance)
        remote_fired = [r for r in names.get('traceway.trigger.fired', []) if attrs(r).get('traceway.trigger.id') == 'e2e-remote-pay']
        check(len(remote_fired) == 1, 'the app matched the next tap against it', f'{len(remote_fired)}')
        check(len(names.get('e2e_paid', [])) == 1, 'the rule streamed app events', f"{len(names.get('e2e_paid', []))}")
        check(len(names.get('e2e_tick', [])) >= 3, 'tracked events stream without an error')
        check(len(issues) == 1, 'still one issue')

        # ---- 7. metrics and the default dashboard --------------------------
        check_metrics(api, since, check)

        # ---- 6. killed in the background, restarted ------------------------
        print('\n[6] the buffer outlives a kill in the background')
        stop()
        launch('restart-a')
        saved = wait_phase('saved', 90).split('session=')[1]
        time.sleep(3)
        stop()
        names, spans, issues, sessions = snapshot(api, since, instance)
        check('e2e before the kill' not in bodies(names), 'the killed run sent its breadcrumbs nowhere')
        check(saved == session_id, 'the restarted app continued the session', saved)
        launch('restart-b')
        resumed = wait_phase('resumed', 90).split('session=')[1]
        check(resumed == saved, 'the next start resumed the same session', resumed)
        wait_phase('done', 90)
        time.sleep(6)
        names, spans, issues, sessions = snapshot(api, since, instance)
        restored = [r for r in names.get('(console)', []) if r.get('body') == 'e2e before the kill']
        check(len(restored) == 1 and attrs(restored[0]).get('session.id') == saved,
              'its error brought up the log the killed run had buffered', f'{len(restored)}')
        taps = [attrs(r) for r in names.get('browser.user_action.click', []) if attrs(r).get('app.widget.id') == 'pay']
        check(len(taps) == 3, 'and the tap, with its selector', f'{len(taps)} pay taps')
        check(len(issues) == 2, 'the second error is its own issue', f'{len(issues)}')
        stop()

        launch('exit-after-error')
        wait_phase('captured', 90)
        stop()
        launch('recover-error')
        wait_phase('recovered', 90)
        for _ in range(12):
            names, _, _, _ = snapshot(api, since, instance)
            errors = [r for r in names.get('exception', [])
                      if 'e2e exit after capture' in attrs(r).get('exception.message', '')]
            if errors:
                break
            time.sleep(1)
        check(len(errors) == 1, 'the next launch delivers the error captured immediately before process exit')

        stop()

        if args.otelcol:
            collector = Collector(args.otelcol)
            echo = Echo()
            try:
                print(f'\n[8] Traceway plus another OpenTelemetry backend (otelcol at {collector.url})')
                external = check_other_backend(api, check, collector, echo, launch, wait_phase, args.state_dir, 'external')
                stop()
                print(f'\n[9] standalone: no connection string, only the collector')
                check_other_backend(api, check, collector, echo, launch, wait_phase, args.state_dir, 'standalone')
                print(f'        collector output: {collector.dir}')
                summary = {'external': external, 'collectorDir': collector.dir}
                with open(os.path.join(collector.dir, 'summary.json'), 'w') as f:
                    json.dump(summary, f)
            finally:
                collector.stop()
                echo.stop()
    finally:
        stop()
        if android:
            android.close()

    print(f'\napp output: {log_dir}')
    print(f"\n{'ALL CHECKS PASSED' if not check.failed else str(check.failed) + ' CHECK(S) FAILED'}")
    sys.exit(1 if check.failed else 0)


if __name__ == '__main__':
    main()
