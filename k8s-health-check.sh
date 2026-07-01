#!/usr/bin/env bash
# ================================================================
# K8s 集群健康巡检脚本 v1.0
# 用法: ./k8s-health-check.sh [--output report.md] [--namespace N]
# 要求: kubectl + jq 已安装, kubeconfig 已配置
# ================================================================
# set -euo pipefail  # 注释掉，改用手动错误处理避免 kubectl 超时导致脚本退出
set -uo pipefail

OUTPUT_FILE=""
TARGET_NS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT_FILE="$2"; shift 2 ;;
    --namespace|-n) TARGET_NS="$2"; shift 2 ;;
    --help|-h) echo "用法: $0 [--output report.md] [--namespace N]" ; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo_section()  { echo -e "\n${CYAN}═══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; }
echo_ok()       { echo -e "  ${GREEN}✓${NC} $1"; }
echo_warn()     { echo -e "  ${YELLOW}⚠ $1${NC}"; }
echo_err()      { echo -e "  ${RED}✗ $1${NC}"; }

# ── 收集结果 ──
REPORT_LINES=()
REPORT_LINES+=("# K8s 集群健康巡检报告")
REPORT_LINES+=("")
REPORT_LINES+=("- 巡检时间: $(date '+%Y-%m-%d %H:%M:%S')")
REPORT_LINES+=("- 集群信息: $(kubectl cluster-info --request-timeout=5s 2>/dev/null | head -1 || echo '无法获取')")
TOTAL_ISSUES=0
CRITICAL=0; WARNINGS=0; PASS=0

add_to_report() { REPORT_LINES+=("$1"); }

check_kubeconfig() {
  echo_section "🔑 集群连接检查"
  if kubectl version --request-timeout=5s &>/dev/null; then
    local sv=$(kubectl version --request-timeout=5s -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('serverVersion',{}).get('gitVersion','?'))" 2>/dev/null || echo "unknown")
    echo_ok "K8s API 正常连接 (${sv})"
    add_to_report "- K8s 版本: ${sv}"
    ((PASS++))
  else
    echo_err "无法连接集群，请检查 kubeconfig"
    add_to_report "- ⚠ 无法连接集群，请检查 kubeconfig"
    ((CRITICAL++))
    exit 1
  fi
}

check_node_health() {
  echo_section "🖥️ 节点健康检查"
  local nodes=$(kubectl get nodes -o json 2>/dev/null)
  local total=$(echo "$nodes" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['items']))" 2>/dev/null || echo 0)
  local ready=$(echo "$nodes" | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for n in d['items'] if any(s['type']=='Ready' and s['status']=='True' for s in n['status']['conditions'])))" 2>/dev/null || echo 0)
  local not_ready=$(( total - ready ))

  echo_ok "节点总数: ${total}"
  echo_ok "Ready 节点: ${ready}"
  add_to_report "- 节点总数: ${total}, Ready: ${ready}"

  if [[ "$not_ready" -gt 0 ]]; then
    echo_err "${not_ready} 个节点 NotReady!"
    local nr_names=$(echo "$nodes" | python3 -c "
import sys,json; d=json.load(sys.stdin)
for n in d['items']:
    if not any(s['type']=='Ready' and s['status']=='True' for s in n['status']['conditions']):
        print('  -', n['metadata']['name'])
" 2>/dev/null)
    echo "$nr_names"
    add_to_report "- ⚠ NotReady 节点:"
    add_to_report "  ${nr_names//$'\n'/$'\n'  }"
    ((CRITICAL+=not_ready))
  fi

  # 检查节点资源压力
  local pressure=$(echo "$nodes" | python3 -c "
import sys,json; d=json.load(sys.stdin)
for n in d['items']:
    conds = {c['type']:c['status'] for c in n['status'].get('conditions',[])}
    for p in ['DiskPressure','MemoryPressure','PIDPressure']:
        if conds.get(p) == 'True':
            print(f'  {n[\"metadata\"][\"name\"]}: {p}')
            break
" 2>/dev/null)
  if [[ -n "$pressure" ]]; then
    echo_warn "节点存在资源压力:"
    echo "$pressure"
    add_to_report "- ⚠ 节点资源压力:"
    add_to_report "  ${pressure//$'\n'/$'\n'  }"
    ((WARNINGS++))
  fi

  # 检查 kubelet 版本一致性
  local versions=$(echo "$nodes" | python3 -c "
import sys,json; d=json.load(sys.stdin)
vers = set()
for n in d['items']:
    v = n['status'].get('nodeInfo',{}).get('kubeletVersion','?')
    vers.add(v)
for v in sorted(vers): print(v)
" 2>/dev/null)
  local vcount=$(echo "$versions" | wc -l)
  if [[ "$vcount" -gt 1 ]]; then
    echo_warn "kubelet 版本不一致 (${vcount} 个不同版本):"
    echo "$versions" | while read v; do echo "  - $v"; done
    add_to_report "- ⚠ kubelet 版本不一致: ${versions//$'\n'/, }"
    ((WARNINGS++))
  fi

  ((PASS++))
}

check_pod_health() {
  echo_section "📦 Pod 状态检查"
  local ns_flag="${TARGET_NS:+--all-namespaces}"
  [[ -n "$TARGET_NS" ]] && ns_flag="-n $TARGET_NS"

  local all_pods=$(kubectl get pods ${ns_flag} -o json --request-timeout=10s 2>/dev/null)
  local total=$(echo "$all_pods" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo 0)

  if [[ "$total" -eq 0 ]]; then
    echo_warn "未找到任何 Pod"
    return
  fi

  echo_ok "Pod 总数: ${total}"

  # 异常 Pod
  local bad_pods=$(echo "$all_pods" | python3 -c "
import sys,json; d=json.load(sys.stdin)
for p in d.get('items',[]):
    ns=p['metadata']['namespace']
    name=p['metadata']['name']
    status=p['status']['phase']
    if status in ('Pending','Unknown','Failed'):
        print(f'{ns}/{name}  status={status}')
" 2>/dev/null)

  if [[ -n "$bad_pods" ]]; then
    local bad_count=$(echo "$bad_pods" | wc -l)
    echo_err "${bad_count} 个异常 Pod:"
    echo "$bad_pods"
    add_to_report "- ⚠ 异常 Pod: ${bad_count}"
    add_to_report "  ${bad_pods//$'\n'/$'\n'  }"
    ((CRITICAL+=bad_count))
  fi

  # CrashLoopBackOff
  local crash=$(echo "$all_pods" | python3 -c "
import sys,json; d=json.load(sys.stdin)
for p in d.get('items',[]):
    for cs in p['status'].get('containerStatuses',[]):
        if cs.get('state',{}).get('waiting',{}).get('reason') in ('CrashLoopBackOff','Error','ImagePullBackOff','CreateContainerConfigError'):
            print(f'{p[\"metadata\"][\"namespace\"]}/{p[\"metadata\"][\"name\"]}  {cs[\"name\"]}  {cs[\"state\"][\"waiting\"][\"reason\"]}')
" 2>/dev/null)

  if [[ -n "$crash" ]]; then
    local crash_count=$(echo "$crash" | wc -l)
    echo_err "${crash_count} 个容器状态异常:"
    echo "$crash"
    add_to_report "- 🔴 CrashLoop/异常容器: ${crash_count}"
    add_to_report "  ${crash//$'\n'/$'\n'  }"
    ((CRITICAL+=crash_count))
  fi

  # OOMKilled / 重启次数
  local restart_high=$(echo "$all_pods" | python3 -c "
import sys,json; d=json.load(sys.stdin)
for p in d.get('items',[]):
    for cs in p['status'].get('containerStatuses',[]):
        r=cs.get('restartCount',0)
        lr=cs.get('lastState',{}).get('terminated',{}).get('reason','')
        if r >= 5:
            print(f'{p[\"metadata\"][\"namespace\"]}/{p[\"metadata\"][\"name\"]}  {cs[\"name\"]}  重启={r}  上次终止={lr}')
" 2>/dev/null)

  if [[ -n "$restart_high" ]]; then
    echo_warn "容器频繁重启 (≥5次):"
    echo "$restart_high"
    add_to_report "- ⚠ 容器频繁重启 (≥5次):"
    add_to_report "  ${restart_high//$'\n'/$'\n'  }"
    ((WARNINGS++))
  fi

  if [[ -z "$bad_pods" && -z "$crash" && -z "$restart_high" ]]; then
    echo_ok "所有 Pod 状态正常"
    add_to_report "- ✅ 所有 Pod 状态正常"
  fi

  ((PASS++))
}

check_resource_usage() {
  echo_section "📊 资源使用情况"

  # 节点资源概览（从 top 节点获取，或 fallback）
  local top_data=""
  top_data=$(kubectl top nodes --request-timeout=5s --no-headers 2>/dev/null | head -20) || true
  if [[ -n "$top_data" ]]; then
    echo_ok "节点资源使用率:"
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        echo "    $line"
      fi
    done <<< "$top_data"
    add_to_report "- 节点资源使用率:"
    add_to_report '```'
    add_to_report "$top_data"
    add_to_report '```'
  else
    echo_warn "metrics-server 不可用，跳过资源使用率检查"
    add_to_report "- ⚠ metrics-server 不可用，无法获取资源使用率"
    ((WARNINGS++))
  fi

  # 检查 Pending PVC
  local pending_pvc=$(kubectl get pvc --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
for p in d.get('items',[]):
    if p['status']['phase'] == 'Pending':
        print(f'{p[\"metadata\"][\"namespace\"]}/{p[\"metadata\"][\"name\"]}  {p[\"spec\"].get(\"storageClassName\",\"<none>\")}')
" 2>/dev/null)

  if [[ -n "$pending_pvc" ]]; then
    echo_warn "Pending PVC 未绑定:"
    echo "$pending_pvc"
    add_to_report "- ⚠ Pending PVC:"
    add_to_report "  ${pending_pvc//$'\n'/$'\n'  }"
    ((WARNINGS++))
  fi

  ((PASS++))
}

check_event_anomalies() {
  echo_section "🚨 近期异常事件"
  local events=$(kubectl get events --all-namespaces --field-selector type=Warning --sort-by=.lastTimestamp -o json 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
items = d.get('items',[])
# 取最近 20 条
for e in items[-20:]:
    ts = e.get('lastTimestamp', e.get('eventTime', ''))[:19]
    ns = e['metadata']['namespace']
    reason = e.get('reason','?')
    obj = e.get('involvedObject',{}).get('kind','?') + '/' + e.get('involvedObject',{}).get('name','?')
    msg = e.get('message','')[:100]
    print(f'{ts}  {ns}  {reason}  {obj}  {msg}')
" 2>/dev/null)

  if [[ -n "$events" ]]; then
    local event_count=$(echo "$events" | wc -l)
    echo_warn "发现 ${event_count} 条 Warning 事件 (最近 20 条):"
    echo "$events"
    add_to_report "- ⚠ Warning 事件 (最近 ${event_count} 条):"
    add_to_report '```'
    add_to_report "$events"
    add_to_report '```'
    ((WARNINGS++))
  else
    echo_ok "无异常事件"
    add_to_report "- ✅ 无异常事件"
  fi

  ((PASS++))
}

check_security() {
  echo_section "🔒 安全基线检查"

  # 检查是否有 Pod 以特权模式运行
  local priv=$(kubectl get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
for p in d.get('items',[]):
    for c in p['spec'].get('containers',[]):
        sc = c.get('securityContext',{})
        if sc.get('privileged') == True:
            print(f'{p[\"metadata\"][\"namespace\"]}/{p[\"metadata\"][\"name\"]}  {c[\"name\"]}')
            break
" 2>/dev/null)

  if [[ -n "$priv" ]]; then
    echo_warn "特权模式容器:"
    echo "$priv"
    add_to_report "- ⚠ 特权模式容器:"
    add_to_report "  ${priv//$'\n'/$'\n'  }"
    ((WARNINGS++))
  fi

  # 检查是否配置了 resource limits/requests
  local no_limits=$(kubectl get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
count=0
for p in d.get('items',[]):
    for c in p['spec'].get('containers',[]):
        r = c.get('resources',{})
        if not r.get('limits') and not r.get('requests'):
            if count < 10:
                print(f'{p[\"metadata\"][\"namespace\"]}/{p[\"metadata\"][\"name\"]}  {c[\"name\"]}')
            count+=1
if count > 10:
    print(f'... 还有 {count-10} 个')
print(f'--- 总计 {count} 个容器未设置资源限制')
" 2>/dev/null)

  if [[ -n "$no_limits" ]]; then
    echo_warn "容器未设置资源限制:"
    echo "$no_limits"
    add_to_report "- ⚠ 容器未设置 Resources 限制:"
    add_to_report "  $(echo "$no_limits" | tail -1)"
    ((WARNINGS++))
  fi

  ((PASS++))
}

check_disk_usage() {
  echo_section "💾 节点磁盘使用情况"
  # 通过 DaemonSet 或者直接 SSH 检查？这里用 kubectl 的 node 信息
  local disk_issues=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
for n in d['items']:
    for cond in n['status'].get('conditions',[]):
        if cond['type'] == 'DiskPressure' and cond['status'] == 'True':
            print(f'{n[\"metadata\"][\"name\"]}: DiskPressure')
" 2>/dev/null)

  if [[ -n "$disk_issues" ]]; then
    echo_err "节点磁盘压力:"
    echo "$disk_issues"
    add_to_report "- ⚠ 节点磁盘压力:"
    add_to_report "  ${disk_issues//$'\n'/$'\n'  }"
    ((CRITICAL++))
  else
    echo_ok "节点磁盘正常"
  fi

  ((PASS++))
}

check_helm_releases() {
  echo_section "🎛️ Helm Release 状态"
  if command -v helm &>/dev/null; then
    local releases=$(helm list --all-namespaces --failed --pending 2>/dev/null | tail -n +2)
    if [[ -n "$releases" ]]; then
      echo_warn "异常的 Helm Release:"
      echo "$releases"
      add_to_report "- ⚠ 异常的 Helm Release:"
      add_to_report '```'
      add_to_report "$releases"
      add_to_report '```'
      ((WARNINGS++))
    else
      # 正常列出
      local all_rel=$(helm list --all-namespaces 2>/dev/null | tail -n +2 | head -30)
      local rel_count=$(echo "$all_rel" | wc -l)
      echo_ok "Helm Releases: ${rel_count} 个 (全部正常)"
    fi
  else
    echo_warn "helm 命令未安装，跳过"
    add_to_report "- ⚠ helm 未安装，跳过检查"
  fi

  ((PASS++))
}

check_cert_expiry() {
  echo_section "🔐 证书过期检查"
  local expiry_info=$(kubectl get secrets --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json,base64
d=json.load(sys.stdin)
for s in d.get('items',[]):
    if s['type'] in ('kubernetes.io/tls','cert-manager.io/certificate'):
        raw = s['data'].get('tls.crt','')
        if not raw: continue
        import ssl, datetime, tempfile, os
        cert_data = base64.b64decode(raw)
        f=tempfile.NamedTemporaryFile(delete=False)
        f.write(cert_data); f.close()
        try:
            cert=ssl._sslobj._test_decode_cert(f.name)
            import subprocess
            r=subprocess.run(['openssl','x509','-enddate','-noout','-in',f.name],capture_output=True,text=True)
            print(f'{s[\"metadata\"][\"namespace\"]}/{s[\"metadata\"][\"name\"]}: {r.stdout.strip()}')
        except:
            pass
        os.unlink(f.name)
" 2>/dev/null || true)

  if [[ -n "$expiry_info" ]]; then
    echo "$expiry_info"
    add_to_report "- TSL 证书信息:"
    add_to_report "  ${expiry_info//$'\n'/$'\n'  }"
  else
    echo_ok "未发现 TLS Secret 或 cert-manager 证书（或无法解析）"
  fi

  ((PASS++))
}

# ── 生成汇总 ──
print_summary() {
  echo -e "\n${CYAN}═══════════════════════════════════════════${NC}"
  echo -e "${CYAN}  巡检总结${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════${NC}"
  echo -e "  检查项: ${PASS}"
  echo -e "  ${RED}严重问题: ${CRITICAL}${NC}"
  echo -e "  ${YELLOW}警告: ${WARNINGS}${NC}"
  echo -e "  ${GREEN}通过: ${PASS}${NC}"

  TOTAL_ISSUES=$((CRITICAL + WARNINGS))
  if [[ "$TOTAL_ISSUES" -eq 0 ]]; then
    echo -e "  ${GREEN}✅ 集群状态良好，无异常${NC}"
  elif [[ "$CRITICAL" -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ 存在 ${WARNINGS} 个警告，建议关注${NC}"
  else
    echo -e "  ${RED}🔴 存在 ${CRITICAL} 个严重问题 + ${WARNINGS} 个警告，建议尽快处理${NC}"
  fi

  add_to_report ""
  add_to_report "## 总结"
  add_to_report "- 检查项总数: ${PASS}"
  add_to_report "- 严重问题: ${CRITICAL}"
  add_to_report "- 警告: ${WARNINGS}"
  [[ "$TOTAL_ISSUES" -eq 0 ]] && add_to_report "- ✅ 集群状态良好"
  [[ "$CRITICAL" -eq 0 && "$WARNINGS" -gt 0 ]] && add_to_report "- ⚠ 存在 ${WARNINGS} 个警告，建议关注"
  [[ "$CRITICAL" -gt 0 ]] && add_to_report "- 🔴 存在 ${CRITICAL} 个严重问题，建议尽快处理"
}

# ── 主流程 ──
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     K8s 集群健康巡检工具 v1.0           ║${NC}"
echo -e "${CYAN}║     巡检时间: $(date '+%Y-%m-%d %H:%M:%S')              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"

check_kubeconfig
check_node_health
check_disk_usage
check_pod_health
check_resource_usage
check_event_anomalies
check_security
check_helm_releases
check_cert_expiry

print_summary

# ── 输出报告 ──
if [[ -n "$OUTPUT_FILE" ]]; then
  printf "%s\n" "${REPORT_LINES[@]}" > "$OUTPUT_FILE"
  echo -e "\n${GREEN}📄 报告已保存到: ${OUTPUT_FILE}${NC}"
fi
