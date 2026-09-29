# EdgeOne Pages → 自建 Xray(XHTTP) 中转

用 EdgeOne Makers（Pages）的边缘函数做中转入口，把请求转发到你自己的服务器，再由服务器上的
nginx 交给 Xray 的 XHTTP 入站。**已在真实环境端到端验证可用**（含 5MB 连续下载与真实网页访问）。

```
Xray 客户端 ──TLS(H1.1)──► edgeone-1py.edgeone.dev   (EdgeOne 边缘函数, /api/*)
                              │  https + Host 重写
                              ▼
                        服务器 156.248.10.150:443     (nginx, TLS 终止)
                              │  http (仅本机)
                              ▼
                       127.0.0.1:58353                (Xray vless+xhttp, path=/session)
```

---

## 一、实测结论（按重要性排序）

| # | 结论 | 说明 |
|---|---|---|
| 1 | **客户端必须强制 HTTP/1.1** | 在 `tlsSettings` 里加 `"alpn": ["http/1.1"]`。用 H2 时 EdgeOne 边缘会在握手后立刻 `broken pipe` 掐断（约 20ms），请求根本进不了函数，日志表现为 `failed to send upload ... broken pipe` |
| 2 | **服务端 path 是前缀匹配** | XHTTP 客户端实际请求的是 `/api/session/<uuid>/<seq>`，所以服务端 `path` 与其对应的 nginx location 都按**前缀**处理（`location /session`，不要用 `location = /session`） |
| 3 | **平台不剥 `/api` 前缀** | 函数内看到的就是 `/api/session/...`，剥离由中转代码完成（`STRIP_PREFIX`，默认 1） |
| 4 | **不要在 `edge-functions/` 根级放 `[[default]].js`** | 与 `edge-functions/api/[[default]].js` 同时存在时，`/api/*` 直接返回空 body 的 404，函数不执行（已实测复现） |
| 5 | `/api/*` 路由不匹配 `/api/`（纯目录） | 访问 `/api/` 命中平台 404 页；`/api/xxx` 才进函数 |
| 6 | 不支持回源 IPv6 | `UPSTREAM` 必须是 IPv4 或 A 记录域名 |
| 7 | Edge 函数请求 body ≤ 1 MB | 建议客户端 `scMaxEachPostBytes` 设为 `500000` 留出余量 |
| 8 | push 后需手动 New Deployment | 控制台 Build & Deploy → New Deployment |
| 9 | WebSocket 只在 Node 云函数可用 | 想用 `stream-up` 需切换成 `cloud-functions/` 版；`packet-up` 用 edge 版即可 |

实测性能（客户端在服务器本机，经 EdgeOne 回连自身）：5MB 连续下载 3 次均 200，**2.0–4.0 MB/s**；
`google/generate_204` 204、0.31s。

## 二、仓库文件

```
├── static/index.html                       # 首页占位（输出目录 static）
├── edge-functions/api/[[default]].js       # Edge 函数 → /api/*   ← packet-up 用这个
├── cloud-functions/api/[[default]].js      # Node 云函数 → /api/* ← 需要 WebSocket 时改用它
├── edgeone.json                            # 云函数最长 120s；/api/* 禁缓存
└── package.json                            # ESM 标记
```

两个版本都映射 `/api/*`，同时存在时 edge 版生效。

## 三、EdgeOne 侧配置

- 框架预设 **Other**、构建命令留空、根目录 `./`、**输出目录 `static`**
- 环境变量：

| 变量 | 示例 | 说明 |
|---|---|---|
| `UPSTREAM` | `https://156.248.10.150:443` | 回源地址（IPv4 / A 记录域名） |
| `HOST` | `999020.xyz` | 回源时写回的 Host 头，用于命中 nginx 的 server 块 |
| `STRIP_PREFIX` | `1`（默认） | 1 = 剥掉 `/api`；0 = 保留 |
| `AUTH_TOKEN` | 可选 | 会附加 `x-relay-token` 头 |
| `DEBUG` | 可选 `1` | 响应附带 `x-debug-*` |

## 四、服务器侧配置（nginx + Xray）

Xray 新增一个**仅本机可达**的入站（不动原有入站）：

```json
{
  "tag": "in-xhttp-relay",
  "listen": "127.0.0.1",
  "port": 58353,
  "protocol": "vless",
  "settings": { "clients": [ { "id": "<你的UUID>" } ], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": { "host": "", "path": "/session", "mode": "auto" }
  }
}
```

nginx 在**每个对外 server 块**里加（前缀匹配，勿用 `=`）：

```nginx
location /session {
    proxy_pass http://127.0.0.1:58353;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;   # 需要配合 map，见下
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    tcp_nodelay on;
}
```

`Connection` 用 map 决定（普通请求保持 keep-alive，升级请求才发 upgrade），放在 http 上下文：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}
```

## 五、客户端配置（可直接用）

```json
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "edgeone-1py.edgeone.dev",
          "port": 443,
          "users": [{ "id": "<你的UUID>", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": { "serverName": "edgeone-1py.edgeone.dev", "alpn": ["http/1.1"] },
        "xhttpSettings": {
          "host": "edgeone-1py.edgeone.dev",
          "path": "/api/session",
          "mode": "packet-up",
          "scMaxEachPostBytes": 500000
        }
      }
    }
  ]
}
```

- `alpn: ["http/1.1"]` 是**必需项**，否则连不上。
- `path` 固定 `/api/session`（要改就改客户端 + nginx location + xray 的 `path` 三处保持一致，且去掉 `/api`）。
- 想用 `stream-up`（WebSocket）：两端 mode 改 `stream-up`，中转换成 `cloud-functions/` 版；云函数有 120 秒上限，需能自动重连。

## 六、自检与排障

```bash
curl https://edgeone-1py.edgeone.dev/api/__health          # 函数是否在跑、环境变量对不对
curl "https://edgeone-1py.edgeone.dev/api/__health?check=1" # 顺带真实探测回源连通性
```

| 现象 | 判断 |
|---|---|
| `hasUpstream:true` + `upstreamCheck.ok:true` | 中转与回源正常，问题在客户端/Xray 配置 |
| 404 空 body + `Server: edgeone makers`（无 `x-relay` 头） | 函数没执行 → 检查是否有多余的根级 catch-all 文件 |
| 502 JSON | 回源失败，看 `error`（地址/端口/证书/IPv6） |
| 客户端日志 `broken pipe` / `http2: force closed` | 没加 `alpn: ["http/1.1"]` |
| 客户端日志 404 | 服务端 `path` 与 nginx location 不匹配（注意前缀匹配规则） |

服务器侧核对：

```bash
grep session /var/log/nginx/access.log | tail        # 看 EdgeOne 边缘 IP 是否在打 /session 并 200
journalctl -u xray -n 30 --no-pager                  # xray 侧日志
```

## 七、本地测试

```bash
node tests/relay.test.mjs      # 40 项行为检查，无外部依赖
```
