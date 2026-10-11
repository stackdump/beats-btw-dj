#!/usr/bin/env node
// Reverse direction of ROADMAP 2.5 share URLs: real JS decodes what Swift encoded.
//
//   DJ_SHARE_URL_OUT=/tmp/swift-share-urls.json make swift-test   (the Swift test writes it)
//   node scripts/beats-share-url-check.mjs /tmp/swift-share-urls.json
//
// File: [{ payload, url }]. For each, JS's own parseShareFromUrl must accept the URL
// (CID verified by JS) and return shareFromPayload(payload, cid).
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const lib = (p) => import(pathToFileURL(path.join(PUBLIC, 'lib', p)).href);
const codec = await lib('share/codec.js');
const url = await lib('share/url.js');
const rows = JSON.parse(readFileSync(process.argv[2], 'utf8'));
let bad = 0;
for (const { payload, url: u } of rows) {
  globalThis.location = { search: new URL(u).search };
  const got = await url.parseShareFromUrl({});
  const cid = await codec.computeCidForJsonLd(payload);
  const want = url.shareFromPayload(payload, cid);
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) { bad++; console.error('MISMATCH', u.slice(0, 80), JSON.stringify(got)?.slice(0, 120)); }
}
console.log(`${rows.length - bad}/${rows.length} Swift-built URLs accepted by JS`);
process.exit(bad ? 1 : 0);
