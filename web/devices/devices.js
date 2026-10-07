// Live device maps: draws each controller from geometry.js, colours every
// control by its binding in the profile JSON, and lights controls as MIDI
// arrives (Web MIDI — Chrome / Edge; Safari has no Web MIDI).
import { DEVICES } from './geometry.js';
import {
    controlNumbers, matches, createDecoder, decodeJog, bindingsFor, statusOf, describeBinding, hex,
} from './decode.js';

const SVGNS = 'http://www.w3.org/2000/svg';
const $ = (id) => document.getElementById(id);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

const state = {
    access: null,
    devices: [],           // { def, profile, jog, shapes: Map(id → {shape, el, parts}), refIndex: Map(key → shapeId) }
    values: new Map(),     // `${dev}|${group}#${index}` → value
    selected: null,        // { dev, shapeId }
    shift: new Map(),      // dev → bool (software shift)
    jogAngle: new Map(),   // `${dev}|${deck}` → degrees
};

const key = (group, index) => `${group}#${index}`;

async function loadJSON(id) {
    const r = await fetch(`../profiles/${id}.json`, { cache: 'no-store' });
    if (!r.ok) throw new Error(`${id}.json: HTTP ${r.status}`);
    return r.json();
}

/** Resolve a geometry ref to {group, index} against the profile, or null. */
function resolveRef(profile, ref) {
    const g = profile.groups.find(x => x.id === ref.g);
    if (!g) return null;
    const index = ref.n != null ? (g.names || []).indexOf(ref.n) : ref.i;
    if (index == null || index < 0) return null;
    if (g.type !== 'pitchbend' && index >= controlNumbers(g).length) return null;
    return { group: g.id, index, g };
}

function midiLabel(g, index) {
    const ch = g.channel != null ? `ch ${g.channel + 1}` : 'any ch';
    const n = controlNumbers(g)[index];
    const num = n != null ? `0x${n.toString(16).toUpperCase().padStart(2, '0')} (${n})` : '';
    const what = { note: 'note', cc: 'CC', cc14: 'CC 14-bit', relative: 'CC relative', pitchbend: 'pitch bend', program: 'program' }[g.type];
    return `${what} ${num} · ${ch}`;
}

// --- rendering --------------------------------------------------------------

function el(tag, attrs = {}, parent) {
    const e = document.createElementNS(SVGNS, tag);
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
    if (parent) parent.appendChild(e);
    return e;
}

function colourFor(dev, shape) {
    if (shape.kind === 'jog') return css('--jog');
    if (shape.noMidi) return css('--nomidi');
    const r = shape.refs.map(ref => resolveRef(dev.profile, ref)).find(Boolean);
    if (!r) return css('--unmapped');
    const st = statusOf(bindingsFor(dev.profile, r.group, r.index));
    return css(st === 'bound' ? '--bound' : st === 'parked' ? '--parked' : '--unmapped');
}

