// 行为测试：用模拟运行时验证 edge-functions（HTTP 中转）与 cloud-functions（含 WS 桥接）两个版本
import edgeMod from '../edgeone-xray-relay/edge-functions/api/[[default]].js';

const handler = edgeMod.default || edgeMod;
const results = [];
function check(name, cond, extra) {
  results.push({ name, pass: !!cond, extra: extra === undefined ? '' : String(extra) });
}

let captured = null;

function okResponse() {
  const stream = new ReadableStream({
    start(c) { c.enqueue(new TextEncoder().encode('hello-from-origin')); c.close(); },
  });
  return new Response(stream, {
    status: 200,
    headers: { 'content-type': 'text/event-stream', 'transfer-encoding': 'chunked', 'x-origin': 'xray' },
  });
}

globalThis.fetch = async (url, init) => {
  captured = {
    url: String(url),
    method: init && init.method,
    headers: init && init.headers,
    hasBody: !!(init && init.body),
  };
  return okResponse();
};

const ENV = { UPSTREAM: 'https://1.2.3.4:8443/', HOST: 'fake.example.com', DEBUG: '1' };

function ctx(url, opts = {}) {
  const { env = {}, method = 'GET', body = null, headers = {}, clientIp = '203.0.113.7' } = opts;
  const h = new Headers(headers);
  const req = new Request(url, {
    method,
    headers: h,
    body: (method === 'GET' || method === 'HEAD') ? undefined : body,
  });
  return { request: req, env, clientIp, params: {} };
}

function wsCtx() {
  return ctx('https://relay.example.com/api/session', {
    env: ENV,
    headers: { Upgrade: 'websocket', 'Sec-WebSocket-Protocol': 'xhttp' },
  });
}

function fakeSocket(bucket, key, listeners) {
  return {
    accepted: false,
    accept() { this.accepted = true; },
    send(d) { bucket.push(d); },
    close() { bucket.push('<<close>>'); },
    addEventListener(t, fn) { listeners[key][t] = fn; },
  };
}

function definePair(clientSocket, serverSocket) {
  Object.defineProperty(globalThis, 'WebSocketPair', {
    value: function () { return { 0: clientSocket, 1: serverSocket }; },
    configurable: true,
    writable: true,
  });
}

/** 模拟 workerd 风格的 Response：接受 101 且保留 webSocket 字段 */
function withWorkersLikeResponse(fn) {
  const RealResponse = globalThis.Response;
  function WorkersLikeResponse(body, init) {
    if (init && init.status === 101) {
      return { status: 101, webSocket: init.webSocket, headers: new Headers() };
    }
    const opts = init ? { status: init.status, headers: init.headers } : undefined;
    return new RealResponse((init && init.status === 101) ? null : body, opts);
  }
  globalThis.Response = WorkersLikeResponse;
  return (async () => {
    try {
      return await fn();
    } finally {
      globalThis.Response = RealResponse;
    }
  })();
}

// 1) 默认（STRIP_PREFIX 缺省 = 剥离 /api），查询串保留，头过滤正确
{
  captured = null;
  const res = await handler(ctx('https://relay.example.com/api/session?x_padding=abc', { env: ENV, method: 'POST', body: 'payload' }));
  check('1 路径剥离 + 查询串保留', captured.url === 'https://1.2.3.4:8443/session?x_padding=abc', captured.url);
  check('1b 请求方法透传', captured.method === 'POST', captured.method);
  check('1c POST body 已转发', captured.hasBody === true);
  check('1d Host 覆盖为伪装域名', captured.headers.get('host') === 'fake.example.com', captured.headers.get('host'));
  check('1e 逐跳头 transfer-encoding 被剔除', captured.headers.get('transfer-encoding') === null);
  check('1f 客户端 IP 注入 x-forwarded-for', captured.headers.get('x-forwarded-for') === '203.0.113.7', captured.headers.get('x-forwarded-for'));
  const text = await res.text();
  check('1g 响应体流式回传', text === 'hello-from-origin', text);
  check('1h 响应逐跳头被剔除', res.headers.get('transfer-encoding') === null);
  check('1i 响应强制 no-store', /no-store/.test(res.headers.get('cache-control') || ''), res.headers.get('cache-control'));
  check('1j DEBUG 诊断头存在', res.headers.get('x-debug-status') === '200', res.headers.get('x-debug-status'));
  check('1k 上游业务头保留', res.headers.get('x-origin') === 'xray', res.headers.get('x-origin'));
  check('1l content-type 保留 SSE', /text\/event-stream/.test(res.headers.get('content-type') || ''), res.headers.get('content-type'));
}

