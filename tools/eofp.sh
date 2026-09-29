#!/bin/bash
# ============================================================
# eofp — EdgeOne 节点指纹批量验证 + 是否承载你的域名
#
# 用途: 从 Shodan 下载大批 IP 后，先用本脚本确认"是不是 EdgeOne 节点"，
#       再看"是否真的承载我的域名"，避免把普通服务器/其它 CDN 混进来。
#
# 三层判定:
#   1) 默认证书指纹（无 SNI 时 EdgeOne 节点统一出示 *.cdn.myqcloud.com）
#      期望值默认: 061e3474ee9494c7f38735dd41493142efa59022d1c114bd942f1ef09fe1d581
#   2) 无 SNI 的 HTTP 响应头 Server: TencentEdgeOne（典型状态 418）
#   3) SNI=你的域名 访问 /api/__health => 200 且 body 含中转标记（真正可用）
#
# 用法:
#   eofp [-d 域名] [-F 期望证书sha256] [-t 线程] [-c 连接超时] [-M 总超时] [-o 输出] 文件...
#   eofp -d 22pp.999020.xyz /root/shodan.txt
#   cat ips.txt | eofp -d 22pp.999020.xyz -
#
# 输出:
#   IP | 默认证书sha256前16 | Server头 | 域名状态码 | 结论
#   结论: OK=指纹+域名都通 / EDGE-ONLY=是EdgeOne但不承载该域名 / NO=不是EdgeOne
# ============================================================

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

DOMAIN="${EO_DOMAIN:-22pp.999020.xyz}"
RQPATH="${EO_PATH:-/api/__health}"
MARKER="${EO_MARKER:-edgeone-xray-relay}"
EXPECT_FP="${EO_FP:-061e3474ee9494c7f38735dd41493142efa59022d1c114bd942f1ef09fe1d581}"
THREADS="${EO_THREADS:-12}"
CTMO="${EO_CONNECT_TIMEOUT:-4}"
TMO="${EO_MAX_TIME:-8}"
OUT=""
FILES=()

while [ $# -gt 0 ]; do
	case "$1" in
		-d) DOMAIN="$2"; shift 2 ;;
		-P) RQPATH="$2"; shift 2 ;;
		-m) MARKER="$2"; shift 2 ;;
		-F) EXPECT_FP="$2"; shift 2 ;;
		-t) THREADS="$2"; shift 2 ;;
		-c) CTMO="$2"; shift 2 ;;
		-M) TMO="$2"; shift 2 ;;
		-o) OUT="$2"; shift 2 ;;
		-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) FILES+=("$1"); shift ;;
	esac
done

