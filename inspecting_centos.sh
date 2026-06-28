#!/bin/bash
#=============================================
# CentOS 深度巡检脚本 → 高端 HTML 报告（含概览指标）
# 新增：标题下方仪表盘（CPU/内存/磁盘/负载/TCP/告警）
# 使用: sudo ./inspect_dashboard.sh
#=============================================

REPORT_DIR="/var/log/server_health"
mkdir -p "$REPORT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_HTML="${REPORT_DIR}/inspect_${TIMESTAMP}.html"

declare -A D

# 辅助函数
log_console() { echo -e "$1"; }
html_escape() { echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'; }

# ============ 数据收集 ============
collect_all() {
    # ---- 系统基础 ----
    D["hostname"]=$(hostname)
    D["os"]=$(cat /etc/redhat-release 2>/dev/null || echo "非CentOS")
    D["kernel"]=$(uname -r)
    D["arch"]=$(uname -m)
    D["virt"]=$(systemd-detect-virt 2>/dev/null || dmidecode -s system-manufacturer 2>/dev/null | head -1 || echo "未知")
    D["selinux"]=$(getenforce 2>/dev/null || echo "未安装")
    D["firewalld"]=$(systemctl is-active firewalld 2>/dev/null || echo "inactive")
    D["current_user"]=$(whoami)
    D["timezone"]=$(timedatectl 2>/dev/null | grep "Time zone" | awk -F: '{print $2}' | xargs || cat /etc/timezone 2>/dev/null || echo "未知")
    D["uptime_str"]=$(uptime -p | sed 's/^up //')
    D["boot_time"]=$(who -b | awk '{print $3, $4}')
    D["cpu_model"]=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
    D["cpu_cores"]=$(nproc)
    D["load_1min"]=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    D["mem_total"]=$(free -h | awk '/^Mem:/{print $2}')
    D["mem_used"]=$(free -h | awk '/^Mem:/{print $3}')
    D["mem_avail"]=$(free -h | awk '/^Mem:/{print $7}')
    D["swap_total"]=$(free -h | awk '/^Swap:/{print $2}')
    D["swap_used"]=$(free -h | awk '/^Swap:/{print $3}')
    D["ip_address"]=$(hostname -I 2>/dev/null | awk '{print $1}')
    D["gateway"]=$(ip route | grep default | awk '{print $3}' | head -1)
    D["total_procs"]=$(ps -e | wc -l)
    D["total_threads"]=$(ps -eLf | wc -l)

    # ---- 概览仪表盘所需指标 ----
    # CPU 使用率 (%)
    read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    cpu_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    cpu_idle=$idle
    if [ "$cpu_total" -gt 0 ]; then
        D["cpu_usage"]=$(awk -v idle=$cpu_idle -v total=$cpu_total 'BEGIN{printf "%.1f", 100 - idle * 100 / total}')
    else
        D["cpu_usage"]="0.0"
    fi
    # 内存使用率 (%)
    D["mem_usage"]=$(free | awk '/^Mem:/{printf "%.1f", $3/$2*100}')
    # 磁盘使用率 (取根分区或最大值)
    disk_pct=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ -z "$disk_pct" ]; then
        disk_pct=$(df -h | grep -vE 'tmpfs|cdrom|loop|overlay|Filesystem' | awk '{print $5}' | sed 's/%//' | sort -rn | head -1)
    fi
    D["disk_usage"]="${disk_pct:-0}"
    # 负载占比 = (1min负载 / 核心数) * 100
    load_percent=$(awk -v load="${D["load_1min"]}" -v cores="${D["cpu_cores"]}" 'BEGIN{printf "%.1f", load / cores * 100}')
    D["load_percent"]="$load_percent"
    # TCP 连接数 (ESTABLISHED)
    D["tcp_estab"]=$(ss -tan state established 2>/dev/null | wc -l)
    # 告警计数（后面统一计算）

    # ---- CPU & 内存 TOP ----
    D["top_mem"]=$(ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "%s|%s|%s\n", $1, $4"%", $NF}')

    # ---- 磁盘 & Inode ----
    D["disk_table"]=$(df -h | grep -vE '^Filesystem|tmpfs|cdrom|loop' | awk '{printf "%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6}')
    D["inode_table"]=$(df -i | grep -vE '^Filesystem|tmpfs|cdrom|loop' | awk '{printf "%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6}')

    # ---- 网络 ----
    D["iface_stats"]=$(ip -s link | awk '/^[0-9]+:/{gsub(/:/,"",$2); iface=$2} /RX:/{rx=$2} /TX:/{tx=$2; printf "%s|%s|%s\n", iface, rx, tx}')
    D["routes"]=$(ip route | head -5)
    D["tcp_states"]=$(ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn | awk '{printf "%s|%s\n", $2, $1}')

    # ---- 内核参数 ----
    D["tcp_max_syn_backlog"]=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "N/A")
    D["tcp_tw_reuse"]=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo "N/A")
    D["tcp_fin_timeout"]=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "N/A")
    D["tcp_keepalive_time"]=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "N/A")
    D["netdev_max_backlog"]=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "N/A")
    D["swappiness"]=$(sysctl -n vm.swappiness 2>/dev/null || echo "N/A")
    D["file_max"]=$(sysctl -n fs.file-max 2>/dev/null || echo "N/A")

    # ---- 文件句柄 ----
    D["fs_used"]=$(sysctl fs.file-nr | awk '{print $3}')
    D["fs_max"]=$(sysctl fs.file-max | awk '{print $3}')
    D["ulimit_n"]=$(ulimit -n)
    D["fd_top5"]=$(for pid in $(ps -eo pid --sort=-%mem | head -6 | tail -5); do
        if [ -d "/proc/$pid/fd" ]; then
            fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
            comm=$(cat /proc/$pid/comm 2>/dev/null)
            echo "$pid|$comm|$fds"
        fi
    done)

    # ---- 进程负载 ----
    D["cpu_top5"]=$(ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "%s|%s|%s\n", $1, $3"%", $NF}')
    D["etime_top5"]=$(ps -eo user,etime,comm --sort=-etime | head -6 | tail -5 | awk '{printf "%s|%s|%s\n", $1, $2, $3}')

    # ---- 关键服务 ----
    services_raw=$(for svc in sshd crond nginx mysqld mariadb docker firewalld chronyd; do
        active=$(systemctl is-active $svc 2>/dev/null || echo "inactive")
        enabled=$(systemctl is-enabled $svc 2>/dev/null || echo "disabled")
        echo "$svc|$active|$enabled"
    done)
    D["services"]=$services_raw
    D["failed_units"]=$(systemctl --failed --no-legend 2>/dev/null || echo "")

    # ---- Docker ----
    if command -v docker &>/dev/null; then
        D["docker_ver"]=$(docker --version | awk '{print $3}' | sed 's/,//')
        D["docker_running"]=$(docker ps -q | wc -l)
        D["docker_total"]=$(docker ps -a -q | wc -l)
        D["docker_stopped"]=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | head -5 | paste -sd ',')
    else
        D["docker_ver"]="未安装"
    fi

    # ---- 安全检查 ----
    D["empty_pass"]=$(awk -F: '($2 == "" && $7 !~ /nologin|false/) {print $1}' /etc/shadow | paste -sd ',')
    D["uid0_users"]=$(awk -F: '($3 == 0) {print $1}' /etc/passwd | grep -v "^root$" | paste -sd ',')
    D["ssh_permit_root"]=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}' || echo "未配置")
    D["ssh_password_auth"]=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}' || echo "未配置")
    D["root_cron"]=$(crontab -l 2>/dev/null | grep -v "^#" | head -10)

    # ---- 大文件 ----
    D["big_files"]=$(find / -type f -size +100M -exec ls -lh {} \; 2>/dev/null | sort -k5 -rh | head -10 | awk '{print $5, $NF}' | paste -sd '|')

    # ---- 日志 ----
    D["journal_errors"]=$(journalctl -p err -b --no-pager 2>/dev/null | tail -10)
    D["messages_errors"]=$(grep -i "error\|fail\|critical" /var/log/messages 2>/dev/null | tail -5)

    # ---- 计算告警数量 ----
    warn=0
    # 负载过高 (负载率 > 100%)
    if (( $(echo "${D["load_percent"]} > 100" | bc -l) )); then warn=$((warn+1)); fi
    # 内存使用率 > 80%
    if (( $(echo "${D["mem_usage"]} > 80" | bc -l) )); then warn=$((warn+1)); fi
    # Swap 使用率 > 10% (如果有swap)
    if [ "${D["swap_total"]}" != "0B" ]; then
        swap_pct=$(free | awk '/^Swap:/{if($2>0) printf "%.0f", $3/$2*100; else print 0}')
        if [ "$swap_pct" -gt 10 ] 2>/dev/null; then warn=$((warn+1)); fi
    fi
    # 磁盘使用率 > 80%
    if [ "${D["disk_usage"]}" -gt 80 ] 2>/dev/null; then warn=$((warn+1)); fi
    # 空口令账号存在
    [ -n "${D["empty_pass"]}" ] && warn=$((warn+1))
    # UID0 非root账号存在
    [ -n "${D["uid0_users"]}" ] && warn=$((warn+1))
    # SELinux 非 Enforcing
    [ "${D["selinux"]}" != "Enforcing" ] && warn=$((warn+1))
    # 防火墙未运行
    [ "${D["firewalld"]}" != "active" ] && warn=$((warn+1))
    # 存在失败服务
    [ -n "${D["failed_units"]}" ] && warn=$((warn+1))
    # Docker (如果安装) 有停止的容器
    if [ "${D["docker_ver"]}" != "未安装" ]; then
        [ -n "${D["docker_stopped"]}" ] && warn=$((warn+1))
    fi
    D["warnings"]=$warn
    # MySQL 深度巡检
    collect_mysql
}