// 2) STRIP_PREFIX=0 时保留完整路径
{
  captured = null;
  await handler(ctx('https://relay.example.com/api/session', { env: Object.assign({}, ENV, { STRIP_PREFIX: '0' }) }));
  check('2 STRIP_PREFIX=0 保留 /api 前缀', captured.url === 'https://1.2.3.4:8443/api/session', captured.url);
}

// 3) 根路径 /api 归一到 /
{
  captured = null;
  await handler(ctx('https://relay.example.com/api', { env: ENV }));
  check('3 /api 归一到 /', captured.url === 'https://1.2.3.4:8443/', captured.url);
}

// 4) 多级子路径
{
  captured = null;
  await handler(ctx('https://relay.example.com/api/a/b/c', { env: ENV }));
  check('4 多级子路径正确拼接', captured.url === 'https://1.2.3.4:8443/a/b/c', captured.url);
}

// 5) 未配置 UPSTREAM 时给明确提示
{
  const res = await handler(ctx('https://relay.example.com/api/session', { env: {} }));
  const body = await res.text();
  check('5 缺 UPSTREAM 返回 500 与提示', res.status === 500 && /UPSTREAM/.test(body), res.status);
}

// 6) Node 风格运行时环境变量回退到 process.env
{
  captured = null;
  process.env.UPSTREAM = 'https://5.6.7.8:8443';
  process.env.STRIP_PREFIX = '0';
  await handler(ctx('https://relay.example.com/api/x', { env: {} }));
  check('6 process.env 回退可用', captured.url === 'https://5.6.7.8:8443/api/x', captured.url);
  delete process.env.UPSTREAM;
  delete process.env.STRIP_PREFIX;
}

// 7) 回源失败时返回 502 而不是抛异常
{
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('dns lookup failed (IPv6 unsupported)'); };
  const res = await handler(ctx('https://relay.example.com/api/session', { env: ENV }));
  const body = await res.text();
  check('7 回源异常 -> 502 且带原因', res.status === 502 && /dns lookup failed/.test(body), res.status);
  globalThis.fetch = realFetch;
}

// 8) 逐跳头过滤大小写不敏感 + 自定义头保留
{
  captured = null;
  await handler(ctx('https://relay.example.com/api/x', {
    env: ENV,
    headers: { 'X-Custom': 'keep-me', Connection: 'keep-alive', 'ACCEPT-ENCODING': 'gzip' },
  }));
  check('8a 自定义头保留', captured.headers.get('x-custom') === 'keep-me');
  check('8b Connection 被剔除', captured.headers.get('connection') === null);
  check('8c Accept-Encoding 被剔除', captured.headers.get('accept-encoding') === null);
}

// ---- 云函数版（cloud-functions）----
const cloudHandler = (await import('../edgeone-xray-relay/cloud-functions/api/[[default]].js')).default;
const WS_PATH = 'wss://1.2.3.4:8443/session';

// 9) 云函数版同样能完成路径改写与回源
{
  captured = null;
  const res = await cloudHandler(ctx('https://relay.example.com/api/session?x_padding=1', { env: ENV, method: 'POST', body: 'payload' }));
  check('9a 云函数版路径改写正确', captured.url === 'https://1.2.3.4:8443/session?x_padding=1', captured.url);
  check('9b 云函数版响应回传', (await res.text()) === 'hello-from-origin');
}

// 10) 回源连不上时返回 502 并带原因
{
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('upstream unreachable'); };
  const res = await cloudHandler(wsCtx());
  const body = await res.text();
  check('10 回源失败 -> 502 带原因', res.status === 502 && /upstream unreachable/.test(body), res.status + ' ' + body.slice(0, 60));
  globalThis.fetch = realFetch;
}

// 11) Node 运行时（有 process.versions.node）：识别为不支持 Workers 风格，直接返回 handler 形态
{
  const listeners = { server: {}, remote: {} };
  const remote = fakeSocket([], 'remote', listeners);
  const server = fakeSocket([], 'server', listeners);
  definePair(fakeSocket([], 'client', listeners), server);

  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    captured = { url: String(url), method: init.method, headers: init.headers };
    return { status: 101, webSocket: remote };
  };

  const out = await cloudHandler(wsCtx());
  check('11a 上游 URL 转成 wss 且保留路径', captured.url === WS_PATH, captured.url);
  check('11b 向上游透传 Upgrade 头', String(captured.headers.get('upgrade')).toLowerCase() === 'websocket', captured.headers.get('upgrade'));
  check('11c 子协议透传上游', captured.headers.get('sec-websocket-protocol') === 'xhttp', captured.headers.get('sec-websocket-protocol'));
  const keys = out && out.websocket ? Object.keys(out.websocket).sort().join(',') : String(out);
  check('11d Node 下走 handler 形态且回调齐全', keys === 'onclose,onerror,onmessage,onopen', keys);

  globalThis.fetch = realFetch;
  delete globalThis.WebSocketPair;
}

