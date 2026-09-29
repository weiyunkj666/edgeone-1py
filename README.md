# EdgeOne Pages → Xray (XHTTP) 反代中转

用 EdgeOne Makers（Pages）的边缘函数做中转，把 `https://你的域名/api/*` 的请求转发到你自己的 Xray 后端。
已在真实环境验证：函数执行、TLS 回源、响应回传全部正常。

---

## 一、实测结论（重要，别踩这几个坑）

| 事实 | 说明 |
|---|---|
| **平台不会剥掉 `/api` 前缀** | 函数内看到的是 `/api/session`，由本代码自行剥离（`STRIP_PREFIX`，默认 1） |
| **不要在 `edge-functions/` 根级放 `[[default]].js`** | 它和 `edge-functions/api/[[default]].js` 同时存在时，`/api/*` 会直接返回**空 body 的 404**，函数根本不执行（已实测复现，删掉根级文件即恢复） |
| **`/api/*` 路由对 `/api/`（只有目录）不生效** | 访问 `/api/` 会命中平台 404 页；`/api/xxx` 才进函数 |
| **不支持回源 IPv6** | `UPSTREAM` 必须是 IPv4 或 A 记录域名 |
| **Edge 函数请求 body ≤ 1 MB**（云函数 6 MB） | XHTTP 单次上传要小于该值 |
| **WebSocket 只在 Node 云函数可用** | `stream-up` 用 `cloud-functions/` 版；`packet-up` 用 edge 版即可 |
| 每次 push 后**需要手动点 New Deployment** | 控制台 Build & Deploy → New Deployment，否则线上不会更新 |

## 二、文件结构

```
edgeone-1py/
├── static/index.html                       # 首页占位（必须有输出目录，这里输出 static）
├── edge-functions/api/[[default]].js       # Edge 函数：映射 /api/*  ← packet-up 用这个
├── cloud-functions/api/[[default]].js      # Node 云函数：映射 /api/*  ← 需要 WS 时改用它
├── edgeone.json                            # 云函数最长 120s；/api/* 禁缓存
└── package.json                            # ESM 标记（云函数构建需要）
```

> 两个版本都映射 `/api/*`，**同时存在时 edge 版生效**；要切换成云函数版，把 `edge-functions/` 删掉再部署。

## 三、构建与部署配置（控制台）

- 框架预设：**Other**
- 构建命令：**留空**
- 根目录：`./`
- **输出目录：`static`**

环境变量：

| 变量 | 示例 | 说明 |
|---|---|---|
| `UPSTREAM` | `https://156.248.10.150:443` | 你的 Xray 后端，IPv4 或 A 记录域名 |
| `HOST` | `999020.xyz` | 转发时写回给后端的 Host 头（Xray 分流/伪装校验） |
| `STRIP_PREFIX` | `1`（默认） | 1 = 剥掉 `/api`；0 = 保留完整路径 |
| `AUTH_TOKEN` | 随机串 | 可选，转发时附加 `x-relay-token` 头，防白嫖 |
| `DEBUG` | `1` | 可选，响应附带 `x-debug-upstream` / `x-debug-status` |

## 四、自检端点（排障第一步）

```bash
# 1) 确认函数在跑、环境变量读到了
curl https://edgeone-1py.edgeone.dev/api/__health

# 2) 顺便真实探测后端连通性（GET 后端根路径，只报告状态码/耗时）
curl "https://edgeone-1py.edgeone.dev/api/__health?check=1"
```

返回示例：

```json
{
  "ok": true,
  "relay": "edgeone-xray-relay/edge",
  "hasUpstream": true,
  "upstream": "https://156.248.10.150:443",
  "host": "999020.xyz",
  "stripPrefix": true,
  "seenPath": "/api/__health",
  "forwardedPath": "/__health",
  "upstreamCheck": { "ok": true, "status": 400, "ms": 5 }
}
```

判断标准：
- `hasUpstream: true` 且 `upstreamCheck.ok: true` → 中转与回源都正常，剩下的问题在 Xray 服务端配置。
- 返回 404 空 body + `Server: edgeone makers` → 函数没被执行（检查是否有多余的根级 catch-all 文件）。
- 返回 502 JSON → 回源失败，看 `error` 字段（地址/端口/证书/IPv6）。

## 五、Xray 配置

### 客户端

```json
{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "edgeone-1py.edgeone.dev",
      "port": 443,
      "users": [{ "id": "你的UUID", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": { "serverName": "edgeone-1py.edgeone.dev" },
    "xhttpSettings": {
      "host": "edgeone-1py.edgeone.dev",
      "path": "/api/session",
      "mode": "packet-up"
    }
  }
}
```

### 服务端

因为 `STRIP_PREFIX=1`，中转会把 `/api/session` 转成 `/session`，所以服务端写 `/session`：

```json
{
  "tag": "in-xhttp",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": { "clients": [{ "id": "你的UUID" }], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [{
        "certificateFile": "/path/fullchain.pem",
        "keyFile": "/path/privkey.pem"
      }]
    },
    "xhttpSettings": { "host": "999020.xyz", "path": "/session", "mode": "packet-up" }
  }
}
```

- 两端 `mode` 必须一致；`path` 按上面规则对齐；`host` 建议与 `HOST` 环境变量一致。
- 想用 `stream-up`：两端都改成 `stream-up`，并把项目切换成 `cloud-functions/` 版（删掉 `edge-functions/`）。
  云函数有 120 秒 wall-clock 上限，长连接会被平台掐断，客户端需能自动重连。

## 六、本地测试

```bash
node tests/relay.test.mjs      # 40 项行为检查，无需装依赖
```

覆盖：路径剥离/保留、查询串保留、逐跳头过滤、POST body 与 SSE 流式回传、
`context.env` 与 `process.env` 回退、`/__health`、WS handler 双向转发、101 回退与运行期探测。
