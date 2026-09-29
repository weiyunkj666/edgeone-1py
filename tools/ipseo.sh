#!/bin/bash
# ============================================================
#  ipseo — EdgeOne 中转 IP 扫描 / 优选
#
#  v1.5  命中后自动查 ipinfo 归属地/运营商（-T 传 token，或用 ~/.ipseo-tokens / $IPINFO_TOKEN）
#  v1.4  扫描过程中实时打印命中的 IP（终端彩色+进度条；重定向则纯文本行）
#
#  两种用法：
#   1) 直接运行  ipseo            → 交互模式（列出 .txt 让你选，和你原来的 ips 一样）
#   2) 带参数     ipseo 文件 [选项] → 命令行模式（可放进 crontab / 批量调用）
#
#  判定标准：SNI + Host 都是你的域名，请求 /api/__health
#    - 严格 TLS 校验（证书必须对域名有效，不加 -k）
#    - HTTP 200 且响应体含中转标记 → 该 IP 真的能把请求送进你的函数
#  = 注意：EdgeOne 按 SNI 路由，不能用 curl -k -H "Host: 域名" https://IP 的老办法
#
#  命令行选项：
#   -d 域名   -p 端口   -P 路径   -m 标记   -t 线程
#   -c 连接超时   -M 总超时   -n 限量   -D 深检条数   -u UUID
#   -o 输出目录   -k 跳过证书校验   -L 只输出IP   -q 安静
#   -T ipinfo token(逗号分隔多个; -T - 关闭归属地)   -h 帮助
# ============================================================

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'
YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

DOMAIN="${EO_DOMAIN:-22pp.999020.xyz}"      # 默认：项目二(Global，含大陆节点)
PORT="${EO_PORT:-443}"
RQPATH="${EO_PATH:-/api/__health}"
MARKER="${EO_MARKER:-edgeone-xray-relay}"
THREADS="${EO_THREADS:-12}"
CTMO="${EO_CONNECT_TIMEOUT:-4}"
TMO="${EO_MAX_TIME:-8}"
MAX_CIDR="${MAX_CIDR_IPS:-4096}"
OUTDIR="${EO_OUTDIR:-/root}"
UUID="${EO_UUID:-}"
LIMIT=0; DEEP=0; QUIET=0; INSECURE=0; LISTONLY=0
GEO_TOK=""
FILES=()

# ---------------- 参数解析 ----------------
parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			-d) DOMAIN="$2"; shift 2 ;;
			-p) PORT="$2"; shift 2 ;;
			-P) RQPATH="$2"; shift 2 ;;
			-m) MARKER="$2"; shift 2 ;;
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
			-T) GEO_TOK="$2"; shift 2 ;;
			-h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
			*) FILES+=("$1"); shift ;;
		esac
	done
}

ask() {  # ask 变量名 "提示" "默认值"
	local __v="$1" __p="$2" __d="$3" __in
	printf "  %s ${BOLD}[%s]${NC}: " "$__p" "$__d"
	read -r __in
	eval "$__v=\${__in:-$__d}"
}

# ipinfo token 自动探测: -T 参数 > $IPINFO_TOKEN > ~/.ipseo-tokens > ~/ips1.bash
detect_tokens() {
	local t="" f
	[ -n "${IPINFO_TOKEN:-}" ] && { printf '%s' "$IPINFO_TOKEN"; return; }
	for f in "$HOME/.ipseo-tokens" "$HOME/.ipinfo-tokens"; do
		[ -s "$f" ] || continue
		t=$(tr '\n' ',' < "$f" | tr -s ',' | sed 's/^,//; s/,$//')
		[ -n "$t" ] && { printf '%s' "$t"; return; }
	done
	for f in "$HOME/ips1.bash" "$HOME/ips.bash" "./ips1.bash" "./ips.bash"; do
		[ -s "$f" ] || continue
		t=$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?IPINFO_TOKEN=' "$f" 2>/dev/null | sed -e 's/^[^=]*=//' -e "s/[\"']//g" | tr -d ' \t\r')
		[ -n "$t" ] && { printf '%s' "$t"; return; }
	done
}

geo_state() {
	if [ -n "${GEO_TOK:-}" ] && [ "$GEO_TOK" != "-" ]; then
		printf '开启 (ipinfo, %s 个token)' "$(printf '%s' "$GEO_TOK" | tr ',' '\n' | grep -c .)"
	else
		printf '关闭'
	fi
}

