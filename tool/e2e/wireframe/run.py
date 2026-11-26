#!/usr/bin/env python3
"""Regression suite for wireframe session replay.

Runs the suite app (example/lib/wireframe_suite/main.dart), which records
itself with TracewayScreenCaptureMode.wireframe while it drives itself
through every scenario with real pointer events, then checks the recording:

  1. structure: rrweb events in time order, a meta event and full snapshot
     first, mutations, touches and drags;
  2. every mutation applies, played through a strict model of rrweb's
     replayer (a node added twice, a missing parent or sibling fails);
  3. at every checkpoint the replayed page shows the texts the scenario
     expects and none it must hide; no secret appears anywhere in the
     recording; animations recorded at least the mutations they asked for;
  4. visual (replay.mjs, in Playwright): rrweb-player renders every
     checkpoint, which is compared with the picture the app took of itself
     at that moment (fidelity: SSIM, edge alignment, color) and with the
     accepted baseline rendering (pixel changes);
  5. size: the bytes each scenario recorded, against the baseline.

Fidelity and size are compared with the baseline in baseline/<platform>-
<size>/; --update-baseline accepts the run as the new baseline.

  # Self-contained: a local collector stands in for Traceway.
  python3 tool/e2e/wireframe/run.py --build

  # Against a running Traceway, plus its dashboard's player:
  python3 tool/e2e/wireframe/run.py --base http://127.0.0.1:8082 \\
      --dsn flutter-dev-token@http://127.0.0.1:8082 \\
      --email admin@localhost.com --password admin --project "Flutter App" \\
      --dashboard http://localhost:5173

  --only forms,overlays   runs those scenarios (plus nothing else)
  --out DIR               where the run's files and report.html go

On Hyprland the app's window is floated and sized like a phone (--size,
400x680 by default, which fits a 800 px high screen with bars).
"""
import argparse, gzip, html, http.server, json, os, platform, shutil, struct, subprocess, sys
import threading, time, urllib.error, urllib.request, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
EXAMPLE = os.path.join(REPO, 'example')
SAMPLE_MS = 150  # the replay is sampled this long after a checkpoint


class Check:
    def __init__(self):
        self.failures = []

    def __call__(self, ok, what, detail=''):
        print(('  PASS  ' if ok else '  FAIL  ') + what + (f'   [{detail}]' if detail else ''), flush=True)
        if not ok:
            self.failures.append(what + (f' [{detail}]' if detail else ''))
        return ok


# ---- the picture and the collector ----------------------------------------------

def photo_png(width=480, height=300):
    """A gradient picture with a sun, so a loaded image is easy to tell."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            dx, dy = x - width * 0.72, y - height * 0.32
            if dx * dx + dy * dy < (height * 0.16) ** 2:
                row += bytes((255, 214, 64))
            elif y > height * 0.68:
                row += bytes((40 + x * 60 // width, 140, 60))
            else:
                row += bytes((90 + y * 100 // height, 150 + y * 80 // height, 235))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


class Server:
    """Serves the picture for network images and, as a local collector,
    takes what the SDK uploads: replay segments are kept, the rest is
    acknowledged."""

    def __init__(self):
        image = photo_png()
        self.segments = []
        self.requests = 0
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def _reply(self, status, body=b'', kind='application/json'):
                self.send_response(status)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.startswith('/photo.png'):
                    self._reply(200, image, 'image/png')
                else:
                    self._reply(404, b'{}')

            def do_POST(self):
                length = int(self.headers.get('Content-Length') or 0)
                body = self.rfile.read(length)
                server.requests += 1
                if self.path.startswith('/api/recordings'):
                    try:
                        if self.headers.get('Content-Encoding') == 'gzip':
                            body = gzip.decompress(body)
                        server.segments.extend(json.loads(body).get('segments') or [])
                    except Exception as e:  # a malformed upload fails the run later
                        print(f'  ...  collector: bad recording upload: {e}', flush=True)
                        self._reply(400, b'{}')
                        return
                self._reply(200, b'{}')

            def log_message(self, *args):
                pass

        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.http.server_address[1]}'

    def recording(self, session):
        """The session's segments in order, as the server joins them."""
        mine = [s for s in self.segments if s.get('sessionId') == session and s.get('exceptionId') is None]
        mine.sort(key=lambda s: s.get('segmentIndex') or 0)
        return [e for s in mine for e in s['events']]


