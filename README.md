# EdgeOne Pages → Xray(XHTTP) 反代中转

把 EdgeOne 的边缘函数/云函数当"中转站"，把 https 请求转发到你自己 Xray 后端的反向代理。
适配 **XHTTP** 传输；对 HTTPUpgrade 的握手请求也能转发，但边缘平台的升级支持有限，见下文"已知限制"。

## 一、目录结构与选哪个版本

```
edgeone-xray-relay/
├── static/index.html                     # 首页占位（必须存在，否则 Pages 没东西可发布）
├── edge-functions/api/[[default]].js     # ① Edge 函数版：匹配 /api/*  → 推荐先用这个（packet-up）
├── cloud-functions/api/[[default]].js    # ② Node 云函数版：匹配 /api/* → 需要 WS 上行(stream-up)时用
└── edgeone.json                          # 云函数最长 120s；/api/* 禁缓存
```

**两个版本的函数路径都映射到 `/api/*`，不要同时启用**，否则路由冲突。先用 ① 跑通，再按需换 ②。

## 二、部署步骤（网页控制台，全程不用装东西）

1. **Fork/新建仓库**：把这个项目推到你自己的 GitHub 仓库（公开私有都行）。
   - 只部署 ①（Edge 函数）：删掉 `cloud-functions/` 目录再推。
   - 只部署 ②（Node 云函数）：删掉 `edge-functions/` 目录，并在仓库根目录加 `package.json`：
     ```json
     { "name": "eo-xray-relay", "type": "module", "private": true }
     ```
     （Node 云函数要构建依赖，根目录必须有 `package.json`；`"type": "module"` 保证 `export default` 语法生效）
2. **进控制台**：腾讯云 EdgeOne 控制台 → 站点服务 → **Pages**（新版叫 Makers）→ **新建项目**。
3. **部署方式**：选「**关联 Git 仓库部署**」，授权后选中刚才的仓库。
4. **构建配置**（关键，照抄）：
   - 框架预设：**其他**
   - 构建命令：**留空**
   - 根目录：`./`
   - **输出目录：`static`**
   - Node 版本：默认即可
5. **环境变量**（同一页面的"环境变量"区域，或部署后在 项目设置 → 环境变量 里补）：

   | 变量 | 必填 | 值示例 | 说明 |
   |---|---|---|---|
   | `UPSTREAM` | ✅ | `https://1.2.3.4:8443` | 你的 Xray 后端。**必须是 IPv4 或 A 记录域名**，Pages 不支持访问 IPv6 |
   | `HOST` | ✅ | `my.domain.com` | 转发时写回给后端的 Host 头，填你伪装用的域名 |
   | `STRIP_PREFIX` | ⬜ | `1` | 默认 1：客户端 `/api/session` → 后端 `/session`。填 `0` 则后端也看到 `/api/session` |
   | `AUTH_TOKEN` | ⬜ | 随机串 | 设了就会带 `x-relay-token` 头，后端可校验，防止中转被陌生人白嫖 |
   | `DEBUG` | ⬜ | `1` | 响应附带 `x-debug-upstream` 等诊断头 |

6. **保存并部署**，等 1 分钟左右拿到 `https://xxx.edgeonepage.com` 域名。
7. **连通性自测**（先把后端 Xray 起好）：

   ```
   curl -v https://xxx.edgeonepage.com/api/health
   ```

   预期：返回 404（后端没有 `/health` 路由，但说明**请求已穿过中转到底后端**）；用 `DEBUG=1` 时看 `x-debug-status` 头即可确认。
   若返回 `UPSTREAM 未配置` 或 502 JSON → 环境变量/后端地址有问题。

## 三、Xray 配置

### 方案 A（推荐）：`mode: packet-up` + Edge 函数版

只用普通 POST/GET，不依赖 WebSocket，最稳。

**客户端（outbounds）**
```json
{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "xxx.edgeonepage.com",
      "port": 443,
      "users": [{ "id": "你的UUID", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": { "serverName": "xxx.edgeonepage.com" },
    "xhttpSettings": {
      "host": "xxx.edgeonepage.com",
      "path": "/api/session",
      "mode": "packet-up"
    }
  }
}
```

**服务端（inbounds）** —— 注意 `path` 要和上面的**去掉前缀后再对得上**：
客户端访问 `/api/session`，中转按 `STRIP_PREFIX=1` 转发成 `/session`，所以服务端写 `/session`。
（若你把 `STRIP_PREFIX=0`，服务端就写 `/api/session`。）

