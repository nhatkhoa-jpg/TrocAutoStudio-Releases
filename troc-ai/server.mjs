import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const HOST = process.env.TROC_AI_HOST || '10.77.0.1';
const PORT = Number(process.env.TROC_AI_PORT || 8787);
const MODEL = process.env.TROC_AI_MODEL || 'gemini-3.5-flash-lite';
const API_KEY = process.env.GEMINI_API_KEY || '';
const STATE_DIR = process.env.TROC_AI_STATE_DIR || '/var/lib/troc-ai';
const QUEUE_DIR = process.env.TROC_AI_QUEUE_DIR || '/srv/troc-work/queue';
const RATE_FILE = path.join(STATE_DIR, 'rate-state.json');
const MAX_BODY = 1024 * 1024;
const MAX_HISTORY = 24;

await fsp.mkdir(STATE_DIR, { recursive: true });
await fsp.mkdir(QUEUE_DIR, { recursive: true });

let gateTail = Promise.resolve();
let queued = 0;
let active = 0;
const inflight = new Map();

function json(res, status, data, extra = {}) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extra,
  });
  res.end(body);
}

function text(res, status, body, type = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'content-type': type,
    'cache-control': status === 200 ? 'public, max-age=60' : 'no-store',
    'x-content-type-options': 'nosniff',
  });
  res.end(body);
}

async function readBody(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw Object.assign(new Error('request_too_large'), { status: 413 });
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw ? JSON.parse(raw) : {};
}

function safeRepo(repo) {
  return typeof repo === 'string' && /^nhatkhoa-jpg\/[A-Za-z0-9._-]+$/.test(repo);
}

function cleanHistory(history) {
  if (!Array.isArray(history)) return [];
  return history.slice(-MAX_HISTORY).map((item) => ({
    role: item?.role === 'assistant' ? 'model' : 'user',
    parts: [{ text: String(item?.content || '').slice(0, 16000) }],
  })).filter((item) => item.parts[0].text.trim());
}

async function readRateState() {
  try {
    return JSON.parse(await fsp.readFile(RATE_FILE, 'utf8'));
  } catch {
    return { cooldownUntil: 0, last429: 0 };
  }
}

async function writeRateState(state) {
  const tmp = `${RATE_FILE}.${process.pid}.tmp`;
  await fsp.writeFile(tmp, JSON.stringify(state), { mode: 0o600 });
  await fsp.rename(tmp, RATE_FILE);
}

function parseRetryAfter(value) {
  if (!value) return 0;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, date - Date.now()) : 0;
}

async function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function withGate(fn) {
  queued += 1;
  let release;
  const previous = gateTail;
  gateTail = new Promise((resolve) => { release = resolve; });
  await previous;
  queued -= 1;
  active += 1;
  try {
    return await fn();
  } finally {
    active -= 1;
    release();
  }
}

function systemInstruction(project, mode) {
  const projectText = project && safeRepo(project) ? `Current project/repository: ${project}.` : 'No repository is selected.';
  const modeText = mode === 'plan'
    ? 'Respond with a concise execution plan. Do not claim work was executed.'
    : 'Respond directly and practically. When the user asks for repository work, explain that an execution job can be queued from the Work button.';
  return [
    'You are Trọc AI, a private assistant running behind the owner\'s Oracle A1 gateway.',
    'Use Vietnamese by default unless the user asks otherwise.',
    projectText,
    modeText,
    'Never claim a command, deployment, commit, build, or external action happened unless the system explicitly reports that action result.',
  ].join(' ');
}