class Api:
    def __init__(self, base, email, password, project_name):
        self.base = base.rstrip('/')
        self.jwt = None
        body = self.call('POST', '/api/login', {'email': email, 'password': password}, project=False)
        self.jwt = body['token']
        found = [p for p in body['projects'] if p['framework'] == 'flutter' and (not project_name or p['name'] == project_name)]
        if not found:
            sys.exit('no flutter project in this account')
        self.project = found[0]

    def call(self, method, path, body=None, project=True):
        url = self.base + path
        if project:
            url += ('&' if '?' in url else '?') + 'projectId=' + self.project['id']
        headers = {'Content-Type': 'application/json'}
        if self.jwt:
            headers['Authorization'] = 'Bearer ' + self.jwt
        req = urllib.request.Request(url, method=method, headers=headers,
                                     data=None if body is None else json.dumps(body).encode())
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None


# ---- rrweb, strictly --------------------------------------------------------------

class Mirror:
    """rrweb's replayer, strictly: see test/wireframe_test.dart."""

    def __init__(self):
        self.nodes = {}
        self.errors = []

    def _build(self, n, parent, with_children):
        nid = n['id']
        if nid in self.nodes:
            self.errors.append(f'id {nid} added while on the page')
        node = {'id': nid, 'tag': n.get('tagName') if n['type'] == 2 else None,
                'text': n.get('textContent') if n['type'] == 3 else None,
                'attrs': dict(n.get('attributes') or {}), 'children': [], 'parent': parent}
        self.nodes[nid] = node
        if with_children:
            for child in n.get('childNodes') or []:
                node['children'].append(self._build(child, node, True))
        return node

    def _unmap(self, node):
        self.nodes.pop(node['id'], None)
        for c in node['children']:
            self._unmap(c)

    def full(self, node):
        self.nodes = {}
        self._build(node, None, True)

    def mutation(self, d, at):
        for key in ('removes', 'adds', 'texts', 'attributes'):
            if not isinstance(d.get(key), list):
                self.errors.append(f'{at}: {key} is not a list')
                return
        for r in d['removes']:
            node, parent = self.nodes.get(r['id']), self.nodes.get(r['parentId'])
            if node is None or parent is None or node not in parent['children']:
                self.errors.append(f'{at}: bad remove {r}')
                continue
            parent['children'].remove(node)
            self._unmap(node)
        for a in d['adds']:
            parent = self.nodes.get(a['parentId'])
            if parent is None:
                self.errors.append(f'{at}: add under missing {a["parentId"]}')
                continue
            node = self._build(a['node'], parent, False)
            nxt = a.get('nextId')
            if nxt is None:
                parent['children'].append(node)
            elif nxt in self.nodes and self.nodes[nxt] in parent['children']:
                parent['children'].insert(parent['children'].index(self.nodes[nxt]), node)
            else:
                self.errors.append(f'{at}: add before missing {nxt}')
                parent['children'].append(node)
        for t in d['texts']:
            node = self.nodes.get(t['id'])
            if node is None or node['tag'] is not None:
                self.errors.append(f'{at}: bad text {t["id"]}')
                continue
            node['text'] = t['value']
        for a in d['attributes']:
            node = self.nodes.get(a['id'])
            if node is None:
                self.errors.append(f'{at}: attributes of missing {a["id"]}')
                continue
            for k, v in a['attributes'].items():
                if v is None:
                    node['attrs'].pop(k, None)
                else:
                    node['attrs'][k] = v

    def texts(self):
        out = []

        def walk(n):
            if n['text'] is not None:
                out.append(n['text'])
            for c in n['children']:
                walk(c)
        screen = self.nodes.get(8)
        if screen:
            walk(screen)
        return out


