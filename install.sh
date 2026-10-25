#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# opencode-termux — 在 Termux (Android aarch64) 上一键安装官方 OpenCode CLI
# 方案: 官方 musl 动态链接版 + patchelf 改 interpreter/rpath
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/OpenCodeV1-Termux/main/install.sh)
#   bash <(curl -fsSL …/install.sh) --uninstall
#
# 原理:
#   官方 opencode-linux-arm64-musl.tar.gz 是动态链接 musl (非静态!),
#   Android 没有 musl 运行环境, 需从 Alpine 获取 ld-musl-aarch64.so.1
#   + libstdc++.so.6 + libgcc_s.so.1, 再用 patchelf 改二进制:
#     interpreter → /usr/lib/ld-musl-aarch64.so.1
#     rpath       → /usr/lib/musl
#
#   DNS: musl 解析器读不到 /etc/resolv.conf (Android 没有), 回退
#   127.0.0.1:53 无人监听 → 卡死 5s。有 root 用 dns53 转发器;
#   无 root 用 dns-bootstrap 实测校验 + proot 绑定 resolv.conf。
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
OPENCODE_DIR="$HOME_DIR/.local/opencode"
REAL_BIN="$OPENCODE_DIR/opencode"
VERSION_FILE="$OPENCODE_DIR/.version"
WRAPPER_PATH="$HOME_DIR/.local/bin/opencode"
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
RPATH="$PREFIX/lib/musl"
CERT_FILE="$PREFIX/etc/tls/cert.pem"
REPO="sst/opencode"
ASSET="opencode-linux-arm64-musl.tar.gz"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- root 判定 / 执行 ----------
# Android 上有 root 不等于装了 Termux 的 sudo 包: Magisk/KernelSU 只提供 su,
# 只判断 `sudo -n` 会把这类设备误判成无 root。探测结果缓存到 .root_mode
# (direct|sudo|su|none), 避免每次启动都触发 su 授权弹窗。
DNS53_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dns53"
DNS_ROOT_MODE_FILE="$DNS53_DIR/.root_mode"

detect_root_mode() {
    if [ "$(id -u 2>/dev/null)" = 0 ]; then echo direct; return 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then echo sudo; return 0; fi
    if command -v su >/dev/null 2>&1; then
        local u
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
        [ "$u" = 0 ] && { echo su; return 0; }
    fi
    echo none
}

refresh_root_mode() {
    mkdir -p "$DNS53_DIR" 2>/dev/null || true
    detect_root_mode > "$DNS_ROOT_MODE_FILE" 2>/dev/null || true
}

root_mode() {
    local m
    m="$(cat "$DNS_ROOT_MODE_FILE" 2>/dev/null || true)"
    [ -n "$m" ] || m="$(detect_root_mode)"
    printf '%s' "$m"
}

have_root() { [ "$(root_mode)" != none ]; }

root_exec() {
    local m p
    m="$(root_mode)"
    p="${PREFIX:-/data/data/com.termux/files/usr}/bin:/system/bin:/system/xbin"
    case "$m" in
        direct) "$@" ;;
        sudo)   sudo -n "$@" ;;
        su)     su -c "PATH=$p:\$PATH $(printf '%q ' "$@")" ;;
        *)      return 1 ;;
    esac
}

# dns53 心跳: 每 20s 刷新, 90s 内新鲜即视为在跑 (普通用户也能读, 不用 su pgrep)
dns53_alive() {
    local f="$DNS53_DIR/.alive" now mt
    [ -f "$f" ] || return 1
    now=$(date +%s)
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $((now - mt)) -lt 90 ]
}

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: curl -fsSL https://opencode.ai/install | bash"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 依赖 ----------
install_dependencies() {
    local need=()
    command -v patchelf >/dev/null || need+=(patchelf)
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    # 有 root → dns53 原生方案; 无 root → proot 兜底
    refresh_root_mode
    if have_root; then
        # dns53 挂掉时用 proot 绑 resolv.conf 兜底, 所以有 root 也装 proot
        command -v proot >/dev/null 2>&1 || need+=(proot)
    else
        need+=(proot)
        command -v sudo >/dev/null 2>&1 || need+=(sudo)
    fi
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    else
        ok "依赖已就绪 (patchelf $(patchelf --version 2>/dev/null | grep -oE '[0-9.]+'), node $(node --version))"
    fi
    if have_root; then
        command -v proot >/dev/null 2>&1 || { info "安装 proot (dns53 失效时的 DNS 兜底)…"; pkg install -y proot; }
    else
        command -v proot >/dev/null 2>&1 || { info "未检测到 root, 安装 proot 兜底…"; pkg install -y proot; }
        warn "未检测到 root: 将使用 proot 兜底方案 (性能略降)"
    fi
}

# ---------- musl 运行库 (Alpine) ----------
# ---------- Alpine 源: 动态版本 + 多镜像回退 ----------
# 不能硬编码 apk 版本号: Alpine 的 edge 是滚动分支, 旧版本会被直接轮掉
# (musl-1.2.6-r2 在 edge 已经 404 了), 所以固定用 latest-stable 分支,
# 并从 APKINDEX.tar.gz (解压出来是纯文本索引) 取当前版本号。
ALPINE_MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main/aarch64"
    "https://mirrors.aliyun.com/alpine/latest-stable/main/aarch64"
    "https://mirrors.ustc.edu.cn/alpine/latest-stable/main/aarch64"
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64"
)

apk_mirror_host() { local h="${1#https://}"; printf '%s' "${h%%/*}"; }

# $1=索引保存路径; 成功后把选中的镜像放进 ALPINE_BASE
alpine_select_mirror() {
    local m
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$m/APKINDEX.tar.gz" -o "$1"; then
            ALPINE_BASE="$m"
            ok "Alpine 镜像: $(apk_mirror_host "$m")"
            return 0
        fi
        warn "镜像不可用: $(apk_mirror_host "$m")"
    done
    fail "所有 Alpine 镜像都取不到 APKINDEX (网络问题?)"
}

