import { songEvents, GENRES } from './events.mjs';
const SC = { Major:[0,2,4,5,7,9,11], Minor:[0,2,3,5,7,8,10], Dorian:[0,2,3,5,7,9,10], Mixolydian:[0,2,4,5,7,9,10], Phrygian:[0,1,3,5,7,8,10], HarmonicMin:[0,2,3,5,7,8,11], Pentatonic:[0,2,4,7,9], MinPentatonic:[0,3,5,7,10], Blues:[0,3,5,6,7,10] };
const out = {};
for (const g of GENRES) {
  const r = songEvents(g, 42);
  const root = r.json.rootNote ?? 48; const sc = SC[r.json.scaleName] || SC.Major;
  const inKey = n => sc.includes((((n - root) % 12) + 12) % 12);
  const by = {};
  for (const e of r.events) { if (['kick','snare','hihat','clap'].includes(e.role) || e.channel>=10) continue; const k = e.role + ':' + (r.json.nets[e.net]?.riffVariant || '-'); (by[k] ||= [0,0]); by[k][0]++; if (!inKey(e.note)) by[k][1]++; }
  const tc = (r.json.nets['melody-1']?.track?.generatorParams) ? '' : '';
  console.log(g.padEnd(9), r.json.scaleName, Object.entries(by).filter(([k])=>!k.startsWith('hit')).map(([k,[n,o]]) => `${k}=${(o/n*100).toFixed(0)}%`).join(' '));
}