def play(events, moments):
    """Plays [events] and returns the text on screen at each moment (ms)."""
    mirror = Mirror()
    shown = {}
    pending = sorted(moments.items(), key=lambda kv: kv[1])
    for i, e in enumerate(events):
        while pending and pending[0][1] < e['timestamp']:
            name, _ = pending.pop(0)
            shown[name] = mirror.texts()
        if e['type'] == 2:
            mirror.full(e['data']['node'])
        elif e['type'] == 3 and e['data'].get('source') == 0:
            mirror.mutation(e['data'], f'event {i}')
        elif e['type'] == 3 and e['data'].get('source') == 2 and e['data'].get('id') not in mirror.nodes:
            mirror.errors.append(f'event {i}: touch on a node not on the page')
    for name, _ in pending:
        shown[name] = mirror.texts()
    return mirror, shown


# ---- the app ----------------------------------------------------------------------

def hypr_window(pid):
    """The app's Hyprland window, once it is mapped."""
    if not shutil.which('hyprctl'):
        return None
    for _ in range(150):
        try:
            clients = json.loads(subprocess.check_output(['hyprctl', 'clients', '-j']))
        except Exception:
            return None
        mine = [c for c in clients if c.get('pid') == pid]
        if mine:
            return mine[0]
        time.sleep(0.2)
    return None


def hypr_size(pid, width, height):
    """Floats the app's window and gives it [width] x [height]."""
    client = hypr_window(pid)
    if client is None:
        return False
    address = client['address']
    window = f'window = "address:{address}"'
    # Hyprland 0.56 takes Lua dispatchers; older releases the classic syntax.
    lua = [f'hl.dsp.window.float({{ action = "enable", {window} }})',
           f'hl.dsp.window.resize({{ x = {width}, y = {height}, {window} }})',
           f'hl.dsp.window.move({{ x = 40, y = 10, {window} }})']
    ok = all(subprocess.run(['hyprctl', 'dispatch', expr], capture_output=True, text=True)
             .stdout.strip() == 'ok' for expr in lua)
    if not ok:
        subprocess.run(['hyprctl', '--batch',
                        f'dispatch setfloating address:{address} ; '
                        f'dispatch resizewindowpixel exact {width} {height},address:{address} ; '
                        f'dispatch movewindowpixel exact 40 10,address:{address}'],
                       check=False, stdout=subprocess.DEVNULL)
    return True


def build_app(flutter):
    print('  ...  building the suite app (flutter build linux --debug)', flush=True)
    env = dict(os.environ, PATH=os.path.dirname(flutter) + os.pathsep + os.environ.get('PATH', ''))
    subprocess.run([flutter, 'build', 'linux', '--debug', '-t', 'lib/wireframe_suite/main.dart'],
                   cwd=EXAMPLE, env=env, check=True)