function drawShape(dev, svg, shape) {
    if (shape.hidden) return null;
    const g = el('g', { class: 'shape', 'data-id': shape.id }, svg);
    const colour = colourFor(dev, shape);
    const parts = {};
    switch (shape.kind) {
    case 'pad': case 'button': case 'key': case 'blackkey': {
        const fill = shape.kind === 'key' ? '#e9e9e4' : shape.kind === 'blackkey' ? '#111' : css('--face');
        parts.body = el('rect', { x: shape.x, y: shape.y, width: shape.w, height: shape.h,
            rx: shape.kind === 'pad' ? 6 : 4, fill, stroke: colour, 'stroke-width': shape.kind.endsWith('key') ? 2 : 3,
            'stroke-dasharray': shape.noMidi ? '4 3' : 'none' }, g);
        if (shape.label) {
            const t = el('text', { x: shape.x + shape.w / 2, y: shape.y + (shape.kind === 'key' ? shape.h - 14 : shape.h / 2) }, g);
            if (shape.kind === 'key') t.setAttribute('style', 'fill:#333');
            t.textContent = shape.label;
        }
        break;
    }
    case 'knob': case 'encoder': {
        el('circle', { cx: shape.x, cy: shape.y, r: shape.r, fill: css('--face'), stroke: colour, 'stroke-width': 3 }, g);
        parts.pointer = el('line', { x1: shape.x, y1: shape.y, x2: shape.x, y2: shape.y - shape.r + 4,
            stroke: '#fff', 'stroke-width': 3, 'stroke-linecap': 'round' }, g);
        parts.pointer.setAttribute('transform', `rotate(${shape.kind === 'encoder' ? 0 : 0} ${shape.x} ${shape.y})`);
        const t = el('text', { x: shape.x, y: shape.y + shape.r + 10 }, g);
        t.textContent = shape.label;
        break;
    }
    case 'fader': case 'hfader': {
        const vert = shape.kind === 'fader';
        el('rect', { x: shape.x, y: shape.y, width: shape.w, height: shape.h, rx: 4, fill: '#111', stroke: colour, 'stroke-width': 3 }, g);
        parts.thumb = vert
            ? el('rect', { x: shape.x - 6, y: shape.y + shape.h / 2 - 7, width: shape.w + 12, height: 14, rx: 3, fill: '#ddd' }, g)
            : el('rect', { x: shape.x + shape.w / 2 - 7, y: shape.y - 6, width: 14, height: shape.h + 12, rx: 3, fill: '#ddd' }, g);
        const t = el('text', vert ? { x: shape.x + shape.w / 2, y: shape.y + shape.h + 12 } : { x: shape.x + shape.w / 2, y: shape.y + shape.h + 16 }, g);
        t.textContent = shape.label;
        break;
    }
    case 'jog': {
        parts.ring = el('circle', { cx: shape.x, cy: shape.y, r: shape.r, fill: '#18181c', stroke: colour, 'stroke-width': 4 }, g);
        el('circle', { cx: shape.x, cy: shape.y, r: shape.r * 0.55, fill: '#222', stroke: '#444' }, g);
        parts.marker = el('line', { x1: shape.x, y1: shape.y - shape.r * 0.6, x2: shape.x, y2: shape.y - shape.r + 6,
            stroke: '#fff', 'stroke-width': 4, 'stroke-linecap': 'round' }, g);
        const t = el('text', { x: shape.x, y: shape.y }, g);
        t.textContent = shape.label;
        break;
    }
    case 'joystick': {
        el('circle', { cx: shape.x, cy: shape.y, r: shape.r, fill: '#111', stroke: colour, 'stroke-width': 3 }, g);
        parts.dot = el('circle', { cx: shape.x, cy: shape.y, r: 14, fill: '#d23c3c' }, g);
        const t = el('text', { x: shape.x, y: shape.y + shape.r + 10 }, g);
        t.textContent = shape.label;
        break;
    }
    }
    const title = el('title', {}, g);
    title.textContent = shape.label || shape.id;
    g.addEventListener('click', () => select(dev, shape.id));
    return { shape, el: g, parts };
}

function renderDevice(dev) {
    const sec = document.createElement('section');
    sec.className = 'device';
    sec.innerHTML = `<h2>${dev.def.title} <span class="port" id="port-${dev.def.id}">not connected</span></h2>
        <p class="coverage" id="cov-${dev.def.id}"></p><p class="gaps" id="gaps-${dev.def.id}"></p>`;
    const { width, height, shapes } = dev.def.geometry;
    const svg = el('svg', { viewBox: `0 0 ${width} ${height}` });
    sec.appendChild(svg);
    $('devices').appendChild(sec);
    dev.shapes = new Map();
    dev.refIndex = new Map();
    for (const shape of shapes) {
        const drawn = drawShape(dev, svg, shape);
        dev.shapes.set(shape.id, drawn || { shape, el: null, parts: {} });
        for (const ref of shape.refs) {
            const r = resolveRef(dev.profile, ref);
            if (r && !dev.refIndex.has(key(r.group, r.index))) dev.refIndex.set(key(r.group, r.index), shape.id);
        }
    }
    renderCoverage(dev);
}