interactive() {
	clear 2>/dev/null || true
	echo "${CYAN}============================================================${NC}"
	echo "  ${BOLD}EdgeOne 中转 IP 扫描 (ipseo)${NC}"
	echo "${CYAN}============================================================${NC}"
	echo "  当前目录: ${BOLD}$(pwd)${NC}"
	echo

	local CURDIR="$(pwd)"
	while :; do
		mapfile -t AVAIL < <(ls -1 "$CURDIR"/*.txt 2>/dev/null | sed "s|^$CURDIR/||")
		echo "  可扫描的 txt 文件 ($CURDIR):"
		if [ ${#AVAIL[@]} -eq 0 ]; then
			echo "    ${YELLOW}(没有 .txt 文件)${NC}"
		else
			local i=1
			for f in "${AVAIL[@]}"; do
				local n=0
				n=$(grep -cE '^[[:space:]]*[0-9]' "$CURDIR/$f" 2>/dev/null || echo 0)
				printf "   %2d) %-44s %7s 行\n" "$i" "$f" "$n"
				i=$((i+1))
			done
		fi
		echo
		echo "  选择: 编号(可多选, 如 1,3,5 / 1-4 / a=全部)  输入 ${BOLD}d${NC} 换目录  输入 ${BOLD}q${NC} 退出"
		printf "  ${BOLD}你的选择${NC} [1]: "
		read -r sel
		case "$sel" in
			q|Q) echo "已退出"; exit 0 ;;
			d|D)
				printf "  输入目录路径: "; read -r CURDIR
				[ -d "$CURDIR" ] || { echo "  ${RED}目录不存在${NC}"; CURDIR="$(pwd)"; }
				continue ;;
		esac
		[ -z "$sel" ] && sel="1"
		FILES=()
		if [ "$sel" = "a" ] || [ "$sel" = "A" ]; then
			for f in "${AVAIL[@]}"; do FILES+=("$CURDIR/$f"); done
		else
			local part
			for part in $(echo "$sel" | tr ',' ' '); do
				if echo "$part" | grep -qE '^[0-9]+-[0-9]+$'; then
					local a="${part%-*}" b="${part#*-}"
					local k=$a
					while [ "$k" -le "$b" ]; do
						[ -n "${AVAIL[$((k-1))]:-}" ] && FILES+=("$CURDIR/${AVAIL[$((k-1))]}")
						k=$((k+1))
					done
				elif echo "$part" | grep -qE '^[0-9]+$'; then
					[ -n "${AVAIL[$((part-1))]:-}" ] && FILES+=("$CURDIR/${AVAIL[$((part-1))]}")
				fi
			done
		fi
		[ ${#FILES[@]} -gt 0 ] && break
		echo "  ${RED}没选到有效文件，重来${NC}"; sleep 1
	done

	echo
	echo "  已选 ${BOLD}${#FILES[@]}${NC} 个文件: ${FILES[*]##*/}"
	echo "${CYAN}------------------------------------------------------------${NC}"
	ask DOMAIN   "目标域名 (项目二含大陆节点)" "$DOMAIN"
	ask PORT     "端口" "$PORT"
	ask RQPATH   "请求路径" "$RQPATH"
	ask THREADS  "线程数 (同段扫描建议 8~16)" "$THREADS"
	ask CTMO     "连接超时秒" "$CTMO"
	ask TMO      "单次总超时秒" "$TMO"
	ask DEEP     "深检条数 (对最快N个验证回源, 0=跳过)" "$DEEP"
	ask UUID     "UUID (选填, 填了会生成 v2rayNG 链接)" "$UUID"
	ask GEO_TOK  "ipinfo token (逗号分隔多个; 回车=不查归属地)" "$GEO_TOK"
	ask OUTDIR   "输出目录" "$OUTDIR"
	ask LIMIT    "随机抽样数量 (0=全部)" "$LIMIT"
	echo "${CYAN}------------------------------------------------------------${NC}"
	echo "  域名 : ${BOLD}$DOMAIN${NC}   端口: ${BOLD}$PORT${NC}   路径: ${BOLD}$RQPATH${NC}"
	echo "  标记 : ${BOLD}$MARKER${NC}   线程: ${BOLD}$THREADS${NC}   超时: 连接${CTMO}s/总${TMO}s"
	echo "  文件 : ${#FILES[@]} 个   深检: ${DEEP}   输出: ${OUTDIR}"
	echo "  归属地: $(geo_state)"
	echo
	printf "  ${BOLD}回车开始扫描${NC} (Ctrl+C 取消)..."; read -r
}

