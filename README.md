# PrivacyMail

一个用 Elixir/OTP 实现的企业邮箱隐私防护服务：识别邮件中的隐形追踪图片、Web Beacon 和带收件人标识的链接，并通过签名图片代理加载正常营销图片与通知图片。

设计目标：

- **不破坏邮件显示**：高置信追踪器替换为同尺寸透明像素；普通图片继续显示，只是 URL 被改写为企业代理。
- **不做投递时预拉取**：改写阶段绝不请求远端图片，避免“代理已拉取”本身成为打开信号；只有收件人客户端真正请求代理 URL 时才回源。
- **区分追踪图与正常图**：不使用“所有外链图片都拦截”的粗策略，而是综合尺寸、隐藏方式、URL/域名、收件人标识等信号评分。
- **高并发不击穿源站和本机**：Bandit/Plug 异步处理、Finch 连接池、ETS 缓存、Single-flight 合并同一 URL 的并发回源。
- **不泄露收件人环境**：回源不带 Cookie、Authorization、Referer 和收件人 UA，使用统一 UA；代理 IP 替代收件人 IP。
- **同时覆盖 HTML 与 plain-text**：HTML 改写图片/链接/CSS，纯文本邮件清洗或包装个性化 URL。
- **防止代理变成开放代理/SSRF 跳板**：URL 带 HMAC 能力令牌，回源前校验协议和 DNS/内网地址，限制重定向、大小和 Content-Type。

## 快速开始

```bash
mix deps.get
mix test
mix run --no-halt
# 默认监听 http://127.0.0.1:4000
```

生产环境必须设置稳定的 HMAC 密钥（多节点/重启后旧邮件中的代理链接仍可验证）：

```bash
export PRIVACY_MAIL_PROXY_SECRET="$(openssl rand -base64 48)"
export BIND_IP=0.0.0.0
export PORT=4000
MIX_ENV=prod mix run --no-halt
```

如果 Webmail 与 API 不同源，配置外部可访问的代理前缀：

```elixir
config :privacy_mail,
  proxy_base_url: "https://mail.example.com/privacy"
```

邮件改写后会生成：

```text
https://mail.example.com/privacy/proxy/image?token=v1.img....
https://mail.example.com/privacy/redirect?token=v1.go....
```

## Elixir API

```elixir
html = """
<img src="https://tracker.example/open.gif?recipient_id=u_123"
     width="1" height="1" style="display:none">

<a href="https://app.example/verify?email=ceo@example.com&token=...">
  验证邮箱
</a>

<img src="https://cdn.shop.example/banner.jpg" width="600" height="200">
"""

{:ok, safe_html, report} =
  PrivacyMail.privatize(html,
    proxy_base_url: "https://mail.example.com/privacy",
    block_threshold: 6
  )

report.counts
# %{
#   images: 2,
#   trackers_blocked: 1,
#   images_proxied: 1,
#   personalized_links: 1,
#   ...
# }
```

只扫描、不改写：

```elixir
report = PrivacyMail.analyze(html)
report.trackers
report.personalized_links
report.findings
```

纯文本邮件：

```elixir
{:ok, safe_text, report} =
  PrivacyMail.privatize_text(
    "Verify: https://app.example/?email=ceo@example.com&token=...",
    proxy_base_url: "https://mail.example.com/privacy"
  )
```

## HTTP API

### `POST /api/analyze`

```bash
curl -sS http://127.0.0.1:4000/api/analyze \
  -H 'content-type: application/json' \
  -d '{"html":"<img src=\"https://t.example/pixel.gif\" width=\"1\" height=\"1\">"}'
```

### `POST /api/privatize`

```bash
curl -sS http://127.0.0.1:4000/api/privatize \
  -H 'content-type: application/json' \
  -d '{"html":"<img src=\"https://cdn.example/a.jpg\" width=\"400\">"}'
```

支持参数：

- `base_url`：邮件中相对 URL 的基础地址。
- `proxy_images`：是否代理普通外链图片，默认 `true`。
- `strip_tracking_params`：是否移除 `utm_*`、`mc_eid`、`fbclid` 等参数。
- `block_threshold`：追踪图片拦截分数。
- `rewrite_links`：`sanitize`（默认）、`redirect_all`、`off`。

### `GET /proxy/image?token=...`

验证 HMAC 令牌后：

1. 规范化 URL 并移除已知追踪参数；
2. 查询 ETS 缓存；
3. 未命中时通过 Single-flight 合并同一 URL 的并发请求；
4. 使用 Finch 连接池回源；
5. 校验图片 MIME/魔数和最大体积；
6. 写入短 TTL 缓存并返回安全响应头。

上游失败时返回透明 GIF，避免邮件布局出现裂图；响应头 `x-pm-proxy-error` 提供错误原因。

### `GET /redirect?token=...`

个人标识链接不直接在邮件中暴露为外部地址，而是跳转到签名跳转网关。网关再次移除已知追踪参数，并发送 `Referrer-Policy: no-referrer`。

> 注意：如果目标 URL 本身的路径或必需参数中包含一次性登录令牌，点击后对方仍会知道“有人主动点击了该链接”。这是用户主动行为，不再是打开邮件即触发的被动回传；网关隐藏了来源页、浏览器 Referer 和企业邮箱环境。

## 识别模型

每个图片/链接都会得到可解释的信号和分数，而不是单一黑名单。

### 强追踪信号

- 已知 ESP/分析/广告追踪域名或 `/track`、`/open`、`/pixel`、`/beacon`、`/collect` 端点；
- `width/height <= 2`、零尺寸、`display:none`、`visibility:hidden`、`opacity:0`；
- 移出视口、`clip` 隐藏；
- `pixel.gif`、`blank.gif`、`spacer.gif` 等常见 Beacon 文件名；
- URL 中包含邮箱、收件人 ID、订阅者 hash、长 UUID/Hex/Base64 路径或查询令牌；
- `mc_eid`、`ml_subscriber_hash`、`gclid`、`fbclid`、`utm_*` 等参数。

