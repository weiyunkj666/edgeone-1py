/**
 * EdgeOne Pages / Makers — Node.js Cloud Function 版中转
 * 用途：与 edge-functions/api/[[default]].js 功能相同，但额外支持 WebSocket 升级，
 *       用于 XHTTP 的 stream-up 模式（客户端经 WS 上行）。
 *
 * 文件位置（与 edge-functions 版二选一，不要同时启用，避免路由冲突）：
 *   ./cloud-functions/api/[[default]].js   -> 匹配 /api/*
 *
 * 环境变量：UPSTREAM / HOST / STRIP_PREFIX / AUTH_TOKEN / DEBUG（含义见 README）
 *
 * 注意：Cloud Functions 单请求 wall clock 上限 120 秒，长连接会被平台断开，
 *       客户端（Xray）需要能自动重连；这是平台限制，代码层面无法绕过。
 */

const HOP_BY_HOP = new Set([
  'connection',
  'proxy-connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'host',
  'content-length',
  'accept-encoding',
  'te',
  'trailer',
  'proxy-authorization',
  'proxy-authenticate',
  'cf-connecting-ip',
  'cf-ipcountry',
  'cf-ray',
  'cf-visitor',
  'x-forwarded-host',
  'x-forwarded-proto',
  'x-forwarded-port',
]);

const API_PREFIX = '/api';

/** 环境变量取值：优先 context.env，再退回 process.env */
function getEnv(context, key) {
  const e = (context && context.env) || {};
  if (e[key] !== undefined && e[key] !== null && e[key] !== '') return String(e[key]);
  const p = globalThis.process;
  const v = p && p.env ? p.env[key] : undefined;
  return (v === undefined || v === null) ? '' : String(v);
}

function upstreamOf(context) {
  return (getEnv(context, 'UPSTREAM') || getEnv(context, 'EO_UPSTREAM')).replace(/\/+$/, '');
}

function stripPrefix(pathname, keep) {
  if (keep) return pathname || '/';
  if (pathname === API_PREFIX || pathname === API_PREFIX + '/') return '/';
  if (pathname.startsWith(API_PREFIX + '/')) return pathname.slice(API_PREFIX.length);
  return pathname || '/';
}

/** 构造目标 URL；ws=true 时换成 ws/wss（WebSocket 回源） */
function targetUrl(context, ws) {
  const inUrl = new URL(context.request.url);
  const t = new URL(upstreamOf(context) + stripPrefix(inUrl.pathname, getEnv(context, 'STRIP_PREFIX') === '0'));
  if (inUrl.search) t.search = inUrl.search;
  if (ws) {
    if (t.protocol === 'https:') t.protocol = 'wss:';
    else if (t.protocol === 'http:') t.protocol = 'ws:';
  }
  return t;
}

function outboundHeaders(context, extra) {
  const headers = new Headers();
  for (const [k, v] of context.request.headers) {
    if (!HOP_BY_HOP.has(k.toLowerCase())) headers.set(k, v);
  }
  const fakeHost = getEnv(context, 'HOST');
  if (fakeHost) headers.set('host', fakeHost);
  const token = getEnv(context, 'AUTH_TOKEN');
  if (token) headers.set('x-relay-token', token);
  if (extra) for (const [k, v] of Object.entries(extra)) headers.set(k, v);
  return headers;
}

export default function onRequest(context) {
  return handleRequest(context).catch((err) => new Response(JSON.stringify({
    ok: false,
    error: String((err && err.message) || err),
  }, null, 2), {
    status: 502,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  }));
}