# ---------------- 采集 IP ----------------
collect() {
	TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT INT TERM
	RAW="$TMPD/raw.txt"; : > "$RAW"
	for f in "${FILES[@]}"; do
		if [ "$f" = "-" ]; then cat >> "$RAW"; else cat "$f" >> "$RAW" 2>/dev/null || echo "${YELLOW}[!] 读不到 $f${NC}" >&2; fi
	done
	sed 's/\r$//; s/#.*//' "$RAW" | tr -s ' \t' '\n' | tr -d '\r' > "$TMPD/tok.txt"
	awk '!/\//' "$TMPD/tok.txt" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u > "$TMPD/plain.txt"
	awk '/\//'   "$TMPD/tok.txt" > "$TMPD/cidrs.txt"
	if [ -s "$TMPD/cidrs.txt" ] && command -v python3 >/dev/null 2>&1; then
		python3 - "$TMPD/cidrs.txt" "$MAX_CIDR" <<'PYEOF' >> "$TMPD/plain.txt"
import ipaddress, sys
fn, cap = sys.argv[1], int(sys.argv[2])
out = []
for line in open(fn):
    line = line.strip()
    if not line: continue
    try: net = ipaddress.ip_network(line, strict=False)
    except Exception: continue
    if net.num_addresses > cap:
        sys.stderr.write("[!] 跳过超大段 %s (%d 个IP)\n" % (line, net.num_addresses)); continue
    out += [str(ip) for ip in (net.hosts() if net.num_addresses > 2 else net)]
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
PYEOF
	fi
	sort -u -o "$TMPD/plain.txt" "$TMPD/plain.txt"
	TOTAL_ALL=$(grep -c . "$TMPD/plain.txt" 2>/dev/null || echo 0)
	if [ "$LIMIT" -gt 0 ] && [ "$TOTAL_ALL" -gt "$LIMIT" ]; then
		shuf -n "$LIMIT" "$TMPD/plain.txt" > "$TMPD/scan.txt" 2>/dev/null || head -n "$LIMIT" "$TMPD/plain.txt" > "$TMPD/scan.txt"
	else
		cp "$TMPD/plain.txt" "$TMPD/scan.txt"
	fi
	TOTAL=$(grep -c . "$TMPD/scan.txt" 2>/dev/null || echo 0)
}