达到 `block_threshold`（默认 6）后，图片不会被代理或回源，而是替换为透明 Data URI，同时保留 `width`/`height`，所以版式不塌。

### 正常营销/通知图片

普通 CDN、明确宽高、有意义 `alt`、`/images/`、`/assets/` 路径会得到负向信号。即使 URL 带 `utm_*`，通常也只是：

- 移除已知追踪参数；
- 签名后改写为代理 URL；
- 添加 `loading="lazy"`、`decoding="async"`；
- 保留原图尺寸、alt 和邮件排版。

### 链接策略

- 已知广告/邮件活动参数：直接清洗；
- 含邮箱/收件人标识或追踪跳转：包装到 `/redirect`；
- 短链：评分并可走跳转网关，避免邮件中直接暴露企业 Referer；
- `mailto:`、`cid:`、`data:` 和页内锚点保持不变。

## 为什么不会在投递时误发“打开信号”

`PrivacyMail.Email.privatize/2` 是纯 HTML 处理流程，不调用 `PrivacyMail.Proxy.Loader` 或 Fetcher。它只生成签名代理 URL。

因此：

- 邮件系统在收信、杀毒、归档或投递阶段改写 HTML，不会预拉图片；
- 只有真人打开邮件且邮件客户端请求 `<img src="/proxy/image?...">` 时才可能回源；
- 高置信 Beacon 连这个请求都不会到达代理业务逻辑，因为 src 已变成本地 Data URI。

## 并发与扩展性

单节点热路径：

```text
收件人请求 ── Bandit 进程 ── ETS 缓存读（无 GenServer 阻塞）
                    │ miss
                    └── SingleFlight key=canonical_url
                           └── 只有一个 Task 经 Finch 回源
                    ┌──── 其他相同 URL 请求等待同一结果
                    └── 写 ETS，后续请求无回源
```

已实现：

- ETS `read_concurrency`；
- 同一 canonical URL 的并发 miss 合并；
- 失败负缓存，防止故障源站被重试风暴打满；
- stale-while-revalidate，后台刷新不阻塞当前响应；
- Finch 连接池；
- 响应大小上限、超时和重定向上限。

多节点部署时：

- HMAC 密钥在所有节点共享；
- 可在前面加 CDN 或 Redis 缓存，缓存键使用规范化后的 URL；
- 代理服务本身无收件人 Session 依赖，可水平扩容；
- 对超大活动，CDN/ETS 命中后不会重复请求源站。

## 安全边界

已实现：

- HMAC-SHA256 能力令牌和常量时间比较；
- 仅允许 HTTP/HTTPS；
- 默认拒绝 loopback、RFC1918、链路本地、云元数据 `169.254.169.254`、IPv6 ULA/link-local；
- 重定向逐跳重新做 SSRF 校验；
- 不转发 Cookie/Authorization/Referer；
- 图片 Content-Type 白名单和魔数嗅探；
- `X-Content-Type-Options: nosniff`；
- SVG 响应使用严格 CSP sandbox；
- 默认移除 `<script>`、`<iframe>`、`<object>`、`<embed>` 和 `on*` 属性，降低 Webmail XSS 风险。

生产建议补充：

- 出站流量走固定 NAT/隔离代理，并在云安全组层面拒绝 RFC1918/元数据地址，缓解 DNS rebinding 的 TOCTOU 窗口；
- 配置域名允许策略或企业租户策略；
- 接入 `:telemetry`/Prometheus 监控缓存命中率、回源延迟、拦截分数分布；
- 对历史邮件使用服务端 opaque ID → URL 映射，可避免 HMAC Token 被解码，并支持密钥轮换。

## 测试

```bash
mix test
```

覆盖：

- 追踪像素/正常营销图/个人标识链接分类；
- HTML、srcset、内联 CSS、`<style>` 中 URL 改写；
- Data URI、`cid:`、`mailto:` 不误改；
- HMAC Token 篡改和用途隔离；
- SSRF 私网地址识别；
- 24 个并发相同 URL 请求只回源一次；
- 失败负缓存；
- Plug 代理、跳转和 JSON API。

## 主要模块

| 模块 | 职责 |
| --- | --- |
| `PrivacyMail.Email` | HTML 扫描、评分结果汇总和安全改写 |
| `PrivacyMail.PlainText` | 纯文本邮件链接识别、清洗和跳转包装 |
| `PrivacyMail.Tracking.Classifier` | 图片/链接信号评分与动作决策 |
| `PrivacyMail.Tracking.Rules` | 追踪域名、参数和路径词规则 |
| `PrivacyMail.HTMLSignals` | 尺寸、隐藏样式等渲染信号 |
| `PrivacyMail.WebURL` | URL 规范化、追踪参数清洗、个人标识识别 |
| `PrivacyMail.Proxy.Token` | HMAC 图片/跳转能力令牌 |
| `PrivacyMail.Proxy.SSRF` | DNS/IP 私网与元数据地址防护 |
| `PrivacyMail.Proxy.Cache` | ETS TTL 缓存 |
| `PrivacyMail.Proxy.SingleFlight` | 同 URL 并发回源合并 |
| `PrivacyMail.Proxy.Loader` | 缓存、stale 刷新和回源编排 |
| `PrivacyMail.Proxy.Fetcher` | Finch 流式限流下载和图片校验 |
| `PrivacyMailWeb.Router` | HTTP API、图片代理和跳转网关 |
