/**
 * EdgeOne Pages / Makers — 反向代理中转（Edge Function）
 *
 * 位置：edge-functions/api/[[default]].js，映射 /api/* 路由，采用「具名导出 onRequest」。
 * 重要：不要把 catch-all 放到 edge-functions/ 根级——它与 api/[[default]].js 同时存在时，
 *       平台的路由解析会异常，导致 /api/* 直接返回空 body 的 404（已实测复现）。
 * 平台不会剥掉 /api 前缀：函数内看到的就是 /api/session，由本文件自行剥离。
 *
 * 环境变量：
 *   UPSTREAM      后端地址，如 https://1.2.3.4:8443（不支持回源 IPv6，必须 IPv4 或 A 记录域名）
 *   HOST          转发时写回给后端的 Host 头（Xray 服务端分流/伪装校验用）
 *   STRIP_PREFIX  默认 "1"：客户端 /api/session -> 后端 /session；设 "0" 保留完整路径
 *   AUTH_TOKEN    若设置，转发时附加 x-relay-token 头
 *   DEBUG         设 "1" 时响应附加 x-debug-* 诊断头
 *
 * 自检：GET /api/__health 返回中转运行状态（不访问后端）
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

/** 环境变量取值：优先 context.env，再退回 process.env（Node 测试环境） */
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

function json(status, body) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-relay': 'edgeone-xray-relay',
    },
  });
}

async function handle(context) {
  const request = context.request;
  const debug = getEnv(context, 'DEBUG') === '1';
  const inUrl = new URL(request.url);
  // 平台会先剥掉 /api 前缀，这里再兜一层，兼容直接带 /api 调用的情况
  const path = stripPrefix(inUrl.pathname, getEnv(context, 'STRIP_PREFIX') === '0');
  const origin = upstreamOf(context);

  // ---- 自检端点：证明函数被真正执行（不碰后端） ----
  if (inUrl.pathname === '/__health' || path === '/__health') {
    return json(200, {
      ok: true,
      relay: 'edgeone-xray-relay/edge',
      runtime: typeof caches === 'undefined' ? 'unknown' : 'worker',
      hasUpstream: !!origin,
      upstream: origin ? origin.replace(/(:\/\/[^/]+).*/, '$1') : null,
      host: getEnv(context, 'HOST') || null,
      stripPrefix: getEnv(context, 'STRIP_PREFIX') !== '0',
      seenPath: inUrl.pathname,
      forwardedPath: path,
      clientIp: context.clientIp || null,
    });
  }

  if (!origin) {
    return json(500, {
      ok: false,
      error: 'UPSTREAM 未配置',
      hint: '在 EdgeOne 控制台的项目设置里添加环境变量 UPSTREAM=https://你的后端:端口，然后重新部署',
    });
  }

  // 目标 URL：路径 + 原始查询串（XHTTP 的 x_padding 等参数必须原样保留）
  const target = new URL(origin + path);
  if (inUrl.search) target.search = inUrl.search;

  const headers = new Headers();
  for (const [k, v] of request.headers) {
    if (!HOP_BY_HOP.has(k.toLowerCase())) headers.set(k, v);
  }
  const fakeHost = getEnv(context, 'HOST');
  if (fakeHost) headers.set('host', fakeHost);
  const token = getEnv(context, 'AUTH_TOKEN');
  if (token) headers.set('x-relay-token', token);
  const clientIp = context.clientIp || '';
  if (clientIp) {
    headers.set('x-forwarded-for', clientIp);
    headers.set('x-real-ip', clientIp);
  }
  headers.set('x-forwarded-proto', 'https');

  const method = request.method.toUpperCase();
  const hasBody = method !== 'GET' && method !== 'HEAD';

  const resp = await fetch(target.toString(), {
    method,
    headers,
    body: hasBody ? request.body : undefined,
    redirect: 'manual',
  });

  const outHeaders = new Headers();
  for (const [k, v] of resp.headers) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    outHeaders.set(k, v);
  }
  outHeaders.set('cache-control', 'no-store, no-cache, must-revalidate');
  outHeaders.set('x-relay', 'edgeone-xray-relay');
  if (debug) {
    outHeaders.set('x-debug-upstream', target.toString());
    outHeaders.set('x-debug-status', String(resp.status));
  }

  return new Response(resp.body, {
    status: resp.status,
    statusText: resp.statusText,
    headers: outHeaders,
  });
}

/** 统一的入口封装：任何异常都返回可读原因，方便排障 */
function entry(context) {
  return handle(context).catch((err) => json(502, {
    ok: false,
    error: String((err && err.message) || err),
    hint: '检查 UPSTREAM 是否可达（不支持 IPv6 回源）、端口与证书是否正确',
  }));
}

// EdgeOne Pages Edge Function：具名导出 onRequest（平台上已验证可用的写法）
export function onRequest(context) {
  return entry(context);
}

export default onRequest;