command -v curl >/dev/null || { echo "${RED}[x] 需要 curl${NC}" >&2; exit 1; }
HAVE_SSL=1; command -v openssl >/dev/null || HAVE_SSL=0
[ "$HAVE_SSL" = 0 ] && echo "${YELLOW}[!] 没装 openssl，将跳过证书指纹（只按 Server 头判断）${NC}" >&2

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT INT TERM
LIST="$TMPD/ips.txt"; : > "$LIST"
if [ ${#FILES[@]} -eq 0 ]; then echo "${RED}[x] 没给输入文件${NC}" >&2; exit 1; fi
for f in "${FILES[@]}"; do
	if [ "$f" = "-" ]; then cat >> "$LIST"; else cat "$f" >> "$LIST" 2>/dev/null; fi
done
sed 's/\r$//; s/#.*//' "$LIST" | awk '{for(i=1;i<=NF;i++) print $i}' \
	| grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u > "$TMPD/clean.txt"
TOTAL=$(wc -l < "$TMPD/clean.txt" | tr -d ' ')
[ "$TOTAL" -eq 0 ] && { echo "${RED}[x] 没有合法 IPv4${NC}" >&2; exit 1; }

echo "${CYAN}目标域名: ${DOMAIN}${RQPATH}   期望证书指纹: ${EXPECT_FP:0:16}...   待测: ${TOTAL}${NC}"

cat > "$TMPD/w.sh" <<'WEOF'
#!/bin/bash
ip="$1"; domain="$2"; path="$3"; marker="$4"; efp="$5"; ct="$6"; mt="$7"; out="$8"; have_ssl="$9"
fp=""
if [ "$have_ssl" = "1" ]; then
	fp=$(echo | timeout "$mt" openssl s_client -connect "$ip:443" -servername "$ip" 2>/dev/null \
		| openssl x509 -noout -fingerprint -sha256 2>/dev/null \
		| sed 's/.*=//' | tr -d ':' | tr 'A-F' 'a-f')
fi
# 无 SNI 的 HTTP 探测（Shodan 视角）
hdr=$(curl -ks -D - -o /dev/null --connect-timeout "$ct" --max-time "$mt" -A 'Mozilla/5.0' "https://$ip/" 2>/dev/null)
code_ip=$(printf '%s' "$hdr" | head -1 | awk '{print $2}')
svr=$(printf '%s' "$hdr" | grep -i '^server:' | head -1 | cut -d' ' -f2- | tr -d '\r')
# SNI=域名 的真实可用性
body=$(mktemp)
code=$(curl -s -o "$body" -w '%{http_code}' --resolve "${domain}:443:${ip}" \
	--connect-timeout "$ct" --max-time "$mt" "https://${domain}${path}" 2>/dev/null)
[ -z "$code" ] && code="000"
mark=NO; grep -qF -- "$marker" "$body" 2>/dev/null && mark=YES
rm -f "$body"

is_eo=NO
[ -n "$fp" ] && [ "$fp" = "$efp" ] && is_eo=YES
case "$svr" in *TencentEdgeOne*) is_eo=YES ;; esac

verdict="NO"
if [ "$is_eo" = "YES" ]; then
	if [ "$code" = "200" ] && [ "$mark" = "YES" ]; then verdict="OK"; else verdict="EDGE-ONLY"; fi
fi
printf '%s\t%s\t%s\t%s/%s\t%s\t%s\n' "$ip" "${fp:0:16}" "${svr:--}" "$code" "$mark" "$verdict" "$code_ip" >> "$out"
WEOF
chmod +x "$TMPD/w.sh"

: > "$TMPD/res.tsv"
xargs -a "$TMPD/clean.txt" -P "$THREADS" -I{} bash "$TMPD/w.sh" {} "$DOMAIN" "$RQPATH" "$MARKER" "$EXPECT_FP" "$CTMO" "$TMO" "$TMPD/res.tsv" "$HAVE_SSL"

OK=$(awk -F'\t' '$5=="OK"' "$TMPD/res.tsv" | wc -l | tr -d ' ')
EO=$(awk -F'\t' '$5=="EDGE-ONLY"' "$TMPD/res.tsv" | wc -l | tr -d ' ')
NO=$(awk -F'\t' '$5=="NO"' "$TMPD/res.tsv" | wc -l | tr -d ' ')

echo ""
echo "${GREEN}可用(OK): ${OK}${NC}   EdgeOne但不承载域名: ${EO}   非EdgeOne: ${NO}   合计: ${TOTAL}"
echo ""
printf "%-16s %-18s %-18s %-12s %s\n" "IP" "默认证书(fp16)" "Server" "域名状态" "结论"
printf "%-16s %-18s %-18s %-12s %s\n" "----------------" "------------------" "------------------" "------------" "------"
awk -F'\t' '$5=="OK"' "$TMPD/res.tsv" | head -40 | awk -F'\t' '{printf "%-16s %-18s %-18s %-12s %s\n",$1,$2,$3,$4,$5}'
[ "$OK" -eq 0 ] && echo "  (没有 OK 的；可看下面 EDGE-ONLY 里的节点是否指纹正确)"
echo ""
awk -F'\t' '$5=="EDGE-ONLY"' "$TMPD/res.tsv" | head -10 | awk -F'\t' '{printf "%-16s %-18s %-18s %-12s %s\n",$1,$2,$3,$4,$5}'

if [ -n "$OUT" ]; then
	{
		echo "# eofp 结果  $(date '+%F %T')"
		echo "# 域名: $DOMAIN$RQPATH   期望指纹: $EXPECT_FP"
		echo "# 结论: OK=可用 / EDGE-ONLY=EdgeOne但未承载该域名 / NO=非EdgeOne"
		printf "%-16s %-18s %-18s %-12s %s\n" "IP" "fp16" "server" "code/mark" "verdict"
		awk -F'\t' '{printf "%-16s %-18s %-18s %-12s %s\n",$1,$2,$3,$4,$5}' "$TMPD/res.tsv"
	} > "$OUT"
	awk -F'\t' '$5=="OK"{print $1}' "$TMPD/res.tsv" > "${OUT%.*}-ok.txt"
	echo ""
	echo "结果文件: $OUT"
	echo "可用IP清单: ${OUT%.*}-ok.txt"
fi