// 12) handler 形态端到端：客户端消息转发到上游，上游消息回传，任一侧关闭同步对侧
{
  const sentToRemote = [];
  const sentToClient = [];
  const listeners = { server: {}, remote: {} };
  const remote = fakeSocket(sentToRemote, 'remote', listeners);
  const server = fakeSocket(sentToClient, 'server', listeners);
  definePair(fakeSocket(sentToClient, 'client', listeners), server);

  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    captured = { url: String(url), method: init.method, headers: init.headers };
    return { status: 101, webSocket: remote };
  };

  let out;
  try {
    out = await cloudHandler(wsCtx());
  } finally {
    globalThis.fetch = realFetch;
  }

  check('12a 上游连接使用 wss 且带上 Upgrade', captured.url === WS_PATH && String(captured.headers.get('upgrade')).toLowerCase() === 'websocket', captured.url);
  const cb = out && out.websocket ? out.websocket : {};
  check('12b handler 回调齐全', ['onopen', 'onmessage', 'onclose', 'onerror'].every((k) => typeof cb[k] === 'function'), Object.keys(cb).join(','));

  const clientWs = fakeSocket(sentToClient, 'client', listeners);
  cb.onopen(clientWs);
  check('12c onopen 后上游监听已注册', typeof listeners.remote.message === 'function' && typeof listeners.remote.close === 'function');
  cb.onmessage(clientWs, 'from-client');
  check('12d 客户端消息转发到上游', sentToRemote.indexOf('from-client') >= 0, JSON.stringify(sentToRemote));
  if (listeners.remote.message) listeners.remote.message({ data: 'from-xray' });
  check('12e 上游消息转发回客户端', sentToClient.indexOf('from-xray') >= 0, JSON.stringify(sentToClient));
  cb.onclose(clientWs, 1000, 'bye');
  check('12f 客户端关闭会关闭上游', sentToRemote.indexOf('<<close>>') >= 0, JSON.stringify(sentToRemote));

  delete globalThis.WebSocketPair;
}

// 13) 运行时构造 101 失败（Node 原生行为）：必须回退到 handler 形态，不能把 200 当成功
{
  const listeners = { server: {}, remote: {} };
  const remote = fakeSocket([], 'remote', listeners);
  const server = fakeSocket([], 'server', listeners);
  definePair(fakeSocket([], 'client', listeners), server);

  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ status: 101, webSocket: remote });
  const versions = globalThis.process.versions;
  const savedNode = versions.node;
  delete versions.node; // 伪装成非 Node 运行时，让代码先走 Workers 风格尝试

  let out;
  try {
    out = await cloudHandler(wsCtx());
  } finally {
    versions.node = savedNode;
    globalThis.fetch = realFetch;
  }

  const keys = out && out.websocket ? Object.keys(out.websocket).sort().join(',') : String(out);
  check('13 Response 拒绝 101 时回退到 handler 形态', keys === 'onclose,onerror,onmessage,onopen', keys);

  delete globalThis.WebSocketPair;
}

// 14) /__health 自检端点：不访问后端即返回运行状态（用于判断函数是否真的被执行）
{
  const realFetch = globalThis.fetch;
  let fetched = false;
  globalThis.fetch = async () => { fetched = true; return okResponse(); };
  const res = await handler(ctx('https://relay.example.com/__health', { env: ENV }));
  const body = await res.json();
  check('14a health 返回 200 且不走后端', res.status === 200 && fetched === false, res.status + ' fetched=' + fetched);
  check('14b health 带 x-relay 标识', res.headers.get('x-relay') === 'edgeone-xray-relay', res.headers.get('x-relay'));
  check('14c health 报告 upstream 与 host', /156\.248|1\.2\.3\.4/.test(String(body.upstream)) && body.host === 'fake.example.com', JSON.stringify({ u: body.upstream, h: body.host }));
  check('14d health 报告 stripPrefix 状态', body.stripPrefix === true, String(body.stripPrefix));
  globalThis.fetch = realFetch;
}

// 15) 平台已剥掉 /api 时（函数内直接看到 /session）也要能正确转发
{
  captured = null;
  await handler(ctx('https://relay.example.com/session?x_padding=9', { env: ENV, method: 'POST', body: 'p' }));
  check('15 无 /api 前缀时路径保持原样', captured.url === 'https://1.2.3.4:8443/session?x_padding=9', captured.url);
}
const failed = results.filter((r) => !r.pass);
for (const r of results) console.log((r.pass ? 'PASS' : 'FAIL') + '  ' + r.name + (r.pass ? '' : '  <-- ' + r.extra));
console.log('\n总计 ' + results.length + ' 项，失败 ' + failed.length + ' 项');
process.exit(failed.length ? 1 : 0);