# ============ MySQL 深度巡检（非明文登录） ============
collect_mysql() {
    D["mysql_available"]="false"
    D["mysql_error_msg"]=""
    if ! command -v mysql &>/dev/null; then
        D["mysql_error_msg"]="未安装 MySQL 客户端 (mysql command not found)"
        return 1
    fi
    MYSQL_CMD="mysql --login-path=health_check --port=3060 --connect-timeout=5 -NB"
    if ! $MYSQL_CMD -e "SELECT 1" &>/dev/null; then
        D["mysql_error_msg"]="连接失败，请确认已执行 'mysql_config_editor set --login-path=health_check --host=localhost --user=监控用户 --password' 并授予必要权限"
        return 1
    fi
    D["mysql_available"]="true"
    D["mysql_version"]=$($MYSQL_CMD -e "SELECT VERSION();" 2>/dev/null)
    D["mysql_uptime"]=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Uptime';" | awk '{print $2}')
    D["mysql_threads_connected"]=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';" | awk '{print $2}')
    D["mysql_max_connections"]=$($MYSQL_CMD -e "SHOW GLOBAL VARIABLES LIKE 'max_connections';" | awk '{print $2}')
    D["mysql_slow_queries"]=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Slow_queries';" | awk '{print $2}')
    D["mysql_slow_query_log"]=$($MYSQL_CMD -e "SHOW GLOBAL VARIABLES LIKE 'slow_query_log';" | awk '{print $2}')
    D["mysql_long_query_time"]=$($MYSQL_CMD -e "SHOW GLOBAL VARIABLES LIKE 'long_query_time';" | awk '{print $2}')
    
    innodb_read_requests=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read_requests';" | awk '{print $2}')
    innodb_reads=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_reads';" | awk '{print $2}')
    if [[ -n "$innodb_read_requests" && "$innodb_read_requests" -gt 0 ]]; then
        hitrate=$(echo "scale=2; ( $innodb_read_requests - ${innodb_reads:-0} ) * 100 / $innodb_read_requests" | bc)
        D["mysql_innodb_hitrate"]="${hitrate}%"
    else
        D["mysql_innodb_hitrate"]="N/A"
    fi
    D["mysql_innodb_buffer_pool_size"]=$($MYSQL_CMD -e "SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';" | awk '{print $2}' | numfmt --to=iec 2>/dev/null || echo "N/A")
    
    qcache_hits=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Qcache_hits';" 2>/dev/null | awk '{print $2}')
    com_select=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Com_select';" 2>/dev/null | awk '{print $2}')
    if [[ -n "$qcache_hits" && -n "$com_select" && $((${com_select:-0} + ${qcache_hits:-0})) -gt 0 ]]; then
        qc_hit=$(echo "scale=2; ${qcache_hits:-0} * 100 / (${com_select:-0} + ${qcache_hits:-0})" | bc)
        D["mysql_qcache_hitrate"]="${qc_hit}%"
    else
        D["mysql_qcache_hitrate"]="未启用或不支持"
    fi
    
    connections=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Connections';" | awk '{print $2}')
    threads_created=$($MYSQL_CMD -e "SHOW GLOBAL STATUS LIKE 'Threads_created';" | awk '{print $2}')
    if [[ -n "$connections" && "$connections" -gt 0 ]]; then
        thread_hit=$(echo "scale=2; ( $connections - ${threads_created:-0} ) * 100 / $connections" | bc)
        D["mysql_thread_hitrate"]="${thread_hit}%"
    else
        D["mysql_thread_hitrate"]="N/A"
    fi
    
    D["mysql_db_total_size"]="$($MYSQL_CMD -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) FROM information_schema.tables;" 2>/dev/null) MB"
    D["mysql_lock_waits"]=$($MYSQL_CMD -e "SELECT COUNT(*) FROM information_schema.INNODB_LOCK_WAITS;" 2>/dev/null)
    D["mysql_long_trx_count"]=$($MYSQL_CMD -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' AND TIME > 60;" 2>/dev/null)
    
    slave_data=$($MYSQL_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if echo "$slave_data" | grep -q "Slave_IO_Running:"; then
        io_running=$(echo "$slave_data" | awk '/Slave_IO_Running:/ {print $2}')
        sql_running=$(echo "$slave_data" | awk '/Slave_SQL_Running:/ {print $2}')
        seconds_behind=$(echo "$slave_data" | awk '/Seconds_Behind_Master:/ {print $2}')
        D["mysql_slave_io"]="$io_running"
        D["mysql_slave_sql"]="$sql_running"
        D["mysql_slave_delay"]="${seconds_behind:-NULL}"
        D["mysql_slave_status"]=$([[ "$io_running" == "Yes" && "$sql_running" == "Yes" ]] && echo "运行正常" || echo "异常")
    else
        D["mysql_slave_status"]="未配置从库"
        D["mysql_slave_delay"]="N/A"
    fi
    if [[ -n "${D["mysql_max_connections"]}" && "${D["mysql_max_connections"]}" -gt 0 ]]; then
        conn_pct=$(echo "scale=1; ${D["mysql_threads_connected"]:-0} * 100 / ${D["mysql_max_connections"]}" | bc)
        D["mysql_conn_usage"]="${conn_pct}%"
    else
        D["mysql_conn_usage"]="N/A"
    fi
}

# ============ HTML 渲染 ============
generate_html() {
    cat > "$REPORT_HTML" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>服务器深度巡检报告</title>
<style>
  :root {
    --bg: #f0f4f8;
    --card-bg: rgba(255,255,255,0.85);
    --primary: #2c3e50;
    --accent: #3498db;
    --success: #27ae60;
    --warning: #f39c12;
    --danger: #e74c3c;
    --text: #2d3436;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body {
    font-family: 'Inter', 'Segoe UI', 'Microsoft YaHei', sans-serif;
    background: linear-gradient(135deg, #e8ecf1 0%, #dce3ea 100%);
    min-height: 100vh;
    padding: 10px 20px;
    color: var(--text);
  }
  .container {
    max-width: 1300px;
    margin: 0 auto;
  }
  .header {
    background: rgba(255,255,255,0.7);
    backdrop-filter: blur(20px);
    border: 1px solid rgba(255,255,255,0.5);
    border-radius: 24px;
    padding: 30px 40px;
    margin-bottom: 20px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.05);
  }
  .header h1 {
    font-size: 32px;
    font-weight: 700;
    background: linear-gradient(135deg, #2c3e50, #3498db);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    text-align: center;
  }
  .header .meta {
    margin-top: 12px;
    font-size: 15px;
    color: #636e72;
    display: flex;
    gap: 30px;
    flex-wrap: wrap;
    justify-content: center;
  }
  .metrics-row {
    display: flex;
    gap: 15px;
    margin-bottom: 20px;
    flex-wrap: wrap;
  }
  .metric-card {
    flex: 1 1 150px;
    background: rgba(255,255,255,0.7);
    backdrop-filter: blur(10px);
    border: 1px solid rgba(255,255,255,0.6);
    border-radius: 16px;
    padding: 15px 18px;
    text-align: center;
    box-shadow: 0 4px 15px rgba(0,0,0,0.04);
    transition: transform 0.2s;
  }
  .metric-card:hover {
    transform: translateY(-3px);
  }
  .metric-card .value {
    font-size: 32px;
    font-weight: 700;
    color: var(--accent);
    margin: 5px 0;
  }
  .metric-card .label {
    font-size: 13px;
    color: #636e72;
    margin-bottom: 5px;
  }
  .progress {
    height: 6px;
    background: rgba(0,0,0,0.08);
    border-radius: 3px;
    margin-top: 8px;
    overflow: hidden;
  }
  .progress-bar {
    height: 100%;
    border-radius: 3px;
    background: linear-gradient(90deg, #3498db, #2ecc71);
  }
  .progress-bar.warn {
    background: linear-gradient(90deg, #f39c12, #e67e22);
  }
  .progress-bar.danger {
    background: linear-gradient(90deg, #e74c3c, #c0392b);
  }
  .tabs {
    display: flex;
    gap: 15px;
    margin-bottom: 20px;
    flex-wrap: wrap;
    justify-content: center;
  }
  .tabs button {
    padding: 12px 28px;
    border: none;
    border-radius: 30px;
    font-size: 15px;
    font-weight: 600;
    background: rgba(255,255,255,0.6);
    backdrop-filter: blur(10px);
    color: #636e72;
    cursor: pointer;
    transition: all 0.3s ease;
    border: 1px solid rgba(255,255,255,0.3);
    box-shadow: 0 2px 8px rgba(0,0,0,0.03);
    width: 19%;
  }
  .tabs button:hover {
    background: rgba(255,255,255,0.9);
    color: #2c3e50;
  }
  .tabs button.active {
    background: white;
    color: var(--accent);
    border-color: white;
    box-shadow: 0 4px 20px rgba(52,152,219,0.2);
  }
  .panel {
    display: none;
  }
  .panel.active {
    display: block;
  }
  .card {
    background: var(--card-bg);
    backdrop-filter: blur(16px);
    border: 1px solid rgba(255,255,255,0.6);
    border-radius: 20px;
    padding: 24px 28px;
    margin-bottom: 20px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.04);
    transition: transform 0.2s;
  }
  .card:hover {
    transform: translateY(-2px);
  }
  h2 {
    font-size: 22px;
    font-weight: 700;
    margin-bottom: 20px;
    padding-bottom: 12px;
    border-bottom: 2px solid rgba(52,152,219,0.2);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  h3 {
    font-size: 18px;
    margin: 16px 0 10px;
    color: var(--primary);
  }
  table {
    width: 100%;
    border-collapse: collapse;
  }
  th, td {
    padding: 12px 15px;
    text-align: left;
    border-bottom: 1px solid rgba(0,0,0,0.05);
  }
  th {
    background: rgba(52,152,219,0.08);
    font-weight: 600;
  }
  tr:hover td {
    background: rgba(52,152,219,0.03);
  }
  .badge {
    padding: 4px 14px;
    border-radius: 30px;
    font-size: 12px;
    font-weight: 600;
    display: inline-block;
  }
  .badge.ok { background: #d4edda; color: #155724; }
  .badge.warn { background: #fff3cd; color: #856404; }
  .badge.err { background: #f8d7da; color: #721c24; }
  .badge.info { background: #d1ecf1; color: #0c5460; }
  .mono {
    font-family: 'Fira Code', 'Courier New', monospace;
    background: rgba(0,0,0,0.04);
    padding: 2px 6px;
    border-radius: 6px;
    font-size: 13px;
  }
  pre {
    background: rgba(0,0,0,0.03);
    padding: 16px;
    border-radius: 12px;
    overflow-x: auto;
    font-size: 13px;
    line-height: 1.6;
    border: 1px solid rgba(0,0,0,0.05);
  }
  .grid-2 {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 20px;
  }
  .stat-value {
    font-size: 24px;
    font-weight: 700;
    color: var(--accent);
  }
  @media (max-width: 768px) {
    .grid-2 { grid-template-columns: 1fr; }
    .header { padding: 20px; }
    .metrics-row { flex-direction: column; }
  }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>🔍 服务器深度巡检报告</h1>
    <div class="meta">
      <span>🖥️ __HOSTNAME__</span>
      <span>🕒 __TIMESTAMP__</span>
    </div>
  </div>

  <!-- 仪表盘指标 -->
  <div class="metrics-row">
    <div class="metric-card">
      <div class="label">CPU 占用</div>
      <div class="value">__CPU_USAGE__%</div>
      <div class="progress"><div class="progress-bar __CPU_BAR_CLASS__" style="width:__CPU_USAGE__%"></div></div>
    </div>
    <div class="metric-card">
      <div class="label">内存占用</div>
      <div class="value">__MEM_USAGE__%</div>
      <div class="progress"><div class="progress-bar __MEM_BAR_CLASS__" style="width:__MEM_USAGE__%"></div></div>
    </div>
    <div class="metric-card">
      <div class="label">磁盘占用 (/)</div>
      <div class="value">__DISK_USAGE__%</div>
      <div class="progress"><div class="progress-bar __DISK_BAR_CLASS__" style="width:__DISK_USAGE__%"></div></div>
    </div>
    <div class="metric-card">
      <div class="label">负载占比</div>
      <div class="value">__LOAD_PERCENT__%</div>
      <div class="progress"><div class="progress-bar __LOAD_BAR_CLASS__" style="width:__LOAD_PERCENT__%"></div></div>
    </div>
    <div class="metric-card">
      <div class="label">TCP 连接</div>
      <div class="value">__TCP_ESTAB__</div>
      <div class="progress"><div class="progress-bar info" style="width:100%"></div></div>
    </div>
    <div class="metric-card">
      <div class="label">⚠️ 警告</div>
      <div class="value __WARN_COLOR__">__WARNINGS__</div>
      <div class="progress"><div class="progress-bar __WARN_BAR_CLASS__" style="width:__WARN_PCT__%"></div></div>
    </div>
  </div>
HTMLEOF

    # 替换概览占位符 (需要先插入，后替换)
    # 我们先生成概览行的占位符，在后续统一替换

    # 填充各个指标
    cpu_val="${D["cpu_usage"]}"
    mem_val="${D["mem_usage"]}"
    disk_val="${D["disk_usage"]}"
    load_val="${D["load_percent"]}"
    tcp_val="${D["tcp_estab"]}"
    warn_val="${D["warnings"]}"

    # 进度条颜色类
    cpu_bar=""; mem_bar=""; disk_bar=""; load_bar=""; warn_bar=""
    [ $(echo "$cpu_val > 80" | bc) -eq 1 ] && cpu_bar="warn"; [ $(echo "$cpu_val > 95" | bc) -eq 1 ] && cpu_bar="danger"
    [ $(echo "$mem_val > 80" | bc) -eq 1 ] && mem_bar="warn"; [ $(echo "$mem_val > 95" | bc) -eq 1 ] && mem_bar="danger"
    [ "$disk_val" -gt 80 ] 2>/dev/null && disk_bar="warn"; [ "$disk_val" -gt 95 ] 2>/dev/null && disk_bar="danger"
    [ $(echo "$load_val > 80" | bc) -eq 1 ] && load_bar="warn"; [ $(echo "$load_val > 100" | bc) -eq 1 ] && load_bar="danger"
    [ "$warn_val" -gt 0 ] && warn_bar="warn"; [ "$warn_val" -gt 5 ] && warn_bar="danger"
    # 警告数量进度条（最多10个告警为100%）
    warn_pct=$(( warn_val * 10 ))
    [ $warn_pct -gt 100 ] && warn_pct=100
    warn_color="color:var(--accent)"
    [ $warn_val -gt 0 ] && warn_color="color:var(--warning)"
    [ $warn_val -gt 5 ] && warn_color="color:var(--danger)"

    sed -i "s/__CPU_USAGE__/$cpu_val/g" "$REPORT_HTML"
    sed -i "s/__MEM_USAGE__/$mem_val/g" "$REPORT_HTML"
    sed -i "s/__DISK_USAGE__/$disk_val/g" "$REPORT_HTML"
    sed -i "s/__LOAD_PERCENT__/$load_val/g" "$REPORT_HTML"
    sed -i "s/__TCP_ESTAB__/$tcp_val/g" "$REPORT_HTML"
    sed -i "s/__WARNINGS__/$warn_val/g" "$REPORT_HTML"
    sed -i "s/__CPU_BAR_CLASS__/$cpu_bar/g" "$REPORT_HTML"
    sed -i "s/__MEM_BAR_CLASS__/$mem_bar/g" "$REPORT_HTML"
    sed -i "s/__DISK_BAR_CLASS__/$disk_bar/g" "$REPORT_HTML"
    sed -i "s/__LOAD_BAR_CLASS__/$load_bar/g" "$REPORT_HTML"
    sed -i "s/__WARN_BAR_CLASS__/$warn_bar/g" "$REPORT_HTML"
    sed -i "s/__WARN_PCT__/$warn_pct/g" "$REPORT_HTML"
    sed -i "s/__WARN_COLOR__/$warn_color/g" "$REPORT_HTML"

    # 替换主机名和时间
    sed -i "s/__HOSTNAME__/$(html_escape "${D["hostname"]}")/g" "$REPORT_HTML"
    sed -i "s/__TIMESTAMP__/$(date '+%Y-%m-%d %H:%M:%S')/g" "$REPORT_HTML"

    # ---- Tab1: 系统概览 ----
    cat >> "$REPORT_HTML" << EOF
  <div class="tabs">
    <button class="tab-link active" onclick="switchTab(event, 'tab1')">📋 系统概览</button>
    <button class="tab-link" onclick="switchTab(event, 'tab2')">⚙️ 资源与性能</button>
    <button class="tab-link" onclick="switchTab(event, 'tab3')">🌐 网络与进程</button>
    <button class="tab-link" onclick="switchTab(event, 'tab4')">🔒 安全与日志</button>
    <button class="tab-link" onclick="switchTab(event, 'tab5')">🐬 MySQL 数据库</button>
  </div>

  <div id="tab1" class="panel active">
    <div class="card">
      <h2>🖥️ 系统信息</h2>
      <div class="grid-2">
        <div><span class="stat-value">$(html_escape "${D["os"]}")</span><br>操作系统</div>
        <div><span class="stat-value">$(html_escape "${D["kernel"]}")</span><br>内核版本</div>
        <div><span class="stat-value">$(html_escape "${D["arch"]}")</span><br>架构</div>
        <div><span class="stat-value">$(html_escape "${D["virt"]}")</span><br>虚拟化</div>
        <div><span class="stat-value">$(html_escape "${D["cpu_model"]}")</span><br>CPU 型号</div>
        <div><span class="stat-value">${D["cpu_cores"]} 核</span><br>CPU 核心</div>
        <div><span class="stat-value">$(html_escape "${D["current_user"]}")</span><br>当前用户</div>
        <div><span class="stat-value">$(html_escape "${D["timezone"]}")</span><br>时区</div>
        <div><span class="stat-value">$(html_escape "${D["ip_address"]}")</span><br>IP 地址</div>
        <div><span class="stat-value">$(html_escape "${D["gateway"]}")</span><br>默认网关</div>
      </div>
    </div>
    <div class="card">
      <h2>⏱️ 运行状态</h2>
      <div class="grid-2">
        <div><span class="stat-value">$(html_escape "${D["boot_time"]}")</span><br>启动时间</div>
        <div><span class="stat-value">$(html_escape "${D["uptime_str"]}")</span><br>已运行</div>
        <div><span class="stat-value">${D["total_procs"]}</span><br>总进程数</div>
        <div><span class="stat-value">${D["total_threads"]}</span><br>总线程数</div>
        <div><span class="stat-value">$( [ "${D["selinux"]}" == "Enforcing" ] && echo "<span class='badge ok'>${D["selinux"]}</span>" || echo "<span class='badge warn'>${D["selinux"]}</span>" )</span><br>SELinux</div>
        <div><span class="stat-value">$( [ "${D["firewalld"]}" == "active" ] && echo "<span class='badge ok'>active</span>" || echo "<span class='badge warn'>${D["firewalld"]}</span>" )</span><br>防火墙</div>
      </div>
    </div>
    <div class="card">
      <h2>📦 关键服务</h2>
      <table>
        <tr><th>服务</th><th>运行状态</th><th>开机自启</th></tr>
EOF
    while IFS='|' read -r svc active enabled; do
        active_class="badge ok"
        [ "$active" != "active" ] && active_class="badge err"
        en_class="badge ok"
        [ "$enabled" != "enabled" ] && en_class="badge warn"
        echo "<tr><td>$svc</td><td><span class='$active_class'>$active</span></td><td><span class='$en_class'>$enabled</span></td></tr>" >> "$REPORT_HTML"
    done <<< "${D["services"]}"
    echo "</table>" >> "$REPORT_HTML"
    if [ -n "${D["failed_units"]}" ]; then
        echo "<p><span class='badge err'>失败服务</span> <pre>$(html_escape "${D["failed_units"]}")</pre></p>" >> "$REPORT_HTML"
    fi
    echo "</div></div>" >> "$REPORT_HTML"

    # ---- Tab2: 资源与性能 ----
    cat >> "$REPORT_HTML" << EOF
  <div id="tab2" class="panel">
    <div class="card">
      <h2>🧠 CPU & 内存</h2>
      <div class="grid-2">
        <div><span class="stat-value">${D["load_1min"]}</span><br>负载 (1min)</div>
        <div><span class="stat-value">${D["mem_total"]}</span><br>总内存</div>
        <div><span class="stat-value">${D["mem_used"]}</span><br>已用内存</div>
        <div><span class="stat-value">${D["mem_avail"]}</span><br>可用内存</div>
        <div><span class="stat-value">${D["swap_total"]}</span><br>Swap 总量</div>
        <div><span class="stat-value">${D["swap_used"]}</span><br>Swap 已用</div>
      </div>
    </div>
    <div class="card">
      <h3>内存占用 TOP5</h3>
      <table>
        <tr><th>用户</th><th>内存</th><th>命令</th></tr>
EOF
    while IFS='|' read -r user mem cmd; do
        echo "<tr><td>$user</td><td>$mem</td><td><span class='mono'>$(html_escape "$cmd")</span></td></tr>" >> "$REPORT_HTML"
    done <<< "${D["top_mem"]}"
    echo "</table></div>" >> "$REPORT_HTML"

    cat >> "$REPORT_HTML" << EOF
    <div class="card">
      <h2>💾 磁盘 & Inode</h2>
      <h3>磁盘使用率</h3>
      <table>
        <tr><th>文件系统</th><th>大小</th><th>已用</th><th>可用</th><th>使用率</th><th>挂载点</th></tr>
EOF
    while IFS='|' read -r fs size used avail pct mnt; do
        echo "<tr><td>$fs</td><td>$size</td><td>$used</td><td>$avail</td><td>$pct</td><td>$mnt</td></tr>" >> "$REPORT_HTML"
    done <<< "${D["disk_table"]}"
    echo "</table><h3>Inode 使用率</h3><table><tr><th>文件系统</th><th>Inodes</th><th>已用</th><th>可用</th><th>使用率</th><th>挂载点</th></tr>" >> "$REPORT_HTML"
    while IFS='|' read -r fs total used free pct mnt; do
        echo "<tr><td>$fs</td><td>$total</td><td>$used</td><td>$free</td><td>$pct</td><td>$mnt</td></tr>" >> "$REPORT_HTML"
    done <<< "${D["inode_table"]}"
    echo "</table></div>" >> "$REPORT_HTML"

    cat >> "$REPORT_HTML" << EOF
    <div class="card">
      <h2>📂 文件句柄</h2>
      <div class="grid-2">
        <div><span class="stat-value">${D["fs_used"]} / ${D["fs_max"]}</span><br>系统句柄 (已用/最大)</div>
        <div><span class="stat-value">${D["ulimit_n"]}</span><br>进程限制 (ulimit -n)</div>
      </div>
      <h3>进程 FD 使用 TOP5</h3>
      <table>
        <tr><th>PID</th><th>进程</th><th>FD 数</th></tr>
EOF
    while IFS='|' read -r pid comm fds; do
        echo "<tr><td>$pid</td><td>$comm</td><td>$fds</td></tr>" >> "$REPORT_HTML"
    done <<< "${D["fd_top5"]}"
    echo "</table></div>" >> "$REPORT_HTML"
    echo "</div>" >> "$REPORT_HTML"

    # ---- Tab3: 网络与进程 ----
    cat >> "$REPORT_HTML" << EOF
  <div id="tab3" class="panel">
    <div class="card">
      <h2>🌐 网络接口流量</h2>
      <table>
        <tr><th>接口</th><th>RX bytes</th><th>TX bytes</th></tr>
EOF
    while IFS='|' read -r iface rx tx; do
        echo "<tr><td>$iface</td><td>$rx</td><td>$tx</td></tr>" >> "$REPORT_HTML"
    done <<< "${D["iface_stats"]}"
    echo "</table><h3>路由表</h3><pre>$(html_escape "${D["routes"]}")</pre></div>" >> "$REPORT_HTML"

    cat >> "$REPORT_HTML" << EOF
    <div class="card">
      <h2>📡 TCP 连接状态</h2>
      <table>
        <tr><th>状态</th><th>数量</th></tr>
EOF
    while IFS='|' read -r state cnt; do
        echo "<tr><td>$state</td><td>$cnt</td></tr>" >> "$REPORT_HTML"
    done <<< "${D["tcp_states"]}"
    echo "</table></div>" >> "$REPORT_HTML"

    cat >> "$REPORT_HTML" << EOF
    <div class="card">
      <h2>⚡ 内核网络参数</h2>
      <table>
        <tr><td>tcp_max_syn_backlog</td><td>${D["tcp_max_syn_backlog"]}</td></tr>
        <tr><td>tcp_tw_reuse</td><td>${D["tcp_tw_reuse"]}</td></tr>
        <tr><td>tcp_fin_timeout</td><td>${D["tcp_fin_timeout"]}</td></tr>
        <tr><td>tcp_keepalive_time</td><td>${D["tcp_keepalive_time"]}</td></tr>
        <tr><td>netdev_max_backlog</td><td>${D["netdev_max_backlog"]}</td></tr>
        <tr><td>swappiness</td><td>${D["swappiness"]}</td></tr>
        <tr><td>file-max</td><td>${D["file_max"]}</td></tr>
      </table>
    </div>
    <div class="card">
      <h2>📈 进程负载</h2>
      <h3>CPU TOP5</h3>
      <table><tr><th>用户</th><th>CPU</th><th>命令</th></tr>
EOF
    while IFS='|' read -r user cpu cmd; do
        echo "<tr><td>$user</td><td>$cpu</td><td><span class='mono'>$(html_escape "$cmd")</span></td></tr>" >> "$REPORT_HTML"
    done <<< "${D["cpu_top5"]}"
    echo "</table><h3>运行时间最长进程</h3><table><tr><th>用户</th><th>时间</th><th>命令</th></tr>" >> "$REPORT_HTML"
    while IFS='|' read -r user etime cmd; do
        echo "<tr><td>$user</td><td>$etime</td><td><span class='mono'>$(html_escape "$cmd")</span></td></tr>" >> "$REPORT_HTML"
    done <<< "${D["etime_top5"]}"
    echo "</table></div>" >> "$REPORT_HTML"
    echo "</div>" >> "$REPORT_HTML"

    # ---- Tab4: 安全与日志 ----
    cat >> "$REPORT_HTML" << EOF
  <div id="tab4" class="panel">
    <div class="card">
      <h2>👤 账户安全</h2>
      <div class="grid-2">
        <div><span class="stat-value">$( [ -z "${D["empty_pass"]}" ] && echo "<span class='badge ok'>无</span>" || echo "<span class='badge err'>${D["empty_pass"]}</span>" )</span><br>空口令账号</div>
        <div><span class="stat-value">$( [ -z "${D["uid0_users"]}" ] && echo "<span class='badge ok'>无</span>" || echo "<span class='badge err'>${D["uid0_users"]}</span>" )</span><br>UID=0 非root</div>
        <div><span class="stat-value">$(html_escape "${D["ssh_permit_root"]}")</span><br>SSH PermitRootLogin</div>
        <div><span class="stat-value">$(html_escape "${D["ssh_password_auth"]}")</span><br>SSH 密码认证</div>
      </div>
    </div>
    <div class="card">
      <h2>🐳 Docker</h2>
      $( if [ "${D["docker_ver"]}" != "未安装" ]; then
           echo "<div class='grid-2'>
                   <div><span class='stat-value'>${D["docker_ver"]}</span><br>版本</div>
                   <div><span class='stat-value'>${D["docker_running"]} / ${D["docker_total"]}</span><br>运行中/总数</div>
                 </div>"
           echo "<p>已停止: ${D["docker_stopped"]}</p>"
         else
           echo "<p>Docker 未安装</p>"
         fi )
    </div>
    <div class="card">
      <h2>📁 大文件分析</h2>
      <pre>$(IFS='|'; echo "${D["big_files"]}" | tr '|' '\n')</pre>
    </div>
    <div class="card">
      <h2>🕓 Root 计划任务</h2>
      <pre>$(html_escape "${D["root_cron"]}")</pre>
    </div>
    <div class="card">
      <h2>📜 系统日志</h2>
      <h3>journalctl 错误 (最后10行)</h3>
      <pre>$(html_escape "${D["journal_errors"]}")</pre>
      <h3>/var/log/messages 最近错误</h3>
      <pre>$(html_escape "${D["messages_errors"]}")</pre>
    </div>
  </div>
EOF
  cat >> "$REPORT_HTML" << EOF
  <div id="tab5" class="panel">
    <div class="card">
      <h2>🐬 MySQL 深度巡检报告</h2>
EOF
    if [ "${D["mysql_available"]}" != "true" ]; then
        echo "<div class='badge err'>MySQL 巡检不可用</div><p>原因：${D["mysql_error_msg"]}</p>" >> "$REPORT_HTML"
    else
        cat >> "$REPORT_HTML" << EOF
      <div class="grid-2">
        <div><span class="stat-value">$(html_escape "${D["mysql_version"]}")</span><br>MySQL 版本</div>
        <div><span class="stat-value">${D["mysql_uptime"]}秒</span><br>运行时间</div>
        <div><span class="stat-value">${D["mysql_threads_connected"]} / ${D["mysql_max_connections"]}</span><br>当前/最大连接数</div>
        <div><span class="stat-value">${D["mysql_conn_usage"]}</span><br>连接使用率</div>
        <div><span class="stat-value">${D["mysql_slow_queries"]}</span><br>慢查询总数</div>
        <div><span class="stat-value">${D["mysql_slow_query_log"]} / ${D["mysql_long_query_time"]}秒</span><br>慢查询日志状态/阈值</div>
        <div><span class="stat-value">${D["mysql_innodb_hitrate"]}</span><br>InnoDB Buffer Pool 命中率</div>
        <div><span class="stat-value">${D["mysql_qcache_hitrate"]}</span><br>查询缓存命中率</div>
        <div><span class="stat-value">${D["mysql_thread_hitrate"]}</span><br>线程缓存命中率</div>
        <div><span class="stat-value">${D["mysql_db_total_size"]}</span><br>数据库总大小</div>
        <div><span class="stat-value">${D["mysql_innodb_buffer_pool_size"]}</span><br>InnoDB Buffer Pool 大小</div>
        <div><span class="stat-value">🔒 锁等待: ${D["mysql_lock_waits"]} | ⏳ 长事务/查询(>60s): ${D["mysql_long_trx_count"]}</span><br>并发与锁信息</div>
      </div>
      <h3>📡 主从复制状态</h3>
      <table>
        <tr><th>复制状态</th><th>IO 线程</th><th>SQL 线程</th><th>延迟(秒)</th></tr>
        <tr><td>${D["mysql_slave_status"]}</td><td>${D["mysql_slave_io"]:-N/A}</td><td>${D["mysql_slave_sql"]:-N/A}</td><td>${D["mysql_slave_delay"]}</td></tr>
      </table>
      <h3>📊 慢查询统计</h3>
      <table>
        <tr><th>SQL 语句</th><th>执行次数</th><th>总耗时</th><th>平均耗时</th><th>95% 耗时</th></tr>
EOF
        while IFS='|' read -r sql count time avg pct; do
            echo "<tr><td><pre class='mono'>$(html_escape "$sql")</pre></td><td>$count</td><td>$time</td><td>$avg</td><td>$pct</td></tr>" >> "$REPORT_HTML"
        done <<< "${D["mysql_slow_stats"]}"
        echo "</table>" >> "$REPORT_HTML"
    fi
    echo "  </div></div>" >> "$REPORT_HTML"

    # 页脚和JS
    cat >> "$REPORT_HTML" << 'HTMLEOF'
  <div style="text-align:center;margin-top:10px;color:#95a5a6;font-size:14px;">
    报告自动生成于 __TIMESTAMP__ | 深度巡检·仪表盘版
  </div>
</div>

<script>
  function switchTab(evt, tabId) {
    var panels = document.getElementsByClassName('panel');
    for (var i=0; i<panels.length; i++) panels[i].classList.remove('active');
    var links = document.getElementsByClassName('tab-link');
    for (var i=0; i<links.length; i++) links[i].classList.remove('active');
    document.getElementById(tabId).classList.add('active');
    evt.currentTarget.classList.add('active');
  }
</script>
</body>
</html>
HTMLEOF
    # 替换占位符
    cpu_val="${D["cpu_usage"]}"; mem_val="${D["mem_usage"]}"; disk_val="${D["disk_usage"]}"
    load_val="${D["load_percent"]}"; tcp_val="${D["tcp_estab"]}"; warn_val="${D["warnings"]}"
    cpu_bar=""; mem_bar=""; disk_bar=""; load_bar=""; warn_bar=""
    [ $(echo "$cpu_val > 80" | bc) -eq 1 ] && cpu_bar="warn"; [ $(echo "$cpu_val > 95" | bc) -eq 1 ] && cpu_bar="danger"
    [ $(echo "$mem_val > 80" | bc) -eq 1 ] && mem_bar="warn"; [ $(echo "$mem_val > 95" | bc) -eq 1 ] && mem_bar="danger"
    [ "$disk_val" -gt 80 ] 2>/dev/null && disk_bar="warn"; [ "$disk_val" -gt 95 ] 2>/dev/null && disk_bar="danger"
    [ $(echo "$load_val > 80" | bc) -eq 1 ] && load_bar="warn"; [ $(echo "$load_val > 100" | bc) -eq 1 ] && load_bar="danger"
    [ "$warn_val" -gt 0 ] && warn_bar="warn"; [ "$warn_val" -gt 5 ] && warn_bar="danger"
    warn_pct=$(( warn_val * 10 )); [ $warn_pct -gt 100 ] && warn_pct=100
    warn_color="color:var(--accent)"; [ $warn_val -gt 0 ] && warn_color="color:var(--warning)"; [ $warn_val -gt 5 ] && warn_color="color:var(--danger)"
    sed -i "s/__CPU_USAGE__/$cpu_val/g; s/__MEM_USAGE__/$mem_val/g; s/__DISK_USAGE__/$disk_val/g; s/__LOAD_PERCENT__/$load_val/g; s/__TCP_ESTAB__/$tcp_val/g; s/__WARNINGS__/$warn_val/g" "$REPORT_HTML"
    sed -i "s/__CPU_BAR_CLASS__/$cpu_bar/g; s/__MEM_BAR_CLASS__/$mem_bar/g; s/__DISK_BAR_CLASS__/$disk_bar/g; s/__LOAD_BAR_CLASS__/$load_bar/g; s/__WARN_BAR_CLASS__/$warn_bar/g; s/__WARN_PCT__/$warn_pct/g" "$REPORT_HTML"
    sed -i "s/__WARN_COLOR__/$warn_color/g; s/__HOSTNAME__/$(html_escape "${D["hostname"]}")/g; s/__TIMESTAMP__/$(date '+%Y-%m-%d %H:%M:%S')/g" "$REPORT_HTML"
}


# ========== 主流程 ==========
collect_all
generate_html
echo "✅ HTML 报告已生成: $REPORT_HTML"
