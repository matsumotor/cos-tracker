// Creatures of Sonaria Tracker - servidor que recebe heartbeats das contas
// e serve dashboard mostrando: contas online, mush e tokens por conta, totais gerais.
// Mesma arquitetura do da-tracker (tracker/server.js).

import express from 'express';
import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;
const AUTH_TOKEN = process.env.AUTH_TOKEN || 'CHANGE_ME_LOCAL_DEV';
const ONLINE_THRESHOLD_MS = 90_000;  // sem heartbeat por 90s = offline

// ----- DB setup -----
const db = new Database(path.join(__dirname, 'tracker.db'));
db.pragma('journal_mode = WAL');
db.exec(`
    CREATE TABLE IF NOT EXISTS accounts (
        userId        INTEGER PRIMARY KEY,
        username      TEXT NOT NULL,
        mush          INTEGER NOT NULL DEFAULT 0,
        maxGrowth     INTEGER NOT NULL DEFAULT 0,
        partialGrowth INTEGER NOT NULL DEFAULT 0,
        reviveToken   INTEGER NOT NULL DEFAULT 0,
        deathToken    INTEGER NOT NULL DEFAULT 0,
        placeId       INTEGER,
        jobId         TEXT,
        sessionStart  INTEGER,
        lastSeen      INTEGER NOT NULL,
        firstSeen     INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_accounts_lastseen ON accounts(lastSeen);
`);

const upsertAccount = db.prepare(`
    INSERT INTO accounts (userId, username, mush, maxGrowth, partialGrowth, reviveToken, deathToken, placeId, jobId, sessionStart, lastSeen, firstSeen)
    VALUES (@userId, @username, @mush, @maxGrowth, @partialGrowth, @reviveToken, @deathToken, @placeId, @jobId, @sessionStart, @ts, @ts)
    ON CONFLICT(userId) DO UPDATE SET
        username = excluded.username,
        mush = excluded.mush,
        maxGrowth = excluded.maxGrowth,
        partialGrowth = excluded.partialGrowth,
        reviveToken = excluded.reviveToken,
        deathToken = excluded.deathToken,
        placeId = excluded.placeId,
        jobId = excluded.jobId,
        sessionStart = CASE
            WHEN accounts.lastSeen < @ts - ${ONLINE_THRESHOLD_MS}
                 OR accounts.sessionStart IS NULL
            THEN @sessionStart
            ELSE accounts.sessionStart
        END,
        lastSeen = excluded.lastSeen
`);
const queryAll = db.prepare(`SELECT * FROM accounts ORDER BY lastSeen DESC`);
const deleteAccount = db.prepare(`DELETE FROM accounts WHERE userId = ?`);

// ----- Express app -----
const app = express();
app.use(express.json({ limit: '256kb' }));
app.use(express.static(path.join(__dirname, 'public')));

// Middleware: auth simples por header
function requireAuth(req, res, next) {
    const token = req.header('X-Auth-Token');
    if (token !== AUTH_TOKEN) {
        return res.status(401).json({ error: 'invalid auth token' });
    }
    next();
}

