#!/bin/bash

CONFIG_FILE="/mnt/data/ican/assistant-deploy/check-page/servers.conf"
CURRENT_HOST=$(hostname -I | awk '{print $1}')
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes"

# 读取服务器列表
if [[ -n "$MONITOR_SERVERS" ]]; then
    IFS=',' read -ra SERVERS <<< "$MONITOR_SERVERS"
elif [[ -f "$CONFIG_FILE" ]]; then
    mapfile -t SERVERS < "$CONFIG_FILE"
    CLEAN_SERVERS=()
    for server in "${SERVERS[@]}"; do
        server=$(echo "$server" | tr -d '\r\n' | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        if [[ -n "$server" && ! "$server" =~ ^[[:space:]]*# ]]; then
            ip=$(echo "$server" | cut -d':' -f1)
            CLEAN_SERVERS+=("$ip")
        fi
    done
    SERVERS=("${CLEAN_SERVERS[@]}")
else
    SERVERS=("10.96.140.66" "10.96.140.67" "10.96.140.68")
fi

# 清理字符串
clean_json_string() {
    echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[\r\n\t]//g'
}

# 获取默认网卡（物理网卡）
get_default_iface() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        for name in eth0 ens192 enp0s3 ens33; do
            if ip link show "$name" &>/dev/null; then
                iface="$name"
                break
            fi
        done
    fi
    echo "$iface"
}

# CPU 使用率（采样1秒）
get_cpu_usage() {
    local server=$1
    local is_local=$([ "$server" == "$CURRENT_HOST" ] && echo "true" || echo "false")
    local cpu_info=""
    if [[ "$is_local" == "true" ]]; then
        local stat1=$(cat /proc/stat 2>/dev/null | grep '^cpu ' | awk '{print $2,$3,$4,$5,$6,$7,$8}')
        sleep 1
        local stat2=$(cat /proc/stat 2>/dev/null | grep '^cpu ' | awk '{print $2,$3,$4,$5,$6,$7,$8}')
        cpu_info="$stat1|$stat2"
    else
        cpu_info=$(ssh $SSH_OPTS $server "
            stat1=\$(cat /proc/stat 2>/dev/null | grep '^cpu ' | awk '{print \$2,\$3,\$4,\$5,\$6,\$7,\$8}')
            sleep 1
            stat2=\$(cat /proc/stat 2>/dev/null | grep '^cpu ' | awk '{print \$2,\$3,\$4,\$5,\$6,\$7,\$8}')
            echo \"\$stat1|\$stat2\"
        " 2>/dev/null)
    fi
    if [[ -z "$cpu_info" ]]; then
        echo "0.0"
        return
    fi
    local stat1=$(echo "$cpu_info" | cut -d'|' -f1)
    local stat2=$(echo "$cpu_info" | cut -d'|' -f2)
    local user1=$(echo $stat1 | cut -d' ' -f1)
    local nice1=$(echo $stat1 | cut -d' ' -f2)
    local system1=$(echo $stat1 | cut -d' ' -f3)
    local idle1=$(echo $stat1 | cut -d' ' -f4)
    local iowait1=$(echo $stat1 | cut -d' ' -f5)
    local irq1=$(echo $stat1 | cut -d' ' -f6)
    local softirq1=$(echo $stat1 | cut -d' ' -f7)
    local user2=$(echo $stat2 | cut -d' ' -f1)
    local nice2=$(echo $stat2 | cut -d' ' -f2)
    local system2=$(echo $stat2 | cut -d' ' -f3)
    local idle2=$(echo $stat2 | cut -d' ' -f4)
    local iowait2=$(echo $stat2 | cut -d' ' -f5)
    local irq2=$(echo $stat2 | cut -d' ' -f6)
    local softirq2=$(echo $stat2 | cut -d' ' -f7)
    local total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1))
    local total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2))
    local idle_diff=$((idle2 - idle1))
    local total_diff=$((total2 - total1))
    if [[ $total_diff -eq 0 ]]; then
        echo "0.0"
    else
        awk -v total=$total_diff -v idle=$idle_diff 'BEGIN {printf "%.1f", (total - idle) * 100 / total}'
    fi
}

# 内存信息（单位GB，保留一位小数）
get_memory() {
    local server=$1
    local is_local=$([ "$server" == "$CURRENT_HOST" ] && echo "true" || echo "false")
    local mem_info=""
    if [[ "$is_local" == "true" ]]; then
        mem_info=$(free -b 2>/dev/null | awk '/^Mem:/ {print $2,$7}')
    else
        mem_info=$(ssh $SSH_OPTS $server "free -b 2>/dev/null | awk '/^Mem:/ {print \$2,\$7}'" 2>/dev/null)
    fi
    if [[ -z "$mem_info" ]]; then
        echo "0.0,0.0,0.0"
        return
    fi
    local total_bytes=$(echo $mem_info | awk '{print $1}')
    local avail_bytes=$(echo $mem_info | awk '{print $2}')
    local used_bytes=$((total_bytes - avail_bytes))
    local total_gb=$(awk -v b=$total_bytes 'BEGIN {printf "%.1f", b/1024/1024/1024}')
    local used_gb=$(awk -v b=$used_bytes 'BEGIN {printf "%.1f", b/1024/1024/1024}')
    local percent=$(awk -v u=$used_bytes -v t=$total_bytes 'BEGIN {printf "%.1f", u*100/t}')
    echo "$total_gb,$used_gb,$percent"
}

