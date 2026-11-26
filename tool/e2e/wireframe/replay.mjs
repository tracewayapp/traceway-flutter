// Renders a wireframe recording, fetched by run.py, in Playwright.
//
// 1. rrweb-player (the dashboard's copy) at 1:1: every checkpoint is
//    rendered and compared (compare.js) with the picture the app took of
//    itself at that moment and with the baseline rendering.
// 2. With --dashboard: the dashboard's session page loads the recording
//    into its own player, and seeking along its progress bar shows the
//    screens at the right times.
//
// Writes <out>/replay, delta, diff, baseline and dashboard PNGs and
// <out>/visual.json.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const args = {};
for (let i = 2; i < process.argv.length; i += 2) {
  args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
}
const here = path.dirname(new URL(import.meta.url).pathname);
const require = createRequire(import.meta.url);
const { chromium } = require(args.playwright);
const out = path.resolve(args.out);
const sample = Number(args.sample || 150);
const events = JSON.parse(fs.readFileSync(path.join(out, 'events.json'), 'utf8'));
const run = JSON.parse(fs.readFileSync(path.join(out, 'run.json'), 'utf8'));
const checkpoints = run.checkpoints;
const first = events[0].timestamp;
const problems = [];
const visual = { checkpoints: {}, problems };

// The player is as big as the screen was at the first checkpoint: the
// window may have been resized before that.
const metas = events.filter((e) => e.type === 4);
const meta = (metas.filter((e) => e.timestamp <= checkpoints[0].at).pop() || metas[0]).data;

const writePng = (file, dataUrl) =>
  fs.writeFileSync(file, Buffer.from(dataUrl.slice(dataUrl.indexOf(',') + 1), 'base64'));

// ---- 1. rrweb-player at 1:1 --------------------------------------------------

const playerDir = path.join(out, 'player');
fs.mkdirSync(playerDir, { recursive: true });
fs.copyFileSync(path.join(args['rrweb-player'], 'dist', 'rrweb-player.umd.cjs'), path.join(playerDir, 'rrweb-player.js'));
fs.copyFileSync(path.join(args['rrweb-player'], 'dist', 'style.css'), path.join(playerDir, 'style.css'));
fs.copyFileSync(path.join(here, 'compare.js'), path.join(playerDir, 'compare.js'));
fs.writeFileSync(path.join(playerDir, 'events.js'), `window.EVENTS = ${JSON.stringify(events)};`);
fs.writeFileSync(
  path.join(playerDir, 'index.html'),
  `<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="style.css">
<style>body{margin:0;background:#fff} .replayer-mouse,.replayer-mouse-tail{display:none!important}
/* The player centers the page with translate(-50%,-50%), a half pixel off
   for an odd size, which blurs it: at 1:1 it needs no centering. */
.rr-player .replayer-wrapper{left:0!important;top:0!important;transform:none!important}</style>
<script src="events.js"></script><script src="rrweb-player.js"></script><script src="compare.js"></script></head>
<body><div id="target"></div><script>
const Player = window.rrwebPlayer.default || window.rrwebPlayer.Player || window.rrwebPlayer;
window.player = new Player({
  target: document.getElementById('target'),
  props: { events: window.EVENTS, width: ${meta.width}, height: ${meta.height},
           autoPlay: false, showController: false, skipInactive: false, mouseTail: false },
});
</script></body></html>`,
);