// POST /heartbeat — chamado pelo Lua de cada conta a cada 30s
app.post('/heartbeat', requireAuth, (req, res) => {
    const { userId, username, mush, maxGrowth, partialGrowth, reviveToken, deathToken, placeId, jobId, sessionStart } = req.body || {};
    if (typeof userId !== 'number' || !username) {
        return res.status(400).json({ error: 'userId (number) and username required' });
    }
    const ts = Date.now();
    try {
        upsertAccount.run({
            userId,
            username,
            mush:          Number(mush)          || 0,
            maxGrowth:     Number(maxGrowth)     || 0,
            partialGrowth: Number(partialGrowth) || 0,
            reviveToken:   Number(reviveToken)   || 0,
            deathToken:    Number(deathToken)    || 0,
            placeId: Number(placeId) || null,
            jobId: jobId || null,
            sessionStart: Number(sessionStart) || ts,
            ts,
        });
        res.json({ ok: true, ts });
    } catch (e) {
        console.error('heartbeat err:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// GET /api/state — usado pelo dashboard pra polling
app.get('/api/state', (req, res) => {
    const now = Date.now();
    const rows = queryAll.all();
    const accounts = rows.map(r => ({
        userId: r.userId,
        username: r.username,
        mush: r.mush || 0,
        maxGrowth: r.maxGrowth || 0,
        partialGrowth: r.partialGrowth || 0,
        reviveToken: r.reviveToken || 0,
        deathToken: r.deathToken || 0,
        placeId: r.placeId,
        jobId: r.jobId,
        online: (now - r.lastSeen) < ONLINE_THRESHOLD_MS,
        sessionDurationMs: r.sessionStart ? (now - r.sessionStart) : 0,
        lastSeenAgoMs: now - r.lastSeen,
        firstSeen: r.firstSeen,
    }));
    const online = accounts.filter(a => a.online);
    const sum = (key, list = accounts) => list.reduce((s, a) => s + a[key], 0);
    res.json({
        ts: now,
        totalAccounts: accounts.length,
        totalOnline: online.length,
        totalMush: sum('mush'),
        totalMaxGrowth: sum('maxGrowth'),
        totalPartialGrowth: sum('partialGrowth'),
        totalReviveToken: sum('reviveToken'),
        totalDeathToken: sum('deathToken'),
        onlineMush: sum('mush', online),
        accounts,
    });
});

// DELETE de contas. Body: { userIds: [123, 456, ...] }
// Auth via X-Auth-Token (mesmo do heartbeat).
app.post('/api/delete', requireAuth, (req, res) => {
    const { userIds } = req.body || {};
    if (!Array.isArray(userIds) || userIds.length === 0) {
        return res.status(400).json({ error: 'userIds array required' });
    }
    let deleted = 0;
    const tx = db.transaction((ids) => {
        for (const id of ids) {
            const r = deleteAccount.run(Number(id));
            deleted += r.changes;
        }
    });
    try {
        tx(userIds);
        res.json({ ok: true, deleted });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// GET / — serve dashboard
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
});

// Healthcheck pro Render
app.get('/health', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

// Icon proxy: resolve assetId via Roblox Thumbnails API e redireciona pra CDN.
// Cache em memoria (24h TTL) — assetId -> imageUrl da CDN.
const iconCache = new Map();
app.get('/icon/:assetId', async (req, res) => {
    const id = String(req.params.assetId).replace(/\D/g, '');
    if (!id) return res.status(400).send('invalid assetId');
    const cached = iconCache.get(id);
    if (cached && cached.expires > Date.now()) {
        return res.redirect(302, cached.url);
    }
    try {
        const apiRes = await fetch(
            `https://thumbnails.roblox.com/v1/assets?assetIds=${id}&size=150x150&format=Png&isCircular=false`,
            { headers: { 'User-Agent': 'Mozilla/5.0' } }
        );
        const json = await apiRes.json();
        const url = json?.data?.[0]?.imageUrl;
        if (!url) return res.status(404).send('thumbnail not available');
        iconCache.set(id, { url, expires: Date.now() + 24 * 60 * 60 * 1000 });
        res.set('Cache-Control', 'public, max-age=86400');
        res.redirect(302, url);
    } catch (e) {
        console.error('icon resolve error:', e.message);
        res.status(500).send(e.message);
    }
});

// Serve o Lua do heartbeat (pra usar via loadstring no executor)
// Uso no autoexec:
//   _G.COS_TRACKER_TOKEN = "seu_token"
//   loadstring(game:HttpGet("https://cos-tracker.onrender.com/heartbeat.lua"))()
app.get('/heartbeat.lua', (req, res) => {
    try {
        const lua = fs.readFileSync(path.join(__dirname, 'cos_heartbeat.lua'), 'utf8');
        res.set('Content-Type', 'text/plain; charset=utf-8');
        res.set('Cache-Control', 'no-cache');
        res.send(lua);
    } catch (e) {
        res.status(500).send(`-- erro lendo cos_heartbeat.lua: ${e.message}`);
    }
});

app.listen(PORT, () => {
    console.log(`cos-tracker rodando em http://localhost:${PORT}`);
    console.log(`auth token: ${AUTH_TOKEN === 'CHANGE_ME_LOCAL_DEV' ? '(default, troca em produção via env AUTH_TOKEN)' : '(configurado via env)'}`);
});
