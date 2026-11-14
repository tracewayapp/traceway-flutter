#!/usr/bin/env python3
"""End-to-end check of the SDK against a running Traceway server.

Starts the scripted example app (example/lib/e2e_main.dart), follows its
E2E_PHASE lines and asserts through the dashboard API what the server holds
at each point:

  1. before the exception: breadcrumbs are NOT on the server (ring buffer)
  2. after it: the issue, its breadcrumbs, the HTTP span, the session and a
     replay clip no longer than the recorder's frame buffer
  3. after a remote-config rule (OpAMP): app events stream without an error,
     and no further replay is uploaded even though the rule asks to stream it

  python3 tool/e2e/run.py --base http://127.0.0.1:8082 --email .. --password .. -- <app command>

The app must be built with TRACEWAY_DSN pointing at a Flutter project of that
account. Needs ffprobe on PATH to inspect the clip.
"""
import argparse, base64, datetime, json, os, subprocess, sys, tempfile, threading, time
import urllib.error, urllib.request

MAX_CLIP_SECONDS = 10.5  # 150 frames at 15 fps, plus rounding


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
        body = {'fromDate': since.isoformat(), 'toDate': (now + datetime.timedelta(minutes=5)).isoformat(),
                'pagination': {'page': 1, 'pageSize': 100}}
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


def event_name(record):
    return (record.get('logAttributes') or {}).get('event.name') or ''


