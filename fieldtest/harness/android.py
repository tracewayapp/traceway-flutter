#!/usr/bin/env python3
"""Fieldmart harness for Flutter on Android, through adb (AGENT-3 step 4).

The same harness serves the emulator on a GitHub runner (the planned route,
with the gateway in capture mode next to it) and a phone on this machine.

  android.py install --serial S --apk-off A --apk-sdk B
  android.py run --serial S --results DIR --scenario S6 --variant stream-img [--evidence]
  android.py block --serial S --results DIR --scenario S1 --variants off,off2 --block 1
  android.py plan --serial S --results DIR --scenarios S1,S6 --variants off,off2,core,stream-img --repetitions 5

`--expire-and-relaunch S` (run, block, plan) starts the SDK variants with an
inactivity timeout of S seconds and, after the standard ending, launches the
app once more when that session has expired: without the autopilot and with
no session of its own, so the SDK ends the killed session (session.end,
app.memory.peak) and the run keeps one session.

The app is driven by its own autopilot; this script launches it with the
launch settings as intent extras, reads the marker lines from logcat (tag
FM), samples /proc once a second, takes screenshots at checkpoints and
records the screen in evidence runs, and performs the standard ending
(Home, 5 s, force-stop). Standard library only.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from common import now_ms, write_json, write_jsonl  # noqa: E402

PACKAGES = {
    'off': 'com.tracewayapp.fieldmart.flutter.off',
    'sdk': 'com.tracewayapp.fieldmart.flutter',
}
PLATFORM = os.environ.get('FM_PLATFORM', 'flutter-android@emulator')
HERE = os.path.dirname(os.path.abspath(__file__))
FIELDTEST = os.path.dirname(HERE)
REPO = os.path.dirname(FIELDTEST)


def package_for(variant):
    return PACKAGES['off' if variant in ('off', 'off2') else 'sdk']


class Adb:
    def __init__(self, serial, adb=None):
        self.serial = serial
        self.adb = adb or os.environ.get('FM_ADB') or shutil.which('adb') or os.path.expanduser('~/Android/Sdk/platform-tools/adb')

    def cmd(self, *args):
        return [self.adb, '-s', self.serial, *args]

    def run(self, *args, check=False, timeout=60):
        r = subprocess.run(self.cmd(*args), capture_output=True, timeout=timeout)
        if check and r.returncode:
            raise RuntimeError(f'adb {" ".join(args)}: {r.stderr.decode(errors="replace")}')
        return r.stdout.decode(errors='replace')

    def shell(self, command, timeout=60):
        return self.run('shell', command, timeout=timeout)

    def epoch_ms(self):
        return int(self.shell('date +%s%3N').strip() or 0)


def write_screen_json(run_dir, pieces, merged=False):
    """screen.json as tools/schema/screen.schema.json wants it. With more than one
    screenrecord piece, screen.mp4 is made afterwards by `merge-screen`."""
    write_json(os.path.join(run_dir, 'screen.json'), {
        'file': 'screen.mp4',
        'startEpochMs': pieces[0]['deviceStartEpochMs'] if pieces else 0,
        'source': 'adb screenrecord --bit-rate 4000000 in pieces of at most 170 s'
                  + (', placed on one timeline by android.py merge-screen' if merged else ''),
        'notes': 'startEpochMs is the device clock read just before screenrecord started; the first frame comes '
                 'a little later (screenrecord start-up), so the alignment is good to about 0.2 s. '
                 f'{len(pieces)} piece(s); between pieces the screen is black for the restart.',
        'pieces': pieces,
    })


def merge_screen(args):
    """Places the screenrecord pieces of an evidence run on one timeline that starts
    with the first piece: screen.mp4 (H.264 as the shared tools encode it)."""
    d = args.run_dir
    info = json.load(open(os.path.join(d, 'screen.json')))
    pieces = [p for p in info.get('pieces', []) if os.path.exists(os.path.join(d, p['file']))]
    if not pieces:
        raise SystemExit('no screenrecord pieces in the run folder')
    t0 = pieces[0]['deviceStartEpochMs']

    def probe(f):
        r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height:format=duration',
                            '-of', 'json', os.path.join(d, f)], capture_output=True, text=True)
        j = json.loads(r.stdout)
        return j['streams'][0]['width'], j['streams'][0]['height'], float(j['format']['duration'])

    w, h, _ = probe(pieces[0]['file'])
    end = max((p['deviceStartEpochMs'] - t0) / 1000 + probe(p['file'])[2] for p in pieces)
    cmd = ['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'color=black:size={w}x{h}:rate=30:duration={end:.3f}']
    for p in pieces:
        cmd += ['-itsoffset', f'{(p["deviceStartEpochMs"] - t0) / 1000:.3f}', '-i', os.path.join(d, p['file'])]
    chain, last = [], '0:v'
    for i in range(len(pieces)):
        out = f'v{i}'
        chain.append(f'[{last}][{i + 1}:v]overlay=eof_action=pass[{out}]')
        last = out
    cmd += ['-filter_complex', ';'.join(chain), '-map', f'[{last}]', '-c:v', 'libx264', '-crf', '23', '-maxrate', '2M',
            '-bufsize', '4M', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', os.path.join(d, 'screen.mp4')]
    subprocess.run(cmd, check=True)
    write_screen_json(d, pieces, merged=True)
    print(f'screen.mp4: {len(pieces)} piece(s), {end:.1f} s, {w}x{h}')


def crop_to_app(args):
    """Screenshots and screen video show the whole screen; the app's window (what
    the replay shows and the boxes are measured in) sits below the status bar.
    Crops both to the window the app reported (FM_INFO size) and sets run.json
    `device`. The window starts at the top of the screen when the app draws behind
    the status bar (FM_INFO padTop > 0, the template's default); otherwise below
    it. --top overrides. Originals stay as app-full/ and screen-full.mp4."""
    d = args.run_dir
    info = [l for l in open(os.path.join(d, 'app.log')) if 'FM_INFO' in l]
    m = re.search(r'size=([\d.]+)x([\d.]+) dpr=([\d.]+)', info[0]) if info else None
    if not m:
        raise SystemExit('no FM_INFO window size in app.log')
    vw, vh, dpr = float(m.group(1)), float(m.group(2)), float(m.group(3))
    pad = re.search(r'padTop=([\d.]+)', info[0])
    shots = sorted(f for f in os.listdir(os.path.join(d, 'app')) if f.endswith('.png')) if os.path.isdir(os.path.join(d, 'app')) else []

    def size(path):
        r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height',
                            '-of', 'csv=p=0', path], capture_output=True, text=True)
        w, h = r.stdout.strip().split(',')[:2]
        return int(w), int(h)

    def crop(src, dst):
        w, h = size(src)
        if args.top is not None:
            top = args.top
        elif pad:
            top = 0 if float(pad.group(1)) > 0 else h - int(round(vh))
        else:
            raise SystemExit('FM_INFO has no padTop: give --top')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', src, '-vf', f'crop={int(round(vw))}:{int(round(vh))}:0:{top}',
                        *(['-c:v', 'libx264', '-crf', '23', '-maxrate', '2M', '-bufsize', '4M', '-pix_fmt', 'yuv420p',
                           '-movflags', '+faststart'] if dst.endswith('.mp4') else []), dst], check=True)
        return top

    top = None
    if shots:
        if not os.path.isdir(os.path.join(d, 'app-full')):
            shutil.copytree(os.path.join(d, 'app'), os.path.join(d, 'app-full'))
        for f in shots:
            top = crop(os.path.join(d, 'app-full', f), os.path.join(d, 'app', f))
    video = os.path.join(d, 'screen.mp4')
    if os.path.exists(video) or os.path.exists(os.path.join(d, 'screen-full.mp4')):
        if not os.path.exists(os.path.join(d, 'screen-full.mp4')):
            shutil.move(video, os.path.join(d, 'screen-full.mp4'))
        top = crop(os.path.join(d, 'screen-full.mp4'), video)
        sj = json.load(open(os.path.join(d, 'screen.json')))
        sj.update({'width': int(round(vw)), 'height': int(round(vh)), 'scale': dpr})
        sj['notes'] = sj.get('notes', '').split(' Cropped to')[0] + (
            f' Cropped to the app window: {int(round(vw))}x{int(round(vh))} px at y={top} of the screen; '
            'the whole screen is screen-full.mp4.')
        write_json(os.path.join(d, 'screen.json'), sj)
    rj = json.load(open(os.path.join(d, 'run.json')))
    rj['device'] = {'width': round(vw / dpr, 2), 'height': round(vh / dpr, 2), 'scale': dpr}
    write_json(os.path.join(d, 'run.json'), rj)
    print(f'app window {vw:.0f}x{vh:.0f} px @ {dpr} at y={top}; {len(shots)} screenshot(s) cropped')


def install(args):
    adb = Adb(args.serial)
    adb.run('reverse', 'tcp:18190', 'tcp:18190', check=True)
    for apk in (args.apk_off, args.apk_sdk):
        print(adb.run('install', '-r', '-g', apk, check=True, timeout=300).strip())
    for pkg in PACKAGES.values():
        # Compiled ahead of the runs, so there is no JIT warm-up difference.
        print(pkg, adb.shell(f'cmd package compile -m speed -f {pkg}', timeout=300).strip())


def parse_stat(line):
    """(name, utime ticks, stime ticks) from one /proc/.../stat line."""
    name = line[line.index('(') + 1:line.rindex(')')]
    f = line.rsplit(')', 1)[1].split()
    return name, int(f[11]), int(f[12])


class Run:
    def __init__(self, args, variant, block=None, order=None):
        self.args = args
        self.adb = Adb(args.serial)
        self.variant = variant
        self.pkg = package_for(variant)
        self.evidence = args.evidence
        self.block = block
        self.order = order
        self.id = args.run_id or common.run_id(PLATFORM.split('@')[0], args.scenario, variant, block or 0, self.evidence)
        self.dir = os.path.join(args.results, PLATFORM, 'evidence' if self.evidence else 'runs', self.id)
        os.makedirs(self.dir)
        self.gateway = common.Gateway(args.gateway)
        self.markers = common.Markers()
        self.flags = ['capture-mode'] if args.capture else []
        self.samples = []
        self.pid = None
        self.stop = threading.Event()
        self.grabs = {}
        self.records = []
        self.actions = []
        self.done_cpu = None
        self.tck = 100
        self.relaunched = None

    def log(self, msg):
        print(f'[{self.id}] {msg}', flush=True)
        with open(os.path.join(self.dir, 'harness.log'), 'a') as f:
            f.write(f'{now_ms()} {msg}\n')

    def extras(self, **more):
        e = {
            'fmRun': self.id, 'fmVariant': self.variant, 'fmScenario': self.args.scenario,
            'fmBaseUrl': self.args.gateway, 'fmFixtures': self.args.gateway + '/fx',
            'fmToken': 'flutter-dev-token', 'fmEvidence': '1' if self.evidence else '0',
            'fmAutopilot': '1', 'fmTarget': self.args.target,
            'fmCampaign': os.path.basename(os.path.normpath(self.args.results)),
        }
        if self.args.fps:
            e['fmFps'] = str(self.args.fps)
        if self.relaunches():
            e['fmSessionIdleMs'] = str(self.args.expire_and_relaunch * 1000)
        e.update(more)
        # The command runs in the device's shell: a value with a space (the target)
        # must stay one word, or am stops reading extras there.
        out = []
        for k, v in e.items():
            out += ['--es', k, shlex.quote(v)]
        return out

    # -- logcat
    def logcat(self):
        self.adb.run('logcat', '-c')
        proc = subprocess.Popen(self.adb.cmd('logcat', '-v', 'epoch', '-s', 'FM:I', 'flutter:I', 'AndroidRuntime:E'),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self._logcat = proc
        out = open(os.path.join(self.dir, 'app.log'), 'w')
        rx = re.compile(r'^\s*(\d+\.\d+)\s+\d+\s+\d+\s+\w\s+(\S+)\s*:\s?(.*)$')
        for raw in proc.stdout:
            line = raw.decode('utf-8', 'replace').rstrip('\n')
            m = rx.match(line)
            if not m:
                continue
            at, tag, msg = m.group(1), m.group(2), m.group(3)
            out.write(f'{int(float(at) * 1000)} {tag} {msg}\n')
            out.flush()
            if tag != 'FM':
                continue
            if msg.startswith('FM_ACTION '):
                try:
                    self.actions.append(json.loads(msg[10:]))
                except json.JSONDecodeError:
                    pass
                continue
            kind, payload = self.markers.feed(msg)
            if kind == 'ready':
                threading.Thread(target=self.sampler, daemon=True).start()
            elif kind == 'checkpoint' and self.evidence:
                threading.Thread(target=self.screencap, args=payload, daemon=True).start()
            elif kind == 'request':
                self.on_request(payload)
            elif kind == 'done':
                self.on_done()
            if self.stop.is_set() and kind == 'done':
                break
        out.close()

    # -- sampling (03-MEASUREMENT.md §3.3)
    def read_proc(self):
        raw = self.adb.shell(f'cat /proc/{self.pid}/stat; echo ==; cat /proc/{self.pid}/statm; echo ==; '
                             f'cat /proc/{self.pid}/task/*/stat 2>/dev/null', timeout=10)
        parts = raw.split('==')
        if len(parts) < 3 or '(' not in parts[0]:
            return None
        _, u, s = parse_stat(parts[0].strip())
        resident = int(parts[1].split()[1]) * 4
        threads = {}
        for line in parts[2].strip().splitlines():
            try:
                name, tu, ts = parse_stat(line)
                threads[name] = threads.get(name, 0) + (tu + ts) * 1000 // self.tck
            except ValueError:
                pass
        return {'cpuUserMs': u * 1000 // self.tck, 'cpuSysMs': s * 1000 // self.tck, 'rssKb': resident, 'threads': threads}

    def sampler(self):
        self.pid = self.adb.shell(f'pidof {self.pkg}').strip().split(' ')[0] or None
        if not self.pid:
            self.log('no pid for the app')
            return
        t0 = self.markers.ready
        while not self.stop.is_set():
            at = self.adb.epoch_ms()
            s = self.read_proc()
            if s is None:
                break
            s['t'] = at - t0
            self.samples.append(s)
            time.sleep(max(0.0, 1.0 - (self.adb.epoch_ms() - at) / 1000))

    def screencap(self, name, at):
        """Raw screencap (RGBA, fast on the device; `-p` makes the device encode a PNG,
        which takes seconds on an emulator), written as PNG here."""
        import struct
        import xgrab
        os.makedirs(os.path.join(self.dir, 'app'), exist_ok=True)
        before = now_ms()
        raw = subprocess.run(self.adb.cmd('exec-out', 'screencap'), capture_output=True).stdout
        got = now_ms()
        path = os.path.join(self.dir, 'app', f'{name}.png')
        try:
            w, h = struct.unpack_from('<II', raw, 0)
            px = raw[len(raw) - w * h * 4:]
            rgb = bytearray(w * h * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = px[0::4], px[1::4], px[2::4]
            xgrab.write_png(path, w, h, bytes(rgb))
        except (struct.error, ValueError) as e:
            self.log(f'screencap {name}: {e}')
        self.grabs[name] = {'checkpointEpochMs': at, 'hostRequestEpochMs': before, 'hostReceivedEpochMs': got,
                            'hostDoneEpochMs': now_ms()}

    def recorder(self):
        """`screenrecord` in chained 170 s pieces, each with the device time it started."""
        n = 0
        while not self.stop.is_set():
            remote = f'/sdcard/fm-{self.id}-{n:02d}.mp4'
            start = self.adb.epoch_ms()
            proc = subprocess.Popen(self.adb.cmd('shell', f'screenrecord --bit-rate 4000000 --time-limit 170 {remote}'))
            self.records.append({'remote': remote, 'deviceStartEpochMs': start})
            while proc.poll() is None:
                if self.stop.wait(0.5):
                    self.adb.shell('pkill -INT screenrecord')
                    proc.wait(timeout=15)
                    break
            n += 1

    def on_request(self, parts):
        what = parts[0]
        try:
            if what == 'background':
                self.adb.shell('input keyevent 3')
            elif what == 'foreground':
                self.adb.shell(f'am start -n {self.pkg}/.MainActivity')
            elif what == 'fault':
                self.gateway.fault(parts[1], int(parts[2]))
            else:
                self.log(f'request {parts} not handled')
        except Exception as e:  # noqa: BLE001
            self.log(f'request {parts}: {e}')

    def relaunches(self):
        return bool(getattr(self.args, 'expire_and_relaunch', 0)) and self.pkg == PACKAGES['sdk']

    def relaunch(self):
        """The launch after the kill, once the session has expired: no autopilot, no
        session of its own (fmSessions=0), the probe file elsewhere; 10 s, then the
        standard ending. The SDK ends the stored session at this start."""
        idle = self.args.expire_and_relaunch
        due = self.markers.done + (idle + 5) * 1000
        wait = (due - self.adb.epoch_ms()) / 1000
        self.log(f'relaunch in {max(0, wait):.0f} s, once the {idle} s inactivity timeout has passed')
        if wait > 0:
            time.sleep(wait)
        self.adb.run('logcat', '-c')
        started = self.adb.epoch_ms()
        extras = self.extras(fmAutopilot='0', fmSessions='0',
                             fmProbeDir=f'/sdcard/Android/data/{self.pkg}/files/fm-probe-relaunch')
        self.adb.shell(f'am start -W -n {self.pkg}/.MainActivity ' + ' '.join(extras), timeout=60)
        time.sleep(10)
        self.adb.shell('input keyevent 3')
        time.sleep(5)
        self.adb.shell(f'am force-stop {self.pkg}')
        ended = self.adb.epoch_ms()
        log = self.adb.run('logcat', '-d', '-v', 'epoch', '-s', 'FM:I', 'flutter:I', 'AndroidRuntime:E', timeout=60)
        open(os.path.join(self.dir, 'app-relaunch.log'), 'w').write(log)
        self.relaunched = {'inactivityS': idle, 'startEpochMs': started, 'endEpochMs': ended,
                           'what': 'launched again after the session expired: no autopilot, no session of its own '
                                   '(fmSessions=0); 10 s, Home, 5 s, force-stop'}
        self.log(f'relaunch done ({(ended - started) / 1000:.1f} s)')

    def on_done(self):
        if self.pid:
            self.done_cpu = self.read_proc()
        # The standard ending: Home, 5 s, force-stop.
        self.adb.shell('input keyevent 3')
        time.sleep(5)
        self.adb.shell(f'am force-stop {self.pkg}')
        self.stop.set()

    def device(self):
        """The screen in logical pixels: `wm size` (an override wins) over `wm density` / 160."""
        size = re.findall(r'(\d+)x(\d+)', self.adb.shell('wm size'))
        dens = re.findall(r'(\d+)', self.adb.shell('wm density'))
        if not size or not dens:
            return None
        w, h = map(int, size[-1])
        scale = int(dens[-1]) / 160
        return {'width': round(w / scale, 2), 'height': round(h / scale, 2), 'scale': scale}

    def window(self, markers):
        """The app's window in logical pixels, from its FM_INFO line."""
        for line in open(os.path.join(self.dir, 'app.log')):
            m = re.search(r'size=([\d.]+)x([\d.]+) dpr=([\d.]+)', line)
            if m:
                dpr = float(m.group(3))
                return {'width': round(float(m.group(1)) / dpr, 2), 'height': round(float(m.group(2)) / dpr, 2), 'scale': dpr}
        return None

    def execute(self):
        self.tck = int(self.adb.shell('getconf CLK_TCK').strip() or 100)
        self.screen = self.device()
        jpath = os.path.join(FIELDTEST, 'fieldmart_ui', 'assets', 'journey.json')
        journey = common.load_journey(jpath)
        scenario_id, scenario = common.find_scenario(journey, self.args.scenario)
        self.gateway.start_run(self.id)
        self.adb.shell(f'am force-stop {self.pkg}')
        if not self.args.keep_state:
            self.adb.shell(f'pm clear {self.pkg}')
        reader = threading.Thread(target=self.logcat, daemon=True)
        reader.start()
        rec = None
        if self.evidence:
            rec = threading.Thread(target=self.recorder, daemon=True)
            rec.start()
            time.sleep(1.0)
        self.log(f'launch {self.variant} ({self.pkg}) scenario {scenario_id}')
        start_out = self.adb.shell(f'am start -W -n {self.pkg}/.MainActivity ' + ' '.join(self.extras()), timeout=60)
        total = re.search(r'TotalTime:\s*(\d+)', start_out)
        deadline = time.time() + scenario.get('durationMs', 0) / 1000 + 120
        while not self.stop.is_set() and time.time() < deadline:
            time.sleep(0.5)
        if not self.stop.is_set():
            self.flags.append('timeout')
            self.adb.shell(f'am force-stop {self.pkg}')
            self.stop.set()
        self._logcat.terminate()
        reader.join(timeout=5)
        if rec:
            rec.join(timeout=30)
            for i, r in enumerate(self.records):
                local = os.path.join(self.dir, f'screen-{i:02d}.mp4')
                self.adb.run('pull', r['remote'], local, timeout=120)
                self.adb.shell(f'rm {r["remote"]}')
                r['file'] = os.path.basename(local)
            write_screen_json(self.dir, self.records)
            if len(self.records) == 1:
                shutil.copy(os.path.join(self.dir, self.records[0]['file']), os.path.join(self.dir, 'screen.mp4'))
        if self.relaunches() and self.markers.done:
            self.relaunch()
        self.collect(scenario_id, scenario, int(total.group(1)) if total else None, jpath)

    def collect(self, scenario_id, scenario, start_total, jpath):
        m = self.markers
        t0, end = m.ready, m.done
        probe = {}
        local = os.path.join(self.dir, 'probe.json')
        self.adb.run('pull', f'/sdcard/Android/data/{self.pkg}/files/fm-probe/{self.id}.json', local)
        if os.path.exists(local):
            probe = json.load(open(local))
        ledger, quiet = self.gateway.wait_quiet(self.id)
        write_jsonl(os.path.join(self.dir, 'ledger.jsonl'), ledger)
        try:
            write_json(os.path.join(self.dir, 'fxlog.json'), self.gateway.fxlog(self.id))
        except Exception as e:  # noqa: BLE001
            self.log(f'fxlog: {e}')
        write_jsonl(os.path.join(self.dir, 'samples.jsonl'), self.samples)
        write_json(os.path.join(self.dir, 'checkpoints.json'),
                   common.checkpoints_file(m, scenario_id, scenario.get('steps', []), t0))
        text, worst = common.driver_log(m, t0 or 0)
        open(os.path.join(self.dir, 'driver.log'), 'w').write(text)
        write_json(os.path.join(self.dir, 'actions.json'), common.enrich_actions(self.actions, scenario.get('steps', [])))
        if self.evidence:
            write_json(os.path.join(self.dir, 'boxes.json'),
                       {n: [{k: b[k] for k in ('text', 'id', 'role', 'x', 'y', 'w', 'h') if k in b} for b in v['boxes']]
                        for n, v in m.boxes.items()})
            write_json(os.path.join(self.dir, 'boxes-detail.json'), m.boxes)
            write_json(os.path.join(self.dir, 'screenshots.json'), self.grabs)
        failed = [s for s in m.steps if not s.get('ok')]
        if self.block == 0 and getattr(self.args, 'warmup', False):
            self.flags.append('warmup')
        if worst > common.LATE_LIMIT_MS:
            self.flags.append('late')
        problems = []
        if end is None:
            problems.append('the journey did not finish (no FM_DONE)')
        if failed:
            problems.append(f'{len(failed)} step(s) failed: ' + '; '.join(
                f"{s.get('i')} {s.get('do')} {s.get('id') or s.get('name') or ''}: {s.get('error')}" for s in failed[:5]))
        if 'timeout' in self.flags:
            self.flags.remove('timeout')
            problems.append('did not finish in time')
        valid = end is not None and worst <= common.LATE_LIMIT_MS and not failed
        if not valid:
            self.flags.append('invalid')
        metrics = {}
        if t0 and end and self.samples and self.done_cpu:
            first = self.samples[0]
            secs = (end - t0) / 1000
            cpu = (self.done_cpu['cpuUserMs'] + self.done_cpu['cpuSysMs']) - (first['cpuUserMs'] + first['cpuSysMs'])
            th = {k: self.done_cpu['threads'].get(k, 0) - first['threads'].get(k, 0) for k in self.done_cpu['threads']}
            ui = th.get('1.ui', 0) + sum(v for k, v in th.items() if k == self.pkg[-15:] or k == 'main')
            metrics.update({
                'M-CPU-1': round(cpu / 1000, 3), 'M-CPU-2': round(100 * cpu / 1000 / secs, 2),
                'M-CPU-3': round(ui / 1000, 3),
                'M-CPU-threads': {k: round(v / 1000, 3) for k, v in sorted(th.items(), key=lambda kv: -kv[1])[:20]},
                'M-CPU-4': round(sum(v for k, v in th.items() if k.startswith('DartWorker')) / 1000, 3),
            })
            metrics.update(common.memory_metrics(self.samples, end - t0, key='rssKb'))
            metrics.update(common.frame_metrics(probe, t0, end))
            metrics.update(common.net_metrics(ledger, secs / 60))
        if start_total is not None:
            metrics['M-ST-1-amstart'] = start_total
        run = {
            'runId': self.id, 'campaign': os.path.basename(os.path.normpath(self.args.results)),
            'platform': PLATFORM, 'target': self.args.target, 'scenario': self.args.scenario,
            'scenarioKey': scenario_id, 'variant': self.variant, 'block': self.block, 'orderInBlock': self.order,
            'evidence': self.evidence, 't0EpochMs': t0, 'endEpochMs': end, 'valid': valid, 'flags': self.flags,
            'sessionId': m.session, 'projectId': None, 'device': self.window(m) or self.screen, 'metrics': metrics,
            'units': 'see 03-MEASUREMENT.md §2',
            'build': {**common.git_state(REPO), 'package': self.pkg},
            'journeyHash': common.sha256_file(jpath),
            'driver': {'worstLateMs': worst, 'failedSteps': len(failed), 'steps': len(m.steps),
                       'summary': m.summary, 'errors': m.errors},
            'ledger': {'lines': len(ledger), 'quiet': quiet},
            'problems': problems,
            **({'relaunch': self.relaunched} if self.relaunched else {}),
        }
        write_json(os.path.join(self.dir, 'run.json'), run)
        self.log(f'done: valid={valid} flags={self.flags} worstLate={worst} ms session={m.session}')


def run_cmd(args):
    Run(args, args.variant, args.block, args.order).execute()


def block_cmd(args):
    order = common.shuffled(args.variants.split(','), args.seed, args.block, args.scenario)
    print(f'block {args.block} of {args.scenario}: {order}', flush=True)
    for i, v in enumerate(order):
        args.run_id = None
        Run(args, v, args.block, i).execute()
        time.sleep(3)


def plan_cmd(args):
    """Every scenario in blocks: one warm-up block (thrown away), then the repetitions."""
    for scenario in args.scenarios.split(','):
        args.scenario = scenario
        for block in range(0 if args.warmup else 1, args.repetitions + 1):
            args.block = block
            block_cmd(args)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--serial', default=os.environ.get('ANDROID_SERIAL', 'emulator-5554'))
    sub = ap.add_subparsers(dest='cmd', required=True)
    ms = sub.add_parser('merge-screen')
    ms.add_argument('--run-dir', required=True)
    ca = sub.add_parser('crop-to-app')
    ca.add_argument('--run-dir', required=True)
    ca.add_argument('--top', type=int, help='y of the app window on the screen, in pixels')
    i = sub.add_parser('install')
    i.add_argument('--apk-off', required=True)
    i.add_argument('--apk-sdk', required=True)
    for name in ('run', 'block', 'plan'):
        r = sub.add_parser(name)
        r.add_argument('--results', required=True)
        r.add_argument('--gateway', default='http://127.0.0.1:18190')
        r.add_argument('--target', default='android-emulator api34 x86_64')
        r.add_argument('--capture', action='store_true', help='the gateway is in capture mode')
        r.add_argument('--evidence', action='store_true')
        r.add_argument('--keep-state', action='store_true')
        r.add_argument('--expire-and-relaunch', type=int, default=0, metavar='S',
                       help='SDK variants: an inactivity timeout of S s, and a launch after the session expired')
        r.add_argument('--fps', type=int)
        r.add_argument('--run-id')
        r.add_argument('--block', type=int, default=0)
        r.add_argument('--order', type=int)
        r.add_argument('--seed', default='0')
        if name == 'run':
            r.add_argument('--scenario', required=True)
            r.add_argument('--variant', required=True)
        elif name == 'block':
            r.add_argument('--scenario', required=True)
            r.add_argument('--variants', required=True)
        else:
            r.add_argument('--scenarios', required=True)
            r.add_argument('--variants', required=True)
            r.add_argument('--repetitions', type=int, default=5)
            r.add_argument('--warmup', action='store_true')
    args = ap.parse_args()
    {'install': install, 'run': run_cmd, 'block': block_cmd, 'plan': plan_cmd, 'merge-screen': merge_screen,
     'crop-to-app': crop_to_app}[args.cmd](args)


if __name__ == '__main__':
    main()
