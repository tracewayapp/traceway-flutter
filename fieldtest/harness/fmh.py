#!/usr/bin/env python3
"""Fieldmart harness for Flutter on Linux (AGENT-3 step 4).

  fmh.py xvfb start|stop|status
  fmh.py gateway start|stop|status [--tools DIR]   the field-test gateway, live mode
  fmh.py build [off|sdk|all]          builds through `heavy`; never under benchrun
  fmh.py proof-off --results DIR      the `off` build contains no SDK
  fmh.py run --results DIR --scenario S6 --variant stream-img [--evidence]
  fmh.py block --results DIR --scenario S1 --variants off,off2 --block 1

`run` and `block` take the measurement lock: start them with
`tools/bin/benchrun`. The app runs on the private display (default :78),
pinned to cores 0-1; the sampler, the screen recorder and this script run
on cores 2-3. Standard library only.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from common import now_ms, write_json, write_jsonl  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FIELDTEST = os.path.dirname(HERE)
REPO = os.path.dirname(FIELDTEST)
CACHE = os.path.expanduser('~/.cache/sdk-field-test/flutter')
FLUTTER = os.environ.get('FM_FLUTTER', os.path.expanduser('~/development/flutter/bin/flutter'))
HEAVY = os.environ.get('FM_HEAVY', os.path.expanduser('~/.cache/sdk-parity/bin/heavy'))
XVFB = os.environ.get('FM_XVFB', os.path.expanduser('~/.cache/flutter-sdk-main.Rwxr4CBI/xorg/usr/bin/Xvfb'))
WIDTH, HEIGHT = 412, 892

APPS = {
    'off': {'dir': 'app_off', 'exe': 'fieldmart_off', 'id': 'com.tracewayapp.fieldmart.flutter.off'},
    'sdk': {'dir': 'app_sdk', 'exe': 'fieldmart_sdk', 'id': 'com.tracewayapp.fieldmart.flutter'},
}


def app_for(variant):
    return APPS['off' if variant in ('off', 'off2') else 'sdk']


def bundle(app):
    return os.path.join(FIELDTEST, app['dir'], 'build', 'linux', 'x64', 'release', 'bundle', app['exe'])


def data_dir(app):
    return os.path.expanduser(f"~/.local/share/{app['id']}")


# ---- Xvfb ----------------------------------------------------------------------

def _xvfb_pidfile(display):
    return os.path.join(CACHE, f'xvfb{display.lstrip(":")}.pid')


def xvfb(args):
    pidfile = _xvfb_pidfile(args.display)
    pid = None
    if os.path.exists(pidfile):
        pid = int(open(pidfile).read().strip() or 0)
        if not os.path.exists(f'/proc/{pid}'):
            pid = None
    if args.action == 'status':
        print(f'{args.display}: ' + (f'running, pid {pid}' if pid else 'not running'))
    elif args.action == 'start':
        if pid:
            print(f'{args.display} already running (pid {pid})')
            return
        if args.display == ':77':
            raise SystemExit(':77 belongs to another session')
        if not os.path.exists(XVFB):
            raise SystemExit(f'no Xvfb at {XVFB}')
        os.makedirs(CACHE, exist_ok=True)
        log = open(os.path.join(CACHE, f'xvfb{args.display.lstrip(":")}.log'), 'a')
        p = subprocess.Popen([XVFB, args.display, '-screen', '0', '1280x1000x24', '-nolisten', 'tcp'],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        open(pidfile, 'w').write(str(p.pid))
        time.sleep(1.0)
        print(f'{args.display} started, pid {p.pid}')
    elif args.action == 'stop':
        if pid:
            os.kill(pid, signal.SIGTERM)
            print(f'{args.display} stopped (pid {pid})')
        if os.path.exists(pidfile):
            os.remove(pidfile)


# ---- gateway -----------------------------------------------------------------------

def default_tools():
    return os.environ.get('FM_TOOLS', os.path.join(REPO, '..', 'sdk-field-test', 'tools'))


def default_node():
    return os.environ.get('FM_NODE') or shutil.which('node') or 'node'


def gateway(args):
    pidfile = os.path.join(CACHE, 'gateway.pid')
    pid = None
    if os.path.exists(pidfile):
        pid = int(open(pidfile).read().split()[0] or 0)
        if not os.path.exists(f'/proc/{pid}'):
            pid = None
    health = common.Gateway(args.gateway).health()
    if args.action == 'status':
        print(f'gateway: {health}; started here: pid {pid}' if pid else f'gateway: {health}')
    elif args.action == 'start':
        if 'error' not in health:
            print(f'a gateway already answers on {args.gateway}: {health}')
            return
        ledger = os.path.join(CACHE, 'gateway', time.strftime('%Y%m%d-%H%M%S'))
        os.makedirs(ledger)
        tools = os.path.abspath(args.tools)
        log = open(os.path.join(ledger, '..', os.path.basename(ledger) + '.log'), 'w')
        p = subprocess.Popen(['taskset', '-c', '2,3', args.node, os.path.join(tools, 'gateway', 'gateway.mjs'), '--mode', 'live',
                              '--port', '18190', '--upstream', 'http://127.0.0.1:18182',
                              '--fixtures', os.path.join(tools, '..', 'fixtures'), '--ledger', ledger],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        open(pidfile, 'w').write(f'{p.pid} {ledger}')
        for _ in range(40):
            time.sleep(0.25)
            if 'error' not in common.Gateway(args.gateway).health():
                break
        print(f'gateway started, pid {p.pid}, ledger {ledger}: {common.Gateway(args.gateway).health()}')
    elif args.action == 'stop':
        if pid:
            os.kill(pid, signal.SIGTERM)
            print(f'gateway stopped (pid {pid})')
            os.remove(pidfile)
        else:
            print('no gateway started here')


# ---- build -----------------------------------------------------------------------

def build(args):
    targets = ['off', 'sdk'] if args.which == 'all' else [args.which]
    for t in targets:
        d = os.path.join(FIELDTEST, APPS[t]['dir'])
        print(f'== {t}: flutter build linux --release', flush=True)
        r = subprocess.run([HEAVY, FLUTTER, 'build', 'linux', '--release'], cwd=d)
        if r.returncode:
            raise SystemExit(r.returncode)
    # `flutter build` may rewrite the repository's own analysis options.
    for f in ('analysis_options.yaml', 'example/analysis_options.yaml'):
        if subprocess.run(['git', '-C', REPO, 'diff', '--quiet', '--', f]).returncode:
            subprocess.run(['git', '-C', REPO, 'checkout', '--', f])
            print(f'reverted {f}')


def proof_off(args):
    """The `off` build has no trace of the SDK (02-APP-SPEC.md §1.5).

    The SDK's code shows in a Dart snapshot as `package:traceway/...` library
    URIs. Every other string containing "traceway" is listed: the app's own
    `traceway-mask` marker key (the spec's marker route for the loyalty
    number) and build paths under the repository folder `traceway-flutter`.
    """
    out = []
    lock = os.path.join(FIELDTEST, 'app_off', 'pubspec.lock')
    text = open(lock).read()
    pkgs = [line.strip().rstrip(':') for line in text.splitlines() if line.startswith('  ') and not line.startswith('   ')]
    out.append(f'app_off/pubspec.lock: {len(pkgs)} packages: {", ".join(pkgs)}')
    out.append(f'  a package named traceway in it: {"traceway" in pkgs or "traceway_video" in pkgs}')

    def scan(label, data, listing):
        strings = subprocess.run(['strings', '-a'], input=data, capture_output=True).stdout.decode(errors='replace').splitlines()
        hits = [x for x in strings if 'traceway' in x.lower()]
        sdk = [x for x in hits if 'package:traceway/' in x]
        other = sorted(set(hits) - set(sdk))
        out.append(f'{label}: {len(sdk)} SDK library URIs (package:traceway/...); other strings with "traceway": {len(other)}')
        for x in other if listing else []:
            out.append(f'    {x[:160]}')

    for app, title in ((APPS['off'], 'app_off'), (APPS['sdk'], 'app_sdk (control)')):
        root = os.path.dirname(bundle(app))
        listing = app is APPS['off']
        scan(f'{title} linux lib/libapp.so', open(os.path.join(root, 'lib', 'libapp.so'), 'rb').read(), listing)
        out.append(f'  bundle lib/: {", ".join(sorted(os.listdir(os.path.join(root, "lib"))))}')
        apk = os.path.join(FIELDTEST, app['dir'], 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')
        if os.path.exists(apk):
            data = subprocess.run(['unzip', '-p', apk, 'lib/x86_64/libapp.so'], capture_output=True).stdout
            scan(f'{title} apk lib/x86_64/libapp.so', data, listing)
    text = '\n'.join(out) + '\n'
    print(text, end='')
    if args.results:
        d = os.path.join(args.results, common.PLATFORM_LINUX)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'off-proof.txt'), 'w').write(text)


# ---- one run -----------------------------------------------------------------------

def proc_cpu(pid):
    """(user ms, system ms) of a process from /proc/<pid>/stat."""
    tck = os.sysconf('SC_CLK_TCK')
    with open(f'/proc/{pid}/stat') as f:
        fields = f.read().rsplit(')', 1)[1].split()
    return int(fields[11]) * 1000 // tck, int(fields[12]) * 1000 // tck


def proc_threads(pid):
    """{thread name: cpu ms} for the process's threads now."""
    tck = os.sysconf('SC_CLK_TCK')
    out = {}
    base = f'/proc/{pid}/task'
    for tid in os.listdir(base):
        try:
            with open(f'{base}/{tid}/stat') as f:
                raw = f.read()
            name = raw[raw.index('(') + 1:raw.rindex(')')]
            fields = raw.rsplit(')', 1)[1].split()
            out[name] = out.get(name, 0) + (int(fields[11]) + int(fields[12])) * 1000 // tck
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
    return out