```json
{
  "tag": "in-xhttp",
  "listen": "0.0.0.0",
  "port": 8443,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "你的UUID" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [{
        "certificateFile": "/path/fullchain.pem",
        "keyFile": "/path/privkey.pem"
      }]
    },
    "xhttpSettings": { "host": "my.domain.com", "path": "/session", "mode": "packet-up" }
  }
}
```

> 路径、mode 两端必须一致；`host` 是伪装域名（和 `HOST` 环境变量对齐最省事）。
> 单次上传 body 别超过 1 MB（Edge 函数上限），必要时调整客户端 `scMaxEachPostBytes`（如 `500000`）。

### 方案 B：`mode: stream-up` + Node 云函数版

需要真正的 WebSocket 双向隧道。用 `cloud-functions/api/[[default]].js`：它用平台支持的 handler 形态
（`{ websocket: { onopen, onmessage, onclose, onerror } }`）接住客户端 WS，再用带 `Upgrade: websocket` 的
`fetch` 连上游 Xray。云函数是 Node 运行时，原生 `Response` 不允许 101，所以代码里做了运行期探测：
若当前运行时其实是 Workers 风格（`WebSocketPair` + `Response(101,{webSocket})` 可用），会自动切换过去。

- 客户端 `xhttpSettings`：`mode: "stream-up"`，其余同上。
- 服务端 `xhttpSettings`：`mode: "stream-up"`。
- 用 `curl` 或浏览器测不通没关系，这条链路只能由 Xray 客户端验证。

### 方案 C：HTTPUpgrade

`network: "httpupgrade"`，`httpupgradeSettings.path: "/api/session"`，服务端同样配 `httpupgrade`。
握手就是一个 `Upgrade: websocket` 的 HTTP GET，走方案 B 的同一段代码即可（同一个函数同时覆盖 XHTTP 与 HTTPUpgrade）。但**EdgeOne 是否允许在函数里回源 101 升级、以及 120 秒上限如何处理长连接，官方没有明确承诺**，需要你自己实测。

## 四、已知限制（务必先读）

1. **不支持 IPv6 回源**，`UPSTREAM` 只能填 IPv4 / A 记录域名。
2. **WebSocket 只在 Node 云函数里支持**，Edge 函数不支持 → `stream-up`/`stream-one` 必须用方案 B（云函数）。
3. **云函数 wall clock 上限 120 秒**，长连接会被平台掐断；Xray 客户端要能自动重连。这是平台行为，代码绕不过去。
4. **Edge 函数请求 body 上限 1 MB**（云函数 6 MB），大上传会失败。
5. **不支持 CONNECT 隧道**，做不了通用 TCP 透明代理，只能承载 HTTP 层协议。
6. **回源 Upgrade 直通未经验证**：代码用 `fetch(..., { Upgrade: 'websocket' })` 取上游 socket，这是 Workers 系的通用写法；
   若你的项目运行时不允许，函数会返回 502 并写明原因（"上游未返回可用的 WebSocket"），此时请用方案 A 的 packet-up 模式。
7. 子协议（`Sec-WebSocket-Protocol`）能否被平台原样回显同样未验证，`stream-up` 若连不上，优先怀疑这里。
8. 静态资源路由优先级高于函数：别在 `static/` 里放 `/api/...` 同名文件。
9. 官方配额页明确会「监控滥用行为」。自用/小范围没问题，**别做成公开的万能代理站**，否则可能被限速或封站点。

## 五、排障清单

| 现象 | 排查方向 |
|---|---|
| 502 JSON，`error` 里有 fetch 失败信息 | 后端地址/端口不通；用了 IPv6；后端 TLS 证书链不完整 |
| 返回 `UPSTREAM 未配置` | 环境变量名写错，或没重新部署 |
| 客户端握手成功但一直没流量 | 服务端 `path`/`mode` 与客户端不一致；`HOST` 头被后端分流规则拒绝 |
| 用一会儿就断 | 命中 120 秒云函数上限或平台空闲超时 → 调小客户端心跳间隔，让它自动重连 |
| `stream-up` 完全连不上，返回 502 | 看响应正文：`上游未返回可用的 WebSocket` = 运行时不支持回源 Upgrade 直通；`回源 WebSocket 连接失败` = 上游地址/端口/证书问题。都不行就换方案 A |
| 需要确认运行时形态 | 走 WS 时若返回 `{ websocket: {...} }` 形态说明走的是官方 handler 分支；若返回 101 响应说明走的是 Workers 分支 |

## 六、本地验证

仓库附带的 `tests/relay.test.mjs` 用模拟运行时覆盖了两版函数的关键行为（路径改写、逐跳头过滤、
流式回传、环境变量回退、WS handler 双向转发、101 回退等 35 项）：

```
node tests/relay.test.mjs
```

不需要装任何依赖，Node 20+ 直接跑。
