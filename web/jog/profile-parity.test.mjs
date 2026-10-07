// node --test web/jog/profile-parity.test.mjs
// The device profile's source of truth is the JSON the Swift app bundles.
// The browser lab still keeps its own JS object; this fails if they drift.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { INPULSE_200_MK3 } from './inpulse-200-mk3.js';

const json = JSON.parse(fs.readFileSync(
    new URL('../../Sources/DJCore/Resources/profiles/inpulse-200-mk3.json', import.meta.url), 'utf8'));

test('JS profile matches Sources/DJCore/Resources/profiles/inpulse-200-mk3.json', () => {
    const js = { ...INPULSE_200_MK3, match: INPULSE_200_MK3.match.source };
    assert.deepEqual(js, json);
});
