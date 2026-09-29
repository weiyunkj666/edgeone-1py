/**
 * EdgeOne Pages / Makers — Edge Function 反向代理中转
 * 用途：把 https://你的域名/api/xxx 透明转发到 UPSTREAM 指向的 Xray 后端
 *       （适配 XHTTP 的 packet-up 模式，对普通 HTTP/HTTPS 请求同样有效）
 *
 * 路由：edge-functions/api/[[default]].js -> 匹配 /api/*（含多级子路径）
 *
 * 必需环境变量（EdgeOne 控制台 → 项目 → 环境变量）：
 *   UPSTREAM   你的后端地址，例如 https://1.2.3.4:8443 或 https://origin.example.com
 *              注意：Pages 不支持回源 IPv6，请填 IPv4 或 A 记录域名
 *   HOST       转发时使用的 Host 头（Xray 服务端按域名分流/伪装校验用）
 *
 * 可选环境变量：
 *   STRIP_PREFIX   默认 "1"：转发时去掉开头的 /api（客户端 /api/session -> 后端 /session）
 *                  设为 "0" 则保留完整路径（后端也会看到 /api/session）
 *   AUTH_TOKEN     若设置，转发时附加 x-relay-token 头，后端可校验，防止中转被白嫖
 *   DEBUG          设为 "1" 时，响应附加 x-debug-* 诊断头
 */

const HOP_BY_HOP = new Set([
  'connection',
  'proxy-connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'host',                 // 由目标 URL / HOST 变量决定
  'content-length',       // 交给 fetch 按实际 body 重新计算
  'accept-encoding',      // 让平台自行协商压缩，避免解压后贴上错误的编码头
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

/** 环境变量取值：优先用 context.env（Makers/Pages 推荐方式），再退回 process.env */
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

export default function onRequest(context) {
  return handle(context).catch((err) => new Response(JSON.stringify({
    ok: false,
    error: String((err && err.message) || err),
    hint: '检查 UPSTREAM 环境变量与后端可达性（后端不支持 IPv6 回源）',
  }, null, 2), {
    status: 502,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  }));
}

async function handle(context) {
  const request = context.request;
  const origin = upstreamOf(context);
  const debug = getEnv(context, 'DEBUG') === '1';

  if (!origin) {
    return json(500, {
      ok: false,
      error: 'UPSTREAM 未配置',
      hint: '在 EdgeOne 控制台的项目设置里添加环境变量 UPSTREAM=https://你的后端:端口，然后重新部署',
    });
  }

  const inUrl = new URL(request.url);
  const path = stripPrefix(inUrl.pathname, getEnv(context, 'STRIP_PREFIX') === '0');

  // 目标 URL：路径 + 原始查询串（XHTTP 的 x_padding 等参数必须原样保留）
  const target = new URL(origin + path);
  if (inUrl.search) target.search = inUrl.search;

  // 组装回源请求头
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

  // 流式回源，不把 body 读进内存
  const resp = await fetch(target.toString(), {
    method,
    headers,
    body: hasBody ? request.body : undefined,
    redirect: 'manual',   // 保留后端返回的 3xx
  });

  // 组装响应：剔除逐跳头
  const outHeaders = new Headers();
  for (const [k, v] of resp.headers) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    outHeaders.set(k, v);
  }
  outHeaders.set('cache-control', 'no-store, no-cache, must-revalidate');
  if (debug) {
    outHeaders.set('x-debug-upstream', target.toString());
    outHeaders.set('x-debug-status', String(resp.status));
    outHeaders.set('x-debug-ct', resp.headers.get('content-type') || '');
    outHeaders.set('x-debug-client-ip', clientIp);
  }

  return new Response(resp.body, {
    status: resp.status,
    statusText: resp.statusText,
    headers: outHeaders,
  });
}

function json(status, body) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}