def snapshot(api, since, instance):
    logs = [r for r in api.page('/api/logs', since)
            if (r.get('resourceAttributes') or {}).get('service.instance.id') == instance]
    names = {}
    for r in logs:
        names.setdefault(event_name(r) or '(console)', []).append(r)
    spans = api.page('/api/spans/search', since)
    issues = api.page('/api/exception-stack-traces', since, {'orderBy': 'last_seen'})
    sessions = api.page('/api/sessions', since)
    return names, spans, issues, sessions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--email', required=True)
    ap.add_argument('--password', required=True)
    ap.add_argument('--project', default='')
    ap.add_argument('app', nargs=argparse.REMAINDER)
    args = ap.parse_args()
    app_cmd = [a for a in args.app if a != '--']
    if not app_cmd:
        sys.exit('pass the app command after --')

    api = Api(args.base, args.email, args.password, args.project)
    check = Check()
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=5)
    for rule in (api.call('GET', '/api/sdk-config/rules')[1] or {}).get('data') or []:
        api.call('DELETE', f"/api/sdk-config/rules/{rule['id']}")

    phases, lines = {}, []
    proc = subprocess.Popen(app_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')

    def pump():
        for line in proc.stdout:
            lines.append(line.rstrip())
            if 'E2E_PHASE ' in line:
                name = line.split('E2E_PHASE ', 1)[1].strip()
                phases[name.split(' ')[0]] = (time.time(), name)
                print('app: ' + name)

    threading.Thread(target=pump, daemon=True).start()

    def wait_phase(name, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if name in phases:
                return phases[name][1]
            if proc.poll() is not None:
                break
            time.sleep(0.2)
        print('\n'.join(lines[-30:]))
        proc.kill()
        sys.exit(f'app never reached phase {name}')

    try:
        instance = wait_phase('start', 90).split('instance=')[1]

        # ---- 1. quiet phase ------------------------------------------------
        wait_phase('breadcrumbs_done', 60)
        time.sleep(8)
        print('\n[1] before the exception: breadcrumbs must still be on the device')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check('exception' not in phases, 'snapshot taken before the exception was thrown')
        check('session.start' in names, 'session.start was sent (control records always stream)')
        for breadcrumb in ('(console)', 'browser.navigation', 'traceway.action', 'e2e_event'):
            check(breadcrumb not in names, f'no {breadcrumb} record on the server yet')
        check(not spans, 'no HTTP span on the server yet', f'{len(spans)} spans')
        check(not issues, 'no issue yet')
        session_rows = [s for s in sessions if (s.get('attributes') or {}).get('service.instance.id') == instance]
        check(len(session_rows) == 1, 'the session exists', f'{len(session_rows)} sessions')
        check(not any(s.get('hasRecording') for s in session_rows), 'no replay uploaded without an exception')

        # ---- 2. the exception ----------------------------------------------
        wait_phase('exception_sent', 120)
        time.sleep(6)  # the server writes recording rows in 2 s batches
        print('\n[2] after the exception: issue, breadcrumbs, span, session and clip')
        names, spans, issues, sessions = snapshot(api, since, instance)
        check(len(names.get('exception', [])) == 1, 'one exception record')
        console = [r.get('body') for r in names.get('(console)', [])]
        check('e2e breadcrumb log' in console, 'print() breadcrumb flushed', f'{len(console)} console records')
        nav = [(r['logAttributes'].get('navigation.action'), r['logAttributes'].get('url.full'))
               for r in names.get('browser.navigation', [])]
        check(('push', '/e2e-detail') in nav, 'navigation breadcrumb flushed', str(nav))
        actions = names.get('traceway.action', [])
        check(len(actions) == 1 and actions[0]['logAttributes'].get('traceway.action.name') == 'tap'
              and actions[0]['logAttributes'].get('traceway.action.data') == '{"step":1}', 'custom action flushed')
        check(len(names.get('e2e_event', [])) == 1, 'tracked event flushed')
        check('traceway.trigger.fired' in names, 'traceway.trigger.fired recorded')
        check(len(spans) == 1 and spans[0]['spanKind'] == 3 and spans[0]['name'] == 'GET',
              'HTTP client span flushed', f'{len(spans)} spans')
        check(not [s for s in spans if '/api/otel/' in json.dumps(s) or '/api/recordings' in json.dumps(s)],
              'the SDK did not record its own requests')

        check(len(issues) == 1, 'one issue', f'{len(issues)} issues')
        record = names['exception'][0]['logAttributes'] if names.get('exception') else {}
        exception_id = record.get('traceway.exception.id')
        session_id = record.get('session.id')
        status, detail = api.call('POST', f'/api/exception-stack-traces/by-id/{exception_id}', {})
        check(status == 200, 'the issue is addressable by the SDK-generated exception id', f'{status}')
        detail = detail if isinstance(detail, dict) else {}
        exc = detail.get('exception') or {}
        stack = exc.get('stackTrace', '')
        check(stack.startswith('StateError: Bad state: e2e boom\n') and 'e2e_main.dart' in stack,
              'stack trace has the error line and app frames')
        attrs = exc.get('attributes') or {}
        check(attrs.get('os.name') and attrs.get('user.id') == 'e2e-user' and attrs.get('service.instance.id') == instance,
              'issue carries device, user and instance attributes', f"os.name={attrs.get('os.name')}")
        check(exc.get('appVersion') == 'e2e-1.0.0', 'issue carries the app version')
        check(detail.get('sessionId') == session_id and session_id == session_rows[0]['id'], 'issue is linked to the session')
        check(attrs.get('traceway.replay.status') == 'requested', 'replay status is requested')

        recording = detail.get('sessionRecording') or {}
        events = recording.get('events') or []
        check(len(events) == 1 and events[0].get('type') == 'flutter_video' and events[0].get('format') == 'mp4',
              'the issue has one flutter_video replay clip')
        if events:
            clip = os.path.join(tempfile.mkdtemp(prefix='traceway-e2e-'), 'clip.mp4')
            with open(clip, 'wb') as f:
                f.write(base64.b64decode(events[0]['data']))
            probe = json.loads(subprocess.run(
                ['ffprobe', '-v', 'error', '-count_frames', '-show_entries',
                 'format=duration:stream=codec_name,width,height,nb_read_frames', '-of', 'json', clip],
                capture_output=True, text=True).stdout or '{}')
            stream = (probe.get('streams') or [{}])[0]
            duration = float((probe.get('format') or {}).get('duration') or 0)
            frames = int(stream.get('nb_read_frames') or 0)
            print(f"        clip: {clip}  {stream.get('codec_name')} {stream.get('width')}x{stream.get('height')}"
                  f"  {frames} frames  {duration:.2f}s  ({os.path.getsize(clip)} bytes)")
            check(stream.get('codec_name') == 'h264', 'clip is a playable H.264 MP4')
            check(30 <= frames <= 150, 'clip holds real frames, never more than the 150-frame buffer', f'{frames}')
            check(0 < duration <= MAX_CLIP_SECONDS, f'clip is not longer than {MAX_CLIP_SECONDS:.1f}s', f'{duration:.2f}s')
            check(events[0].get('durationSeconds', 99) <= MAX_CLIP_SECONDS, 'reported durationSeconds within the cap')
            started = datetime.datetime.fromisoformat(recording['startedAt'].replace('Z', '+00:00'))
            ended = datetime.datetime.fromisoformat(recording['endedAt'].replace('Z', '+00:00'))
            check((ended - started).total_seconds() <= MAX_CLIP_SECONDS, 'startedAt..endedAt within the cap',
                  f'{(ended - started).total_seconds():.2f}s')

        status, timeline = api.call('GET', f"/api/sessions/{session_id}/timeline?from={urllib.request.quote(since.isoformat())}"
                                           f"&to={urllib.request.quote((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)).isoformat())}")
        text = json.dumps(timeline)
        check(status == 200 and 'e2e breadcrumb log' in text and '/e2e-detail' in text and 'has-organizations' in text,
              'session timeline shows the log, navigation and network breadcrumbs', f'{status}')
        sessions_now = [s for s in sessions if s['id'] == session_id]
        check(bool(sessions_now) and sessions_now[0].get('hasRecording'), 'the session reports a recording')

        # ---- 3. remote config over OpAMP ------------------------------------
        print('\n[3] remote config: stream app events; a replay "stream" setting must be ignored')
        ticks_before = len(names.get('e2e_tick', []))
        check(ticks_before == 0, 'tracked events are buffered before the rule exists')
        status, body = api.call('POST', '/api/sdk-config/rules', {
            'name': 'e2e stream', 'enabled': True, 'conditions': {},
            'settings': {'signals': {'custom': {'mode': 'stream', 'sampleRate': 1}},
                         'replay': {'mode': 'stream', 'sessionSampleRate': 1}},
        })
        check(status in (200, 201), 'rule created through the dashboard API', f'{status} {body if status >= 300 else ""}')
        time.sleep(40)
        names, spans, issues, sessions = snapshot(api, since, instance)
        applied = names.get('traceway.config.applied', [])
        check(len(applied) >= 2, 'the app applied the new remote config', f'{len(applied)} config.applied records')
        ticks = names.get('e2e_tick', [])
        check(len(ticks) >= 3, 'tracked events now arrive without any exception', f'{len(ticks)} e2e_tick records')
        check('(console)' not in names or all(r.get('body') != 'e2e tick 3' for r in names['(console)']),
              'console logs stay buffered (only custom was switched to stream)')
        status, detail2 = api.call('POST', f'/api/exception-stack-traces/by-id/{exception_id}', {})
        status, rec = api.call('GET', f"/api/sessions/{session_id}/recording?startedAt={urllib.request.quote(sessions_now[0]['startedAt'])}")
        rec_events = (rec or {}).get('events') if isinstance(rec, dict) else None
        check(status == 200 and rec_events is not None and len(rec_events) == 1,
              'still exactly one replay clip for the session: nothing streamed',
              f'{status} {len(rec_events) if rec_events is not None else rec}')
        check(len(issues) == 1, 'still one issue')
    finally:
        proc.kill()

    print(f"\n{'ALL CHECKS PASSED' if not check.failed else str(check.failed) + ' CHECK(S) FAILED'}")
    sys.exit(1 if check.failed else 0)


if __name__ == '__main__':
    main()