# 磁盘分区（保留原始单位，如 "0.2G"）
get_disk_partitions() {
    local server=$1
    local is_local=$([ "$server" == "$CURRENT_HOST" ] && echo "true" || echo "false")
    local partitions="["
    local first=true
    local df_data=""
    if [[ "$is_local" == "true" ]]; then
        df_data=$(df -h 2>/dev/null | tail -n +2 | grep -v 'tmpfs\|devtmpfs\|overlay')
    else
        df_data=$(ssh $SSH_OPTS $server "df -h 2>/dev/null | tail -n +2 | grep -v 'tmpfs\|devtmpfs\|overlay'" 2>/dev/null)
    fi
    while read -r filesystem size used avail percent mount; do
        [[ -z "$filesystem" ]] && continue
        [[ "$filesystem" == "tmpfs" || "$filesystem" == "devtmpfs" || "$filesystem" == "overlay" ]] && continue
        # 清理百分比
        percent_num=$(echo "$percent" | tr -d '%')
        [[ -z "$percent_num" ]] && percent_num=0
        mount_esc=$(clean_json_string "$mount")
        fs_esc=$(clean_json_string "$filesystem")
        [[ "$first" == "true" ]] && first=false || partitions+=","
        partitions+="{\"filesystem\":\"$fs_esc\",\"mount\":\"$mount_esc\",\"total\":\"$size\",\"used\":\"$used\",\"avail\":\"$avail\",\"percent\":$percent_num}"
    done <<< "$df_data"
    partitions+="]"
    echo "$partitions"
}

# 网络流量（字节，使用默认网卡）
get_network() {
    local server=$1
    local is_local=$([ "$server" == "$CURRENT_HOST" ] && echo "true" || echo "false")
    local iface=""
    local rx=0
    local tx=0
    if [[ "$is_local" == "true" ]]; then
        iface=$(get_default_iface)
        rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    else
        local result=$(ssh $SSH_OPTS $server "
            iface=\$(ip route | grep default | awk '{print \$5}' | head -1)
            if [[ -z \"\$iface\" ]]; then
                for name in eth0 ens192 enp0s3 ens33; do
                    if ip link show \"\$name\" &>/dev/null; then
                        iface=\"\$name\"
                        break
                    fi
                done
            fi
            echo \"\$iface \$(cat /sys/class/net/\$iface/statistics/rx_bytes 2>/dev/null || echo 0) \$(cat /sys/class/net/\$iface/statistics/tx_bytes 2>/dev/null || echo 0)\"
        " 2>/dev/null)
        iface=$(echo "$result" | awk '{print $1}')
        rx=$(echo "$result" | awk '{print $2}')
        tx=$(echo "$result" | awk '{print $3}')
        [[ -z "$iface" ]] && iface="unknown"
        [[ -z "$rx" ]] && rx=0
        [[ -z "$tx" ]] && tx=0
    fi
    local rx_gb=$(awk -v b=$rx 'BEGIN {printf "%.2f", b/1024/1024/1024}')
    local tx_gb=$(awk -v b=$tx 'BEGIN {printf "%.2f", b/1024/1024/1024}')
    echo "{\"iface\":\"$(clean_json_string "$iface")\",\"rx_bytes\":$rx,\"tx_bytes\":$tx,\"rx_gb\":$rx_gb,\"tx_gb\":$tx_gb}"
}

# 服务器运行时间
get_uptime() {
    local server=$1
    local is_local=$([ "$server" == "$CURRENT_HOST" ] && echo "true" || echo "false")
    local uptime_str=""
    if [[ "$is_local" == "true" ]]; then
        uptime_str=$(uptime -p 2>/dev/null || echo "0 minutes")
    else
        uptime_str=$(ssh $SSH_OPTS $server "uptime -p 2>/dev/null || echo \"0 minutes\"")
    fi
    # 清理uptime输出，移除前缀 "up "
    uptime_str=$(echo "$uptime_str" | sed 's/^up //')
    echo "$(clean_json_string "$uptime_str")"
}

# 采集单台服务器
collect_server() {
    local server=$1
    local cpu=$(get_cpu_usage "$server")
    local mem_info=$(get_memory "$server")
    local mem_total=$(echo $mem_info | cut -d',' -f1)
    local mem_used=$(echo $mem_info | cut -d',' -f2)
    local mem_percent=$(echo $mem_info | cut -d',' -f3)
    local disk_parts=$(get_disk_partitions "$server")
    local network=$(get_network "$server")
    local uptime=$(get_uptime "$server")
    cat <<EOF
{"host":"$server","status":"online","cpu":$cpu,"mem":{"total":$mem_total,"used":$mem_used,"percent":$mem_percent},"disk_partitions":$disk_parts,"network":$network,"uptime":"$uptime"}
EOF
}

# 主程序
{
    echo -n "{\"time\":\"$(date +%H:%M:%S)\",\"timestamp\":$(date +%s),\"servers\":["
    first=true
    for server in "${SERVERS[@]}"; do
        server=$(echo "$server" | cut -d':' -f1 | tr -d '[:space:]')
        [[ -z "$server" ]] && continue
        # 跳过无法连接的远程服务器
        if [[ "$server" != "$CURRENT_HOST" ]]; then
            ssh -o ConnectTimeout=2 $SSH_OPTS $server "echo ok" &>/dev/null || continue
        fi
        [[ "$first" == "true" ]] && first=false || echo -n ","
        server_data=$(collect_server "$server")
        echo -n "$server_data"
    done
    echo -n "]}"
} 2>/dev/null