async function handleRequest(context) {
  const request = context.request;
  const debug = getEnv(context, 'DEBUG') === '1';

  if (!upstreamOf(context)) return new Response('UPSTREAM 未配置', { status: 500 });

  // ---- WebSocket 升级分支（XHTTP stream-up / HTTPUpgrade 走这里）----
  const upgrade = (request.headers.get('upgrade') || '').toLowerCase();
  if (upgrade === 'websocket') {
    return proxyWebSocket(context);
  }

  const t = targetUrl(context, false);
  const method = request.method.toUpperCase();
  const hasBody = method !== 'GET' && method !== 'HEAD';

  const resp = await fetch(t.toString(), {
    method,
    headers: outboundHeaders(context, {
      'x-forwarded-for': context.clientIp || '',
      'x-forwarded-proto': 'https',
      'x-real-ip': context.clientIp || '',
    }),
    body: hasBody ? request.body : undefined,
    redirect: 'manual',
  });

  const outHeaders = new Headers();
  for (const [k, v] of resp.headers) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    outHeaders.set(k, v);
  }
  outHeaders.set('cache-control', 'no-store, no-cache, must-revalidate');
  if (debug) {
    outHeaders.set('x-debug-upstream', t.toString());
    outHeaders.set('x-debug-status', String(resp.status));
  }

  return new Response(resp.body, {
    status: resp.status,
    statusText: resp.statusText,
    headers: outHeaders,
  });
}

/**
 * WS 升级处理。运行时有两大类 WebSocket 形态，按运行期探测二选一：
 *   ① Workers 风格：WebSocketPair + Response(101, { webSocket })
 *      —— Node 原生 Response 会拒绝 101 或静默忽略 webSocket 字段，必须显式校验
 *   ② 官方模板风格：返回 { websocket: { onopen, onmessage, onclose, onerror } }
 * 两者都不可用时给出明文原因，而不是无声失败。
 */
async function proxyWebSocket(context) {
  const target = targetUrl(context, true);
  if (detectPairSupport() === 'no') {
    return proxyWithHandlerObject(context, target);
  }
  // 'yes' / 'unknown'：先按 Workers 风格试，失败再退回 handler 形态
  return proxyWithWebSocketPair(context, target, true);
}

/** 'yes' | 'no' | 'unknown' */
function detectPairSupport() {
  if (typeof WebSocketPair !== 'function') return 'no';
  const versions = (globalThis.process && globalThis.process.versions) || {};
  if (versions.node) {
    // Node 原生 Response 不支持 webSocket 字段，只能走 handler 形态
    return 'no';
  }
  return 'unknown';
}

/**
 * 构造 101 升级响应，并校验运行时是否真的接受了 webSocket 字段。
 * 不满足条件就抛错，由上层退回 handler 形态，避免把 200 当成升级成功。
 */
function makeUpgradeResponse(clientSocket) {
  const res = new Response(null, { status: 101, webSocket: clientSocket });
  if (!res || res.status !== 101 || res.webSocket !== clientSocket) {
    throw new Error('runtime ignores Response webSocket init');
  }
  return res;
}

/** ① Workers 风格：WebSocketPair + Response(101) */
async function proxyWithWebSocketPair(context, target, allowFallback) {
  const pair = new WebSocketPair();
  const client = Object.values(pair)[0];
  const server = Object.values(pair)[1];
  server.accept();

  const connected = await connectUpstream(context, target);
  if (connected.error) {
    closeQuietly(server, 1011, 'upstream connect failed');
    return connected.error;
  }
  bridge(server, connected.remote);

  let res;
  try {
    res = makeUpgradeResponse(client);
  } catch (err) {
    closeQuietly(server, 1011, 'pair response unsupported');
    closeQuietly(connected.remote, 1011, 'pair response unsupported');
    if (allowFallback) return proxyWithHandlerObject(context, target);
    return runtimeError('当前运行时无法用 Response(101,{webSocket}) 完成升级：' + String((err && err.message) || err));
  }
  return res;
}

