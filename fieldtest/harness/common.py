"""What the Linux and Android harnesses share: the gateway's control routes,
the journey file, marker parsing, metrics and the run folder
(sdk-field-test 05-RESULTS-FORMAT.md §2-3). Standard library only."""
import hashlib
import json
import os
import random
import statistics
import subprocess
import time
import urllib.error
import urllib.request

PLATFORM_LINUX = 'flutter-linux'
# A local run is noisy when other processes averaged more than this share of
# one core (03-MEASUREMENT.md says 25; this campaign's host, GATE1.md: 40).
NOISY_PCT = 40
LATE_LIMIT_MS = 1500


def now_ms():
    return int(time.time() * 1000)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return 'sha256:' + h.hexdigest()


def run_id(platform, scenario, variant, block=None, evidence=False):
    tag = 'ev' if evidence else f'b{block:02d}'
    return f'{platform}-{scenario}-{variant}-{tag}-{random.getrandbits(16):04x}'


def git_state(repo):
    def git(*args):
        return subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True).stdout.strip()
    return {
        'sdkCommit': git('rev-parse', '--short', 'HEAD'),
        'sdkDirty': bool(git('status', '--porcelain', '--', 'lib', 'pubspec.yaml')),
        'fieldtestDirty': bool(git('status', '--porcelain', '--', 'fieldtest')),
    }


# ---- gateway -----------------------------------------------------------------

class Gateway:
    def __init__(self, base):
        self.base = base.rstrip('/')

    def _req(self, method, path, body=None, timeout=10):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={'content-type': 'application/json'} if data else {})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()

    def health(self):
        try:
            return json.loads(self._req('GET', '/ctl/health', timeout=3))
        except Exception as e:  # noqa: BLE001
            return {'error': str(e)}

    def start_run(self, run):
        return self._req('POST', '/ctl/run', {'runId': run})

    def fault(self, mode, seconds):
        return self._req('POST', '/ctl/fault', {'mode': mode, 'seconds': seconds})

    def mark(self, name):
        return self._req('POST', '/ctl/mark', {'name': name})

    def ledger(self, run):
        raw = self._req('GET', f'/ctl/ledger?run={run}', timeout=30).decode()
        raw = raw.strip()
        if not raw:
            return []
        if raw.startswith('['):
            return json.loads(raw)
        return [json.loads(line) for line in raw.splitlines() if line.strip()]

    def fxlog(self, run):
        return json.loads(self._req('GET', f'/ctl/fxlog?run={run}', timeout=30))

    def wait_quiet(self, run, quiet_s=5, limit_s=90):
        """Waits until the run's ledger has not grown for [quiet_s]."""
        last, since, start = -1, time.time(), time.time()
        lines = []
        while time.time() - start < limit_s:
            try:
                lines = self.ledger(run)
            except (urllib.error.URLError, OSError):
                lines = lines
            if len(lines) != last:
                last, since = len(lines), time.time()
            elif time.time() - since >= quiet_s:
                return lines, True
            time.sleep(1)
        return lines, False


# ---- journey -----------------------------------------------------------------

def load_journey(path):
    with open(path) as f:
        return json.load(f)


def find_scenario(journey, scenario):
    s = journey.get('scenarios', {})
    if scenario in s:
        return scenario, s[scenario]
    for k, v in s.items():
        if k.startswith(scenario + '-'):
            return k, v
    raise SystemExit(f'no scenario {scenario} in the journey')


# ---- markers -----------------------------------------------------------------

class Markers:
    """Collects what the app's marker lines say, in arrival order."""

    def __init__(self):
        self.ready = None
        self.fully = None
        self.done = None
        self.session = None
        self.screens = []
        self.checkpoints = []   # (name, epochMs)
        self.boxes = {}
        self.steps = []
        self.requests = []
        self.errors = []
        self.summary = None
        self.journey = None
        self.background = []
        self.probe_path = None
        self.start = None

    def feed(self, line):
        """Returns (kind, payload) for lines the harness acts on."""
        head, _, rest = line.partition(' ')
        try:
            if head == 'FM_READY':
                self.ready = int(rest.split()[-1])
                return 'ready', self.ready
            if head == 'FM_FULLY':
                self.fully = int(rest.split()[-1])
            elif head == 'FM_START':
                self.start = rest
            elif head == 'FM_SCREEN':
                name, at = rest.rsplit(' ', 1)
                self.screens.append((name, int(at)))
            elif head == 'FM_SESSION':
                self.session = rest.strip()
            elif head == 'FM_CP':
                name, at = rest.rsplit(' ', 1)
                self.checkpoints.append((name, int(at)))
                return 'checkpoint', (name, int(at))
            elif head == 'FM_BOXES':
                b = json.loads(rest)
                self.boxes[b['name']] = b
            elif head == 'FM_STEP':
                self.steps.append(json.loads(rest))
            elif head == 'FM_JOURNEY':
                self.journey = json.loads(rest)
            elif head == 'FM_SUMMARY':
                self.summary = json.loads(rest)
            elif head == 'FM_REQ':
                parts = rest.split()
                self.requests.append(parts)
                return 'request', parts
            elif head == 'FM_BACKGROUND':
                self.background.append(int(rest.split()[-1]))
            elif head == 'FM_PROBE':
                self.probe_path = rest.split(' ', 3)[-1]
            elif head == 'FM_DONE':
                self.done = int(rest.split()[-1])
                return 'done', self.done
            elif head in ('FM_ERROR', 'FM_PROBE_ERROR'):
                self.errors.append(rest)
        except (ValueError, KeyError, json.JSONDecodeError) as e:
            self.errors.append(f'unparsed {head}: {e}')
        return None, None


