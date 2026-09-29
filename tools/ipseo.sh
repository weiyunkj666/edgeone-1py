#!/bin/bash
# ============================================================
# ipseo — 批量检测「哪些 IP 能作为 EdgeOne Pages 中转入口」
#
# 与 Cloudflare 系工具的区别（重要）：
#   EdgeOne 按 SNI + Host 路由，不能像 CF 那样 curl -k -H "Host: 域名" https://IP/
#   本脚本用 --resolve 把「真实 IP」和「真实 SNI/Host」分离，等价于客户端直连该 IP
#
# 判定标准（三层，逐层更严）：
#   1) TCP+TLS 握手成功（证书必须对域名有效，不加 -k）
#   2) HTTP 200 且响应体含中转标记（默认 edgeone-xray-relay）→ 该 IP 真的能把请求送进你的函数
#   3) 可选深检（-D N）：请求 ?check=1，回源 ok → 该 IP 上整条链路（含回源）都通
#
# 用法:
#   ipseo [-d 域名] [-p 端口] [-P 路径] [-t 线程] [-c 连接超时] [-m 总超时]
#         [-n 限量] [-D 深检条数] [-u UUID] [-o 输出目录] [-k 跳过证书校验]
#         [-L 只输出IP列表] [-q 安静] 文件 [文件...]
#   也支持从标准输入读:  cat ips.txt | ipseo -
#
# 示例:
#   ipseo /root/3-9.txt
#   ipseo -t 64 -n 2000 -D 20 -u <你的UUID> /root/3-9.txt /root/ips20260301.txt
#
# 环境变量同名可覆盖默认值: EO_DOMAIN / EO_PORT / EO_PATH / EO_MARKER / EO_THREADS 等
#
# ⚠️ 并发调优（实测教训）:
#   同网段大量 IP 一起打时，线程给太猛会让连接饱和、把正常 IP 误判成失败。
#   实测同一段 508 个 IP: 40 线程 -> 只命中 5 个;  8 线程 -> 命中 507 个。
#   建议 -t 8~16；大列表先切小段跑，或分级: 先 -c 2 -M 4 粗筛，再对通过者细测。
# ============================================================

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'
YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

DOMAIN="${EO_DOMAIN:-edgeone-1py.edgeone.dev}"
PORT="${EO_PORT:-443}"
RQPATH="${EO_PATH:-/api/__health}"
MARKER="${EO_MARKER:-edgeone-xray-relay}"
SERVER_X="${EO_SERVER:-edgeone makers}"
THREADS="${EO_THREADS:-12}"
CTMO="${EO_CONNECT_TIMEOUT:-4}"
TMO="${EO_MAX_TIME:-8}"
MAX_CIDR="${MAX_CIDR_IPS:-4096}"
OUTDIR="${EO_OUTDIR:-/root}"
UUID="${EO_UUID:-}"
LIMIT=0
DEEP=0
QUIET=0
INSECURE=0
LISTONLY=0
FILES=()

while [ $# -gt 0 ]; do
	case "$1" in
		-d) DOMAIN="$2"; shift 2 ;;
		-p) PORT="$2"; shift 2 ;;
		-P) RQPATH="$2"; shift 2 ;;
		-m) MARKER="$2"; shift 2 ;;
		-s) SERVER_X="$2"; shift 2 ;;
		-t) THREADS="$2"; shift 2 ;;
		-c) CTMO="$2"; shift 2 ;;
		-M) TMO="$2"; shift 2 ;;
		-n) LIMIT="$2"; shift 2 ;;
		-D) DEEP="$2"; shift 2 ;;
		-u) UUID="$2"; shift 2 ;;
		-o) OUTDIR="$2"; shift 2 ;;
		-k) INSECURE=1; shift ;;
		-L) LISTONLY=1; shift ;;
		-q) QUIET=1; shift ;;
		-h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-|*) FILES+=("$1"); shift ;;
	esac
done

for dep in curl awk sort; do
	command -v "$dep" >/dev/null 2>&1 || { echo "${RED}[x] 缺少依赖: $dep${NC}" >&2; exit 1; }
done
[ "$PORT" = "443" ] || INSECURE_NOTE=1

