# OpenCodeV1-Termux

> **归档仓库**:本仓库是 OpenCode **V1** 的 Termux 适配,已冻结不再更新。
> V2 的适配在 [opencode-termux](https://github.com/xkxxs/opencode-termux) —— 官方把
> V2 的分发从 GitHub Releases 改成了 npm (`@opencode/cli-linux-arm64-musl`),
> 仓库也切过去了。还要用 V1 的话看这里。

在 Termux (Android ARM64) 上一键安装**官方** OpenCode CLI V1 (sst/opencode),纯脚本方案,不发布 npm 分发包。

> 官方 `opencode-linux-arm64-musl` 构建 + `patchelf` 改 interpreter/rpath,
> 运行库取自 Alpine Linux (ld-musl + libstdc++ + libgcc),经本地 DNS 转发器解析。

## 原理

| 组件 | 来源 | 说明 |
|---|---|---|
| `opencode` 二进制 | [sst/opencode](https://github.com/sst/opencode) 官方 musl 构建 | 动态链接 musl (非静态),不能直接跑 |
| `ld-musl-aarch64.so.1` | Alpine musl 包 | patchelf 设为 interpreter |
| `libstdc++.so.6` + `libgcc_s.so.1` | Alpine v3.20 包 | patchelf 设为 rpath (`/usr/lib/musl`) |
| DNS | dns53 转发器 / dns-bootstrap | Android 无 `/etc/resolv.conf`,musl 解析器回退 127.0.0.1:53 无人监听 → 卡死 5s |

**下载走 gh-proxy 镜像** (mirror 优先, GitHub 直连兜底),国内可装。

## 前置要求

- Termux + aarch64 (ARM64)
- 有 root: dns53 原生方案 (推荐)
- 无 root: 自动改用 dns-bootstrap + proot 兜底

## 一行命令安装

优先用 gh-proxy（缓存约几分钟）；拉不动时依次换 jsDelivr（约 12 小时缓存）或 GitHub 直连（实时，但国内网络不稳定）：

```bash
# 推荐: gh-proxy
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/OpenCodeV1-Termux/main/install.sh)

# 备选 1: jsDelivr CDN (约 12 小时缓存, 新提交可能延迟)
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xkxxs/OpenCodeV1-Termux@main/install.sh)

# 备选 2: GitHub 直连 (国内可能超时)
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/OpenCodeV1-Termux/main/install.sh)
```

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 依赖安装 | `pkg install patchelf nodejs-lts proot` (root 通过 `su` 识别, 不要求 Termux 的 sudo 包; proot 始终安装作 DNS 兜底) |
| musl 运行库 | 从 Alpine 获取 ld-musl + libstdc++ + libgcc (已存在则跳过) |
| DNS 修复 | 有 root: dns53 转发器 + `.bashrc` / `.zshrc` 常驻 (心跳 `.alive` 判断存活, dns53 挂了自动用 proot 兜底); 无 root: dns-bootstrap 实测校验 + proot 绑定; `dns53-aaaa on|off|status` 切换 AAAA 屏蔽 |
| 安装 OpenCode | GitHub API 查最新版 (mirror 优先) → 下载 musl tarball → patchelf ×2 → 验证 → 换入 |
| 生成 wrapper | `~/.local/bin/opencode`: 启动前自动查版更新、`opencode update` 完整升级流程、修复 `~/.opencode/bin` PATH 陷阱 |
| 写入 PATH | `~/.local/bin` 幂等写入 `~/.bashrc`;默认 shell 是 zsh(或已安装 zsh / 已有 `~/.zshrc`)时同时写入 `~/.zshrc` |
| 验证 | `opencode --version` |

## 使用

```bash
opencode                     # 启动: 先检查最新版, 非最新自动更新再启动
opencode update              # 更新到最新版
opencode update --force      # 已最新也强制重装
bash ~/.check_dns.sh         # DNS 一键诊断
node ~/.local/bin/dnsq.js api.deepseek.com   # 单点解析测试
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

> ⚠️ 不要用 opencode 官方的 `opencode upgrade` 命令:它只替换文件、不重跑 patchelf,更新即变砖。
> 本 wrapper 的 `opencode update` 内置完整流程 (查版 → 下载 → patchelf → 验证 → 原子换入)。

## 配置模型 (DeepSeek 等)

OpenCode 支持 Anthropic 兼容端点:

```bash
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_AUTH_TOKEN=sk-你的APIKey
export ANTHROPIC_MODEL=deepseek-v4-flash
# 持久化: 追加到 ~/.bashrc（zsh 用户为 ~/.zshrc）
```

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `cannot execute: required file not found` | 二进制 interpreter 不存在 | 重跑 `bash install.sh` (自动 patchelf) |
| `Error relocating libtermux-exec-ld-preload.so: __register_atfork` | termux-exec 的 LD_PRELOAD hook (Bionic) 被 musl 加载 | wrapper 已 `unset LD_PRELOAD` |
| API 请求恰好卡 5s 超时 | DNS 卡死 (musl 读不到 resolv.conf) | dns53/dns-bootstrap 已自动处理; `bash ~/.check_dns.sh` 诊断 |
| `-S: error while loading shared libraries` | Termux 命令在特定 shell 的怪癖 | 用完整路径调用或重登 shell |
| glibc 版 Segfault | 用错了非 musl 构建 | 本方案用 musl 版,不要用 `opencode-linux-arm64.tar.gz` |

## 许可证

MIT