/** ② 官方模板风格：{ websocket: { onopen, onmessage, onclose, onerror } } */
async function proxyWithHandlerObject(context, target) {
  const connected = await connectUpstream(context, target);
  if (connected.error) return connected.error;
  const remote = connected.remote;

  let bound = false;
  let clientWs = null;

  const bindUpstream = (ws) => {
    clientWs = ws;
    if (bound || !remote) return;
    bound = true;
    listen(remote, 'message', (ev) => {
      try {
        clientWs.send(ev.data);
      } catch (_) { /* 客户端已断开 */ }
    });
    listen(remote, 'close', (ev) => closeQuietly(clientWs, ev && ev.code, ev && ev.reason));
    listen(remote, 'error', () => closeQuietly(clientWs, 1011, 'upstream error'));
  };

  return {
    websocket: {
      onopen(ws) {
        bindUpstream(ws);
      },
      onmessage(ws, message) {
        bindUpstream(ws);
        if (!remote) return;
        try {
          remote.send(message);
        } catch (_) { /* 上游已断开 */ }
      },
      onclose(ws, code, reason) {
        closeQuietly(remote, code, reason && reason.toString ? reason.toString() : reason);
      },
      onerror(ws, err) {
        closeQuietly(remote, 1011, String((err && err.message) || err).slice(0, 100));
      },
    },
  };
}

/** 与上游 Xray 建立 WS 连接；返回 { remote } 或 { error } */
async function connectUpstream(context, target) {
  const headers = outboundHeaders(context, {
    'x-forwarded-for': context.clientIp || '',
    'x-forwarded-proto': 'https',
  });
  // 子协议：Xray stream-up 需要协议头原样回显，这里把客户端的值透传给上游
  const subproto = context.request.headers.get('sec-websocket-protocol');
  if (subproto) headers.set('sec-websocket-protocol', subproto);
  headers.set('upgrade', 'websocket');
  headers.set('connection', 'Upgrade');

  let resp;
  try {
    resp = await fetch(target.toString(), { method: 'GET', headers });
  } catch (err) {
    return { error: new Response('回源 WebSocket 连接失败: ' + String((err && err.message) || err), { status: 502 }) };
  }

  const remote = resp && resp.webSocket;
  if (!remote) {
    return {
      error: new Response(
        '上游未返回可用的 WebSocket（status=' + (resp ? resp.status : '?') +
        '）。若运行时不支持 fetch 的 Upgrade 直通，请改用 packet-up 模式。',
        { status: 502 }),
    };
  }
  try {
    remote.accept();
  } catch (_) { /* 已 accept 会抛错，忽略 */ }
  return { remote };
}

/** 双向消息桥接 + 任一侧关闭/出错时关闭另一侧 */
function bridge(server, remote) {
  const closeBoth = (code, reason) => {
    closeQuietly(server, code, reason);
    closeQuietly(remote, code, reason);
  };
  listen(server, 'message', (ev) => {
    try {
      remote.send(ev.data);
    } catch (_) {
      closeBoth(1011, 'relay send failed');
    }
  });
  listen(remote, 'message', (ev) => {
    try {
      server.send(ev.data);
    } catch (_) {
      closeBoth(1011, 'relay send failed');
    }
  });
  listen(server, 'close', (ev) => closeQuietly(remote, ev && ev.code, ev && ev.reason));
  listen(remote, 'close', (ev) => closeQuietly(server, ev && ev.code, ev && ev.reason));
  listen(server, 'error', () => closeBoth(1011, 'client error'));
  listen(remote, 'error', () => closeBoth(1011, 'upstream error'));
}

function listen(sock, type, fn) {
  sock.addEventListener(type, fn);
}

function closeQuietly(sock, code, reason) {
  if (!sock) return;
  try {
    sock.close(code, reason);
  } catch (_) {
    try {
      sock.close();
    } catch (_) { /* 已关闭 */ }
  }
}

function runtimeError(message) {
  return new Response(message + '\n提示：改用 packet-up 模式（无需 WebSocket）可绕开该限制。', {
    status: 501,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
}