TMPD=$(mktemp -d)
HITS="${TMPD}/hits.tsv"      # ip \t 总耗时 \t TLS耗时 \t server头
DONE="${TMPD}/done.cnt"
touch "$HITS" "$DONE"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# ---------------- 1. 收集 IP（支持纯IP、CIDR、带注释的文件） ----------------
RAW="${TMPD}/raw.txt"
: > "$RAW"
if [ ${#FILES[@]} -eq 0 ]; then
	echo "${RED}[x] 没给输入文件。示例: ipseo /root/3-9.txt${NC}" >&2
	exit 1
fi
for f in "${FILES[@]}"; do
	if [ "$f" = "-" ]; then cat >> "$RAW"; else cat "$f" >> "$RAW" 2>/dev/null || echo "${YELLOW}[!] 读不到 $f，跳过${NC}" >&2; fi
done

PLAIN="${TMPD}/plain.txt"; CIDRS="${TMPD}/cidrs.txt"
: > "$PLAIN"; : > "$CIDRS"
sed 's/\r$//' "$RAW" | sed 's/#.*//' | awk '{for(i=1;i<=NF;i++) print $i}' | while read -r x; do
	case "$x" in
		*/*) echo "$x" ;;
		*.*.*.*) echo "$x" ;;
	esac
done > "${TMPD}/tokens.txt"

awk '!/\//' "${TMPD}/tokens.txt" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u > "$PLAIN"
awk '/\//'   "${TMPD}/tokens.txt" > "$CIDRS"

# CIDR 展开：优先 python3（快），否则用 bash 逐段算（慢但可用）
if [ -s "$CIDRS" ]; then
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$CIDRS" "$MAX_CIDR" <<'PYEOF' >> "$PLAIN"
import ipaddress, sys
fn, cap = sys.argv[1], int(sys.argv[2])
out = []
for line in open(fn):
    line = line.strip()
    if not line: continue
    try:
        net = ipaddress.ip_network(line, strict=False)
    except Exception:
        continue
    if net.num_addresses > cap:
        sys.stderr.write("[!] 跳过超大段 %s (%d 个IP)\n" % (line, net.num_addresses))
        continue
    for ip in net.hosts() if net.num_addresses > 2 else net:
        out.append(str(ip))
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
PYEOF
	else
		echo "${YELLOW}[!] 无 python3，CIDR 段跳过${NC}" >&2
	fi
fi

sort -u -o "$PLAIN" "$PLAIN"
TOTAL_ALL=$(wc -l < "$PLAIN" | tr -d ' ')
if [ "$LIMIT" -gt 0 ] && [ "$TOTAL_ALL" -gt "$LIMIT" ]; then
	shuf -n "$LIMIT" "$PLAIN" > "${TMPD}/scan.txt" 2>/dev/null || head -n "$LIMIT" "$PLAIN" > "${TMPD}/scan.txt"
else
	cp "$PLAIN" "${TMPD}/scan.txt"
fi
TOTAL=$(wc -l < "${TMPD}/scan.txt" | tr -d ' ')

[ "$QUIET" -eq 0 ] && {
	echo "${CYAN}==============================================${NC}"
	echo "  目标域名 : ${BOLD}${DOMAIN}${NC}  (SNI + Host)"
	echo "  端口/路径: ${BOLD}${PORT}${RQPATH}${NC}"
	echo "  命中标记 : ${BOLD}${MARKER}${NC}"
	echo "  Server校验: ${BOLD}${SERVER_X:-关闭}${NC}"
	echo "  证书校验 : ${BOLD}$([ "$INSECURE" -eq 1 ] && echo '关闭(-k)' || echo '开启')${NC}"
	echo "  待测 IP  : ${BOLD}${TOTAL}${NC} (输入合计 ${TOTAL_ALL})"
	echo "  线程/超时: ${BOLD}${THREADS}${NC} / 连接${CTMO}s 总${TMO}s"
	echo "${CYAN}==============================================${NC}"
}

# ---------------- 2. 并发探测 ----------------
cat > "${TMPD}/worker.sh" <<'WEOF'
#!/bin/bash
ip="$1"; domain="$2"; port="$3"; path="$4"; marker="$5"; srv="$6"
ct="$7"; mt="$8"; ua="$9"; hits="${10}"; donef="${11}"; insecure="${12}"

opts=(-sS --resolve "${domain}:${port}:${ip}" --connect-timeout "$ct" --max-time "$mt" -A "$ua")
[ "$insecure" = "1" ] && opts+=(-k)
hdr=$(mktemp); body=$(mktemp)
w=$(curl "${opts[@]}" -D "$hdr" -o "$body" -w '%{http_code}|%{time_appconnect}|%{time_total}' \
	"https://${domain}:${port}${path}" 2>/dev/null)
[ -z "$w" ] && w="000|0|0"
code="${w%%|*}"; r="${w#*|}"; tls="${r%%|*}"; tot="${r#*|}"

ok=0
if [ "$code" = "200" ] && grep -qF -- "$marker" "$body" 2>/dev/null; then ok=1; fi
svr=$(grep -i '^server:' "$hdr" 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r')
if [ "$ok" = "1" ] && [ -n "$srv" ]; then
	case "$svr" in *"$srv"*) ;; *) ok=0 ;; esac
fi

if [ "$ok" = "1" ]; then
	flock 9
	printf '%s\t%s\t%s\t%s\n' "$ip" "$tot" "$tls" "$svr" >> "$hits"
	flock -u 9
fi
rm -f "$hdr" "$body"
echo -n x >> "$donef"
WEOF
chmod +x "${TMPD}/worker.sh"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
START=$(date +%s)

if command -v xargs >/dev/null 2>&1; then
	# 进度：后台每秒刷新
	if [ "$QUIET" -eq 0 ] && [ -t 1 ]; then
		( while :; do
			d=$(wc -c < "$DONE" 2>/dev/null | tr -d ' ')
			p=$(( TOTAL > 0 ? d * 100 / TOTAL : 0 ))
			printf "\r  %s进度: %d/%d (%d%%)%s   " "$CYAN" "$d" "$TOTAL" "$p" "$NC"
			[ "$d" -ge "$TOTAL" ] && break
			sleep 1
		done ) &
		PROG_PID=$!
	fi
	xargs -a "${TMPD}/scan.txt" -P "$THREADS" -I{} bash "${TMPD}/worker.sh" \
		{} "$DOMAIN" "$PORT" "$RQPATH" "$MARKER" "$SERVER_X" "$CTMO" "$TMO" "$UA" "$HITS" "$DONE" "$INSECURE" 9>"${TMPD}/hits.lock"
	[ -n "${PROG_PID:-}" ] && { kill "$PROG_PID" 2>/dev/null; wait "$PROG_PID" 2>/dev/null; }
else
	echo "${RED}[x] 缺少 xargs${NC}" >&2; exit 1
fi
ELAPSED=$(( $(date +%s) - START ))
[ "$QUIET" -eq 0 ] && printf "\r%s进度: %d/%d (100%%)%s\n" "$CYAN" "$TOTAL" "$TOTAL" "$NC"

# ---------------- 3. 排序 + 输出 ----------------
SORTED="${TMPD}/sorted.tsv"
sort -n -t$'\t' -k2,2 "$HITS" > "$SORTED" 2>/dev/null || cp "$HITS" "$SORTED"
HITN=$(wc -l < "$SORTED" | tr -d ' ')

TS=$(date +%Y%m%d-%H%M%S)
OUT_TXT="${OUTDIR}/eo-ok-${TS}.txt"
OUT_CSV="${OUTDIR}/eo-ok-${TS}.csv"
mkdir -p "$OUTDIR"

{
	echo "域名: ${DOMAIN}"
	echo "端口: ${PORT}"
	echo "请求路径: ${RQPATH}"
	echo "命中标记: ${MARKER}"
	[ -n "$SERVER_X" ] && echo "Server校验: ${SERVER_X}"
	echo "证书校验: $([ "$INSECURE" -eq 1 ] && echo '关闭(-k)' || echo '开启')"
	echo "检测时间: $(date '+%Y-%m-%d %H:%M:%S')"
	echo "输入合计IP: ${TOTAL_ALL}"
	echo "实际扫描: ${TOTAL}"
	echo "可用IP: ${HITN}"
	echo "线程: ${THREADS}   超时: 连接${CTMO}s/总${TMO}s   耗时: ${ELAPSED}s"
	echo ""
	printf "%-18s | %-10s | %-10s | %s\n" "IP" "总耗时(s)" "TLS(s)" "Server"
	echo "-------------------|------------|------------|--------------------"
	while IFS=$'\t' read -r ip tot tls svr; do
		printf "%-18s | %-10s | %-10s | %s\n" "$ip" "$tot" "$tls" "$svr"
	done < "$SORTED"
} > "$OUT_TXT"

{
	echo "ip,total_s,tls_s,server"
	while IFS=$'\t' read -r ip tot tls svr; do
		echo "$ip,$tot,$tls,$svr"
	done < "$SORTED"
} > "$OUT_CSV"

# ---------------- 4. 深检 + 客户端链接 ----------------
DEEP_OK="${TMPD}/deep.tsv"; : > "$DEEP_OK"
if [ "$DEEP" -gt 0 ] && [ "$HITN" -gt 0 ]; then
	[ "$QUIET" -eq 0 ] && echo "${CYAN}>>> 深检前 ${DEEP} 个（?check=1，验证回源）...${NC}"
	head -n "$DEEP" "$SORTED" | while IFS=$'\t' read -r ip tot tls svr; do
		body=$(curl -sS --resolve "${DOMAIN}:${PORT}:${ip}" --connect-timeout "$CTMO" --max-time $((TMO*3)) \
			-A "$UA" "https://${DOMAIN}:${PORT}${RQPATH}?check=1" 2>/dev/null)
		if printf '%s' "$body" | grep -q '"upstreamCheck"' && printf '%s' "$body" | grep -q '"ok": true'; then
			printf '%s\t%s\n' "$ip" "deep-ok" >> "$DEEP_OK"
			[ "$QUIET" -eq 0 ] && echo "    ${GREEN}✓${NC} ${ip}  回源正常"
		else
			[ "$QUIET" -eq 0 ] && echo "    ${YELLOW}·${NC} ${ip}  中转通但回源未验证"
		fi
	done
fi

if [ "$LISTONLY" -eq 1 ]; then
	cut -f1 "$SORTED"
else
	[ "$QUIET" -eq 0 ] && {
		echo ""
		echo "${GREEN}==============================================${NC}"
		echo "  ${BOLD}可用 IP: ${HITN} / ${TOTAL}${NC}   耗时 ${ELAPSED}s"
		echo "${GREEN}==============================================${NC}"
		if [ "$HITN" -gt 0 ]; then
			echo ""
			printf "  %-18s %-10s %s\n" "IP" "延迟(s)" "Server"
			echo "  ------------------ ---------- --------------------"
			head -n 30 "$SORTED" | while IFS=$'\t' read -r ip tot tls svr; do
				printf "  %-18s %-10s %s\n" "$ip" "$tot" "$svr"
			done
			[ "$HITN" -gt 30 ] && echo "  ...（完整 ${HITN} 条见 ${OUT_TXT}）"
		fi
		[ -s "$DEEP_OK" ] && { echo ""; echo "  ${GREEN}回源也正常的 IP${NC}:"; cut -f1 "$DEEP_OK" | sed 's/^/    /'; }
		echo ""
		echo "  结果文件:"
		echo "    ${OUT_TXT}"
		echo "    ${OUT_CSV}"
	}
fi

# 客户端链接（把 address 换成优选 IP，sni/host 仍是域名）
if [ -n "$UUID" ] && [ "$HITN" -gt 0 ]; then
	LINKFILE="${OUTDIR}/eo-links-${TS}.txt"
	: > "$LINKFILE"
	head -n 10 "$SORTED" | while IFS=$'\t' read -r ip tot tls svr; do
		printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&alpn=http%%2F1.1&fp=chrome&type=xhttp&host=%s&path=%%2Fapi%%2Fsession&mode=packet-up#EO-%s\n' \
			"$UUID" "$ip" "$PORT" "$DOMAIN" "$DOMAIN" "$ip" >> "$LINKFILE"
	done
	[ "$QUIET" -eq 0 ] && { echo ""; echo "  客户端链接（前 10 个优选 IP，可直接导入 v2rayNG）:"; cat "$LINKFILE"; }
	echo "  链接文件: ${LINKFILE}"
fi