# ---------------- 并发探测 ----------------
scan() {
	cat > "$TMPD/w.sh" <<'WEOF'
#!/bin/bash
ip="$1"; domain="$2"; port="$3"; path="$4"; marker="$5"; ct="$6"; mt="$7"; ua="$8"; hits="$9"; donef="${10}"; insecure="${11}"; live="${12}"; geotok="${13}"; tmpd="${14}"
opts=(-sS --resolve "${domain}:${port}:${ip}" --connect-timeout "$ct" --max-time "$mt" -A "$ua")
[ "$insecure" = "1" ] && opts+=(-k)
hdr=$(mktemp); body=$(mktemp)
w=$(curl "${opts[@]}" -D "$hdr" -o "$body" -w '%{http_code}|%{time_appconnect}|%{time_total}' "https://${domain}:${port}${path}" 2>/dev/null)
[ -z "$w" ] && w="000|0|0"
code="${w%%|*}"; r="${w#*|}"; tls="${r%%|*}"; tot="${r#*|}"
ok=0
[ "$code" = "200" ] && grep -qF -- "$marker" "$body" 2>/dev/null && ok=1
svr=$(grep -i '^server:' "$hdr" 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r')
region="-"; city="-"; country="-"; org="-"; isp="-"; geostr=""
if [ "$ok" = "1" ] && [ -n "$geotok" ] && [ "$geotok" != "-" ] && [ ! -f "${tmpd}/geo.off" ]; then
	IFS=',' read -r -a TOKA <<< "$geotok"
	nt=${#TOKA[@]}; [ "$nt" -le 0 ] && nt=1
	info=""
	for attempt in 1 2; do
		idx=$(( ( ${ip##*.} + attempt ) % nt ))
		tok="${TOKA[$idx]}"
		if [ -n "$tok" ]; then u="https://ipinfo.io/${ip}?token=${tok}"; else u="https://ipinfo.io/${ip}"; fi
		info=$(curl -s --connect-timeout 3 --max-time 4 "$u" 2>/dev/null)
		if [ -n "$info" ] && ! printf '%s' "$info" | grep -q '"error"'; then break; fi
		info=""; sleep 1
	done
	if [ -n "$info" ]; then
		jf() { printf '%s' "$2" | tr -d '\n\r' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1 | tr -d '\t'; }
		region=$(jf region "$info"); city=$(jf city "$info"); country=$(jf country "$info"); org=$(jf org "$info")
		[ -z "$region" ] && region="-"; [ -z "$city" ] && city="-"
		[ -z "$country" ] && country="-"; [ -z "$org" ] && org="-"
		if [ "$region" = "-" ] && [ "$city" = "-" ] && [ "$country" = "-" ] && [ "$org" = "-" ]; then info=""; fi
	fi
	if [ -n "$info" ]; then
		case "$org" in
			*[Tt]encent*) isp="腾讯云" ;;
			*[Aa]libaba*|*aliyun*) isp="阿里云" ;;
			*"China Telecom"*|*CHINANET*|*Chinanet*) isp="电信" ;;
			*Unicom*|*UNICOM*) isp="联通" ;;
			*"China Mobile"*|*CMNET*|*CMCC*) isp="移动" ;;
			*Huawei*) isp="华为云" ;;
			*) isp="其他" ;;
		esac
		loc="${region}/${city}"
		[ "$country" = "CN" ] || loc="${country}:${loc}"
		geostr="${loc} ${isp}"
		flock 9; echo -n x >> "${tmpd}/geo.ok"; flock -u 9
	else
		region="-"; city="-"; country="-"; org="-"; isp="-"
		flock 9
		echo -n x >> "${tmpd}/geo.fail"
		gf=$(wc -c < "${tmpd}/geo.fail" 2>/dev/null | tr -d ' ')
		gs=$(wc -c < "${tmpd}/geo.ok" 2>/dev/null | tr -d ' ')
		flock -u 9
		[ "${gf:-0}" -ge 6 ] && [ "${gs:-0}" -eq 0 ] && touch "${tmpd}/geo.off"
	fi
fi
if [ "$ok" = "1" ]; then
	flock 9
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ip" "$tot" "$tls" "$svr" "$region" "$city" "$country" "$org" "$isp" >> "$hits"
	flock -u 9
	if [ -n "$geostr" ]; then
		case "$live" in
			1) printf '\r  \033[0;32m✔ 命中\033[0m  %-16s %8ss  %-20s %s\033[K\n' "$ip" "$tot" "$svr" "$geostr" ;;
			2) printf '  命中  %-16s %8ss  %-20s %s\n' "$ip" "$tot" "$svr" "$geostr" ;;
		esac
	else
		case "$live" in
			1) printf '\r  \033[0;32m✔ 命中\033[0m  %-16s %8ss  %-24s\033[K\n' "$ip" "$tot" "$svr" ;;
			2) printf '  命中  %-16s %8ss  %s\n' "$ip" "$tot" "$svr" ;;
		esac
	fi
