// Pilot save helper: writes the panel's notes, marks and queue order to <data folder>\panel.json, so nothing has to
// be "linked" by hand. Listens on 127.0.0.1 only; every request needs the secret in <data folder>\token.txt, which
// build.ps1 puts into the panel HTML. Started by the "Pilot panel - <name> (helper)" task; no admin.
//   node panel-server.js <data folder> <port>
//   GET  /panel   -> panel.json (or an empty state)
//   POST /panel   -> merges the posted state into panel.json (newest "updated" wins per item), returns the result
//   GET  /health  -> {"ok":true}
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const DIR = process.argv[2] || __dirname;
const PANEL = path.join(DIR, 'panel.json');
const PORT = parseInt(process.argv[3] || '47231', 10);
const TOKEN = fs.readFileSync(path.join(DIR, 'token.txt'), 'utf8').trim();
if (TOKEN.length < 32) throw new Error('token.txt is missing or too short');

function ts(x) { const t = Date.parse(x || ''); return isNaN(t) ? 0 : t; }
function emptyState() { return { v: 1, notes: {}, notesOrder: { ids: [], updated: '' }, marks: {}, queueOrder: { ids: [], updated: '' }, myQueue: {}, deleted: {}, updated: '' }; }
function normalize(s) {
  const e = emptyState();
  if (!s || typeof s !== 'object' || Array.isArray(s)) return e;
  for (const k of Object.keys(e)) if (s[k] == null || typeof s[k] !== typeof e[k]) s[k] = e[k];
  if (!Array.isArray(s.queueOrder.ids)) s.queueOrder = e.queueOrder;
  if (!Array.isArray(s.notesOrder.ids)) s.notesOrder = e.notesOrder;
  return s;
}
// The same merge as the page (board.template.html mergeState).
function mergeState(a, b) {
  a = normalize(a); b = normalize(b);
  const out = emptyState();
  for (const d of [a.deleted, b.deleted]) for (const id in d) if (ts(d[id]) > ts(out.deleted[id])) out.deleted[id] = d[id];
  for (const coll of ['notes', 'myQueue', 'marks']) for (const src of [a[coll], b[coll]]) for (const id in src) {
    const v = src[id]; if (!v || typeof v !== 'object') continue;
    const cur = out[coll][id]; if (!cur || ts(v.updated) > ts(cur.updated)) out[coll][id] = v;
  }
  for (const coll of ['notes', 'myQueue']) for (const id in out[coll]) if (out.deleted[id] && ts(out.deleted[id]) >= ts(out[coll][id].updated)) delete out[coll][id];
  for (const o of ['queueOrder', 'notesOrder']) out[o] = ts(b[o].updated) > ts(a[o].updated) ? b[o] : a[o];
  out.updated = ts(b.updated) > ts(a.updated) ? b.updated : a.updated;
  return out;
}
function readPanel() {
  try { let t = fs.readFileSync(PANEL, 'utf8'); if (t.charCodeAt(0) === 0xFEFF) t = t.slice(1); return t.trim() ? normalize(JSON.parse(t)) : emptyState(); }
  catch (e) { return emptyState(); }
}
function writePanel(s) {
  const tmp = PANEL + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2), 'utf8');
  fs.renameSync(tmp, PANEL);
}

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Pilot-Token');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Private-Network', 'true');
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  const url = req.url.split('?')[0];
  if (url === '/health') { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end('{"ok":true}'); }
  if (url !== '/panel') { res.writeHead(404); return res.end(); }
  if (req.headers['x-pilot-token'] !== TOKEN) { res.writeHead(403); return res.end(); }
  if (req.method === 'GET') { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify(readPanel())); }
  if (req.method !== 'POST') { res.writeHead(405); return res.end(); }
  let body = '', size = 0;
  req.on('data', c => { size += c.length; if (size > 5 * 1024 * 1024) { res.writeHead(413); res.end(); req.destroy(); } else body += c; });
  req.on('end', () => {
    if (res.writableEnded) return;
    let incoming;
    try { incoming = JSON.parse(body); } catch (e) { res.writeHead(400); return res.end('bad json'); }
    const merged = mergeState(readPanel(), incoming);
    try { writePanel(merged); } catch (e) { res.writeHead(500); return res.end(String(e.message)); }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(merged));
  });
});
server.on('error', e => { if (e.code === 'EADDRINUSE') process.exit(0); throw e; });   // already running
server.listen(PORT, '127.0.0.1');