function renderCoverage(dev) {
    const p = dev.profile;
    let bound = 0, parked = 0, unmapped = 0;
    const undrawn = [];
    for (const g of p.groups) {
        const n = g.type === 'pitchbend' ? 1 : controlNumbers(g).length;
        let notDrawn = 0;
        for (let i = 0; i < n; i++) {
            const st = statusOf(bindingsFor(p, g.id, i));
            if (st === 'bound') bound++; else if (st === 'parked') parked++; else unmapped++;
            if (!dev.refIndex.has(key(g.id, i))) notDrawn++;
        }
        // A group bound as a whole (e.g. all 128 key notes, so octave shifts
        // work) only needs its physical controls drawn.
        const groupWide = p.layout.some(b => b.group === g.id && b.index == null);
        if (notDrawn && !(groupWide && notDrawn < n)) undrawn.push(notDrawn === n ? g.id : `${g.id} (${notDrawn} of ${n})`);
    }
    // Geometry refs that point at nothing in the profile.
    const badRefs = dev.def.geometry.shapes.flatMap(s => s.refs.filter(r => !resolveRef(p, r)).map(r => `${s.id}→${r.g}/${r.n ?? r.i}`));
    $(`cov-${dev.def.id}`).innerHTML =
        `<b>${bound + parked + unmapped}</b> controls in the profile · <b>${bound}</b> bound · <b>${parked}</b> parked · <b>${unmapped}</b> without a layout entry`
        + (dev.jog ? ' · jog wheels via the jog profile' : '');
    const gaps = [];
    if (undrawn.length) gaps.push(`Not on the diagram: ${undrawn.join(', ')}`);
    if (badRefs.length) gaps.push(`Diagram refs not in the profile: ${badRefs.join(', ')}`);
    $(`gaps-${dev.def.id}`).textContent = gaps.join(' · ');
}

// --- selection / info -----------------------------------------------------------

function select(dev, shapeId) {
    if (state.selected) {
        const prev = state.devices.find(d => d.def.id === state.selected.dev)?.shapes.get(state.selected.shapeId);
        prev?.el?.querySelector('rect, circle')?.classList.remove('sel');
    }
    state.selected = { dev: dev.def.id, shapeId };
    const s = dev.shapes.get(shapeId);
    s?.el?.querySelector('rect, circle')?.classList.add('sel');
    renderInfo();
}

function renderInfo() {
    if (!state.selected) return;
    const dev = state.devices.find(d => d.def.id === state.selected.dev);
    const { shape } = dev.shapes.get(state.selected.shapeId);
    const rows = [];
    if (shape.kind === 'jog') {
        rows.push(`<tr><td colspan="2">Jog wheel, deck ${shape.jogDeck}: touch note 0x${dev.jog.touch.note.toString(16)}, scratch CC 0x${dev.jog.scratchCC.toString(16)}, bend CC 0x${dev.jog.bendCC.toString(16)} on the deck channel (+${dev.jog.shiftChannelOffset} with SHIFT). Bound to the deck's turntable.</td></tr>`);
    }
    if (shape.noMidi) rows.push('<tr><td colspan="2">Sends no MIDI — it changes what the device sends.</td></tr>');
    for (const ref of shape.refs) {
        const r = resolveRef(dev.profile, ref);
        if (!r) { rows.push(`<tr><td>${ref.g}/${ref.n ?? ref.i}</td><td style="color:var(--unmapped)">not in profile</td></tr>`); continue; }
        const binds = bindingsFor(dev.profile, r.group, r.index);
        const v = state.values.get(`${dev.def.id}|${key(r.group, r.index)}`);
        const name = r.g.names?.[r.index];
        rows.push(`<tr><td><code>${r.group}[${r.index}]</code>${name ? ` ${name}` : ''}<br><span class="muted">${midiLabel(r.g, r.index)}</span>${r.g.comment ? `<br><span class="muted">${r.g.comment}</span>` : ''}</td>
            <td>${binds.length ? binds.map(describeBinding).join('<br>') : '<span style="color:var(--unmapped)">no layout entry</span>'}${v != null ? `<br><span class="muted">last value ${typeof v === 'number' ? v.toFixed(3) : v}</span>` : ''}</td></tr>`);
    }
    const canFlash = shape.refs.some(ref => ledFor(dev, resolveRef(dev.profile, ref)));
    $('info').innerHTML = `<b>${dev.def.title}</b> · ${shape.label || shape.id}${shape.note ? `<br><span class="muted">${shape.note}</span>` : ''}
        <table>${rows.join('')}</table>
        ${canFlash ? '<p><button id="flash">Flash its LED on the device</button></p>' : ''}`;
    $('flash')?.addEventListener('click', () => flash(dev, shape));
}

