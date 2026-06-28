#!/bin/bash

# Linux 服务器自动巡检脚本
# 功能：检查 CPU、内存、磁盘、进程、网络端口状态，并在终端输出结果

# 配置参数
CHECK_PROCESSES=(sshd nginx mysql redis)
CHECK_PORTS=(22 80 443 3306 6379)

# 要检查的关键服务
CHECK_SERVICES=(sshd cron syslog-ng rsyslog)

# 获取主机名和 IP 地址
get_host_info() {
    hostname=$(hostname)
    ip=$(hostname -I | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip="127.0.0.1"
    fi
    echo "主机名: $hostname"
    echo "IP地址: $ip"
    echo "巡检时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# 获取系统信息摘要
get_system_summary() {
    echo "【系统信息摘要】"
    if [ -f "/etc/os-release" ]; then
        os_info=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    else
        os_info="未知"
    fi

    kernel_version=$(uname -r)
    cpu_cores=$(nproc)
    if [ -f "/proc/cpuinfo" ]; then
        cpu_model=$(grep "model name" /proc/cpuinfo | head -n 1 | cut -d':' -f2 | xargs)
    else
        cpu_model="未知"
    fi
    
    total_memory=$(free -h | awk '/^Mem:/ {print $2}')
    total_disk=$(df -h / | awk 'NR==2 {print $2}')
    public_ip=$(curl -s https://api.ipify.org 2>/dev/null || echo "无法获取")
    load_average=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    
    echo "操作系统: $os_info"
    echo "内核版本: $kernel_version"
    echo "CPU型号: $cpu_model"
    echo "CPU核心数: $cpu_cores"
    echo "总内存: $total_memory"
    echo "总磁盘空间: $total_disk"
    echo "公网IP: $public_ip"
    echo "负载平均值: $load_average"
    echo ""
}

# 检查 CPU 使用率和负载
check_cpu() {
    echo "【CPU 状态】"
    cpu_percent=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    cpu_count=$(nproc)
    load_avg=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    load1=$(echo $load_avg | awk '{print $1}')
    load5=$(echo $load_avg | awk '{print $2}')
    load15=$(echo $load_avg | awk '{print $3}')
    
    load_threshold=$(echo "$cpu_count * 0.8" | awk '{print $1}')
    load_status="正常"
    if awk "BEGIN {exit !($load1 > $load_threshold)}"; then
        load_status="警告"
    fi
    
    status="正常"
    if awk "BEGIN {exit !($cpu_percent > 80)}"; then
        status="警告"
    fi
    
    echo "使用率: ${cpu_percent}%"
    echo "1分钟负载: $load1"
    echo "5分钟负载: $load5"
    echo "15分钟负载: $load15"
    echo "负载状态: $load_status"
    echo ""

}

# 检查内存使用率
check_memory() {
    echo "【内存状态】"
    mem_total=$(free -g | awk '/Mem/{print $2}')
    mem_used=$(free -g | awk '/Mem/{print $3}')
    mem_available=$(free -g | awk '/Mem/{print $7}')
    mem_percent=$(free | awk '/Mem/{print $3/$2 * 100}')
    
    status="正常"
    if awk "BEGIN {exit !($mem_percent > 80)}"; then
        status="警告"
    fi
    
    echo "使用率: ${mem_percent}%"
    echo "总内存: ${mem_total}GB"
    echo "可用内存: ${mem_available}GB"
    echo ""

}

# 检查磁盘使用率
check_disk() {
    echo "【磁盘状态】"
    df -h -P | tail -n +2 | while read -r line; do
        if echo "$line" | grep -q -E "^(tmpfs|devtmpfs)"; then
            continue
        fi
        
        filesystem=$(echo "$line" | awk '{print $1}')
        total=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        available=$(echo "$line" | awk '{print $4}')
        usage=$(echo "$line" | awk '{print $5}')
        mountpoint=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        
        usage_percent=$(echo $usage | sed 's/%//g' | grep -E '[0-9]+')
        
        if [[ -n $usage_percent && $usage_percent =~ ^[0-9]+$ ]]; then
            if (( usage_percent > 85 )); then
                status="警告"
            else
                status="正常"
            fi
        else
            status="无法获取"
        fi
        
        if [[ -n $filesystem && -n $mountpoint && -n $usage && $mountpoint != "挂载点" && $filesystem != "文件系统" ]]; then
            echo "挂载点: $mountpoint"
            echo "文件系统: $filesystem"
            echo "使用率: $usage"
            echo "总空间: $total"
            echo "可用空间: $available"
            echo ""
        fi
    done
}

# 检查磁盘 IO 状态
check_disk_io() {
    echo "【磁盘IO状态】"
    if command -v iostat > /dev/null; then
        io_result=$(iostat -xd 2 2 | awk ' 
 /^Device/ {section++; next} 
 section==2 { 
     dev=$1 
     if (dev == "" || dev ~ /^dm-[0-9]+/) 
         next 
     rrqm=$6 
     wrqm=$7 
     rawait=$11 
     wawait=$12 
     qu=$9 
     util=$NF 
     status="正常" 
     if (util > 80 || rawait > 50 || wawait > 50 || qu > 5) 
         status="异常" 
     printf "\n设备: %s\n", dev 
     printf "  %%rrqm: %.2f\n", rrqm 
     printf "  %%wrqm: %.2f\n", wrqm 
     printf "  r_await: %.2f\n", rawait 
     printf "  w_await: %.2f\n", wawait 
     printf "  avgqu-sz: %.2f\n", qu 
     printf "  %%util: %.2f\n", util 
     printf "  状态: %s\n", status 
 }')
        echo "$io_result" | grep -v "状态:"
    else
        echo "iostat 命令不可用，无法检查磁盘 IO 状态"
    fi
    echo ""
}

# 检查进程状态
check_processes() {
    echo "【进程状态】"
    for process in "${CHECK_PROCESSES[@]}"; do
        if pgrep -x "$process" > /dev/null; then
            status="运行中"
        else
            status="未运行"
        fi
        echo "进程名: $process"
        echo "状态: $status"
    done
    echo ""
}

# 检查系统服务状态
check_services() {
    echo "【系统服务状态】"
    
    if command -v systemctl > /dev/null; then
        running_services=$(systemctl list-units --type=service --state=running | grep -c "loaded active running")
        total_services=$(systemctl list-units --type=service | grep -c "loaded")
        
        echo "运行的服务数量: $running_services"
        echo "总服务数量: $total_services"
        
        critical_services=(${CHECK_SERVICES[@]})
        echo "关键服务状态:"
        for service in "${critical_services[@]}"; do
            if systemctl status $service 2>/dev/null | grep -q "active (running)"; then
                echo "  - $service: 运行中"
            else
                echo "  - $service: 未运行"
            fi
        done
    else
        echo "无法检查服务状态: systemctl 命令不可用"
    fi
    echo ""
}

# 检查 CPU 和内存使用最高的前 5 个进程
check_top_processes() {
    echo "【CPU使用最高的前5个进程】"
    ps -eo pid,comm,%cpu --sort=-%cpu | head -n 6 | tail -n 5 | while read -r line; do
        pid=$(echo $line | awk '{print $1}')
        name=$(echo $line | awk '{print $2}')
        cpu_percent=$(echo $line | awk '{print $3}')
        echo "PID: $pid, 进程名: $name, CPU使用率: ${cpu_percent}%"
    done
    
    echo ""
    echo "【内存使用最高的前5个进程】"
    ps -eo pid,comm,%mem --sort=-%mem | head -n 6 | tail -n 5 | while read -r line; do
        pid=$(echo $line | awk '{print $1}')
        name=$(echo $line | awk '{print $2}')
        mem_percent=$(echo $line | awk '{print $3}')
        echo "PID: $pid, 进程名: $name, 内存使用率: ${mem_percent}%"
    done
    echo ""
}

# 检查网络端口
check_ports() {
    echo "【网络与安全状态】"
    echo "端口状态:"
    for port in "${CHECK_PORTS[@]}"; do
        if nc -z $ip $port 2>/dev/null; then
            status="开放"
        else
            status="关闭"
        fi
        echo "  - 端口: $port, 状态: $status"
    done
    echo ""
}

# 检查系统启动时间
check_uptime() {
    echo "系统启动时间:"
    uptime_str=$(uptime -p)
    uptime_cn=$(echo "$uptime_str" | sed 's/up //' | sed 's/ days*/天/' | sed 's/ day*/天/' | sed 's/ hours*/小时/' | sed 's/ hour*/小时/' | sed 's/ minutes*/分钟/' | sed 's/ minute*/分钟/')
    boot_time=$(who -b | awk '{print $3, $4}')
    echo "  - 运行时间: $uptime_cn"
    echo "  - 启动时间: $boot_time"
    echo ""
}

# 检查僵尸进程
check_zombie_processes() {
    echo "僵尸进程:"
    zombie_count=$(ps -eo stat | grep -c "^Z")
    if (( zombie_count > 0 )); then
        status="警告"
    else
        status="正常"
    fi
    echo "  - 数量: $zombie_count"
    echo ""

}

# 检查网络状态
check_network_status() {
    echo "网络状态:"
    connection_count=$(netstat -an | grep ESTABLISHED | wc -l)
    
    if command -v ping > /dev/null; then
        total_time=0
        count=0
        
        for i in {1..3}; do
            ping_output=$(ping -c 1 -W 2 www.baidu.com 2>&1)
            
            ping_time=$(echo "$ping_output" | grep -o "时间=[0-9]*" | head -n 1 | sed 's/时间=//')
            
            if [ -z "$ping_time" ]; then
                ping_time=$(echo "$ping_output" | grep -o "time=[0-9.]*" | head -n 1 | sed 's/time=//')
            fi
            
            if [ -z "$ping_time" ]; then
                time_line=$(echo "$ping_output" | grep -E "时间|time" | head -n 1)
                ping_time=$(echo "$time_line" | grep -o "[0-9]\+" | head -n 1)
            fi
            
            if [ -n "$ping_time" ]; then
                total_time=$(awk "BEGIN {print $total_time + $ping_time}")
                count=$((count + 1))
            fi
            
            sleep 0.5
        done
        
        if [ $count -gt 0 ]; then
            avg_time=$(awk "BEGIN {print $total_time / $count}")
            avg_time=$(printf "%.1f" $avg_time)
            ping_result="${avg_time} ms"
            if awk "BEGIN {exit !($avg_time <= 100)}"; then
                net_status="正常"
            else
                net_status="警告"
            fi
        else
            ping_result="9999 ms"
            net_status="警告"
        fi
    else
        ping_result="无法测试"
        net_status="警告"
    fi
    
    echo "  - 连接数: $connection_count"
    echo "  - 网络延迟: $ping_result"
    
    echo "  - 接口信息:"
    if command -v ifconfig > /dev/null; then
        ifconfig | grep -E '^[a-z]' | grep -v lo | awk '{print $1}' | while read -r interface; do
            rx_bytes=$(ifconfig $interface | grep RX | grep bytes | awk '{print $2}' | sed 's/bytes://')
            tx_bytes=$(ifconfig $interface | grep TX | grep bytes | awk '{print $2}' | sed 's/bytes://')
            rx_mb=$(echo "$rx_bytes" | awk '{print $1 / 1024 / 1024}')
            tx_mb=$(echo "$tx_bytes" | awk '{print $1 / 1024 / 1024}')
            rx_mb=$(printf "%.2f" $rx_mb)
            tx_mb=$(printf "%.2f" $tx_mb)
            echo "    - $interface: 发送 ${tx_mb} MB, 接收 ${rx_mb} MB"
        done
    elif command -v ip > /dev/null; then
        ip -o link show | grep -v lo | awk '{print $2}' | sed 's/:$//' | while read -r interface; do
            rx_bytes=$(ip -s link show $interface | grep RX: | tail -n 1 | awk '{print $1}')
            tx_bytes=$(ip -s link show $interface | grep TX: | tail -n 1 | awk '{print $1}')
            rx_mb=$(echo "$rx_bytes" | awk '{print $1 / 1024 / 1024}')
            tx_mb=$(echo "$tx_bytes" | awk '{print $1 / 1024 / 1024}')
            rx_mb=$(printf "%.2f" $rx_mb)
            tx_mb=$(printf "%.2f" $tx_mb)
            echo "    - $interface: 发送 ${tx_mb} MB, 接收 ${rx_mb} MB"
        done
    fi
    
    echo ""
    
    echo "防火墙状态:"
    firewall_status="未运行"
    allowed_ports=()
    
    if command -v firewalld > /dev/null; then
        if systemctl status firewalld 2>/dev/null | grep -q "active (running)"; then
            firewall_status="运行中 (firewalld)"
            if command -v firewall-cmd > /dev/null; then
                allowed_ports=$(firewall-cmd --list-all | grep -E 'ports:|services:' | awk '{print $2}' | tr ' ' ',')
            fi
        fi
    elif command -v ufw > /dev/null; then
        if ufw status 2>/dev/null | grep -q "active"; then
            firewall_status="运行中 (ufw)"
            allowed_ports=$(ufw status | grep -E 'ALLOW|allow' | awk '{print $1}' | tr '\n' ',')
        fi
    elif command -v iptables > /dev/null; then
        if iptables -L 2>/dev/null | grep -q "ACCEPT"; then
            firewall_status="运行中 (iptables)"
            allowed_ports=$(iptables -L | grep -E 'ACCEPT.*dpt:' | sed 's/.*dpt:\([0-9]\+\).*/\1/' | tr '\n' ',')
        fi
    fi
    
    echo "    - 状态: $firewall_status"
    if [ -n "$allowed_ports" ]; then
        echo "    - 允许的端口/服务: $allowed_ports"
    fi
    
    echo ""
    
    echo "SELinux 状态:"
    if command -v getenforce > /dev/null; then
        selinux_status=$(getenforce)
        if [ "$selinux_status" = "Enforcing" ]; then
            selinux_status_cn="开启"
        elif [ "$selinux_status" = "Permissive" ]; then
            selinux_status_cn="宽松"
        else
            selinux_status_cn="关闭"
        fi
    else
        selinux_status_cn="未安装或不可用"
    fi
    echo "  - 状态: $selinux_status_cn"
    
    echo ""
}

# 检查安全状态
check_security() {
    echo "安全状态:"
    
    failed_login_count=0
    failed_users=()
    if [ -f "/var/log/auth.log" ]; then
        failed_login_count=$(grep "Failed password" /var/log/auth.log | wc -l)
        local temp_users=()
        while IFS= read -r line; do
            user=$(echo "$line" | awk '{
                for(i=1;i<=NF;i++) {
                    if($i=="for") {
                        if($(i+1)=="invalid" && $(i+2)=="user") {
                            print $(i+3)
                        } else {
                            print $(i+1)
                        }
                        break
                    }
                }
            }')
            if [ -n "$user" ]; then
                temp_users+=($user)
            fi
        done < <(grep "Failed password" /var/log/auth.log)
        if [ ${#temp_users[@]} -gt 0 ]; then
            failed_users=$(printf "%s\n" "${temp_users[@]}" | sort | uniq -c | awk '{print $2 " (" $1 "次)"}' | tr '\n' ' ' | sed 's/ $//')
        fi
    elif [ -f "/var/log/secure" ]; then
        failed_login_count=$(grep "Failed password" /var/log/secure | wc -l)
        local temp_users=()
        while IFS= read -r line; do
            user=$(echo "$line" | awk '{
                for(i=1;i<=NF;i++) {
                    if($i=="for") {
                        if($(i+1)=="invalid" && $(i+2)=="user") {
                            print $(i+3)
                        } else {
                            print $(i+1)
                        }
                        break
                    }
                }
            }')
            if [ -n "$user" ]; then
                temp_users+=($user)
            fi
        done < <(grep "Failed password" /var/log/secure)
        if [ ${#temp_users[@]} -gt 0 ]; then
            failed_users=$(printf "%s\n" "${temp_users[@]}" | sort | uniq -c | awk '{print $2 " (" $1 "次)"}' | tr '\n' ' ' | sed 's/ $//')
        fi
    fi
    
    permission_issues=()
    critical_files=(/etc/shadow /etc/sudoers)
    for file in "${critical_files[@]}"; do
        if [ -f "$file" ]; then
            perm=$(stat -c "%a" $file)
            if (( perm & 0007 != 0 )); then
                permission_issues+=($file)
            fi
        fi
    done
    
    recent_logins=""
    if command -v last > /dev/null; then
        recent_logins=$(last -n 5 | grep -v "wtmp begins" | awk '{
            user = $1;
            if(user == "reboot" || user == "") {
                next;
            }
            ip = "本地登录";
            time = $3 " " $4 " " $5;
            for(i=NF; i>=1; i--) {
                if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                    ip = $i;
                    break;
                }
            }
            print "用户: " user ", IP: " ip ", 时间: " time;
        }')
        if [ -z "$recent_logins" ]; then
            recent_logins="无有效登录记录"
        fi
    else
        recent_logins="无法获取登录记录"
    fi
    
    echo "  - SSH配置检查:"
    if [ -f "/etc/ssh/sshd_config" ]; then
        root_login=$(grep "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -z "$root_login" ]; then
            root_login="prohibit-password"
        fi
        if [ "$root_login" = "no" ]; then
            echo "    - Root登录: 已禁用"
        else
            echo "    - Root登录: 允许 (安全风险)"
        fi
        
        password_auth=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -z "$password_auth" ]; then
            password_auth="yes"
        fi
        if [ "$password_auth" = "no" ]; then
            echo "    - 密码认证: 已禁用 (推荐)"
        else
            echo "    - 密码认证: 启用"
        fi
        
        ssh_port=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -z "$ssh_port" ]; then
            ssh_port="22"
        fi
        if [ "$ssh_port" = "22" ]; then
            echo "    - SSH端口: 默认端口 (建议更改)"
        else
            echo "    - SSH端口: $ssh_port"
        fi
    else
        echo "    - 无法检查SSH配置: 配置文件不存在"
    fi
    
    echo "  - 自动更新检查:"
    if command -v dpkg > /dev/null; then
        if dpkg -l | grep -q "unattended-upgrades"; then
            echo "    - 自动更新: 已配置"
        else
            echo "    - 自动更新: 未配置 (建议启用)"
        fi
    elif command -v yum > /dev/null; then
        if systemctl status yum-cron 2>/dev/null | grep -q "active"; then
            echo "    - 自动更新: 已配置"
        else
            echo "    - 自动更新: 未配置 (建议启用)"
        fi
    else
        echo "    - 自动更新: 无法检查"
    fi
    
    echo "  - 入侵防御系统检查:"
    ips_status="未安装"
    if command -v fail2ban-client > /dev/null; then
        if systemctl status fail2ban 2>/dev/null | grep -q "active"; then
            ips_status="Fail2ban 运行中"
        else
            ips_status="Fail2ban 已安装但未运行"
        fi
    elif command -v crowdsec > /dev/null; then
        if systemctl status crowdsec 2>/dev/null | grep -q "active"; then
            ips_status="CrowdSec 运行中"
        else
            ips_status="CrowdSec 已安装但未运行"
        fi
    fi
    echo "    - 状态: $ips_status"
    
    echo "  - 密码策略检查:"
    if [ -f "/etc/login.defs" ]; then
        min_length=$(grep -E "^PASS_MIN_LEN\s+" /etc/login.defs | head -n 1 | awk '{print $2}' | xargs)
        if [ -n "$min_length" ] && [[ "$min_length" =~ ^[0-9]+$ ]]; then
            if (( min_length >= 12 )); then
                echo "    - 密码最小长度: $min_length (符合要求)"
            else
                echo "    - 密码最小长度: $min_length (建议至少12位)"
            fi
        else
            echo "    - 密码最小长度: 未配置 (建议至少12位)"
        fi
        
        has_upper=$(grep "ucredit" /etc/security/pwquality.conf | head -n 1 | awk -F'=' '{print $2}' | xargs)
        has_lower=$(grep "lcredit" /etc/security/pwquality.conf | head -n 1 | awk -F'=' '{print $2}' | xargs)
        has_digit=$(grep "dcredit" /etc/security/pwquality.conf | head -n 1 | awk -F'=' '{print $2}' | xargs)
        has_special=$(grep "ocredit" /etc/security/pwquality.conf | head -n 1 | awk -F'=' '{print $2}' | xargs)
        
        complexity_status="未配置"
        if [ -n "$has_upper" ] && [ -n "$has_lower" ] && [ -n "$has_digit" ] && [ -n "$has_special" ]; then
            complexity_status="已配置"
        fi
        echo "    - 密码复杂度要求: $complexity_status"
    elif [ -f "/etc/pam.d/common-password" ]; then
        if grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
            echo "    - 密码策略: 已配置 (使用 pam_pwquality)"
        else
            echo "    - 密码策略: 未配置"
        fi
    else
        echo "    - 密码策略: 无法检查"
    fi
    
    echo "  - SUID文件检查:"
    common_suid_paths='^/usr/bin/|^/bin/|^/sbin/|^/usr/sbin/|^/usr/lib|^/usr/libexec'
    known_suid_bins='ping$|sudo$|mount$|umount$|su$|passwd$|chsh$|newgrp$|gpasswd$|chfn$'
    
    suspicious_suid_files=$(find / -type f -perm -4000 2>/dev/null | \
        grep -v -E "$common_suid_paths" | \
        grep -v -E "$known_suid_bins" | \
        wc -l)
    
    if [ "$suspicious_suid_files" -eq 0 ]; then
        echo "    - 状态: 未发现可疑的SUID文件"
    else
        echo "    - 状态: 发现 $suspicious_suid_files 个可疑的SUID文件 (建议检查)"
    fi
    
    security_status="正常"
    if (( failed_login_count >= 5 )); then
        security_status="警告"
    fi
    if [ ${#permission_issues[@]} -gt 0 ]; then
        security_status="警告"
    fi
    
    echo "  - 登录失败次数: $failed_login_count"
    if [ -n "$failed_users" ]; then
        echo "  - 登录失败的用户: $failed_users"
    fi
    if [ ${#permission_issues[@]} -gt 0 ]; then
        echo "  - 权限问题:"
        for issue in "${permission_issues[@]}"; do
            echo "    - $issue 权限过于宽松"
        done
    fi
    echo "  - 安全状态: $security_status"
    echo "最近登录:"
    echo "$recent_logins"
    echo ""
}



# 主函数
main() {
    echo "==========================================="
    echo "服务器巡检报告"
    echo "==========================================="
    echo ""
    
    get_host_info
    get_system_summary
    check_cpu
    check_memory
    check_disk
    check_disk_io
    check_processes
    check_services
    check_top_processes
    check_ports
    check_uptime
    check_zombie_processes
    check_network_status
    check_security
    
    echo "==========================================="
    echo "巡检完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==========================================="
}

# 执行主函数
main