const browser = await chromium.launch({
  executablePath: args.chromium,
  headless: true,
  args: ['--allow-file-access-from-files', '--font-render-hinting=none'],
});
const page = await browser.newPage({ viewport: { width: meta.width + 40, height: meta.height + 40 }, deviceScaleFactor: 1 });
const consoleErrors = [];
page.on('console', (m) => {
  if (m.type() === 'error' || m.type() === 'warning') consoleErrors.push(m.text());
});
page.on('pageerror', (e) => consoleErrors.push(String(e)));
await page.goto('file://' + path.join(playerDir, 'index.html'), { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => window.player && window.twCompare);
// The player sizes itself to the first meta event on a timer: let it.
await page.waitForTimeout(300);
for (const cp of checkpoints) {
  await page.evaluate((t) => window.player.goto(t, false), cp.at + sample - first);
  await page.waitForTimeout(350);
  await page.locator('.replayer-wrapper').screenshot({ path: path.join(out, 'replay', `${cp.name}.png`) });
}

for (const cp of checkpoints) {
  const name = cp.name;
  const baselinePng = args.baseline ? path.join(args.baseline, `${name}.png`) : null;
  const hasBaseline = baselinePng && fs.existsSync(baselinePng);
  if (hasBaseline) fs.copyFileSync(baselinePng, path.join(out, 'baseline', `${name}.png`));
  let result;
  try {
    result = await page.evaluate((input) => window.twCompare(input), {
      app: `file://${out}/app/${name}.png`,
      replay: `file://${out}/replay/${name}.png`,
      baseline: hasBaseline ? `file://${baselinePng}` : null,
      ignore: cp.ignore || [],
      appIgnore: cp.appIgnore || [],
    });
  } catch (e) {
    problems.push(`${name}: cannot compare (${e.message})`);
    continue;
  }
  writePng(path.join(out, 'delta', `${name}.png`), result.delta);
  if (result.diff) writePng(path.join(out, 'diff', `${name}.png`), result.diff);
  const [aw, ah, rw, rh] = result.size;
  if (aw !== rw || ah !== rh) problems.push(`${name}: the app's picture is ${aw}x${ah}, the replay ${rw}x${rh}`);
  visual.checkpoints[name] = { fidelity: result.fidelity, golden: result.golden, size: result.size };
  const f = result.fidelity;
  console.log(
    `  ...  ${name}: ssim ${f.ssim.toFixed(3)} edges ${f.edges.toFixed(3)} color ${f.color.toFixed(3)}` +
      (result.golden ? `, ${(result.golden.changed * 100).toFixed(2)}% changed` : ''),
  );
}
const replayErrors = consoleErrors.filter((m) => /Node with id|node not found|Exception in mutation|Uncaught/i.test(m));
if (replayErrors.length) problems.push(`rrweb-player reported ${replayErrors.length} problems: ${replayErrors.slice(0, 3).join(' | ')}`);
else console.log('  PASS  rrweb-player played the whole session without warnings about missing nodes');

// ---- 2. the dashboard --------------------------------------------------------

if (args.dashboard) {
  try {
    const dash = await browser.newPage({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 1 });
    await dash.goto(`${args.dashboard}/login`);
    await dash.fill('input[type=email]', args.email);
    await dash.fill('input[type=password]', args.password);
    await dash.click('button[type=submit]');
    await dash.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 30000 });
    await dash.evaluate((pid) => localStorage.setItem('CURRENT_PROJECT_ID', pid), args.project);
    await dash.goto(`${args.dashboard}/sessions/${args.session}`);
    await dash.locator('.replayer-wrapper iframe').waitFor({ timeout: 60000 });
    const frame = dash.frameLocator('.replayer-wrapper iframe');
    await frame.locator('#tw').waitFor({ timeout: 30000 });
    await dash.waitForTimeout(1000);
    await dash.screenshot({ path: path.join(out, 'dashboard', 'session-page.png'), fullPage: true });
    console.log('  PASS  the dashboard session page plays the wireframe in its rrweb player');
    const progress = dash.locator('.rr-progress');
    const total = events[events.length - 1].timestamp - first;
    const picks = checkpoints.filter((cp) =>
      /^(overlays-dialog|lists-jumped|forms-filled|privacy|tables-expanded|animations-hero|native)$/.test(cp.name),
    );
    for (const cp of picks) {
      const fraction = (cp.at + sample - first) / total;
      await progress.scrollIntoViewIfNeeded();
      const box = await progress.boundingBox();
      await dash.mouse.click(box.x + box.width * fraction, box.y + box.height / 2);
      await dash.waitForTimeout(900);
      await dash.locator('.rr-player').screenshot({ path: path.join(out, 'dashboard', `${cp.name}.png`) });
      const at = await dash.locator('.rr-timeline__time').first().innerText();
      const expected = (cp.at + sample - first) / 1000;
      const [m, sec] = at.split(':').map(Number);
      if (Math.abs(m * 60 + sec - expected) > 2) problems.push(`the dashboard player is at ${at} for ${cp.name}, not ${expected.toFixed(1)}s`);
      else console.log(`  PASS  the dashboard player seeks to ${cp.name} (${at})`);
    }
  } catch (e) {
    problems.push(`dashboard: ${e.message.split('\n')[0]}`);
  }
}

await browser.close();
fs.writeFileSync(path.join(out, 'visual.json'), JSON.stringify(visual, null, 1));
process.exit(0);