fi
rm -f "$hdr" "$body"
echo -n x >> "$donef"
WEOF
	chmod +x "$TMPD/w.sh"
	UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
	HITS="$TMPD/hits.tsv"; DONE="$TMPD/done.cnt"; : > "$HITS"; : > "$DONE"
	: > "$TMPD/geo.ok"; : > "$TMPD/geo.fail"; rm -f "$TMPD/geo.off"
	LIVE=1
	if [ "$QUIET" -eq 1 ] || [ "$LISTONLY" -eq 1 ]; then LIVE=0
	elif [ ! -t 1 ]; then LIVE=2; fi
	[ "$LIVE" != "0" ] && echo "  开始扫描 ${BOLD}${TOTAL}${NC} 个 IP，线程 ${THREADS} 个并发 ...（命中即时打印，Ctrl+C 可中断）  归属地: $(geo_state)"
	START=$(date +%s)
	PROG_PID=""
	if [ "$LIVE" = "1" ]; then
		( while :; do
			d=$(wc -c < "$DONE" 2>/dev/null | tr -d ' ')
			h=$(grep -c . "$HITS" 2>/dev/null || echo 0)
			el=$(( $(date +%s) - START ))
			eta="--"
			[ "${d:-0}" -gt 0 ] && eta=$(( (TOTAL - d) * el / d ))s
			printf '\r  进度 %s/%s (%s%%)  命中 %s  已用 %ss  ETA %s\033[K' "${d:-0}" "$TOTAL" "$(( TOTAL > 0 ? ${d:-0} * 100 / TOTAL : 0 ))" "$h" "$el" "$eta"
			sleep 1
			[ "${d:-0}" -ge "$TOTAL" ] && break
		done ) &
		PROG_PID=$!
	fi
	xargs -a "$TMPD/scan.txt" -P "$THREADS" -I{} bash "$TMPD/w.sh" \
		{} "$DOMAIN" "$PORT" "$RQPATH" "$MARKER" "$CTMO" "$TMO" "$UA" "$HITS" "$DONE" "$INSECURE" "$LIVE" "$GEO_TOK" "$TMPD" 9>"$TMPD/hits.lock"
	[ -n "$PROG_PID" ] && { kill "$PROG_PID" 2>/dev/null; wait "$PROG_PID" 2>/dev/null; printf '\r%*s\r' 90 ''; }
	if [ -f "$TMPD/geo.off" ] && [ "$LIVE" != "0" ]; then
		echo "  ${YELLOW}[!] ipinfo 连续查询失败，本次已跳过归属地（检查网络或 token 是否有效）${NC}"
	fi
	ELAPSED=$(( $(date +%s) - START ))
	SORTED="$TMPD/sorted.tsv"
	sort -n -t$'\t' -k2,2 "$HITS" > "$SORTED" 2>/dev/null || cp "$HITS" "$SORTED"
	HITN=$(grep -c . "$SORTED" 2>/dev/null || echo 0)
}

# ---------------- 输出 ----------------
# 归属地单元格: 国内显示 省/市 运营商；境外显示 国家:省/市 运营商
geo_cell() {
	if [ -z "$1" ] || [ "$1" = "-" ]; then printf '-'; return; fi
	if [ "$3" = "CN" ] || [ -z "$3" ] || [ "$3" = "-" ]; then
		printf '%s/%s %s' "$1" "$2" "${4:--}"
	else
		printf '%s:%s/%s %s' "$3" "$1" "$2" "${4:--}"
	fi
}

report() {
	TS=$(date +%Y%m%d-%H%M%S)
	mkdir -p "$OUTDIR"
	OUT="${OUTDIR}/eo-ok-${TS}.txt"
	{
		echo "域名: $DOMAIN   端口: $PORT   路径: $RQPATH"
		echo "标记: $MARKER   线程: $THREADS   证书校验: $([ "$INSECURE" -eq 1 ] && echo 关闭 || echo 开启)"
		echo "时间: $(date '+%F %T')   输入合计: $TOTAL_ALL   实际扫描: $TOTAL   可用: $HITN   耗时: ${ELAPSED}s"
		echo "归属地: $(geo_state)"
		echo ""
		printf "%-16s %-10s %-10s %-24s %s\n" "IP" "总耗时(s)" "TLS(s)" "Server" "归属地(ipinfo)"
		echo "----------------|----------|----------|------------------------|-----------------------------------"
		while IFS=$'\t' read -r ip tot tls svr region city country org isp; do printf "%-16s %-10s %-10s %-24s %s\n" "$ip" "$tot" "$tls" "$svr" "$(geo_cell "$region" "$city" "$country" "$isp")"; done < "$SORTED"
	} > "$OUT"
	{
		echo "ip,total_s,tls_s,server,region,city,country,org,isp"
		while IFS=$'\t' read -r ip tot tls svr region city country org isp; do
			printf '%s,%s,%s,%s,%s,%s,%s,"%s",%s\n' "$ip" "$tot" "$tls" "$svr" "$region" "$city" "$country" "$org" "$isp"
		done < "$SORTED"
	} > "${OUT%.*}.csv"

	if [ "$LISTONLY" -eq 1 ]; then cut -f1 "$SORTED"; return; fi

	echo
	echo "${GREEN}============================================================${NC}"
	echo "  可用 IP: ${BOLD}${HITN}${NC} / ${TOTAL}    耗时 ${ELAPSED}s"
	echo "${GREEN}============================================================${NC}"
	if [ "$HITN" -gt 0 ]; then
		printf "  %-16s %-9s %-20s %s\n" "IP" "延迟(s)" "Server" "归属地 / 运营商"
		echo "  ---------------- --------- -------------------- ------------------------------------"
		head -n 25 "$SORTED" | while IFS=$'\t' read -r ip tot tls svr region city country org isp; do printf "  %-16s %-9s %-20s %s\n" "$ip" "$tot" "$svr" "$(geo_cell "$region" "$city" "$country" "$isp")"; done
		[ "$HITN" -gt 25 ] && echo "  ...（完整 $HITN 条见 $OUT）"
		if [ -n "${GEO_TOK:-}" ] && [ "$GEO_TOK" != "-" ]; then
			echo "  运营商分布: $(awk -F'\t' '$9!="-" && $9!="" {c[$9]++} END{for(k in c) printf "%s %d  ", k, c[k]}' "$SORTED")"
		fi
	else
		echo "  ${YELLOW}没有可用 IP。常见原因：${NC}"
		echo "   1) 这批 IP 不承载该域名（换 -d 域名，或换项目的对应池子）"
		echo "   2) 本机到这些 IP 的网络不通（换国内机器/换线路再试）"
		echo "   3) 并发太高造成误判（把线程降到 8~12）"
	fi
	echo
	echo "  结果文件: $OUT"
	echo "           ${OUT%.*}.csv"
}

