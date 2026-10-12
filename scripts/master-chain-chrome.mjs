#!/usr/bin/env node
// Runs scripts/master-chain-chrome-reference.html in headless Chrome (raw CDP, node >= 22, no
// npm) and writes what it prints to Tests/DJCoreTests/Fixtures/beats/master-chain-chrome.json.
// (--dump-dom does not wait for an OfflineAudioContext render; this waits for the page.)
//
//   node scripts/master-chain-chrome.mjs        # $CHROME overrides the browser path
//
// Needs .build/tone/Tone-15.1.22.js (scripts/beats-macro-fx.mjs fetches and checks it).

import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const page = pathToFileURL(path.join(here, 'master-chain-chrome-reference.html')).href;
const outFile = path.resolve(process.argv[2] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats/master-chain-chrome.json'));
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!existsSync(path.join(here, '../.build/tone/Tone-15.1.22.js'))) throw new Error('run scripts/beats-macro-fx.mjs first (it fetches Tone)');
const PORT = 9388;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${mkdtempSync(path.join(tmpdir(), 'master-chain-chrome-'))}`, '--disable-gpu',
  '--no-first-run', '--allow-file-access-from-files', '--autoplay-policy=no-user-gesture-required',
  '--disable-background-timer-throttling', '--disable-renderer-backgrounding', 'about:blank'], { stdio: 'ignore' });
const done = (code) => { try { chrome.kill(); } catch {} process.exit(code); };

let target;
for (let i = 0; i < 80 && !target; i++) {
  await sleep(250);
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find((t) => t.type === 'page'); } catch {}
}
if (!target) { console.error('no Chrome target'); done(1); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0;
const pending = new Map();
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id) { pending.get(m.id)?.(m); pending.delete(m.id); }
  if (m.method === 'Runtime.exceptionThrown') console.error('exception:', m.params.exceptionDetails.exception?.description);
};
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const mid = ++id;
  pending.set(mid, (m) => (m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result)));
  ws.send(JSON.stringify({ id: mid, method, params }));
});
await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url: page });
let text = 'pending';
for (let i = 0; i < 600 && text === 'pending'; i++) {
  await sleep(250);
  try {
    const r = await send('Runtime.evaluate', { expression: "document.getElementById('out')?.textContent ?? 'pending'", returnByValue: true });
    text = r.result.value;
  } catch {}
}
if (!text.startsWith('{')) { console.error(text.slice(0, 2000)); done(1); }
writeFileSync(outFile, text + '\n');
const j = JSON.parse(text);
console.log(`${path.relative(process.cwd(), outFile)}: ${j.scenarios.length} scenarios, ${j.chrome}`);
done(0);