def proc_status(pid, key):
    with open(f'/proc/{pid}/status') as f:
        for line in f:
            if line.startswith(key + ':'):
                return int(line.split()[1])
    return None


def thread_groups(threads, exe):
    """M-CPU-3 (UI = the main thread, which runs the UI isolate on Linux),
    raster (engine raster thread and Mesa's software rasterizer), Dart
    workers (the SDK's `Isolate.run` work lands here), the rest."""
    g = {'ui': 0, 'raster': 0, 'io': 0, 'dartWorker': 0, 'other': 0}
    for name, ms in threads.items():
        if name == exe[:15]:
            g['ui'] += ms
        elif name.startswith('io.flutter.rast') or name.startswith('llvmpipe'):
            g['raster'] += ms
        elif name.startswith('io.flutter.io') or name.startswith('io.worker'):
            g['io'] += ms
        elif name.startswith('DartWorker'):
            g['dartWorker'] += ms
        else:
            g['other'] += ms
    return g


def diff(a, b):
    return {k: b.get(k, 0) - a.get(k, 0) for k in set(a) | set(b)}


class Run:
    def __init__(self, args, variant, block=None, order=None):
        self.args = args
        self.variant = variant
        self.app = app_for(variant)
        self.evidence = args.evidence
        self.block = block
        self.order = order
        self.platform = common.PLATFORM_LINUX
        self.id = args.run_id or common.run_id(self.platform, args.scenario, variant, block or 0, self.evidence)
        sub = 'evidence' if self.evidence else 'runs'
        self.dir = os.path.join(args.results, self.platform, sub, self.id)
        os.makedirs(self.dir)
        self.gateway = common.Gateway(args.gateway)
        self.markers = common.Markers()
        self.flags = []
        self.problems = []
        self.cpu = {}
        self.threads = {}
        self.hwm = None
        self.proc = None
        self.sampler = None
        self.recorder = None
        self.grabber = None
        self.grabs = {}
        self.actions = []
        self.ledger_dir = None
        self.sync_epoch_ms = None
        self.tools = os.path.abspath(args.tools)

    def log(self, msg):
        print(f'[{self.id}] {msg}', flush=True)
        with open(os.path.join(self.dir, 'harness.log'), 'a') as f:
            f.write(f'{now_ms()} {msg}\n')

    def node(self, *argv, check=False):
        r = subprocess.run(['taskset', '-c', '2,3', self.args.node, *argv], capture_output=True, text=True)
        if check and r.returncode:
            raise SystemExit(f'node {argv[0]}: {r.stderr or r.stdout}')
        return r

    # -- before launch
    def prepare(self):
        # The vendored copy of shared/ (tools/bin/sync-shared), which the app bundles.
        journey_path = os.path.join(FIELDTEST, 'shared', 'journey.json')
        self.journey = common.load_journey(journey_path)
        self.journey_hash = common.sha256_file(journey_path)
        lock = json.load(open(os.path.join(FIELDTEST, 'shared', 'fixtures.lock.json')))
        self.fixtures_hash = f"sha256:{lock.get('hash')}"
        self.scenario_id, self.scenario = common.find_scenario(self.journey, self.args.scenario)
        exe = bundle(self.app)
        if not os.path.exists(exe):
            raise SystemExit(f'no build at {exe}: run `fmh.py build`')
        health = self.gateway.health()
        if 'error' in health:
            raise SystemExit(f'no gateway on {self.args.gateway} ({health["error"]}): run `fmh.py gateway start`')
        answer = json.loads(self.gateway.start_run(self.id))
        self.ledger_dir = os.path.dirname(answer['ledger'])
        if not self.args.keep_state:
            self._clear_state()

    def _clear_state(self):
        # Moved aside, not deleted: the run can be looked at afterwards.
        state = os.path.join(data_dir(self.app), 'traceway_v2')
        if os.path.exists(state):
            trash = os.path.join(CACHE, 'state-trash', self.id)
            os.makedirs(os.path.dirname(trash), exist_ok=True)
            shutil.move(state, trash)
            self.log(f'moved SDK state to {trash}')

    def env(self):
        e = {k: v for k, v in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'WAYLAND_SOCKET')}
        e.update({
            # The desktop may run Wayland; the app must open on the private display.
            'GDK_BACKEND': 'x11',
            'DISPLAY': self.args.display,
            'FM_RUN': self.id,
            'FM_VARIANT': self.variant,
            'FM_SCENARIO': self.args.scenario,
            'FM_BASE_URL': self.args.gateway,
            'FM_FIXTURES': self.args.gateway + '/fx',
            'FM_TOKEN': 'flutter-dev-token',
            'FM_EVIDENCE': '1' if self.evidence else '0',
            'FM_AUTOPILOT': '1',
            'FM_TARGET': 'linux-xvfb',
            'FM_CAMPAIGN': os.path.basename(os.path.normpath(self.args.results)),
        })
        if self.args.fps:
            e['FM_FPS'] = str(self.args.fps)
        return e

    # -- screen recording (evidence)
    def start_recorder(self):
        self.recorder = subprocess.Popen(
            ['taskset', '-c', '2,3', 'ffmpeg', '-loglevel', 'error', '-y', '-f', 'x11grab', '-draw_mouse', '0',
             '-framerate', '30', '-video_size', f'{WIDTH}x{HEIGHT}', '-i', f'{self.args.display}+0,0',
             # Absolute (wall-clock) timestamps: x11grab stamps each frame with the
             # time it was grabbed, the clock the app and the SDK use.
             '-copyts', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-maxrate', '2M', '-bufsize', '4M',
             '-pix_fmt', 'yuv420p', '-g', '60', '-f', 'matroska', os.path.join(self.dir, 'screen.mkv')],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.dir, 'ffmpeg.log'), 'w'))
        time.sleep(0.6)

    def stop_recorder(self):
        if not self.recorder:
            return
        try:
            self.recorder.stdin.write(b'q')
            self.recorder.stdin.flush()
        except BrokenPipeError:
            pass
        try:
            self.recorder.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.recorder.kill()
        mkv = os.path.join(self.dir, 'screen.mkv')
        probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=start_time,duration',
                                '-show_entries', 'stream=nb_read_packets', '-count_packets', '-of', 'json', mkv],
                               capture_output=True, text=True)
        info = json.loads(probe.stdout or '{}')
        start = float(info.get('format', {}).get('start_time', 0))
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', mkv, '-c', 'copy', '-movflags', '+faststart',
                        os.path.join(self.dir, 'screen.mp4')], check=False)
        frames = int((info.get('streams') or [{}])[0].get('nb_read_packets', 0))
        mp4 = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json',
                                         os.path.join(self.dir, 'screen.mp4')], capture_output=True, text=True).stdout or '{}')
        duration = float(mp4.get('format', {}).get('duration', 0))
        write_json(os.path.join(self.dir, 'screen.json'), {
            'file': 'screen.mp4',
            'startEpochMs': round(start * 1000, 1),
            'syncEpochMs': self.sync_epoch_ms,
            'source': f'ffmpeg x11grab of the private X display {self.args.display} at +0,0, 30 fps, H.264 CRF 23; '
                      'every frame carries the wall-clock time it was grabbed (-copyts), the clock the app and the SDK use',
            'width': WIDTH, 'height': HEIGHT, 'scale': 1,
            'notes': f'{frames} frames, {duration:.2f} s. Video time t is epoch startEpochMs + 1000 t (exact per frame); '
                     'before the app starts, a magenta window turns green at syncEpochMs (the sync flash of '
                     'tools/replay-render/sync.mjs, drawn on the X display). The app window is at 0,0.',
        })
        os.remove(mkv)

    # -- the app's output
    def reader(self):
        out = open(os.path.join(self.dir, 'app.log'), 'w')
        for raw in self.proc.stdout:
            line = raw.decode('utf-8', 'replace').rstrip('\n')
            at = now_ms()
            out.write(f'{at} {line}\n')
            out.flush()
            if line.startswith('FM_ACTION '):
                try:
                    self.actions.append(json.loads(line[10:]))
                except json.JSONDecodeError:
                    pass
                continue
            kind, payload = self.markers.feed(line)
            if kind == 'ready':
                self._on_ready()
            elif kind == 'checkpoint' and self.evidence:
                self._grab(*payload)
            elif kind == 'request':
                self._on_request(payload)
            elif kind == 'done':
                self._on_done()
        out.close()

    def _exclude_pids(self):
        """What runs next to the app on purpose: the gateway, the backend, the X server,
        the screen recorder and this harness. Their CPU is not host noise."""
        pids = {os.getpid()}
        if self.recorder:
            pids.add(self.recorder.pid)
        for pattern in ('gateway.mjs', f'Xvfb {self.args.display}', 'devtesting-embedded'):
            r = subprocess.run(['pgrep', '-f', pattern], capture_output=True, text=True)
            pids.update(int(x) for x in r.stdout.split())
        return sorted(pids)

    def _on_ready(self):
        pid = self.proc_pid
        self.cpu['t0'] = proc_cpu(pid)
        self.threads['t0'] = proc_threads(pid)
        sampler = os.path.join(self.tools, 'sampler', 'proc-sampler.mjs')
        self.sampler = subprocess.Popen(
            ['taskset', '-c', '2,3', self.args.node, sampler, '--pid', str(pid), '--out', os.path.join(self.dir, 'samples.jsonl'),
             '--interval-ms', '1000', '--threads', '--t0', str(self.markers.ready),
             '--exclude-pids', ','.join(str(p) for p in self._exclude_pids())],
            stdout=open(os.path.join(self.dir, 'sampler.log'), 'w'), stderr=subprocess.STDOUT)

    def _grab(self, name, at):
        try:
            os.makedirs(os.path.join(self.dir, 'app'), exist_ok=True)
            path = os.path.join(self.dir, 'app', f'{name}.png')
            grabbed = self.grabber.png(path, 0, 0, WIDTH, HEIGHT)
            self.grabs[name] = {'checkpointEpochMs': at, 'grabEpochMs': round(grabbed), 'lagMs': round(grabbed - at)}
        except Exception as e:  # noqa: BLE001
            self.log(f'screenshot {name} failed: {e}')

    def _on_request(self, parts):
        try:
            if parts[0] == 'fault':
                self.gateway.fault(parts[1], int(parts[2]))
                self.log(f'fault {parts[1]} {parts[2]} s')
            else:
                self.log(f'request {" ".join(parts)} is not handled on Linux')
        except Exception as e:  # noqa: BLE001
            self.log(f'request {parts} failed: {e}')

    def _on_done(self):
        pid = self.proc_pid
        self.cpu['done'] = proc_cpu(pid)
        self.threads['done'] = proc_threads(pid)
        self.hwm = proc_status(pid, 'VmHWM')
        # The standard ending: Home (simulated on Linux), 5 s, then stopped.
        os.kill(pid, signal.SIGUSR1)
        threading.Timer(5.0, self._terminate).start()

    def _terminate(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)

    # -- the whole run
    def execute(self):
        self.prepare()
        if self.evidence:
            import xgrab
            self.grabber = xgrab.Grabber(self.args.display)
            self.start_recorder()
            # Magenta, then green: the renderer finds the switch in the video.
            self.sync_epoch_ms = round(self.grabber.flash(0, 0, WIDTH, HEIGHT), 1)
            time.sleep(0.2)
        self.log(f'launch {self.variant} ({self.app["exe"]}) scenario {self.scenario_id}')
        self.spawn_ms = now_ms()
        self.proc = subprocess.Popen(['taskset', '-c', '0,1', bundle(self.app)], env=self.env(),
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.proc_pid = self.proc.pid
        t = threading.Thread(target=self.reader, daemon=True)
        t.start()
        limit = self.scenario.get('durationMs', 0) / 1000 + 90
        try:
            self.proc.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            self.problems.append('did not finish in time; killed')
            self.proc.kill()
            self.proc.wait()
        t.join(timeout=5)
        if self.sampler:
            self.sampler.send_signal(signal.SIGINT)
            try:
                self.sampler.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.sampler.kill()
        if self.evidence:
            self.stop_recorder()
            self.grabber.close()
        return self.collect()

    def collect(self):
        m = self.markers
        t0 = m.ready
        end = m.done
        probe = {}
        probe_src = m.probe_path or os.path.join(data_dir(self.app), 'fm-probe', f'{self.id}.json')
        if os.path.exists(probe_src):
            shutil.copy(probe_src, os.path.join(self.dir, 'probe.json'))
            probe = json.load(open(probe_src))
        # The run is closed when the gateway saw nothing of it for 5 s.
        try:
            quiet = json.loads(self.gateway._req('GET', f'/ctl/quiet?run={self.id}&ms=5000&timeout=90000', timeout=100))
        except Exception as e:  # noqa: BLE001
            quiet = {'error': str(e)}
        export = ['export', '--ledger', self.ledger_dir, '--run', self.id, '--to', self.dir]
        r = self.node(os.path.join(self.tools, 'gateway', 'ledger.mjs'), *export, *([] if self.evidence else ['--no-bodies']))
        if r.returncode:
            self.problems.append(f'ledger export: {r.stderr.strip()[:300]}')
        ledger_path = os.path.join(self.dir, 'ledger.jsonl')
        ledger = [json.loads(x) for x in open(ledger_path)] if os.path.exists(ledger_path) else []
        requests = [x for x in ledger if x.get('path')]
        steps = self.scenario.get('steps', [])
        write_json(os.path.join(self.dir, 'checkpoints.json'),
                   common.checkpoints_file(m, self.scenario_id, steps, t0, screenshots=self.evidence))
        text, worst = common.driver_log(m, t0 or 0)
        open(os.path.join(self.dir, 'driver.log'), 'w').write(text)
        write_json(os.path.join(self.dir, 'actions.json'), common.enrich_actions(self.actions, steps))
        if self.evidence:
            keep = ('text', 'id', 'role', 'x', 'y', 'w', 'h')
            boxes = {name: [{k: b[k] for k in keep if k in b} for b in v['boxes']] for name, v in m.boxes.items()}
            write_json(os.path.join(self.dir, 'boxes.json'), boxes)
            write_json(os.path.join(self.dir, 'boxes-detail.json'), m.boxes)
            write_json(os.path.join(self.dir, 'screenshots.json'), self.grabs)
        samples = []
        sp = os.path.join(self.dir, 'samples.jsonl')
        if os.path.exists(sp):
            samples = [x for x in (json.loads(line) for line in open(sp) if line.strip()) if not x.get('final')]

        # Validity (03-MEASUREMENT.md §5.3); flags as run.schema.json allows them.
        failed = [s for s in m.steps if not s.get('ok')]
        rc = self.proc.returncode
        if worst > common.LATE_LIMIT_MS:
            self.flags.append('late')
        if end is None:
            self.problems.append('the journey did not finish (no FM_DONE)')
        if failed:
            self.problems.append(f'{len(failed)} step(s) failed: ' + '; '.join(f"{s.get('i')} {s.get('do')} {s.get('id') or s.get('name') or ''}: {s.get('error')}" for s in failed[:5]))
        if end is not None and rc not in (-signal.SIGTERM, 0):
            self.flags.append('crashed')
        noise = common.host_noise(samples)
        if noise is not None and noise > 25:
            self.flags.append('noisy')
        if os.environ.get('BENCHRUN_STATE') == 'noisy' and 'noisy' not in self.flags:
            self.flags.append('noisy')
        valid = end is not None and worst <= common.LATE_LIMIT_MS and not failed and 'crashed' not in self.flags
        if not valid:
            self.flags.append('invalid')
        if getattr(self.args, 'warmup', False):
            self.flags.append('warmup')
        if getattr(self.args, 'retry', False):
            self.flags.append('retry')

        metrics = {}
        if t0 and end and 't0' in self.cpu and 'done' in self.cpu:
            secs = (end - t0) / 1000
            u = self.cpu['done'][0] - self.cpu['t0'][0]
            s = self.cpu['done'][1] - self.cpu['t0'][1]
            groups = thread_groups(diff(self.threads['t0'], self.threads['done']), self.app['exe'])
            metrics.update({
                'M-CPU-1': round((u + s) / 1000, 3),
                'M-CPU-1-user': round(u / 1000, 3),
                'M-CPU-1-sys': round(s / 1000, 3),
                'M-CPU-2': round(100 * (u + s) / 1000 / secs, 2),
                'M-CPU-3': round(groups['ui'] / 1000, 3),
                'M-CPU-threads': {k: round(v / 1000, 3) for k, v in groups.items()},
                'M-CPU-4': round(groups['dartWorker'] / 1000, 3),
            })
            if self.args.scenario.startswith('S0'):
                idle = [x for x in samples if 10000 <= x.get('t', -1) <= 70000]
                if len(idle) >= 2:
                    c0 = idle[0].get('cpuUserMs', 0) + idle[0].get('cpuSysMs', 0)
                    c1 = idle[-1].get('cpuUserMs', 0) + idle[-1].get('cpuSysMs', 0)
                    metrics['M-CPU-5'] = round(100 * (c1 - c0) / (idle[-1]['t'] - idle[0]['t']), 2)
            metrics.update(common.memory_metrics(samples, end - t0))
            if self.hwm:
                metrics['M-MEM-2-VmHWM'] = round(self.hwm / 1024, 1)
            metrics.update(common.frame_metrics(probe, t0, end))
            metrics.update(common.net_metrics(requests, secs / 60))
        if t0:
            metrics['M-ST-1'] = t0 - self.spawn_ms
        if m.fully:
            metrics['M-ST-2'] = m.fully - self.spawn_ms

        run = {
            'runId': self.id,
            'campaign': os.path.basename(os.path.normpath(self.args.results)),
            'platform': self.platform,
            'target': f'linux-xvfb release build, {WIDTH}x{HEIGHT} @1x, software rendering (Mesa llvmpipe)',
            'scenario': self.args.scenario,
            'variant': self.variant,
            'block': self.block,
            'orderInBlock': self.order,
            'evidence': self.evidence,
            't0EpochMs': t0 or 0,
            'endEpochMs': end or 0,
            'valid': valid,
            'flags': self.flags,
            'sessionId': m.session,
            'projectId': None,
            'device': {'width': WIDTH, 'height': HEIGHT, 'scale': 1},
            'metrics': metrics,
            'units': 'see 03-MEASUREMENT.md §2',
            'build': {**common.git_state(REPO), 'appBuildId': self.app['exe'],
                      'binarySha256': common.sha256_file(bundle(self.app))},
            'journeyHash': self.journey_hash,
            'fixturesHash': self.fixtures_hash,
            'scenarioKey': self.scenario_id,
            'spawnEpochMs': self.spawn_ms,
            'problems': self.problems,
            'driver': {'worstLateMs': worst, 'failedSteps': len(failed), 'steps': len(m.steps),
                       'actions': len(self.actions), 'summary': m.summary, 'errors': m.errors},
            'ledger': {'lines': len(ledger), 'requests': len(requests), 'quiet': quiet},
            'hostOtherPct': noise,
            'benchrun': os.environ.get('BENCHRUN_STATE'),
            'exitCode': rc,
        }
        write_json(os.path.join(self.dir, 'run.json'), run)
        self.validate()
        self.log(f'done: valid={valid} flags={self.flags} worstLate={worst} ms session={m.session} problems={self.problems}')
        return run

    def validate(self):
        """Checks the files against tools/schema; the result goes into schema.txt."""
        out = []
        for kind, name in (('run', 'run.json'), ('checkpoints', 'checkpoints.json'), ('actions', 'actions.json'),
                           ('boxes', 'boxes.json'), ('screen', 'screen.json')):
            f = os.path.join(self.dir, name)
            if os.path.exists(f):
                r = self.node(os.path.join(self.tools, 'schema', 'validate.mjs'), kind, f)
                out.append(f'{name}: {"ok" if r.returncode == 0 else "FAIL"} {(r.stdout + r.stderr).strip()[:400]}')
        open(os.path.join(self.dir, 'schema.txt'), 'w').write('\n'.join(out) + '\n')
        if any('FAIL' in x for x in out):
            self.log('schema: ' + ' | '.join(x for x in out if 'FAIL' in x))


def run_cmd(args):
    r = Run(args, args.variant, args.block, args.order)
    r.execute()


def block_cmd(args):
    variants = args.variants.split(',')
    order = common.shuffled(variants, args.seed, args.block, args.scenario)
    print(f'block {args.block} of {args.scenario}: {order}', flush=True)
    for i, v in enumerate(order):
        args.run_id = None
        args.retry = False
        run = Run(args, v, args.block, i).execute()
        time.sleep(args.gap)
        # A noisy or invalid run is kept, marked, and repeated once (03-MEASUREMENT.md §5).
        if not args.warmup and ('noisy' in run['flags'] or not run['valid']):
            args.run_id = None
            args.retry = True
            Run(args, v, args.block, i).execute()
            args.retry = False
            time.sleep(args.gap)


# ---- startup (03-MEASUREMENT.md §4) ---------------------------------------------------

def startup_cmd(args):
    """One repetition of the startup procedure: every variant in a seeded order,
    each from a cold process: 3 s, launch, FM_READY and FM_FULLY, 5 s, stop."""
    variants = args.variants.split(',')
    scenario = 'S0-startup-kept' if args.keep_state else 'S0-startup'
    order = common.shuffled(variants, args.seed, args.block, scenario)
    print(f'startup repetition {args.block} ({scenario}): {order}', flush=True)
    gw = common.Gateway(args.gateway)
    for i, v in enumerate(order):
        app = app_for(v)
        rid = common.run_id(common.PLATFORM_LINUX, scenario, v, args.block)
        d = os.path.join(args.results, common.PLATFORM_LINUX, 'runs', rid)
        os.makedirs(d)
        gw.start_run(rid)
        if not args.keep_state:
            state = os.path.join(data_dir(app), 'traceway_v2')
            if os.path.exists(state):
                trash = os.path.join(CACHE, 'state-trash', rid)
                os.makedirs(os.path.dirname(trash), exist_ok=True)
                shutil.move(state, trash)
        time.sleep(3)
        env = {k: val for k, val in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'WAYLAND_SOCKET')}
        env.update({'GDK_BACKEND': 'x11', 'DISPLAY': args.display, 'FM_RUN': rid, 'FM_VARIANT': v, 'FM_SCENARIO': scenario,
                    'FM_BASE_URL': args.gateway, 'FM_FIXTURES': args.gateway + '/fx', 'FM_TOKEN': 'flutter-dev-token',
                    'FM_EVIDENCE': '0', 'FM_AUTOPILOT': '0', 'FM_TARGET': 'linux-xvfb',
                    'FM_CAMPAIGN': os.path.basename(os.path.normpath(args.results))})
        spawn = now_ms()
        p = subprocess.Popen(['taskset', '-c', '0,1', bundle(app)], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        markers = common.Markers()
        log = open(os.path.join(d, 'app.log'), 'w')
        deadline = time.time() + 30

        def read():
            for raw in p.stdout:
                line = raw.decode('utf-8', 'replace').rstrip('\n')
                log.write(f'{now_ms()} {line}\n')
                markers.feed(line)

        t = threading.Thread(target=read, daemon=True)
        t.start()
        while time.time() < deadline and markers.fully is None and p.poll() is None:
            time.sleep(0.05)
        time.sleep(5)
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
        t.join(timeout=3)
        log.close()
        ok = markers.ready is not None and markers.fully is not None
        metrics = {}
        if markers.ready:
            metrics['M-ST-1'] = markers.ready - spawn
        if markers.fully:
            metrics['M-ST-2'] = markers.fully - spawn
        flags = [] if ok else ['invalid']
        if os.environ.get('BENCHRUN_STATE') == 'noisy':
            flags.append('noisy')
        write_json(os.path.join(d, 'run.json'), {
            'runId': rid, 'campaign': os.path.basename(os.path.normpath(args.results)), 'platform': common.PLATFORM_LINUX,
            'target': f'linux-xvfb release build, {WIDTH}x{HEIGHT} @1x, software rendering (Mesa llvmpipe)',
            'scenario': scenario, 'variant': v, 'block': args.block, 'orderInBlock': i, 'evidence': False,
            't0EpochMs': markers.ready or 0, 'endEpochMs': markers.fully or 0, 'valid': ok, 'flags': flags,
            'sessionId': markers.session, 'projectId': None, 'device': {'width': WIDTH, 'height': HEIGHT, 'scale': 1},
            'metrics': metrics, 'units': 'see 03-MEASUREMENT.md §2', 'spawnEpochMs': spawn,
            'build': {**common.git_state(REPO), 'appBuildId': app['exe'], 'binarySha256': common.sha256_file(bundle(app))},
            'journeyHash': common.sha256_file(os.path.join(FIELDTEST, 'shared', 'journey.json')),
            'fixturesHash': 'sha256:' + json.load(open(os.path.join(FIELDTEST, 'shared', 'fixtures.lock.json'))).get('hash', ''),
            'procedure': '03-MEASUREMENT.md §4: cold process, 3 s, launch, FM_READY / FM_FULLY, 5 s, SIGTERM; '
                         + ('SDK state kept from the previous launch' if args.keep_state else 'SDK state cleared'),
            'benchrun': os.environ.get('BENCHRUN_STATE'),
        })
        print(f'[{rid}] M-ST-1 {metrics.get("M-ST-1")} ms, M-ST-2 {metrics.get("M-ST-2")} ms{"" if ok else " INVALID"}', flush=True)


# ---- the whole tier -----------------------------------------------------------------------

def plan_cmd(args):
    """Every block of the tier, each under its own `benchrun` (quiet host, lock),
    so other work can take the lock between blocks. Stops when most runs are noisy."""
    me = os.path.abspath(__file__)
    benchrun = os.path.join(os.path.abspath(args.tools), 'bin', 'benchrun')
    base = [sys.executable, me, '--display', args.display]
    common_args = ['--results', args.results, '--tools', args.tools, '--node', args.node, '--gateway', args.gateway,
                   '--seed', str(args.seed)]
    steps = []
    for scenario in args.scenarios.split(','):
        variants = args.variants + (',stream-noimg' if scenario in args.noimg.split(',') else '')
        for block in range(0, args.repetitions + 1):
            steps.append([*base, 'block', *common_args, '--scenario', scenario, '--variants', variants,
                          '--block', str(block), *(['--warmup'] if block == 0 else [])])
    for rep in range(1, args.startup + 1):
        steps.append([*base, 'startup', *common_args, '--variants', args.variants, '--block', str(rep)])
    for rep in range(1, args.startup_kept + 1):
        steps.append([*base, 'startup', *common_args, '--variants', args.variants, '--block', str(rep), '--keep-state'])
    if args.soak:
        steps.append([*base, 'block', *common_args, '--scenario', 'S8', '--variants', args.soak, '--block', '1'])
    print(f'plan: {len(steps)} blocks', flush=True)
    for i, cmd in enumerate(steps):
        if i < args.skip:
            continue
        print(f'== {i + 1}/{len(steps)} {time.strftime("%H:%M:%S")} {" ".join(cmd[3:])}', flush=True)
        r = subprocess.run([benchrun, *cmd])
        print(f'== {i + 1}/{len(steps)} exit {r.returncode} {time.strftime("%H:%M:%S")}', flush=True)
        runs = []
        root = os.path.join(args.results, common.PLATFORM_LINUX, 'runs')
        for d in os.listdir(root):
            f = os.path.join(root, d, 'run.json')
            if os.path.exists(f):
                runs.append(json.load(open(f)))
        measured = [x for x in runs if 'warmup' not in x['flags']]
        noisy = [x for x in measured if 'noisy' in x['flags']]
        print(f'   runs so far {len(runs)}, measured {len(measured)}, noisy {len(noisy)}', flush=True)
        if len(measured) >= 10 and len(noisy) > 0.5 * len(measured):
            print('STOP: most runs are noisy', flush=True)
            return
    print('PLAN DONE', flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--display', default=':78')
    sub = ap.add_subparsers(dest='cmd', required=True)

    x = sub.add_parser('xvfb')
    x.add_argument('action', choices=['start', 'stop', 'status'])

    g = sub.add_parser('gateway')
    g.add_argument('action', choices=['start', 'stop', 'status'])
    g.add_argument('--tools', default=default_tools())
    g.add_argument('--node', default=default_node())
    g.add_argument('--gateway', default='http://127.0.0.1:18190')

    b = sub.add_parser('build')
    b.add_argument('which', nargs='?', default='all', choices=['off', 'sdk', 'all'])

    p = sub.add_parser('proof-off')
    p.add_argument('--results')

    for name in ('run', 'block', 'startup', 'plan'):
        r = sub.add_parser(name)
        r.add_argument('--results', required=True, help='results/<campaign> folder')
        r.add_argument('--tools', default=default_tools())
        r.add_argument('--node', default=default_node())
        r.add_argument('--gateway', default='http://127.0.0.1:18190')
        r.add_argument('--scenario', required=name in ('run', 'block'))
        r.add_argument('--evidence', action='store_true')
        r.add_argument('--warmup', action='store_true', help='a warm-up block: its runs are flagged warmup')
        r.add_argument('--keep-state', action='store_true')
        r.add_argument('--fps', type=int)
        r.add_argument('--run-id')
        r.add_argument('--block', type=int, default=0)
        r.add_argument('--order', type=int)
        if name == 'run':
            r.add_argument('--variant', required=True)
        else:
            r.add_argument('--variants', required=True)
            r.add_argument('--seed', default='0')
            r.add_argument('--gap', type=float, default=3.0)
        if name == 'plan':
            r.add_argument('--scenarios', required=True)
            r.add_argument('--repetitions', type=int, default=5)
            r.add_argument('--noimg', default='S1,S2', help='scenarios that also run stream-noimg')
            r.add_argument('--startup', type=int, default=10)
            r.add_argument('--startup-kept', type=int, default=0)
            r.add_argument('--soak', default='', help='variants for one S8 block, e.g. off,stream-img')
            r.add_argument('--skip', type=int, default=0, help='blocks already done')

    args = ap.parse_args()
    {'xvfb': xvfb, 'gateway': gateway, 'build': build, 'proof-off': proof_off, 'run': run_cmd,
     'block': block_cmd, 'startup': startup_cmd, 'plan': plan_cmd}[args.cmd](args)


if __name__ == '__main__':
    main()