async function callGemini(payload) {
  if (!API_KEY) {
    const err = new Error('gemini_key_missing');
    err.status = 503;
    throw err;
  }

  const state = await readRateState();
  if (state.cooldownUntil && state.cooldownUntil > Date.now()) {
    const err = new Error('gemini_cooldown');
    err.status = 429;
    err.retryAfterMs = state.cooldownUntil - Date.now();
    throw err;
  }

  const prompt = String(payload.message || '').trim().slice(0, 32000);
  if (!prompt) {
    const err = new Error('message_required');
    err.status = 400;
    throw err;
  }

  const body = {
    systemInstruction: { parts: [{ text: systemInstruction(payload.project, payload.mode) }] },
    contents: [...cleanHistory(payload.history), { role: 'user', parts: [{ text: prompt }] }],
    generationConfig: {
      temperature: 0.35,
      maxOutputTokens: 4096,
    },
  };

  const fingerprint = crypto.createHash('sha256').update(JSON.stringify({ model: MODEL, body })).digest('hex');
  const existing = inflight.get(fingerprint);
  if (existing) return existing;

  const task = withGate(async () => {
    let lastError;
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(MODEL)}:generateContent?key=${encodeURIComponent(API_KEY)}`;
      let response;
      try {
        response = await fetch(url, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(120000),
        });
      } catch (error) {
        lastError = error;
        await wait(Math.min(8000, 750 * (2 ** attempt)) + Math.floor(Math.random() * 300));
        continue;
      }

      if (response.ok) {
        const data = await response.json();
        const answer = (data?.candidates?.[0]?.content?.parts || [])
          .map((part) => part?.text || '')
          .join('')
          .trim();
        if (!answer) {
          const err = new Error('empty_model_response');
          err.status = 502;
          throw err;
        }
        return { answer, model: MODEL, usage: data?.usageMetadata || null };
      }

      const raw = (await response.text()).slice(0, 4000);
      lastError = Object.assign(new Error(`gemini_http_${response.status}`), { status: response.status, detail: raw });

      if (response.status === 429) {
        const retryAfter = parseRetryAfter(response.headers.get('retry-after'));
        const cooldownMs = retryAfter || Math.min(15 * 60_000, 15_000 * (2 ** attempt));
        const nextState = { cooldownUntil: Date.now() + cooldownMs, last429: Date.now() };
        await writeRateState(nextState);
        lastError.retryAfterMs = cooldownMs;
        break;
      }

      if (response.status >= 500 && response.status <= 599) {
        await wait(Math.min(10000, 1000 * (2 ** attempt)) + Math.floor(Math.random() * 500));
        continue;
      }
      break;
    }
    throw lastError || Object.assign(new Error('gemini_unavailable'), { status: 502 });
  });

  inflight.set(fingerprint, task);
  try {
    return await task;
  } finally {
    setTimeout(() => inflight.delete(fingerprint), 30_000).unref?.();
  }
}

async function queueJob(payload) {
  const task = String(payload.task || '').trim().slice(0, 24000);
  const repo = String(payload.repo || '').trim();
  if (!task) throw Object.assign(new Error('task_required'), { status: 400 });
  if (!safeRepo(repo)) throw Object.assign(new Error('invalid_repo'), { status: 400 });
  const id = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
  const spec = {
    id,
    target_repo: repo,
    base_branch: String(payload.base_branch || 'main').slice(0, 128),
    model: MODEL,
    task,
    status: 'queued',
    created_at: new Date().toISOString(),
  };
  const finalPath = path.join(QUEUE_DIR, `${id}.json`);
  const tmpPath = `${finalPath}.tmp`;
  await fsp.writeFile(tmpPath, JSON.stringify(spec, null, 2), { mode: 0o600 });
  await fsp.rename(tmpPath, finalPath);
  return spec;
}

async function listJobs() {
  const roots = [
    ['queued', QUEUE_DIR],
    ['running', path.join(path.dirname(QUEUE_DIR), 'running')],
    ['done', path.join(path.dirname(QUEUE_DIR), 'done')],
    ['failed', path.join(path.dirname(QUEUE_DIR), 'failed')],
  ];
  const jobs = [];
  for (const [bucket, dir] of roots) {
    try {
      for (const name of await fsp.readdir(dir)) {
        if (!name.endsWith('.json')) continue;
        try {
          const data = JSON.parse(await fsp.readFile(path.join(dir, name), 'utf8'));
          jobs.push({ ...data, bucket });
        } catch { }
      }
    } catch { }
  }
  return jobs.sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || ''))).slice(0, 40);
}

async function serveStatic(req, res, pathname) {
  const relative = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const target = path.resolve(PUBLIC_DIR, relative);
  if (!target.startsWith(PUBLIC_DIR + path.sep) && target !== path.join(PUBLIC_DIR, 'index.html')) return false;
  try {
    const stat = await fsp.stat(target);
    if (!stat.isFile()) return false;
    const ext = path.extname(target).toLowerCase();
    const types = {
      '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
      '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon',
    };
    text(res, 200, await fsp.readFile(target), types[ext] || 'application/octet-stream');
    return true;
  } catch {
    return false;
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    if (req.method === 'GET' && pathname === '/api/health') {
      const rate = await readRateState();
      return json(res, 200, {
        ok: true,
        service: 'troc-ai',
        hostname: os.hostname(),
        uptime_seconds: Math.round(process.uptime()),
        model: MODEL,
        gemini_ready: Boolean(API_KEY),
        active_requests: active,
        queued_requests: queued,
        cooldown_until: rate.cooldownUntil || 0,
      });
    }

    if (req.method === 'POST' && pathname === '/api/chat') {
      const payload = await readBody(req);
      const result = await callGemini(payload);
      return json(res, 200, result);
    }

    if (req.method === 'POST' && pathname === '/api/jobs') {
      const payload = await readBody(req);
      const job = await queueJob(payload);
      return json(res, 202, { ok: true, job });
    }

    if (req.method === 'GET' && pathname === '/api/jobs') {
      return json(res, 200, { jobs: await listJobs() });
    }

    if (req.method === 'GET' || req.method === 'HEAD') {
      if (await serveStatic(req, res, pathname)) return;
      if (!pathname.startsWith('/api/')) {
        const fallback = await fsp.readFile(path.join(PUBLIC_DIR, 'index.html'));
        return text(res, 200, fallback, 'text/html; charset=utf-8');
      }
    }

    return json(res, 404, { error: 'not_found' });
  } catch (error) {
    const status = Number(error?.status || 500);
    return json(res, status, {
      error: error?.message || 'server_error',
      retry_after_ms: error?.retryAfterMs || undefined,
    }, error?.retryAfterMs ? { 'retry-after': String(Math.max(1, Math.ceil(error.retryAfterMs / 1000))) } : {});
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Trọc AI listening on http://${HOST}:${PORT} model=${MODEL} gemini_ready=${Boolean(API_KEY)}`);
});