deep_and_links() {
	if [ "$DEEP" -gt 0 ] && [ "$HITN" -gt 0 ]; then
		echo
		echo "${CYAN}>>> 深检前 ${DEEP} 个（?check=1 验证回源）...${NC}"
		DOK="$TMPD/dok.txt"; : > "$DOK"
		head -n "$DEEP" "$SORTED" | while IFS=$'\t' read -r ip tot tls svr; do
			b=$(curl -sS --resolve "${DOMAIN}:${PORT}:${ip}" --connect-timeout "$CTMO" --max-time $((TMO*3)) \
				-A "$UA" "https://${DOMAIN}:${PORT}${RQPATH}?check=1" 2>/dev/null)
			if printf '%s' "$b" | grep -q '"upstreamCheck"' && printf '%s' "$b" | grep -q '"ok": true'; then
				printf '%s\n' "$ip" >> "$DOK"; echo "    ${GREEN}✓${NC} $ip  回源正常"
			else
				echo "    ${YELLOW}·${NC} $ip  中转通/回源未确认"
			fi
		done
		[ -s "$DOK" ] && cp "$DOK" "$OUTDIR/eo-deep-ok-$(date +%Y%m%d-%H%M%S).txt"
	fi
	if [ -n "$UUID" ] && [ "$HITN" -gt 0 ]; then
		LF="$OUTDIR/eo-links-$(date +%Y%m%d-%H%M%S).txt"; : > "$LF"
		head -n 10 "$SORTED" | while IFS=$'\t' read -r ip tot tls svr; do
			printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&alpn=http%%2F1.1&fp=chrome&type=xhttp&host=%s&path=%%2Fapi%%2Fsession&mode=packet-up#EO-%s\n' \
				"$UUID" "$ip" "$PORT" "$DOMAIN" "$DOMAIN" "$ip" >> "$LF"
		done
		echo
		echo "${CYAN}>>> 客户端链接（前 10 个优选 IP，可直接导入 v2rayNG）:${NC}"
		cat "$LF"
		echo "  链接文件: $LF"
	fi
}

# ---------------- 主流程 ----------------
for dep in curl awk sort; do
	command -v "$dep" >/dev/null 2>&1 || { echo "${RED}[x] 缺少依赖: $dep${NC}" >&2; exit 1; }
done

[ -n "${EO_GEO_TOK:-}" ] && GEO_TOK="$EO_GEO_TOK"
[ -z "$GEO_TOK" ] && GEO_TOK="$(detect_tokens)"
if [ $# -eq 0 ]; then interactive; else parse_args "$@"; fi
[ ${#FILES[@]} -eq 0 ] && { echo "${RED}[x] 没选文件${NC}" >&2; exit 1; }

collect
[ "${TOTAL:-0}" -eq 0 ] && { echo "${RED}[x] 没有解析出合法 IPv4${NC}" >&2; exit 1; }
scan
report
deep_and_links