def run_app(app, env, out, size, timeout_s):
    """Runs the tour and collects what the app printed."""
    proc = subprocess.Popen(app, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    threading.Thread(target=hypr_size, args=(proc.pid, *size), daemon=True).start()
    # The window has a title bar, and the view is what is left under it:
    # the window grows by what the view lacks.
    window = list(size)
    run = {'checkpoints': [], 'scenarios': [], 'failed': [], 'secrets': [], 'session': None,
           'window': None, 'done': False, 'capture_ms': []}
    log = open(os.path.join(out, 'app.log'), 'w')
    deadline = time.time() + timeout_s
    timer = threading.Timer(timeout_s, proc.kill)
    timer.start()
    for line in proc.stdout:
        log.write(line)
        log.flush()
        line = line.strip()
        if 'E2E_CHECKPOINT ' in line:
            cp = json.loads(line.split('E2E_CHECKPOINT ', 1)[1])
            run['checkpoints'].append(cp)
            print(f'  ...  checkpoint {cp["name"]}' + ('' if cp['settled'] else '  (never settled)'), flush=True)
        elif 'E2E_SCENARIO_FAILED ' in line:
            sid, error = (line.split('E2E_SCENARIO_FAILED ', 1)[1] + ' ').split(' ', 1)
            run['failed'].append((sid, error.strip()))
            print(f'  ...  scenario {sid} failed: {error.strip()}', flush=True)
        elif 'E2E_SCENARIO ' in line:
            sid, at = line.split('E2E_SCENARIO ', 1)[1].split()[:2]
            run['scenarios'].append({'id': sid, 'at': int(at)})
        elif 'E2E_SECRET ' in line:
            run['secrets'].append(json.loads(line.split('E2E_SECRET ', 1)[1]))
        elif 'E2E_SESSION ' in line:
            run['session'] = line.split()[-1]
        elif 'E2E_VIEW ' in line:
            view = [int(v) for v in line.split()[-1].split('x')]
            if view[0] < 700 and view != list(size):
                window = [window[0] + size[0] - view[0], window[1] + size[1] - view[1]]
                hypr_size(proc.pid, *window)
        elif 'E2E_WINDOW ' in line:
            run['window'] = line.split()[-1]
            print(f'  ...  window {run["window"]}', flush=True)
        elif 'E2E_FAILED' in line:
            print('  app failed: ' + line, flush=True)
        elif 'average capture' in line or 'capture took' in line:
            run['capture_ms'].append(line)
        if 'E2E_DONE' in line:
            run['done'] = True
            break
        if time.time() > deadline:
            break
    timer.cancel()
    try:
        proc.wait(30)
    except subprocess.TimeoutExpired:
        proc.kill()
    run['exit'] = proc.returncode
    return run


# ---- checks -------------------------------------------------------------------------

def check_recording(check, events, run, subset=False):
    cps = run['checkpoints']
    size = len(json.dumps(events))
    kinds = {}
    for e in events:
        key = e['type'] if e['type'] != 3 else f"3.{e['data'].get('source')}"
        kinds[key] = kinds.get(key, 0) + 1
    print(f'  ...  {len(events)} events, {size // 1024} KB as JSON: {kinds}', flush=True)
    check(bool(events) and events[0]['type'] == 4 and len(events) > 1 and events[1]['type'] == 2,
          'the recording starts with a meta event and a full snapshot')
    check(all(e['type'] in (2, 3, 4, 5) for e in events), 'every event is an rrweb event',
          str({e['type'] for e in events}))
    stamps = [e['timestamp'] for e in events]
    check(stamps == sorted(stamps), 'events are in time order across segments')
    if cps:
        check(bool(events) and events[0]['timestamp'] <= cps[0]['at'] and
              events[-1]['timestamp'] >= cps[-1]['at'], 'the recording covers the whole tour')
    # The whole tour taps and drags plenty; a few scenarios may not.
    least = 0 if subset else 4
    check(kinds.get('3.0', 0) > least * 2, 'the screen changes are mutations', f"{kinds.get('3.0', 0)} mutations")
    check(kinds.get('3.2', 0) > least, 'touches are recorded', f"{kinds.get('3.2', 0)} touch interactions")
    check(kinds.get('3.6', 0) > least, 'drags are recorded as touch moves', f"{kinds.get('3.6', 0)} moves")
    return {'events': len(events), 'bytes': size, 'kinds': kinds}


def check_checkpoints(check, events, run):
    cps = run['checkpoints']
    mirror, shown = play(events, {cp['name']: cp['at'] + SAMPLE_MS for cp in cps})
    check(not mirror.errors, 'every mutation of the session applies as rrweb replays it',
          '; '.join(mirror.errors[:5]))
    mutations = sorted(e['timestamp'] for e in events if e['type'] == 3 and e['data'].get('source') == 0)
    results = {}
    previous = 0
    for cp in cps:
        name = cp['name']
        problems = []
        if not cp['settled']:
            problems.append('the screen never settled')
        joined = '\n'.join(shown.get(name, []))
        missing = [w for w in cp['shows'] if w not in joined]
        leaked = [h for h in cp['hides'] if h in joined]
        if missing:
            problems.append(f'missing {missing}')
        if leaked:
            problems.append(f'shows {leaked}')
        count = sum(1 for t in mutations if previous < t <= cp['at'])
        if cp.get('minMutations') and count < cp['minMutations']:
            problems.append(f'{count} mutations since the last checkpoint, wanted {cp["minMutations"]}')
        previous = cp['at']
        check(not problems, f'replay at {name} shows that screen', '; '.join(problems))
        results[name] = {'problems': problems, 'mutations': count}
    text = json.dumps(events, ensure_ascii=False)
    leaked = [s for s in run['secrets'] if s in text]
    check(not leaked, 'no secret appears anywhere in the recording', f'leaked {leaked}' if leaked else
          f'{len(run["secrets"])} secrets')
    return results


def scenario_bytes(events, run):
    """What each scenario recorded, from its start to the next one's."""
    starts = sorted(run['scenarios'], key=lambda s: s['at'])
    out = {}
    for i, s in enumerate(starts):
        end = starts[i + 1]['at'] if i + 1 < len(starts) else float('inf')
        chosen = [e for e in events if s['at'] <= e['timestamp'] < end]
        out[s['id']] = {'bytes': len(json.dumps(chosen)), 'events': len(chosen),
                        'mutations': sum(1 for e in chosen if e['type'] == 3 and e['data'].get('source') == 0)}
    return out


def evaluate_visual(check, visual, baseline, args, run):
    """Fidelity against the baseline's and the floors; changes against the
    baseline rendering."""
    cps = {cp['name']: cp for cp in run['checkpoints']}
    known = baseline.get('checkpoints', {})
    floors = {'ssim': 0.55, 'edges': 0.35, 'color': 0.6}
    verdicts = {}
    for name, v in visual['checkpoints'].items():
        problems = []
        fid = v.get('fidelity') or {}
        base = (known.get(name) or {}).get('fidelity') or {}
        for metric, floor in floors.items():
            value = fid.get(metric)
            if value is None:
                problems.append(f'no {metric}')
                continue
            if value < floor:
                problems.append(f'{metric} {value:.3f} below the floor {floor}')
            if metric in base and value < base[metric] - args.tolerance:
                problems.append(f'{metric} {value:.3f} fell from {base[metric]:.3f}')
        golden = v.get('golden')
        limit = cps.get(name, {}).get('maxChange') or args.max_change
        if golden is None:
            if not args.update_baseline and known:
                problems.append('no baseline rendering')
        elif golden['changed'] > limit:
            problems.append(f'{golden["changed"] * 100:.2f}% of pixels changed from the baseline (limit {limit * 100:.2f}%)')
        verdicts[name] = problems
        check(not problems, f'visual {name}', '; '.join(problems) if problems else
              f'ssim {fid.get("ssim", 0):.3f} edges {fid.get("edges", 0):.3f} color {fid.get("color", 0):.3f}'
              + (f', {golden["changed"] * 100:.2f}% changed' if golden else ''))
    missing = sorted(set(known) - set(visual['checkpoints']))
    if missing and not args.only:
        check(False, 'every baseline checkpoint was reached', f'missing {missing}')
    return verdicts


def check_sizes(check, sizes, baseline, args):
    known = baseline.get('scenarios', {})
    for sid, size in sizes.items():
        base = (known.get(sid) or {}).get('bytes')
        if base is None or args.update_baseline:
            continue
        ok = size['bytes'] <= base * 1.5 + 20000
        check(ok, f'scenario {sid} records about as much as before',
              f'{size["bytes"] // 1024} KB, baseline {base // 1024} KB')


# ---- report -------------------------------------------------------------------------

def write_report(out, run, stats, sizes, text_results, visual, verdicts, baseline, check, args):
    e = html.escape
    known = baseline.get('checkpoints', {})
    rows = []
    for cp in run['checkpoints']:
        name = cp['name']
        v = visual.get('checkpoints', {}).get(name, {})
        fid = v.get('fidelity') or {}
        base = (known.get(name) or {}).get('fidelity') or {}
        golden = v.get('golden')
        problems = (text_results.get(name) or {}).get('problems', []) + verdicts.get(name, [])

        def metric(key):
            value = fid.get(key)
            if value is None:
                return '–'
            delta = '' if key not in base else f' <small>({value - base[key]:+.3f})</small>'
            return f'{value:.3f}{delta}'
        img = lambda path, cls='': f'<a href="{path}"><img class="{cls}" src="{path}" loading="lazy"></a>' if os.path.exists(os.path.join(out, path)) else '<span class="none">–</span>'
        rows.append(f'''<tr class="{'fail' if problems else 'pass'}" id="{e(name)}">
<th><b>{e(name)}</b><br><small>{e(cp['scenario'])}</small><br>
<span class="badge">{'FAIL' if problems else 'PASS'}</span>
<table class="m"><tr><td>SSIM</td><td>{metric('ssim')}</td></tr><tr><td>edges</td><td>{metric('edges')}</td></tr>
<tr><td>color</td><td>{metric('color')}</td></tr>
<tr><td>changed</td><td>{'–' if golden is None else f"{golden['changed'] * 100:.2f}%"}</td></tr>
<tr><td>mutations</td><td>{(text_results.get(name) or {}).get('mutations', '–')}</td></tr></table>
{''.join(f'<div class="p">{e(p)}</div>' for p in problems)}</th>
<td>{img(f'app/{name}.png')}</td><td>{img(f'replay/{name}.png')}</td>
<td>{img(f'delta/{name}.png')}</td><td>{img(f'baseline/{name}.png')}</td><td>{img(f'diff/{name}.png')}</td></tr>''')
    size_rows = ''.join(
        f'<tr><td>{e(sid)}</td><td>{s["bytes"] // 1024} KB</td><td>{s["events"]}</td><td>{s["mutations"]}</td>'
        f'<td>{(baseline.get("scenarios", {}).get(sid) or {}).get("bytes", 0) // 1024} KB</td></tr>'
        for sid, s in sizes.items())
    failures = ''.join(f'<li>{e(f)}</li>' for f in check.failures)
    passed = not check.failures
    with open(os.path.join(out, 'report.html'), 'w') as f:
        f.write(f'''<!doctype html><meta charset="utf-8"><title>Wireframe replay suite</title>
<style>
body{{font:14px system-ui;margin:16px;color:#222}} h1{{margin:0 0 4px}}
.sum{{padding:10px 14px;border-radius:8px;margin:12px 0;background:{'#e8f5e9' if passed else '#ffebee'}}}
table.r{{border-collapse:collapse}} table.r>tbody>tr>td,table.r>tbody>tr>th{{vertical-align:top;padding:6px;border-bottom:1px solid #ddd}}
table.r th{{text-align:left;width:190px;font-weight:normal}} img{{width:190px;border:1px solid #ccc;display:block}}
tr.fail>th .badge{{background:#c62828}} .badge{{background:#2e7d32;color:#fff;border-radius:4px;padding:1px 6px;font-size:11px}}
table.m td{{padding:0 8px 0 0;font-size:12px}} .p{{color:#c62828;font-size:12px;margin-top:4px}} .none{{color:#aaa}}
label{{margin-right:12px}} table.s td{{padding:2px 10px}}
</style>
<h1>Wireframe replay suite</h1>
<div>{e(run.get('window') or '')} · session {e(run.get('session') or '')} · {len(run['checkpoints'])} checkpoints ·
{stats.get('events', 0)} events · {stats.get('bytes', 0) // 1024} KB · baseline {e(args.baseline_key)}</div>
<div class="sum"><b>{'PASSED' if passed else f'FAILED: {len(check.failures)} check(s)'}</b><ul>{failures}</ul></div>
<label><input type="checkbox" id="onlyfail"> failures only</label>
<p>Columns: what the app drew · the replay (rrweb-player at 1:1) · where they differ (brighter is more) ·
the accepted baseline rendering · the replay's changes from it (red; yellow is anti-aliasing).
SSIM, edges and color compare the replay with the app (1 is identical; in brackets the change from the baseline).</p>
<table class="r"><tr><th></th><th>App</th><th>Replay</th><th>App vs replay</th><th>Baseline</th><th>Changes</th></tr>
{''.join(rows)}</table>
<h2>Size per scenario</h2><table class="s"><tr><th>scenario</th><th>bytes</th><th>events</th><th>mutations</th><th>baseline</th></tr>{size_rows}</table>
{'<h2>Dashboard</h2><img src="dashboard/session-page.png" style="width:100%">' if os.path.exists(os.path.join(out, 'dashboard', 'session-page.png')) else ''}
<script>document.getElementById('onlyfail').onchange=e=>document.querySelectorAll('tr.pass').forEach(r=>r.style.display=e.target.checked?'none':'')</script>
''')


# ---- main ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', help='a running Traceway; without it a local collector takes the uploads')
    ap.add_argument('--dsn', help='connection string of the Flutter project on --base')
    ap.add_argument('--email')
    ap.add_argument('--password')
    ap.add_argument('--project', default='')
    ap.add_argument('--dashboard', default='', help="the dashboard's URL, to check its player too (needs --base)")
    ap.add_argument('--out', default=os.path.expanduser('~/.cache/tw-wireframe/suite'))
    ap.add_argument('--only', default='', help='comma-separated scenario ids')
    ap.add_argument('--size', default='400x680')
    ap.add_argument('--build', action='store_true', help='build the suite app first')
    ap.add_argument('--flutter', default=shutil.which('flutter') or os.path.expanduser('~/development/flutter/bin/flutter'))
    ap.add_argument('--app', default=os.path.join(EXAMPLE, 'build', 'linux', 'x64', 'debug', 'bundle', 'traceway_example'))
    ap.add_argument('--state-dir', default='~/.local/share/com.example.traceway_example/traceway_v2',
                    help="the app's SDK state, cleared before the run")
    ap.add_argument('--baseline', default=os.path.join(HERE, 'baseline'))
    ap.add_argument('--update-baseline', action='store_true', help='accept this run as the baseline')
    ap.add_argument('--tolerance', type=float, default=0.03, help='how far a fidelity metric may fall')
    ap.add_argument('--max-change', type=float, default=0.002, help='share of pixels that may change from the baseline')
    ap.add_argument('--timeout', type=int, default=900, help='seconds the tour may take')
    ap.add_argument('--playwright', default=os.environ.get('PLAYWRIGHT_DIR', os.path.expanduser('~/Work/workspace/js-client/node_modules/playwright')))
    ap.add_argument('--rrweb-player', default=os.path.join(REPO, '..', 'traceway', 'frontend', 'node_modules', 'rrweb-player'))
    ap.add_argument('--chromium', default=shutil.which('chromium') or '/usr/bin/chromium')
    args = ap.parse_args()
    if args.base and not (args.dsn and args.email and args.password):
        sys.exit('--base needs --dsn, --email and --password')
    width, height = (int(v) for v in args.size.split('x'))
    args.baseline_key = f'{platform.system().lower()}-{args.size}'
    baseline_dir = os.path.join(args.baseline, args.baseline_key)

    out = os.path.abspath(args.out)
    for sub in ('app', 'replay', 'delta', 'diff', 'baseline', 'dashboard'):
        path = os.path.join(out, sub)
        if os.path.isdir(path):
            for f in os.listdir(path):
                os.remove(os.path.join(path, f))
        os.makedirs(path, exist_ok=True)
    check = Check()
    if args.build:
        build_app(args.flutter)
    if not os.path.exists(args.app):
        sys.exit(f'no app at {args.app}: run with --build')

    server = Server()
    api = Api(args.base, args.email, args.password, args.project) if args.base else None
    dsn = args.dsn if api else f'suite-token@{server.base}'
    state = os.path.expanduser(args.state_dir)
    if os.path.isdir(state):
        shutil.rmtree(state)  # a fresh install: nothing to resume
    env = dict(os.environ, E2E_SHOTS=os.path.join(out, 'app'), E2E_IMAGE_URL=f'{server.base}/photo.png',
               TRACEWAY_DSN=dsn, E2E_SIZE=args.size)
    if args.only:
        env['E2E_ONLY'] = args.only
    print(f'Running the suite against {"Traceway at " + args.base if api else "a local collector"}', flush=True)
    run = run_app([args.app], env, out, (width, height), args.timeout)
    check(run['exit'] == 0 and run['done'], 'the app finished its tour', f'exit {run["exit"]}')
    check(run['window'] == args.size, 'the window has the size of a phone', run['window'] or '')
    for sid, error in run['failed']:
        check(False, f'scenario {sid} ran', error)
    check(run['session'] is not None, 'the app reported its session', run['session'] or '')
    if not run['session'] or not run['checkpoints']:
        sys.exit(1)

    last = run['checkpoints'][-1]['at']
    events = []
    for _ in range(20):
        time.sleep(1.5)
        if api:
            events = (api.call('GET', f'/api/sessions/{run["session"]}/recording') or {}).get('events') or []
        else:
            events = server.recording(run['session'])
        if events and events[-1]['timestamp'] >= last:
            break
    with open(os.path.join(out, 'events.json'), 'w') as f:
        json.dump(events, f)
    with open(os.path.join(out, 'run.json'), 'w') as f:
        json.dump(run, f, indent=1)
    stats = check_recording(check, events, run, subset=bool(args.only))
    text_results = check_checkpoints(check, events, run)
    sizes = scenario_bytes(events, run)

    baseline = {}
    if os.path.exists(os.path.join(baseline_dir, 'metrics.json')):
        with open(os.path.join(baseline_dir, 'metrics.json')) as f:
            baseline = json.load(f)
    elif not args.update_baseline:
        print(f'  ...  no baseline at {baseline_dir}: fidelity is held to its floors only', flush=True)

    visual = {'checkpoints': {}}
    node = shutil.which('node')
    if node and os.path.isdir(args.playwright) and os.path.isdir(args.rrweb_player):
        cmd = [node, os.path.join(HERE, 'replay.mjs'), '--out', out, '--playwright', args.playwright,
               '--rrweb-player', os.path.abspath(args.rrweb_player), '--chromium', args.chromium,
               '--baseline', baseline_dir, '--sample', str(SAMPLE_MS), '--session', run['session']]
        if api and args.dashboard:
            cmd += ['--dashboard', args.dashboard, '--email', args.email, '--password', args.password,
                    '--project', api.project['id']]
        result = subprocess.run(cmd)
        check(result.returncode == 0, 'Playwright replayed the recording')
        with open(os.path.join(out, 'visual.json')) as f:
            visual = json.load(f)
        for problem in visual.get('problems', []):
            check(False, problem)
    else:
        check(False, 'Playwright replayed the recording', 'node, Playwright or rrweb-player is missing')
    verdicts = evaluate_visual(check, visual, baseline, args, run)
    check_sizes(check, sizes, baseline, args)

    if args.update_baseline:
        if check.failures and not all(f.startswith('visual ') for f in check.failures):
            print('  ...  not updating the baseline: the run failed checks other than visual ones', flush=True)
        else:
            os.makedirs(baseline_dir, exist_ok=True)
            merged = dict(baseline.get('checkpoints', {})) if args.only else {}
            only = set(args.only.split(',')) if args.only else None
            scenario_of = {cp['name']: cp['scenario'] for cp in run['checkpoints']}
            for name, v in visual['checkpoints'].items():
                # A subset run re-baselines only its own scenarios' screens.
                if only is not None and scenario_of.get(name) not in only:
                    continue
                shutil.copy(os.path.join(out, 'replay', f'{name}.png'), os.path.join(baseline_dir, f'{name}.png'))
                merged[name] = {'fidelity': v.get('fidelity')}
            scen = dict(baseline.get('scenarios', {})) if args.only else {}
            scen.update({sid: {'bytes': s['bytes']} for sid, s in sizes.items()})
            if not args.only:
                for f in os.listdir(baseline_dir):
                    if f.endswith('.png') and f[:-4] not in merged:
                        os.remove(os.path.join(baseline_dir, f))
            with open(os.path.join(baseline_dir, 'metrics.json'), 'w') as f:
                json.dump({'checkpoints': merged, 'scenarios': scen}, f, indent=1, sort_keys=True)
            print(f'  ...  baseline updated: {baseline_dir}', flush=True)
            check.failures = [f for f in check.failures if not f.startswith('visual ')]

    write_report(out, run, stats, sizes, text_results, visual, verdicts, baseline, check, args)
    print(f'\n{"FAILED" if check.failures else "PASSED"}: {len(check.failures)} failed check(s); '
          f'report: {os.path.join(out, "report.html")}')
    sys.exit(1 if check.failures else 0)


if __name__ == '__main__':
    main()