# $1=索引路径 $2=包名 → 当前版本号; 解析失败则输出空串。
# 关键: 不能让 set -e 因为 pipeline 非零而"静默"退出 —— 曾出现过
# "没有任何报错、脚本直接结束" 的情况 (某些 tar 不认 apk 的扩展头会报错退出)。
alpine_version() {
    local idx="$1" pkg="$2" out=""
    # 注意: awk 打完就 exit, tar 会收到 SIGPIPE(141); 在 pipefail 下整条 pipeline 非零,
    # 若写成 `out=$(...) || out=""` 会把已经取到的值清空, 且 set -e 会让脚本"静默结束"。
    # 因此一律用 `|| true`: 保留已捕获的输出, 只吃掉非零退出码。
    out=$( { tar -xzOf "$idx" APKINDEX 2>/dev/null || true; } \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    # 回退: 用 gzip 先解压再喂给 tar, 绕开 tar 对 APK-TOOLS.checksum.SHA1 扩展头的处理差异
    [ -n "$out" ] || out=$( { gzip -dc "$idx" 2>/dev/null || true; } | tar -xOf - APKINDEX 2>/dev/null \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    printf '%s' "$out"
}

# $1=索引路径 $2=包名 $3=输出文件
alpine_fetch_apk() {
    local idx="$1" pkg="$2" out="$3" ver="" m
    ver="$(alpine_version "$idx" "$pkg")" || true
    if [ -z "$ver" ]; then
        warn "解析 $pkg 版本号失败, 下面是 tar 的真实输出:"
        tar -xzOf "$idx" APKINDEX >/dev/null || true
        fail "无法从 APKINDEX 解析 $pkg 的版本号"
    fi
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 120 "$m/$pkg-$ver.apk" -o "$out"; then
            info "$pkg-$ver.apk ← $(apk_mirror_host "$m")"
            return 0
        fi
        warn "$pkg-$ver.apk 下载失败: $(apk_mirror_host "$m")"
    done
    fail "$pkg.apk 下载失败 (已试 ${#ALPINE_MIRRORS[@]} 个镜像)"
}

# 需要: ld-musl-aarch64.so.1 + libstdc++.so.6 + libgcc_s.so.1
# 已存在则跳过 (幂等)
install_musl_libs() {
    if [ -x "$INTERP" ] && [ -f "$RPATH/libstdc++.so.6" ] && [ -f "$RPATH/libgcc_s.so.1" ]; then
        ok "musl 运行库已就绪 (ld-musl + libstdc++ + libgcc)"
        return
    fi

    local work idx
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/musl.XXXXXX")
    idx="$work/APKINDEX.tar.gz"
    alpine_select_mirror "$idx"

    info "获取 musl 动态链接器 (Alpine musl 包)…"
    alpine_fetch_apk "$idx" musl "$work/musl.apk"
    (cd "$work" && tar xzf musl.apk) || fail "musl.apk 解压失败"
    [ -f "$work/lib/ld-musl-aarch64.so.1" ] || fail "musl.apk 内容异常"
    cp "$work/lib/ld-musl-aarch64.so.1" "$PREFIX/lib/"
    chmod +x "$PREFIX/lib/ld-musl-aarch64.so.1"
    ok "ld-musl-aarch64.so.1 已安装"

    info "获取 C++ 运行库 (Alpine libgcc + libstdc++)…"
    mkdir -p "$RPATH"
    alpine_fetch_apk "$idx" libgcc "$work/libgcc.apk"
    alpine_fetch_apk "$idx" "libstdc++" "$work/libstdcxx.apk"
    (cd "$work" && tar xzf libgcc.apk && tar xzf libstdcxx.apk) || fail "C++ 库解压失败"
    cp "$work/usr/lib/libgcc_s.so.1" "$work/usr/lib/libstdc++.so.6"* "$RPATH/" 2>/dev/null || {
        cp "$work/usr/lib/libgcc_s.so.1" "$RPATH/"
        cp "$work/usr/lib/libstdc++.so.6.0.32" "$RPATH/libstdc++.so.6"
        cp "$work/usr/lib/libstdc++.so.6.0.32" "$RPATH/libstdc++.so.6.0.32"
    }
    chmod +x "$RPATH/"libstdc++.so.6* "$RPATH/libgcc_s.so.1"
    rm -rf "$work"
    ok "C++ 运行库已安装到 $RPATH"
}

# ---------- shell rc (bash + zsh) ----------
# 默认 shell 是 zsh 时不会读 ~/.bashrc, 只写 .bashrc 的 PATH / DNS 钩子等于没设。
# 按 $SHELL / 已安装的 zsh / 已有的 .zshrc 判断要写哪些 rc 文件。
shell_rcs() {
    printf '%s\n' "$HOME_DIR/.bashrc"
    if [ "$(basename "${SHELL:-bash}")" = "zsh" ] \
       || [ -f "$HOME_DIR/.zshrc" ] \
       || command -v zsh >/dev/null 2>&1; then
        printf '%s\n' "$HOME_DIR/.zshrc"
    fi
}

ensure_path_rc() {
    local rc
    while IFS= read -r rc; do
        [ -e "$rc" ] || : > "$rc"
        if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            info "~/.local/bin 已加入 PATH ($rc)"
        fi
    done < <(shell_rcs)
}

# ---------- DNS 修复 ----------
# musl 解析器读不到 /etc/resolv.conf (Android 没有), 回退 127.0.0.1:53
# 有 root → dns53 本地转发器 + .bashrc / .zshrc 常驻
# 无 root → dns-bootstrap 实测校验 + proot 绑定 resolv.conf (wrapper 运行时自动选择)
fix_dns() {
    # 与 opencode-termux 的 dns53 组件共用目录: 53 端口唯一, 一台设备只跑
    # 一个 dns53 实例; 心跳/日志/诊断也统一到 ~/.local/share/dns53。
    local dns53="$DNS53_DIR/dns53.js"
    local dnsboot="$DNS53_DIR/dns-bootstrap.js"
    mkdir -p "$DNS53_DIR" "$HOME_DIR/.local/bin"
    refresh_root_mode

    if ! have_root; then
        info "未检测到 root, 使用 dns-bootstrap + proot 兜底"
        info "dns-bootstrap 会自动实测候选 DNS 应答质量 (SERVFAIL/空/被过滤全判废), 只写入真实可用的 resolv.conf"
        cat > "$dnsboot" << 'DNSBOOT_EOF'
#!/usr/bin/env node
// dns-bootstrap — 无 root 环境下的 DNS 自动校验器
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有)。
//       有 root 时 dns53.js 监听 127.0.0.1:53 转发解析; 无 root 绑不了特权端口,
//       只能让 musl 直接查 resolv.conf 里的公网 DNS。
//       本脚本解决后者: 实际探测当前网络 → 逐个实测公网 DNS 应答质量
//       (SERVFAIL/空应答/CNAME-only 全判废) → 只把"实测通过"的写进 resolv.conf,
//       再交给 proot 绑定。网络被拦截时给出明确报错, 不再静默卡 5 秒。
// 用法:
//   node dns-bootstrap.js            # 单次校验并重写 resolv.conf (wrapper 启动前用)
//   node dns-bootstrap.js --daemon   # 常驻: 每 60s 重测重写 (开机/打开终端时拉起)
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const PUBLIC_DNS = ['223.5.5.5', '119.29.29.29', '114.114.114.114', '2400:3200::1', '2402:4e00::'];
// 测速用域名: 主测 API 域名; 若主域名本身被网络过滤, 回退测国内域名判断网络是否可用
const PROBE_DOMAINS = ['api.deepseek.com', 'www.baidu.com'];
const TIMEOUT_MS = 2500;
const RESOLV = process.env.DNS_RESOLV_CONF ||
  `${process.env.PREFIX || '/data/data/com.termux/files/usr'}/etc/resolv.conf`;
const scriptDir = (() => {
  try { return path.dirname(fs.realpathSync(process.argv[1] || __filename)); }
  catch (_) { return __dirname; }
})();
const DNS_DIR = process.env.DNS53_DIR || scriptDir;
const LOG = process.env.DNS_BOOTSTRAP_LOG || `${DNS_DIR}/logs/dns-bootstrap.log`;
const log = (m) => {
  try {
    fs.mkdirSync(path.dirname(LOG), { recursive: true });
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`);
  } catch (_) {}
};

// 探测手机当前网络 DNS (与 dns53 同一套逻辑, 无 root 也能跑 dumpsys)
function discoverPhoneDns() {
  const servers = [];
  // 首选 bionic/netd 的当前服务器: 无子进程、无阻塞 (getprop/dumpsys 会卡 3-5s)。
  try {
    for (const ip of require('dns').getServers()) {
      if (ip && !ip.includes(':')) servers.push(ip);
    }
  } catch (_) {}
  if (servers.length) {
    return [...new Set(servers)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0');
  }
  try {
    const props = execFileSync('/system/bin/getprop', [], { encoding: 'utf8', timeout: 3000 });
    for (const line of props.split('\n')) {
      const m = line.match(/^\[net\.\S+\.dns\d+\]:\s*\[([0-9.]+)\]/);
      if (m) servers.push(m[1]);
    }
  } catch (_) {}
  if (servers.length === 0) {
    try {
      const out = execFileSync('/system/bin/dumpsys', ['connectivity'], { encoding: 'utf8', timeout: 5000 });
      const blocks = out.split('NetworkAgentInfo{').slice(1);
      const scored = [];
      for (const b of blocks) {
        const dm = b.match(/DnsAddresses:\s*\[([^\]]*)\]/);
        if (!dm) continue;
        const ips = [];
        let hit;
        const re = /(\d{1,3}(?:\.\d{1,3}){3})/g;
        while ((hit = re.exec(dm[1]))) ips.push(hit[1]);
        if (!ips.length) continue;
        const score = (b.includes('TRANSPORT_PRIMARY') ? 0 : 1) + (b.includes('INTERNET') && b.includes('VALIDATED') ? 0 : 2);
        scored.push([score, ips]);
      }
      scored.sort((a, b) => a[0] - b[0]);
      for (const [, ips] of scored) servers.push(...ips);
    } catch (_) {}
  }
  return [...new Set(servers)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0');
}

// DNS 查询 (UDP 53, 非特权端口即可发起)
function queryDNS(server, host, timeout = TIMEOUT_MS) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket(server.includes(':') ? 'udp6' : 'udp4');
    const id = Buffer.from([Math.floor(Math.random() * 256), Math.floor(Math.random() * 256)]);
    const q = Buffer.alloc(12 + 2 + host.length + 4);
    id.copy(q, 0);
    q[2] = 0x01; // RD (flags 低字节)
    q[5] = 1;    // QDCOUNT
    let off = 12;
    for (const part of host.split('.')) { q[off++] = part.length; q.write(part, off); off += part.length; }
    q[off++] = 0; q[off++] = 0; q[off++] = 1; q[off++] = 0; q[off++] = 1; // A IN
    const t0 = Date.now();
    const timer = setTimeout(() => { try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'timeout', ms: Date.now() - t0 }); }, timeout);
    sock.on('message', (resp) => {
      clearTimeout(timer);
      resolve({ ok: !badAnswer(resp), ms: Date.now() - t0, raw: resp });
      try { sock.close(); } catch (_) {}
    });
    sock.on('error', () => { clearTimeout(timer); try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'error', ms: Date.now() - t0 }); });
    sock.send(q, 53, server);
  });
}

// 应答校验: 返回 true = 应答有问题 (与 dns53 的 isBadResponse 同套标准)
// 坏应答: 报文过短 / SERVFAIL / rcode=0 无答案 / 查 A 却只回 CNAME 不附地址 (ISP 过滤)
function badAnswer(resp) {
  if (resp.length < 12) return true;
  const rcode = resp.readUInt16BE(2) & 0x0f;
  if (rcode === 2) return true;
  if (rcode !== 0 && rcode !== 3) return true; // 只放行 NOERROR / NXDOMAIN
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return rcode === 0; // NOERROR 无答案 = 被过滤; NXDOMAIN 合法
  let off = 12;
  const skipName = (p) => {
    let hops = 0;
    while (off < p.length && p[off] !== 0) {
      if ((p[off] & 0xc0) === 0xc0) { off += 2; return; }
      off += p[off] + 1;
      if (++hops > 32) break;
    }
    off++;
  };
  for (let i = 0; i < qd && off < resp.length; i++) { skipName(resp); off += 4; }
  for (let i = 0; i < an && off + 10 <= resp.length; i++) {
    skipName(resp);
    const type = resp.readUInt16BE(off);
    const len = resp.readUInt16BE(off + 8);
    off += 10 + len;
    if (type === 1 || type === 28) return false; // 有 A/AAAA 记录
  }
  return true; // 只有 CNAME/NS 等 → 过滤特征
}

// 对单个服务器实测: 主域名失败再试备域名, 任一通过即为可用
async function probe(server) {
  for (const host of PROBE_DOMAINS) {
    const r = await queryDNS(server, host);
    if (r.ok) return { ip: server, ms: r.ms, host, ok: true };
  }
  return { ip: server, ms: Infinity, ok: false };
}

async function runOnce() {
  const phone = discoverPhoneDns();
  const candidates = [...phone, ...PUBLIC_DNS];
  const uniq = [];
  for (const ip of candidates) if (!uniq.includes(ip)) uniq.push(ip);
  if (uniq.length === 0) uniq.push(...PUBLIC_DNS);

  const results = await Promise.all(uniq.map((ip) => probe(ip)));
  const good = results.filter((r) => r.ok).sort((a, b) => a.ms - b.ms);

  for (const r of results) {
    log(`probe ${r.ip}: ${r.ok ? `OK ${r.ms}ms via ${r.host}` : 'FAILED'}`);
  }

  const comment = [];
  if (phone.length) comment.push(`# phone dns: ${phone.join(', ')}`);
  const top = good.slice(0, 3);
  const body = top.length
    ? top.map((r) => `nameserver ${r.ip}`).join('\n') + '\n'
    : 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 2400:3200::1\nnameserver 2402:4e00::\n';

  fs.mkdirSync(path.dirname(RESOLV), { recursive: true });
  fs.writeFileSync(RESOLV, `${comment.join('\n')}\n# auto-written by dns-bootstrap.js @ ${new Date().toISOString()}\n${body}`);
  log(`resolv.conf updated: ${top.map((r) => r.ip).join(', ') || 'NONE (fallback public)'}`);

  return good.length;
}

async function main() {
  const daemon = process.argv.includes('--daemon');
  const doOnce = async () => {
    try {
      const n = await runOnce();
      if (n === 0) log('ALL upstreams failed — network DNS likely blocked');
    } catch (e) {
      log(`error: ${e.message}`);
      process.exitCode = 1;
    }
  };
  if (daemon) {
    await doOnce();
    log('daemon started (poll every 60s)');
    setInterval(() => { doOnce(); }, 60000);
  } else {
    await doOnce();
  }
}

main();
DNSBOOT_EOF
        chmod +x "$dnsboot"
        info "dns-bootstrap.js 已写入: $dnsboot"

        node "$dnsboot" || warn "当前网络 DNS 全部不可用 (53 被拦截?), 已回退公共 DNS 写入 resolv.conf"
        info "如需原生直跑方案, 请在 Magisk 中授权 Termux 后重跑本脚本"
        return
    fi

    ok "root 可用, 使用 dns53 原生方案"
    cat > "$dns53" << 'DNS53_EOF'
#!/usr/bin/env node
// dns53 — 本地 DNS 转发器 (127.0.0.1:53)
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有),
//       回退到默认 127.0.0.1:53, 而手机上没人监听该端口 → DNS 卡死 → 5s 超时。
// 方案: 在 127.0.0.1:53 上监听 UDP, 优先转发到手机当前使用的 DNS (延迟更低),
//       再依次回退到公共 DNS (IPv4: 阿里/腾讯/114; IPv6: 阿里/CNNIC/移动), 回传响应。
// 运行: sudo node dns53.js  (53 是特权端口)
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');

// 公共兜底 DNS (手机 DNS 探测缺失时使用): IPv4 与 IPv6 各自独立
const PUBLIC_DNS4 = [
  ['223.5.5.5', 53],      // 阿里
  ['119.29.29.29', 53],   // 腾讯
  ['114.114.114.114', 53],// 114
];
const PUBLIC_DNS6 = [
  ['2400:3200::1', 53],   // 阿里 IPv6
  ['2402:4e00::', 53],    // 腾讯 DNSPod IPv6
  ['2408:8899::8', 53],   // 移动 IPv6
];
const TIMEOUT_MS = 1500;
// 单个上游等 250ms 没回就并行问下一个 (hedge): 国内 DNS 通常 <100ms,
// 被墙/丢包的 8.8.8.8 要等满超时, 串行会卡 3-4 秒。
const STAGGER_MS = 250;
// AAAA 屏蔽开关 (默认开启): 屏蔽后客户端只走 IPv4,
// 避免境外 IPv6 不可达导致连接卡死 (如 OpenAI 域名)。
// 境内 IPv6 可用时, 可设 DNS53_DISABLE_AAAA=0 关闭屏蔽。
const DISABLE_AAAA = process.env.DNS53_DISABLE_AAAA !== '0';
// 组件目录 = 本脚本所在目录 (与 agent 目录解耦; sudo 下 HOME 不可靠)
const scriptDir = (() => {
  try { return path.dirname(fs.realpathSync(process.argv[1] || __filename)); }
  catch (_) { return __dirname; }
})();
const DNS_DIR = process.env.DNS53_DIR || scriptDir;
const LOG = process.env.DNS53_LOG || `${DNS_DIR}/logs/dns53.log`;
// 心跳: wrapper / check_dns 用它的 mtime 判断 dns53 是否活着,
// 这样普通用户不用每次 su pgrep (避免授权弹窗), 也能在 dns53 挂掉时自动回退。
const ALIVE = `${DNS_DIR}/.alive`;
const beat = () => { try { fs.writeFileSync(ALIVE, String(Date.now())); } catch (_) {} };
const clearAlive = () => { try { fs.unlinkSync(ALIVE); } catch (_) {} };
const log = (m) => {
  try {
    fs.mkdirSync(path.dirname(LOG), { recursive: true });
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`);
  } catch (_) {}
};
// 日志轮转: 超过 2MB 截掉前半 (调试期高频查询日志会涨)
function rotateLog() {
  try {
    const st = fs.statSync(LOG);
    if (st.size > 2 * 1024 * 1024) {
      const content = fs.readFileSync(LOG, 'utf8');
      fs.writeFileSync(LOG, content.slice(Math.floor(content.length / 2)));
      log('LOG ROTATED');
    }
  } catch (_) {}
}
setInterval(rotateLog, 60000);

let UPSTREAMS = [...PUBLIC_DNS4, ...PUBLIC_DNS6];

// 探测手机当前 DNS: 同时收集 IPv4 与 IPv6 (优先默认网络)
function discoverPhoneDns() {
  const v4 = [];
  const v6 = [];
  // 首选 bionic/netd 的当前服务器: 无子进程、无阻塞, 切网后 netd 会自动更新。
  // (旧实现先跑 getprop / dumpsys connectivity 同步子进程, 最长阻塞 5s,
  //  表现为每 60s 刷新时有一次查询卡 4 秒左右)
  try {
    for (const ip of require('dns').getServers()) {
      if (!ip) continue;
      if (ip.includes(':')) v6.push(ip); else v4.push(ip);
    }
  } catch (_) {}
  if (v4.length || v6.length) {
    return {
      v4: [...new Set(v4)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0'),
      v6: [...new Set(v6)].filter((ip) => ip !== '::1' && ip !== '::'),
    };
  }
  // 不再用 getprop/dumpsys 同步兜底: root 下 getServers 可能为空, 而 dumpsys
  // 会阻塞事件循环 3-5s (每 60s 刷新 → 查询卡顿)。拿不到手机 DNS 时,
  // refreshDns 会退回 PUBLIC_DNS* 列表 (国内公共 DNS 在前)。
  return {
    v4: [...new Set(v4)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0'),
    v6: [...new Set(v6)].filter((ip) => ip !== '::1' && ip !== '::'),
  };
}

// 刷新上游: 手机 DNS 在前 (v4/v6 各自), 公共 DNS 兜底 (每分钟一次, 网络切换后自动跟随)
function refreshDns() {
  const phone = discoverPhoneDns();
  if (phone.v4.length === 0 && phone.v6.length === 0) return;
  const now = Date.now();
  for (const [h, t] of DEMOTED) if (now - t > DEMOTE_TTL) DEMOTED.delete(h);
  const merged = [];
  const add = (ip) => {
    if (!merged.some((s) => s[0] === ip)) merged.push([ip, 53]);
  };
  for (const ip of [...phone.v4, ...PUBLIC_DNS4.map((s) => s[0])]) add(ip);
  for (const ip of [...phone.v6, ...PUBLIC_DNS6.map((s) => s[0])]) add(ip);
  // 降级过的主机保持置底, 直到 TTL 到期
  // (否则每分钟的 refreshDns 会按手机顺序重建, 把坏上游又排回第一位)
  if (DEMOTED.size) {
    merged.sort((a, b) => (DEMOTED.has(a[0]) ? 1 : 0) - (DEMOTED.has(b[0]) ? 1 : 0));
  }
  if (JSON.stringify(merged) !== JSON.stringify(UPSTREAMS)) {
    UPSTREAMS = merged;
    log(`dns servers: ${merged.map((s) => s[0]).join(', ')}`);
  }
}

// 连续空应答计数: 记录各上游的连续"被过滤"次数, 达到阈值后降级到底部
const strikes = new Map();
const MAX_STRIKES = 3;
// 已降级的主机 (host -> 时间); refreshDns 重建上游列表时保持置底, TTL 后恢复
const DEMOTED = new Map();
const DEMOTE_TTL = 10 * 60 * 1000;

// 判断应答是否有效: 返回 true = 应答异常, 应换下一个上游。
// 覆盖: 报文过短 / SERVFAIL / A 查询 rcode=0 但答案为空 / A 查询只回 CNAME 没给 A
//       (中国 ISP DNS 常见过滤手法: 剥离 CNAME 链末端的地址记录)。
// 注意: AAAA 查询 (qtype=28) 一律放行 —— 域名没有 IPv6 记录时 NOERROR+0 答案、
//       部分上游对 AAAA 返回 NOTIMP 都是正常现象, 应由客户端自行回退 A 记录。
function isBadResponse(resp, qtype) {
  if (resp.length < 12) return true;
  const flags = resp.readUInt16BE(2);
  const rcode = flags & 0x0f;
  if (rcode === 2) return true; // SERVFAIL
  if (qtype === 28) return false; // AAAA: 空/NOTIMP/CNAME-only 均合法, 不判坏
  if (rcode !== 0 && rcode !== 3) return true; // NOTIMP/REFUSED 等 → 判坏换上游
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return true; // A 查询 rcode=0 但无任何答案 = 被过滤
  if (qtype !== 1) return false; // 非 A 查询, 只做基本校验
  // 逐条解析答案区, 看是否含有 A 记录
  let off = 12;
  const skipName = (p) => {
    let hops = 0;
    while (off < p.length && p[off] !== 0) {
      if ((p[off] & 0xc0) === 0xc0) { off += 2; return; }
      off += p[off] + 1;
      if (++hops > 32) break;
    }
    off++;
  };
  for (let i = 0; i < qd && off < resp.length; i++) { skipName(resp); off += 4; }
  for (let i = 0; i < an && off + 10 <= resp.length; i++) {
    skipName(resp);
    const type = resp.readUInt16BE(off);
    const len = resp.readUInt16BE(off + 8);
    off += 10 + len;
    if (type === 1) return false; // 找到 A 记录, 应答有效
  }
  return true; // A 查询答案区只有 CNAME/NS 等, 没有地址记录
}

// 降级: 移到列表末尾并记录, 刷新时保持置底
function demote(host) {
  DEMOTED.set(host, Date.now());
  const idx = UPSTREAMS.findIndex((s) => s[0] === host);
  if (idx >= 0) {
    const [s] = UPSTREAMS.splice(idx, 1);
    UPSTREAMS.push(s);
  }
  log(`demoted bad upstream ${host}`);
}

// 从查询报文解析 qtype (跳过问题名, 不受 EDNS 附加区影响)
function queryType(msg) {
  if (msg.length < 16) return 0;
  let off = 12;
  let hops = 0;
  while (off < msg.length && msg[off] !== 0) {
    if ((msg[off] & 0xc0) === 0xc0) return 0; // 压缩指针不出现于查询
    off += msg[off] + 1;
    if (++hops > 32) return 0;
  }
  if (off >= msg.length) return 0;
  off++; // root label
  if (off + 4 > msg.length) return 0;
  return (msg[off] << 8) | msg[off + 1];
}

// 从查询报文解析域名 (与 queryType 共用同一套偏移, 保证一致性)
function queryName(msg) {
  if (msg.length < 12) return null;
  let off = 12;
  let name = '';
  while (off < msg.length && msg[off] !== 0) {
    const len = msg[off++];
    if (off + len > msg.length) return null;
    name += (name ? '.' : '') + msg.slice(off, off + len).toString();
    off += len;
  }
  if (off >= msg.length) return null;
  return name;
}

// IPv6 地址字符串 → 16 字节 (处理 :: 简写与 IPv4 内嵌)
function ipv6ToBytes(ip) {
  const buf = Buffer.alloc(16);
  const v4m = ip.match(/(.*):([0-9.]+)$/);
  let head, tail;
  if (v4m && v4m[2].includes('.')) {
    head = v4m[1]; tail = v4m[2].split('.').map(Number);
  } else {
    head = ip; tail = [];
  }
  const [hs, ts] = head.split('::');
  let h = hs ? hs.split(':').filter(Boolean) : [];
  const t = ts ? ts.split(':').filter(Boolean) : [];
  while (h.length + t.length + (tail.length ? 2 : 0) < 8) h.push('0');
  const all = h.concat(t);
  all.forEach((part, i) => { if (part !== undefined) buf.writeUInt16BE(parseInt(part, 16) || 0, i * 2); });
  if (tail.length) {
    tail.forEach((b, i) => { buf.writeUInt8(b, 12 + i); });
  }
  return buf;
}

// 构造 DNS 应答: 复用客户端查询报文, 填上答案
function buildResponse(msg, answers) {
  const qnameLen = msg.length - 12;
  const resp = Buffer.alloc(12 + qnameLen + answers.length * 16);
  msg.copy(resp, 0, 0, 12 + qnameLen);
  resp[2] |= 0x80; // QR
  resp[3] |= 0x80; // RA
  resp[6] = answers.length >> 8; resp[7] = answers.length & 0xff;
  let off = 12 + qnameLen;
  for (const a of answers) {
    resp.writeUInt16BE(0xc00c, off); off += 2; // 指针 → 问题名
    resp.writeUInt16BE(a.type, off); off += 2;
    resp.writeUInt16BE(1, off); off += 2;      // IN
    resp.writeUInt32BE(60, off); off += 4;     // TTL
    if (a.type === 1) {
      resp.writeUInt16BE(4, off); off += 2;
      for (const b of a.ip.split('.').map(Number)) resp.writeUInt8(b, off++);
    } else {
      resp.writeUInt16BE(16, off); off += 2;
      ipv6ToBytes(a.ip).copy(resp, off); off += 16;
    }
  }
  return resp;
}

const netd = require('dns'); // node 内置解析 (走 bionic/netd, 不受 UDP 53 封锁影响)

// 最后兜底: UDP 上游失败时, 用系统解析 (netd) 回答 (onDone 通知调用方)
function netdFallback(msg, rinfo, qtype, onDone, qid) {
  const host = queryName(msg);
  if (!host || (qtype !== 1 && qtype !== 28)) {
    log(`netd fallback q${qid}: unsupported query (qtype=${qtype})`);
    if (onDone) onDone();
    return;
  }
  const family = qtype === 1 ? 4 : 6;
  const t1 = Date.now();
  netd.lookup(host, { family, timeout: 5000 }, (err, ip) => {
    // onDone 返回 false 表示已有上游先应答, 这里不能再发第二份
    if (onDone && onDone() === false) return;
    if (err) {
      // NXDOMAIN 或解析失败: 回 rcode=3 (合法应答, 客户端正常处理)
      const resp = Buffer.alloc(12 + msg.length - 12);
      msg.copy(resp, 0, 0, msg.length);
      resp[2] |= 0x80; // QR
      resp[3] = (resp[3] & 0x70) | 0x80 | 0x03; // RA + rcode=NXDOMAIN
      server.send(resp, rinfo.port, rinfo.address);
      log(`netd fallback q${qid} ${host} → NXDOMAIN/err ${err.code || err.message} (${Date.now() - t1}ms)`);
      return;
    }
    const resp = buildResponse(msg, [{ type: qtype, ip }]);
    server.send(resp, rinfo.port, rinfo.address);
    log(`netd fallback q${qid} ${host} → ${ip} (${family === 4 ? 'A' : 'AAAA'}) ${Date.now() - t1}ms`);
  });
}

const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  const qtype = queryType(msg);
  const qid = msg.readUInt16BE(0).toString(16);
  const qhost = queryName(msg) || '?';
  const t0 = Date.now();
  log(`>> q${qid} ${qhost} type=${qtype === 1 ? 'A' : qtype === 28 ? 'AAAA' : qtype} from ${rinfo.address}`);
  // AAAA 屏蔽: 直接回 NOERROR+0 答案 (合法"无 IPv6 记录"), 不走上游
  if (qtype === 28 && DISABLE_AAAA) {
    const resp = Buffer.alloc(msg.length);
    msg.copy(resp, 0, 0, msg.length);
    resp[2] |= 0x80; // QR
    resp[3] |= 0x80; // RA
    server.send(resp, rinfo.port, rinfo.address);
    log(`<< q${qid} ${qhost} AAAA suppressed (IPv6 disabled) ${Date.now() - t0}ms`);
    return;
  }
  let done = false;
  let netdStarted = false;
  // 任一上游失败 → 并行启动 netd 兜底 (先回先赢; onDone 返回 false = 已有应答, 不再发)
  const startNetd = () => {
    if (netdStarted || done) return;
    netdStarted = true;
    log(`>> q${qid} netd fallback started (${Date.now() - t0}ms in)`);
    netdFallback(msg, rinfo, qtype, () => {
      if (done) return false;
      done = true;
      return true;
    }, qid);
  };
  // 快照本次查询的上游列表: demote/refreshDns 会改 UPSTREAMS, 迭代中不能用活引用
  const upstreams = UPSTREAMS.slice();
  let i = 0;
  // 依次尝试上游; 失败的那个计 strike (超时也算), 达到阈值降级,
  // 然后继续试下一个上游 —— 同时并行启动 netd 兜底, 避免串行等待过长。
  const tryNext = () => {
    if (done) return;
    if (i >= upstreams.length) { startNetd(); return; }
    const [host, port] = upstreams[i++];
    const t1 = Date.now();
    const tag = `q${qid}->${host}`;
    const sock = dgram.createSocket(host.includes(':') ? 'udp6' : 'udp4');
    let doneHere = false;
    let hedge = null;
    const finish = (fn) => {
      if (doneHere) return;
      doneHere = true;
      clearTimeout(timer);
      if (hedge) clearTimeout(hedge);
      sock.close();
      fn();
    };
    const fail = (why) => {
      if (done) { finish(() => {}); return; }  // 其他上游/netd 已应答, 别再计 strike
      finish(() => {
        const n = (strikes.get(host) || 0) + 1;
        strikes.set(host, n);
        if (n >= MAX_STRIKES) { strikes.delete(host); demote(host); }
        log(`${why} ${tag} (${Date.now() - t1}ms, strike ${n}/${MAX_STRIKES})`);
        startNetd();
        tryNext();
      });
    };
    const timer = setTimeout(() => fail('timeout'), TIMEOUT_MS);
    // 并行 hedge: 不等这个上游超时, 250ms 后同时问下一个, 先回先赢
    hedge = setTimeout(() => {
      if (doneHere || done) return;
      tryNext();
    }, STAGGER_MS);
    sock.on('message', (resp) => {
      if (doneHere) return;
      if (done) { finish(() => {}); return; }  // 防双发: 已有人先回过了
      if (isBadResponse(resp, qtype)) { fail('bad response'); return; }
      finish(() => {
        if (strikes.has(host)) strikes.delete(host);
        done = true;
        server.send(resp, rinfo.port, rinfo.address);
        log(`<< q${qid} ${qhost} OK via ${host} (${Date.now() - t1}ms, total ${Date.now() - t0}ms)`);
      });
    });
    sock.on('error', (e) => fail(`error: ${e.message}`));
    sock.send(msg, port, host, (e) => {
      if (e) fail(`send error: ${e.message}`);
    });
  };
  tryNext();
});

server.on('error', (e) => {
  log(`server error: ${e.message}`);
  if (process.stderr.isTTY) console.error(`dns53 server error: ${e.message}`);
  // 端口被占等致命错误: 占着没意义, 直接退出 (避免僵尸进程)
  process.exit(1);
});
server.bind(53, '127.0.0.1', () => {
  refreshDns();
  beat();
  setInterval(beat, 20000);
  log('dns53 listening on 127.0.0.1:53');
  if (process.stdout.isTTY) console.log('dns53 listening on 127.0.0.1:53');
  setInterval(refreshDns, 60000);
});

process.on('exit', clearAlive);
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(sig, () => { clearAlive(); process.exit(0); });
}
DNS53_EOF
    chmod +x "$dns53"
    info "dns53.js 已更新: $dns53"
    cat > "$HOME_DIR/.local/bin/dns53-aaaa" << 'AAAA_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dns53-aaaa — 一键切换 dns53 的 AAAA 屏蔽
# 用法: dns53-aaaa on|off|status
set -euo pipefail

D53="$HOME/.local/share/dns53/dns53.js"
LOG="$HOME/.local/share/dns53/logs/dns53.log"
MODE="$(cat "$HOME/.local/share/dns53/.root_mode" 2>/dev/null || echo none)"

root_exec() {
    case "$MODE" in
        direct) "$@" ;;
        sudo)   sudo -n "$@" ;;
        su)     su -c "PATH=${PREFIX:-/data/data/com.termux/files/usr}/bin:/system/bin:/system/xbin:\$PATH $(printf '%q ' "$@")" ;;
        *)      echo "需要 root (未检测到 root/su)" >&2; return 1 ;;
    esac
}

get_pid() {
    root_exec pgrep -f '^node .*dns5[3]\.js' 2>/dev/null | head -1
}

show_status() {
    local pid mode
    pid=$(get_pid)
    if [ -z "$pid" ]; then
        echo "dns53 未运行"
        return
    fi
    mode=$(root_exec cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | sed -n 's/^DNS53_DISABLE_AAAA=//p')
    if [ "$mode" = "0" ]; then
        echo "关闭（放行 AAAA/IPv6）| PID $pid"
    else
        echo "开启（屏蔽 AAAA，只走 IPv4）| PID $pid"
    fi
}

restart() {
    local val="$1" label="$2"
    root_exec pkill -f '^node .*dns5[3]\.js' 2>/dev/null || true
    sleep 1
    mkdir -p "$HOME/.local/share/dns53/logs"
    root_exec env DNS53_DISABLE_AAAA="$val" nohup node "$D53" > "$LOG" 2>&1 &
    sleep 1
    echo "✓ $label"
    show_status
}

case "${1:-status}" in
    on)  restart 1 "AAAA 屏蔽已开启（默认，只走 IPv4）" ;;
    off) restart 0 "AAAA 屏蔽已关闭（放行 IPv6）" ;;
    status) show_status ;;
    *) echo "用法: dns53-aaaa on|off|status" >&2; exit 1 ;;
esac
AAAA_EOF
    chmod +x "$HOME_DIR/.local/bin/dns53-aaaa"
    info "dns53-aaaa 切换脚本已生成: ~/.local/bin/dns53-aaaa"

    # 幂等更新 hook: 旧版是 sudo -n, Magisk 设备上永远起不来 → 先删旧块再写。
    # 新块有结束标记; 旧块没有, 只能删到第一个独立 fi (旧块内无嵌套 fi)。
    # zsh 用户不读 .bashrc, 两个 rc 文件都写。
    local rc
    while IFS= read -r rc; do
        if grep -q '# ===== DNS 转发器结束 =====' "$rc" 2>/dev/null; then
            sed -i '/# ===== DNS 转发器常驻 (dns53) =====/,/# ===== DNS 转发器结束 =====/d' "$rc"
        elif grep -q 'DNS 转发器常驻 (dns53)' "$rc" 2>/dev/null; then
            sed -i '/# ===== DNS 转发器常驻 (dns53) =====/,/^fi$/d' "$rc"
        fi
        cat >> "$rc" << 'BASHRC_EOF'

# ===== DNS 转发器常驻 (dns53) =====
# 背景: musl 程序 (codex/opencode) 的解析器读不到 /etc/resolv.conf (Android 没有),
#       回退到 127.0.0.1:53, 而手机无人监听 → DNS 卡死 5s 超时。
# 心跳: dns53 每 20s 写 .alive; 90s 内新鲜即视为在跑。用心跳而不是 pgrep:
#       普通用户 pgrep root 进程不可靠, 而每次 su 又可能弹授权框。
__dns_dir="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
__dns_mt=0
if [ -r "$__dns_dir/.alive" ]; then
    __dns_mt=$(stat -c %Y "$__dns_dir/.alive" 2>/dev/null || echo 0)
fi
if [ $(( $(date +%s) - __dns_mt )) -ge 90 ] && [ -f "$__dns_dir/dns53.js" ]; then
    __dns_mode=$(cat "$__dns_dir/.root_mode" 2>/dev/null || echo none)
    case "$__dns_mode" in
        direct) nohup node "$__dns_dir/dns53.js" >/dev/null 2>&1 & ;;
        sudo)   sudo -n nohup node "$__dns_dir/dns53.js" >/dev/null 2>&1 & ;;
        su)     su -c "${PREFIX:-/data/data/com.termux/files/usr}/bin/node $__dns_dir/dns53.js >/dev/null 2>&1 &" ;;
    esac
    unset __dns_mode
fi
unset __dns_dir __dns_mt
# ===== DNS 转发器结束 =====
BASHRC_EOF
        info "dns53 常驻逻辑已写入 $rc"
    done < <(shell_rcs)

    if dns53_alive; then
        ok "DNS 转发器已在运行"
    else
        # 旧版 dns53 (2.0.0) 没有心跳: 进程在跑但 .alive 缺失 → 重启到新代码,
        # 否则 53 端口被旧进程占着, 新实例起不来, wrapper 也就永远看不到心跳。
        root_exec pkill -f '^node .*dns5[3]\.js' 2>/dev/null || true
        sleep 1
        mkdir -p "$DNS53_DIR/logs"
        root_exec nohup node "$dns53" > "$DNS53_DIR/logs/dns53.log" 2>&1 &
        sleep 1
        if dns53_alive; then
            ok "DNS 转发器已启动 (127.0.0.1:53)"
        else
            warn "DNS 转发器启动失败 (日志: $DNS53_DIR/logs/dns53.log), 启动时将用 proot 兜底"
        fi
    fi

    # 诊断工具
    local dnsq="$DNS53_DIR/dnsq.js"
    local check="$HOME_DIR/.check_dns.sh"
    cat > "$dnsq" << 'DNSQ_EOF'
#!/usr/bin/env node
// dnsq.js — 用原始 UDP 查询域名 A 记录
// 用法: node dnsq.js <host> [dns-server]
//   默认查 127.0.0.1:53 (dns53 转发器); 无 root 方案下传 resolv.conf 的 nameserver
//
// 注意: 不能用 require('dns').Resolver({servers}) —— 在 Termux (bionic) 上
// 它可能忽略自定义 server, 一律交给 netd, 导致 "没有监听也能解析成功" 的假象。
const dgram = require('dgram');
const host = process.argv[2];
const server = process.argv[3] || '127.0.0.1';
if (!host) {
  console.error('usage: node dnsq.js <host> [server]');
  process.exit(2);
}

const t0 = Date.now();
const id = (Math.random() * 65536) | 0;

function buildQuery() {
  const labels = host.split('.').filter(Boolean);
  const size = 12 + labels.reduce((n, l) => n + 1 + l.length, 0) + 5;
  const b = Buffer.alloc(size);
  b.writeUInt16BE(id, 0);
  b.writeUInt16BE(0x0100, 2); // RD
  b.writeUInt16BE(1, 4); // QDCOUNT
  let o = 12;
  for (const l of labels) {
    b[o++] = l.length;
    b.write(l, o, 'ascii');
    o += l.length;
  }
  b[o++] = 0;
  b.writeUInt16BE(1, o); // A
  b.writeUInt16BE(1, o + 2); // IN
  return b;
}

function skipName(buf, o) {
  while (o < buf.length) {
    const l = buf[o];
    if (l === 0) return o + 1;
    if ((l & 0xc0) === 0xc0) return o + 2;
    o += l + 1;
  }
  return o;
}

function done(line, code) {
  console.log(line);
  try { sock.close(); } catch (_) {}
  process.exit(code);
}

const sock = dgram.createSocket(server.includes(':') ? 'udp6' : 'udp4');
const timer = setTimeout(() => done(`  ${host} @${server} → ★ TIMEOUT (${Date.now() - t0}ms)`, 1), 3000);

sock.on('error', (e) => done(`  ${host} @${server} → ★ ${e.code || e.message} (${Date.now() - t0}ms)`, 1));
sock.on('message', (resp) => {
  clearTimeout(timer);
  const ms = Date.now() - t0;
  if (resp.length < 12 || resp.readUInt16BE(0) !== id) {
    return done(`  ${host} @${server} → ★ 响应不匹配 (${ms}ms)`, 1);
  }
  const rcode = resp.readUInt16BE(2) & 0xf;
  const ancount = resp.readUInt16BE(6);
  const ips = [];
  try {
    let o = skipName(resp, 12) + 4; // 跳过问题 (name + type + class)
    for (let i = 0; i < ancount && o + 10 <= resp.length; i++) {
      o = skipName(resp, o);
      if (o + 10 > resp.length) break;
      const type = resp.readUInt16BE(o);
      const rdlen = resp.readUInt16BE(o + 8);
      o += 10;
      if (type === 1 && rdlen === 4) ips.push(`${resp[o]}.${resp[o + 1]}.${resp[o + 2]}.${resp[o + 3]}`);
      o += rdlen;
    }
  } catch (_) {}
  if (ips.length) return done(`  ${host} @${server} → OK IPs=[${ips.join(',')}] (${ms}ms)`, 0);
  const why = rcode === 3 ? 'NXDOMAIN' : rcode !== 0 ? `rcode=${rcode}` : 'NO-A';
  done(`  ${host} @${server} → ★ ${why} (${ms}ms)`, 1);
});

const q = buildQuery();
sock.send(q, 0, q.length, 53, server, (err) => {
  if (err) done(`  ${host} @${server} → ★ ${err.code || err.message} (${Date.now() - t0}ms)`, 1);
});
DNSQ_EOF
    cat > "$check" << 'CHECK_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# check_dns.sh — 一键判断"DNS 问题 vs 网络/服务器问题"
# 用法: bash ~/.check_dns.sh [域名...]
DNS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
DNSQ="$DNS_DIR/dnsq.js"
LOG="$DNS_DIR/logs/dns53.log"
HOSTS=(api.deepseek.com api.anthropic.com opencode.ai www.baidu.com)
[ $# -gt 0 ] && HOSTS=("$@")

echo "═══ 诊断 $(date '+%F %T') ═══"

echo "── dns53 状态 ──"
alive=0
if [ -f "$DNS_DIR/.alive" ]; then
  mt=$(stat -c %Y "$DNS_DIR/.alive" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - mt )) -lt 90 ] && alive=1
fi
if [ "$alive" = 1 ]; then
  echo "运行中 (root 模式: $(cat "$DNS_DIR/.root_mode" 2>/dev/null || echo '?'))"
else
  echo "★ 未运行! 请重开终端; 或: su -c \"nohup node $DNS_DIR/dns53.js &\""
fi
grep 'dns servers:' "$LOG" 2>/dev/null | tail -1 || echo "(无日志)"

echo "── 域名解析 (经 127.0.0.1:53 / dns53 转发) ──"
for h in "${HOSTS[@]}"; do
  timeout 6 node "$DNSQ" "$h" || true
done

echo "── HTTPS 连通性 ──"
for u in https://api.deepseek.com/v1 https://api.anthropic.com/v1 https://opencode.ai https://www.baidu.com; do
  printf "  %s → " "$u"
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 8 "$u" || echo "★ 超时/失败"
done

echo "── 最近 12 条 dns53 日志 ──"
tail -12 "$LOG" 2>/dev/null || echo "无日志文件"
CHECK_EOF
    chmod +x "$dnsq" "$check"
    ok "诊断工具已安装: ~/.check_dns.sh (用法: bash ~/.check_dns.sh)"
}

# ---------- 安装官方 OpenCode ----------
install_opencode() {
    info "查询最新版本 (GitHub API, mirror 优先)…"
    local version=""
    version=$(curl -fsSL --max-time 20 "https://gh-proxy.com/https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name": *"v[^"]+"' | head -n1 | cut -d'"' -f4) || true
    if [ -z "$version" ]; then
        version=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
            | grep -oE '"tag_name": *"v[^"]+"' | head -n1 | cut -d'"' -f4) || true
    fi
    [ -n "$version" ] || fail "无法获取最新版本 (网络问题?)"
    info "最新版本: $version"

    local installed=""
    [ -f "$VERSION_FILE" ] && installed=$(cat "$VERSION_FILE" 2>/dev/null || true)
    if [ -x "$REAL_BIN" ] && [ "$installed" = "$version" ]; then
        ok "已是最新版本 $version, 跳过下载"
        return
    fi

    local work
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/opencode.XXXXXX")
    # 双引号: 路径在设置时立即展开成字面量。
    # 单引号版本会在函数返回时才求值, 而 RETURN trap 会泄漏到调用方
    # (调用方返回时再次触发), 那时 $work 已出作用域 → set -u 报 unbound variable。
    trap "rm -rf '$work'" RETURN
    info "下载 $ASSET ($version, 约 50MB)…"
    local dl=0
    for url in \
        "https://gh-proxy.com/https://github.com/$REPO/releases/download/$version/$ASSET" \
        "https://github.com/$REPO/releases/download/$version/$ASSET"; do
        # 不用 -s: 保留 curl 的进度条
        if curl -fSL --progress-bar --connect-timeout 15 --max-time 600 "$url" -o "$work/$ASSET"; then
            dl=1; break
        fi
    done
    [ "$dl" = 1 ] || fail "下载失败 (mirror 与直连均不可用)"

    tar xzf "$work/$ASSET" -C "$work" || fail "解压失败"
    local new_bin="$work/opencode"
    [ -f "$new_bin" ] || fail "tarball 内未找到 opencode 二进制"
    chmod +x "$new_bin"

    info "patchelf: interpreter → $INTERP"
    patchelf --set-interpreter "$INTERP" "$new_bin" || fail "patchelf interpreter 失败"
    info "patchelf: rpath → $RPATH"
    patchelf --set-rpath "$RPATH" "$new_bin" || fail "patchelf rpath 失败"

    # 验证能跑才替换
    # 无 root 时 musl 二进制被 Android seccomp 拦截 → Bad system call, 需走 proot
    local verify_env="env -u LD_PRELOAD SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
    local verify_ok=0
    if command -v proot >/dev/null 2>&1; then
        proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" \
            $verify_env "$new_bin" --version >/dev/null 2>&1 && verify_ok=1
    fi
    if [ "$verify_ok" -eq 0 ]; then
        $verify_env "$new_bin" --version >/dev/null 2>&1 && verify_ok=1
    fi
    if [ "$verify_ok" -ne 1 ]; then
        fail "新二进制验证失败 (如无 root 请确保已安装 proot), 已放弃替换"
    fi

    mkdir -p "$OPENCODE_DIR"
    mv -f "$new_bin" "$REAL_BIN"
    chmod +x "$REAL_BIN"
    echo "$version" > "$VERSION_FILE"
    ok "OpenCode $version 已安装"
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# opencode wrapper for Termux
# ~/.local/bin/opencode
#
# Official OpenCode (sst/opencode) musl build, patched:
#   interpreter → Termux musl loader (ld-musl-aarch64.so.1)
#   rpath       → Termux musl libs (libstdc++, libgcc_s)
#
# Usage:
#   opencode [args...]          run opencode (patched); 启动前自动
#                               检查最新版本, 非最新则自动更新再启动
#   opencode update [--force]   re-download latest musl build,
#                               re-patch, atomically swap binary
#   opencode upgrade            alias of update
#
# Env:
#   OPENCODE_NO_AUTO_UPDATE=1   skip auto-update check on startup
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="$HOME"
BIN_DIR="$HOME_DIR/.local/opencode"
REAL_BIN="$BIN_DIR/opencode"
VERSION_FILE="$BIN_DIR/.version"
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
RPATH="$PREFIX/lib/musl"
REPO="sst/opencode"
ASSET="opencode-linux-arm64-musl.tar.gz"

export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"

# termux-exec's LD_PRELOAD hook lib is Bionic-compiled; the musl
# dynamic linker can't relocate it. opencode doesn't need it.
unset LD_PRELOAD

# Get latest tag (vX.Y.Z): gh-proxy mirror first (国内可用), 直连兜底。
# 参数: $1 = mirror 超时(默认20) $2 = 直连超时(默认15)
latest_version() {
    local mirror_timeout="${1:-20}" direct_timeout="${2:-15}"
    local api="https://api.github.com/repos/$REPO/releases/latest"
    local v=""
    v="$(curl -fsSL --max-time "$mirror_timeout" "https://gh-proxy.com/$api" 2>/dev/null \
        | grep -oE '"tag_name": *"v[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    if [ -z "$v" ]; then
        v="$(curl -fsSL --max-time "$direct_timeout" "$api" 2>/dev/null \
            | grep -oE '"tag_name": *"v[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    fi
    printf '%s' "$v"
}

# Download release asset: gh-proxy mirror first, GitHub direct as fallback.
download_asset() {
    local ver="$1" out="$2"
    for url in \
        "https://gh-proxy.com/https://github.com/$REPO/releases/download/$ver/$ASSET" \
        "https://github.com/$REPO/releases/download/$ver/$ASSET"; do
        if curl -fSL --progress-bar --connect-timeout 15 --max-time 600 "$url" -o "$out"; then
            return 0
        fi
    done
    return 1
}

# 运行 opencode 二进制: 有 root 直跑, 无 root 走 proot (避免 seccomp 拦截 musl 系统调用)
run_opencode() {
    local bin="$1"; shift
    local _env="env -u LD_PRELOAD SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
    if [ "$(root_mode)" != none ]; then
        $_env "$bin" "$@"
    elif command -v proot >/dev/null 2>&1; then
        proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" $_env "$bin" "$@"
    else
        $_env "$bin" "$@"
    fi
}

# 本地已记录版本; 无记录时从二进制本身探测 (可能为空)
current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        run_opencode "$REAL_BIN" --version 2>/dev/null \
            | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1 || true
    fi
}

# 版本比较: 去掉 v 前缀, $1 >= $2 返回 0
version_ge() {
    local a="${1#v}" b="${2#v}"
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
}

# 下载 → 解压 → patchelf → 验证 → 原子换入。失败返回 1 (保留旧二进制)。
do_update() {
    local VERSION="$1"
    echo "==> 下载 $ASSET ($VERSION, 约 50MB, 可能较慢) …"
    local TMP
    TMP="$(mktemp -d "${TMPDIR:-$HOME}/.opencode-update.XXXXXX")" || return 1
    # 同上: 双引号立即展开路径, 避免 RETURN trap 泄漏到调用方后 $TMP 未绑定
    trap "rm -rf '$TMP'" RETURN
    if ! download_asset "$VERSION" "$TMP/$ASSET"; then
        echo "!! 下载失败(mirror 与直连均不可用)" >&2
        return 1
    fi

    if ! tar xzf "$TMP/$ASSET" -C "$TMP"; then
        echo "!! 解压失败" >&2
        return 1
    fi
    local NEW_BIN="$TMP/opencode"
    chmod +x "$NEW_BIN"
    echo "==> patchelf: interpreter + rpath …"
    patchelf --set-interpreter "$INTERP" "$NEW_BIN" || return 1
    patchelf --set-rpath "$RPATH" "$NEW_BIN" || return 1

    # 验证能跑再替换; 失败则保留旧二进制
    if ! run_opencode "$NEW_BIN" --version >/dev/null 2>&1; then
        echo "!! 新二进制无法运行, 已回滚(旧版保留)" >&2
        return 1
    fi
    mv -f "$NEW_BIN" "$REAL_BIN" || return 1
    chmod +x "$REAL_BIN"
    echo "$VERSION" > "$VERSION_FILE"
    echo "✓ 更新完成: $(run_opencode "$REAL_BIN" --version)"
}

case "${1:-}" in
    --update|-u|update|upgrade)
        FORCE=0
        if [ "${2:-}" = "--force" ] || [ "${2:-}" = "-f" ]; then FORCE=1; fi

        command -v patchelf >/dev/null 2>&1 \
            || { echo "缺少 patchelf: pkg install patchelf" >&2; exit 1; }

        echo "== 检查最新版本 …"
        VERSION="$(latest_version)"
        [ -n "$VERSION" ] || { echo "!! 无法获取最新版本(网络问题?)" >&2; exit 1; }

        CURRENT="$(current_version)"
        if [ "$FORCE" -eq 0 ] && [ -n "$CURRENT" ] && version_ge "$CURRENT" "$VERSION"; then
            echo "✓ 已是最新 ($CURRENT)"
            exit 0
        fi

        do_update "$VERSION" || exit 1
        ;;
    *)
        # 自动更新: 启动前快速检查最新版本 (短超时, 网络差时静默跳过),
        # 非最新则自动更新; 更新失败不阻塞, 用现有版本启动。
        if [ "${OPENCODE_NO_AUTO_UPDATE:-0}" != "1" ]; then
            LATEST="$(latest_version 10 6)" || true
            if [ -n "$LATEST" ]; then
                CURRENT="$(current_version)"
                if [ -z "$CURRENT" ] || ! version_ge "$CURRENT" "$LATEST"; then
                    echo "→ 检测到新版本 $LATEST (当前 ${CURRENT:-未知}), 自动更新…"
                    if do_update "$LATEST"; then
                        echo "→ 更新完毕, 继续启动 opencode…"
                    else
                        echo "!! 自动更新失败, 继续使用现有版本启动" >&2
                    fi
                fi
            fi
        fi
        # DNS: musl 读不到 /etc/resolv.conf, 默认查 127.0.0.1:53。
        # 心跳新鲜才代表 dns53 真在跑; 只看 root 会误判 (dns53 挂了 → 原生直跑 = DNS 全挂)。
        __dns_dir="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
        __alive=0
        if [ -f "$__dns_dir/.alive" ]; then
            __mt=$(stat -c %Y "$__dns_dir/.alive" 2>/dev/null || echo 0)
            [ $(( $(date +%s) - __mt )) -lt 90 ] && __alive=1
        fi
        __rmode=$(cat "$__dns_dir/.root_mode" 2>/dev/null || echo none)
        if [ "$__rmode" = none ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            __rmode=sudo
        fi
        if [ "$__rmode" != none ]; then
            # root 但 dns53 没在跑: 先按缓存的模式拉起, 起不来再走 proot
            if [ "$__alive" = 0 ] && [ -f "$__dns_dir/dns53.js" ]; then
                mkdir -p "$__dns_dir/logs"
                case "$__rmode" in
                    direct) nohup node "$__dns_dir/dns53.js" >> "$__dns_dir/logs/dns53.log" 2>&1 & ;;
                    sudo)   sudo -n nohup node "$__dns_dir/dns53.js" >> "$__dns_dir/logs/dns53.log" 2>&1 & ;;
                    su)     su -c "${PREFIX:-/data/data/com.termux/files/usr}/bin/node $__dns_dir/dns53.js >> $__dns_dir/logs/dns53.log 2>&1 &" ;;
                esac
                sleep 1
                if [ -f "$__dns_dir/.alive" ]; then
                    __mt=$(stat -c %Y "$__dns_dir/.alive" 2>/dev/null || echo 0)
                    [ $(( $(date +%s) - __mt )) -lt 90 ] && __alive=1
                fi
            fi
            if [ "$__alive" = 1 ]; then
                exec "$REAL_BIN" "$@"
            elif command -v proot >/dev/null 2>&1 && [ -f "${PREFIX}/etc/resolv.conf" ]; then
                # dns53 起不来: proot 绑实测过的 resolv.conf, 避免 127.0.0.1 全失败
                node "$__dns_dir/dns-bootstrap.js" >/dev/null 2>&1 || true
                exec proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$REAL_BIN" "$@"
            else
                echo "!! dns53 未运行且无法用 proot 兜底, 直接启动 (DNS 可能失效)" >&2
                exec "$REAL_BIN" "$@"
            fi
        elif command -v proot >/dev/null 2>&1; then
            exec proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$REAL_BIN" "$@"
        else
            exec "$REAL_BIN" "$@"
        fi
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER_PATH"

    ensure_path_rc

    # PATH 陷阱: 官方安装脚本 (opencode.ai/install) 创建的 ~/.opencode/bin
    # 排在 PATH 前面, 里面可能是跑不起来的 glibc 版; 换成 wrapper 副本
    if [ -d "$HOME_DIR/.opencode/bin" ]; then
        if [ -x "$HOME_DIR/.opencode/bin/opencode" ]; then
            if ! head -1 "$HOME_DIR/.opencode/bin/opencode" | grep -q 'opencode wrapper'; then
                warn "检测到官方脚本残留 (~/.opencode/bin/opencode, 非 wrapper), 替换…"
            fi
            cp "$WRAPPER_PATH" "$HOME_DIR/.opencode/bin/opencode"
            chmod +x "$HOME_DIR/.opencode/bin/opencode"
            info "已同步 wrapper 到 ~/.opencode/bin (PATH 陷阱修复)"
        fi
    fi
    ok "启动 wrapper 已生成: $WRAPPER_PATH"
}

# ---------- 验证 ----------
verify() {
    local ver
    ver=$(PATH="$HOME_DIR/.local/bin:$PATH" "$WRAPPER_PATH" --version 2>/dev/null) \
        || fail "验证失败: opencode 无法运行"
    ok "安装成功: $ver"
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 OpenCode 并移除 wrapper…"
    rm -f "$WRAPPER_PATH"
    rm -rf "$OPENCODE_DIR"
    if [ -d "$HOME_DIR/.opencode/bin" ]; then
        rm -f "$HOME_DIR/.opencode/bin/opencode"
    fi
    ok "已卸载"
    warn "DNS 转发器 (dns53) 已保留 — codex 等其他 musl 程序可能依赖它"
    warn "如需一并移除: bash ~/.local/share/dns53/install.sh --uninstall (或 rm -rf ~/.local/share/dns53)"
    exit 0
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步: 配置模型"
    echo "=============================================================="
    echo
    echo "  OpenCode 支持 Anthropic 兼容端点 (DeepSeek 提供):"
    echo "    export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic"
    echo "    export ANTHROPIC_AUTH_TOKEN=sk-你的APIKey"
    echo "    export ANTHROPIC_MODEL=deepseek-v4-flash"
    echo "    (持久化: 追加到 ~/.bashrc; zsh 用户为 ~/.zshrc)"
    echo
    echo "  常用命令:"
    echo "    opencode                  启动"
    echo "    opencode update           更新到最新版"
    echo "    opencode update --force   已最新也强制重装"
    echo "    重跑本脚本即更新           (bash <(curl -fsSL …/install.sh))"
    echo "    重跑本脚本 --uninstall    卸载"
    echo
    echo "  安装完成后请退出 Termux 重新打开 (或新开一个会话), 让 PATH 生效。"
    echo
    echo "  建议的 Android 设置 (防止 Termux 被系统杀后台):"
    echo "    1. 开发者选项 → 停止限制子进程: 开启"
    echo "    2. 系统设置 → 应用 → Termux → 电池: 不优化"
    echo "    3. 后台活动 / 自启动: 设为无限制"
    echo
    echo "  官方文档: https://opencode.ai/docs"
    echo "=============================================================="
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "opencode-termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
install_dependencies
install_musl_libs
fix_dns
install_opencode
write_wrapper
verify
show_guide