# ---- metrics -----------------------------------------------------------------

def percentile(values, p):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def frame_metrics(probe, t0, end, interval_ms=1000 / 60):
    """M-FR-1..4 from the probe's frames that started inside [t0, end]."""
    frames = [f for f in probe.get('frames', []) if t0 <= f.get('startEpochMs', 0) <= end]
    total = [f['total'] / 1000 for f in frames]
    build = [f['build'] / 1000 for f in frames]
    raster = [f['raster'] / 1000 for f in frames]
    if not total:
        return {}
    slow = sum(1 for t in total if t > 1.5 * interval_ms)
    r = lambda x: None if x is None else round(x, 2)  # noqa: E731
    return {
        'M-FR-1': {'p50': r(percentile(total, 50)), 'p90': r(percentile(total, 90)),
                   'p95': r(percentile(total, 95)), 'p99': r(percentile(total, 99))},
        'M-FR-1-build': {'p50': r(percentile(build, 50)), 'p90': r(percentile(build, 90)), 'p99': r(percentile(build, 99))},
        'M-FR-1-raster': {'p50': r(percentile(raster, 50)), 'p90': r(percentile(raster, 90)), 'p99': r(percentile(raster, 99))},
        'M-FR-2': round(100 * slow / len(total), 2),
        'M-FR-3': sum(1 for t in total if t >= 700),
        'M-FR-4': r(max(total)),
        'frames': len(total),
    }


def net_metrics(ledger, minutes):
    by_route, count = {}, {}
    for line in ledger:
        p = line.get('path', '?').split('?')[0]
        by_route[p] = by_route.get(p, 0) + int(line.get('wireBytes') or 0)
        count[p] = count.get(p, 0) + 1
    total_kb = sum(by_route.values()) / 1024
    return {
        'M-NET-1': {'totalKb': round(total_kb, 1), 'perMinKb': round(total_kb / minutes, 1) if minutes else None,
                    'byRoute': {k: round(v / 1024, 1) for k, v in sorted(by_route.items())}},
        'M-NET-2': count,
    }


def memory_metrics(samples, t_end_ms, key='pssKb'):
    """M-MEM-1 (median of the last 20 s) and M-MEM-2 (peak), MB."""
    values = [(s.get('t', 0), s.get(key) or s.get('rssKb')) for s in samples]
    values = [(t, v) for t, v in values if v]
    if not values:
        return {}
    last = [v for t, v in values if t_end_ms - 20000 <= t <= t_end_ms] or [values[-1][1]]
    return {'M-MEM-1': round(statistics.median(last) / 1024, 1),
            'M-MEM-2': round(max(v for _, v in values) / 1024, 1)}


def host_noise(samples):
    # The sampler's first tick covers almost no time: its share is meaningless.
    v = [s['hostOtherPct'] for s in samples[1:] if isinstance(s.get('hostOtherPct'), (int, float))]
    return round(statistics.mean(v), 1) if v else None


def write_json(path, value):
    with open(path, 'w') as f:
        json.dump(value, f, indent=1)
        f.write('\n')


def write_jsonl(path, rows):
    with open(path, 'w') as f:
        for r in rows:
            f.write(json.dumps(r) + '\n')


def checkpoints_file(markers, scenario_id, steps, t0, screenshots=False):
    by_name = {s.get('name'): s for s in steps if s.get('do') == 'checkpoint'}
    out = []
    for name, at in markers.checkpoints:
        s = by_name.get(name, {})
        cp = {'name': name, 'epochMs': at, 'tMs': at - t0 if t0 else 0, 'scenario': scenario_id,
              'shows': s.get('shows', []), 'hides': s.get('hides', []), 'masked': s.get('masked', []),
              'settleMs': s.get('settleMs', 400)}
        for k in ('overlay', 'list', 'screen', 'during'):
            if s.get(k):
                cp[k] = s[k]
        if screenshots:
            cp['screenshot'] = f'app/{name}.png'
        out.append(cp)
    return out


def driver_log(markers, t0):
    lines = [f'# T0 (FM_READY) {t0}; times in ms from T0; late = start - t']
    worst = 0
    for s in markers.steps:
        worst = max(worst, s.get('lateMs', 0))
        what = s.get('id') or s.get('name') or ''
        status = 'ok' if s.get('ok') else f"FAILED {s.get('error')}"
        lines.append(f"{s.get('i'):>3} t={s.get('t'):>6} start={s.get('startMs'):>6} late={s.get('lateMs'):>5} "
                     f"end={s.get('endMs'):>6} {s.get('do'):<10} {what} {status}")
    lines.append(f'# worst lateness {worst} ms; limit {LATE_LIMIT_MS} ms')
    return '\n'.join(lines) + '\n', worst


def shuffled(variants, seed, block, scenario):
    order = list(variants)
    random.Random(f'{seed}-{scenario}-{block}').shuffle(order)
    return order


def enrich_actions(actions, steps):
    """The typed text of each type or paste action, from its journey step (the
    app reports the field and the length; R-17 needs the text): a type or
    paste step's `text`, or a pick step's `value` typed into the picker's
    search field."""
    for a in actions:
        if a.get('do') not in ('type', 'paste') or a.get('text'):
            continue
        i = a.get('step')
        if not isinstance(i, int) or not 0 <= i < len(steps):
            continue
        step = steps[i]
        text = step.get('text') if step.get('do') in ('type', 'paste') else step.get('value')
        if text is not None:
            a['text'] = str(text)
    return actions