// --- LEDs -------------------------------------------------------------------------

function ledFor(dev, r) {
    const leds = dev.profile.leds;
    if (!r || !leds) return null;
    const note = controlNumbers(r.g)[r.index];
    if (leds.rgbGroups.includes(r.group)) return { on: [leds.rgbFullStatus, note, 5], off: [0x90, note, 0] };
    if (leds.singleGroups.includes(r.group)) {
        const st = 0x90 | (r.g.channel ?? 0);
        return { on: [st, note, leds.singleOn], off: [st, note, leds.singleOff] };
    }
    return null;
}

function outputFor(dev) {
    if (!state.access) return null;
    for (const o of state.access.outputs.values()) if (matches(dev.profile, o.name)) return o;
    return null;
}

function flash(dev, shape) {
    const out = outputFor(dev);
    if (!out) return log(dev.def.id, [], 'no MIDI output for this device', 'undecoded');
    for (const ref of shape.refs) {
        const led = ledFor(dev, resolveRef(dev.profile, ref));
        if (!led) continue;
        let on = true, n = 0;
        const t = setInterval(() => {
            out.send(on ? led.on : led.off);
            on = !on;
            if (++n >= 6) { clearInterval(t); out.send(led.off); }
        }, 160);
        log(dev.def.id, led.on, `LED flash → ${out.name}`, 'bound');
        return;
    }
}

// --- live input -------------------------------------------------------------------

function hit(dev, shapeId) {
    const s = dev.shapes.get(shapeId);
    if (!s?.el) return;
    s.el.classList.add('hit');
    clearTimeout(s.timer);
    s.timer = setTimeout(() => s.el.classList.remove('hit'), 260);
}

function showValue(dev, shapeId, e) {
    const s = dev.shapes.get(shapeId);
    if (!s?.el) return;
    const { shape, parts } = s;
    if (parts.pointer && e.delta) {
        const a = ((s.angle || 0) + e.delta * 12) % 360;
        s.angle = a;
        parts.pointer.setAttribute('transform', `rotate(${a} ${shape.x} ${shape.y})`);
    } else if (parts.pointer) {
        parts.pointer.setAttribute('transform', `rotate(${-135 + e.value * 270} ${shape.x} ${shape.y})`);
    }
    if (parts.thumb) {
        if (shape.kind === 'fader') parts.thumb.setAttribute('y', shape.y + (1 - e.value) * shape.h - 7);
        else parts.thumb.setAttribute('x', shape.x + e.value * shape.w - 7);
    }
    if (parts.dot) {
        if (e.group === 'joystickX') parts.dot.setAttribute('cx', shape.x + (e.value - 0.5) * 2 * (shape.r - 14));
        else parts.dot.setAttribute('cy', shape.y - e.value * (shape.r - 14));
    }
    if (parts.body && (shape.kind === 'pad' || shape.kind.endsWith('key') || shape.kind === 'button')) {
        parts.body.setAttribute('fill-opacity', e.pressed ? '0.45' : '1');
    }
}

