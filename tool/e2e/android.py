"""Device lifecycle for the scripted Flutter example."""
import json
import subprocess
from urllib.parse import urlsplit


class AndroidApp:
    package = 'com.example.traceway_example'

    def __init__(self, serial, base):
        self.adb = ['adb', '-s', serial]
        self.base = base
        self.forwards = set()

    def run(self, *args, **kwargs):
        return subprocess.run(self.adb + list(args), check=True, capture_output=True,
                              text=True, **kwargs).stdout.strip()

    def force_stop(self):
        self.run('shell', 'am', 'force-stop', self.package)

    def forward_loopback(self, url):
        target = urlsplit(url)
        if target.hostname not in ('127.0.0.1', 'localhost', '::1'):
            return
        port = f'tcp:{target.port or (443 if target.scheme == "https" else 80)}'
        mappings = [line.split()[-2:] for line in self.run('reverse', '--list').splitlines()]
        if [port, port] not in mappings:
            self.run('reverse', '--no-rebind', port, port)
            self.forwards.add(port)

    def launch(self, scenario, settings):
        self.force_stop()
        if scenario in (None, 'external', 'standalone'):
            self.run('shell', 'pm', 'clear', self.package)
        self.forward_loopback(self.base)
        for key in ('E2E_ECHO', 'E2E_COLLECTOR'):
            if key in settings:
                self.forward_loopback(settings[key])
        config = dict(settings)
        if scenario:
            config['E2E_SCENARIO'] = scenario
        self.run('shell', 'run-as', self.package, 'mkdir', '-p', 'files')
        self.run('shell', 'run-as', self.package, 'tee', 'files/e2e-launch.json',
                 input=json.dumps(config))
        stamp = self.run('shell', 'date', '+%m-%d\\ %H:%M:%S.000')
        self.run('shell', 'am', 'start', '-W', '-n', self.package + '/.MainActivity')
        pid = self.run('shell', 'pidof', '-s', self.package)
        return self.adb + ['logcat', '--pid=' + pid, '-T', stamp, '-v', 'raw', 'flutter:I', '*:S']

    def close(self):
        for port in self.forwards:
            self.run('reverse', '--remove', port)
