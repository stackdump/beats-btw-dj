// Profile-driven MIDI decoding — a port of Sources/DJCore/Surface.swift
// (SurfaceDecoder + layout lookup) and the jog parse in JogEvent.swift, so the
// diagram labels exactly what the Swift app does with each message.

export function controlNumbers(g) {
    if (Array.isArray(g.numbers)) return g.numbers;
    if (typeof g.first === 'number' && typeof g.count === 'number') {
        return Array.from({ length: g.count }, (_, i) => g.first + i);
    }
    return g.type === 'pitchbend' ? [0] : [];
}

export function matches(profile, portName) {
    return new RegExp(profile.match, 'i').test(portName || '');
}

/** Stateful decoder for one port: remembers 14-bit MSBs. */
export function createDecoder(profile) {
    const msb = new Map();
    return function decode(data) {
        if (!data || data.length < 2) return null;
        const status = data[0] & 0xF0, ch = data[0] & 0x0F;
        const d1 = data[1], d2 = data.length > 2 ? data[2] : 0;
        const ev = (g, i, value, pressed, extra = {}) => ({
            group: g.id, index: i, value, pressed, name: g.names?.[i] ?? null, ...extra,
        });
        for (const g of profile.groups) {
            if (g.channel != null && g.channel !== ch) continue;
            const nums = controlNumbers(g);
            switch (g.type) {
            case 'note':
                if (status === 0x90 || status === 0x80) {
                    const i = nums.indexOf(d1);
                    if (i >= 0) return ev(g, i, d2 / 127, status === 0x90 && d2 > 0);
                }
                break;
            case 'cc':
                if (status === 0xB0) {
                    const i = nums.indexOf(d1);
                    if (i >= 0) return ev(g, i, d2 / 127, d2 > 0);
                }
                break;
            case 'relative':
                if (status === 0xB0) {
                    const i = nums.indexOf(d1);
                    if (i >= 0) {
                        const delta = d2 < 0x40 ? d2 : d2 - 0x80;
                        return ev(g, i, 0, delta !== 0, { delta });
                    }
                }
                break;
            case 'cc14':
                if (status === 0xB0) {
                    let i = nums.indexOf(d1);
                    if (i >= 0) {
                        msb.set((ch << 8) | d1, d2);
                        return ev(g, i, Math.min(1, (d2 << 7) / 16383), d2 > 0);
                    }
                    if (d1 >= 32 && (i = nums.indexOf(d1 - 32)) >= 0) {
                        const hi = msb.get((ch << 8) | (d1 - 32)) ?? 0;
                        const v = ((hi << 7) | d2) / 16383;
                        return ev(g, i, v, v > 0, { lsb: true });
                    }
                }
                break;
            case 'program':
                if (status === 0xC0) {
                    const i = nums.indexOf(d1);
                    if (i >= 0) return ev(g, i, 1, true);
                }
                break;
            case 'pitchbend':
                if (status === 0xE0) {
                    const v = ((d2 << 7) | d1) / 16383;
                    return ev(g, 0, v, v !== 0.5);
                }
                break;
            }
        }
        return null;
    };
}

/** Jog wheel decode (JogProfile.parse): touch / scratch / bend per deck. */
export function decodeJog(jog, data) {
    if (!jog || !data || data.length < 3) return null;
    const type = data[0] & 0xF0, ch = data[0] & 0x0F;
    let deck = null, shift = false;
    for (const [name, c] of Object.entries(jog.decks).sort()) {
        if (ch === c) { deck = name; break; }
        if (ch === c + jog.shiftChannelOffset) { deck = name; shift = true; break; }
    }
    if (!deck) return null;
    if ((type === 0x90 || type === 0x80) && data[1] === jog.touch.note) {
        return { kind: 'touch', deck, shift, down: type === 0x90 && data[2] > 0 };
    }
    if (type === 0xB0 && (data[1] === jog.scratchCC || data[1] === jog.bendCC)) {
        const v = data[2];
        const ticks = jog.encoding === 'offset64' ? v - 0x40 : (v < 0x40 ? v : v - 0x80);
        if (ticks === 0) return null;
        return { kind: data[1] === jog.scratchCC ? 'scratch' : 'bend', deck, shift, ticks };
    }
    return null;
}

/** Layout entries for a control: exact index first, then group-wide. */
export function bindingsFor(profile, group, index) {
    const exact = profile.layout.filter(b => b.group === group && b.index === index);
    return exact.length ? exact : profile.layout.filter(b => b.group === group && b.index == null);
}

/** 'bound' | 'parked' | 'unmapped' for the unshifted layer of a control. */
export function statusOf(bindings) {
    const base = bindings.find(b => b.shift == null || b.shift === false) || bindings[0];
    if (!base) return 'unmapped';
    return base.action === 'unbound' ? 'parked' : 'bound';
}

export function describeBinding(b) {
    if (!b) return 'no layout entry';
    const shift = b.shift === true ? 'SHIFT+ ' : '';
    if (b.action === 'unbound') return `${shift}parked — ${b.reason || 'no reason given'}`;
    const deck = b.deck ? ` deck ${b.deck}` : '';
    const slot = b.slot != null ? ` slot ${b.slot + 1}` : '';
    return `${shift}${b.action}${deck}${slot}`;
}

export const hex = (bytes) => Array.from(bytes, b => b.toString(16).toUpperCase().padStart(2, '0')).join(' ');