function onMessage(dev, port, data) {
    if (dev.jog) {
        const j = decodeJog(dev.jog, data);
        if (j) {
            const shape = dev.def.geometry.shapes.find(s => s.kind === 'jog' && s.jogDeck === j.deck);
            const s = shape && dev.shapes.get(shape.id);
            if (s) {
                if (j.kind === 'touch') s.parts.ring.setAttribute('stroke', j.down ? css('--hit') : css('--jog'));
                else {
                    const k = `${dev.def.id}|${j.deck}`;
                    const a = (state.jogAngle.get(k) || 0) + j.ticks * 360 / dev.jog.ticksPerRev;
                    state.jogAngle.set(k, a);
                    s.parts.marker.setAttribute('transform', `rotate(${a} ${shape.x} ${shape.y})`);
                }
                hit(dev, shape.id);
            }
            return log(dev.def.id, data, `jog ${j.deck} ${j.kind}${j.ticks ? ' ' + j.ticks : ''}${j.down != null ? (j.down ? ' down' : ' up') : ''}${j.shift ? ' (shift)' : ''}`, 'jog', true);
        }
        // Zero-tick jog messages decode to nothing; ignore quietly.
        if ((data[0] & 0xF0) === 0xB0 && (data[1] === dev.jog.scratchCC || data[1] === dev.jog.bendCC)) return;
    }
    const e = dev.decode(data);
    if (!e) return log(dev.def.id, data, `undecoded (${port})`, 'undecoded');
    state.values.set(`${dev.def.id}|${key(e.group, e.index)}`, e.delta ? `Δ${e.delta}` : e.value);
    const binds = bindingsFor(dev.profile, e.group, e.index);
    if (binds.some(b => b.action === 'shift')) state.shift.set(dev.def.id, e.pressed);
    const shiftHeld = state.shift.get(dev.def.id) || false;
    const b = binds.find(x => x.shift == null || x.shift === shiftHeld) || binds[0];
    const status = !b ? 'unmapped' : b.action === 'unbound' ? 'parked' : 'bound';
    const shapeId = dev.refIndex.get(key(e.group, e.index));
    if (shapeId) {
        hit(dev, shapeId);
        showValue(dev, shapeId, e);
        if (state.selected?.dev === dev.def.id && state.selected.shapeId === shapeId) renderInfo();
    }
    const control = `${e.group}[${e.index}]${e.name ? ' ' + e.name : ''} ${e.delta ? 'Δ' + e.delta : e.value.toFixed(3)}`;
    log(dev.def.id, data, `${control} → ${describeBinding(b)}${shapeId ? '' : '  (not on diagram)'}`, status, e.lsb);
}

// --- log --------------------------------------------------------------------------

let lastLine = null;
function log(devId, data, text, cls, coalesce = false) {
    const box = $('log');
    const line = `${new Date().toLocaleTimeString([], { hour12: false })} ${devId.padEnd(7)} ${hex(data).padEnd(9)} ${text}`;
    if (coalesce && lastLine && lastLine.dataset.key === `${devId}|${text.split(' ')[0]}|${cls}`) {
        lastLine.textContent = line;
    } else {
        const div = document.createElement('div');
        div.className = cls;
        div.dataset.key = `${devId}|${text.split(' ')[0]}|${cls}`;
        div.textContent = line;
        box.appendChild(div);
        lastLine = div;
        while (box.childElementCount > 400) box.firstChild.remove();
    }
    box.scrollTop = box.scrollHeight;
}

// --- MIDI wiring ------------------------------------------------------------------

function bindInputs() {
    const connected = new Set();
    for (const input of state.access.inputs.values()) {
        const dev = state.devices.find(d => matches(d.profile, input.name));
        input.onmidimessage = dev ? (ev) => onMessage(dev, input.name, ev.data) : null;
        if (dev) connected.add(dev.def.id);
        if (dev) $(`port-${dev.def.id}`).textContent = `● ${input.name}`;
    }
    for (const dev of state.devices) {
        const p = $(`port-${dev.def.id}`);
        p.classList.toggle('on', connected.has(dev.def.id));
        if (!connected.has(dev.def.id)) p.textContent = 'not connected';
    }
    $('midi').textContent = `MIDI: ${connected.size} of ${state.devices.length} devices connected`;
}

async function main() {
    for (const def of DEVICES) {
        const profile = await loadJSON(def.profile);
        const jog = def.jog ? await loadJSON(def.jog) : null;
        const dev = { def, profile, jog, decode: createDecoder(profile) };
        state.devices.push(dev);
        renderDevice(dev);
    }
    $('clear').addEventListener('click', () => { $('log').textContent = ''; lastLine = null; });
    if (!navigator.requestMIDIAccess) {
        $('midi').textContent = 'MIDI: this browser has no Web MIDI — open in Chrome for live input';
        return;
    }
    try {
        state.access = await navigator.requestMIDIAccess({ sysex: false });
        state.access.onstatechange = bindInputs;
        bindInputs();
    } catch (err) {
        $('midi').textContent = `MIDI: access denied (${err.message || err})`;
    }
}

main().catch(err => { $('midi').textContent = `error: ${err.message}`; console.error(err); });
