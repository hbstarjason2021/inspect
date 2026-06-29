#!/bin/bash

# 配置参数
CONFIG_FILE="servers.conf"
CURRENT_HOST=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "$(hostname)" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no"

# 日志文件路径（可根据实际情况调整）
LOG_PATHS=("/var/log/messages" "/var/log/secure" "/var/log/audit/audit.log")

# 输出目录
OUTPUT_DIR="/mnt/data/ican/assistant-deploy/check-page/events"
LOG_DIR="$OUTPUT_DIR/logs"

# 数据文件
EVENTS_FILE="$OUTPUT_DIR/events.json"
STATUS_FILE="$OUTPUT_DIR/status.json"

# 日志轮转配置
MAX_EVENTS=1000
MAX_LOG_SIZE=10485760 # 10MB

# 确保目录存在
mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# 清理字符串
clean_json_string() {
    echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[\r\n\t]/ /g'
}

# 记录日志（同时写入日志文件，并输出到 stderr 供调试查看）
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/collector.log"
    echo "[$timestamp] [$level] $message" >&2   # 调试信息输出到 stderr，不污染返回值
}

# 检查日志文件大小并轮转
rotate_logs() {
    if [[ -f "$LOG_DIR/collector.log" && $(stat -c "%s" "$LOG_DIR/collector.log" 2>/dev/null || echo 0) -ge $MAX_LOG_SIZE ]]; then
        local backup_file="$LOG_DIR/collector_$(date +"%Y%m%d_%H%M%S").log"
        mv "$LOG_DIR/collector.log" "$backup_file"
        gzip "$backup_file"
        log_message "INFO" "日志文件已轮转，备份为 $backup_file.gz"
    fi
}

# 读取服务器列表
read_servers() {
    local servers=()
    if [[ -f "$CONFIG_FILE" ]]; then
        mapfile -t servers < "$CONFIG_FILE"
        local clean_servers=()
        for server in "${servers[@]}"; do
            server=$(echo "$server" | tr -d '\r\n' | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            if [[ -n "$server" && ! "$server" =~ ^[[:space:]]*# ]]; then
                ip=$(echo "$server" | cut -d':' -f1)
                clean_servers+=($ip)
            fi
        done
        servers=(${clean_servers[@]})
    else
        servers=()
    fi
    echo "${servers[@]}"
}

# 主函数
main() {
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    local all_warnings=()
    local collected_count=0
    
    log_message "INFO" "开始抓取远程服务器的 journalctl -p warning 前五条数据"
    
    # 读取服务器列表
    local servers=($(read_servers))
    log_message "INFO" "服务器列表: ${servers[@]}"
    
    # 遍历所有服务器
    for server in "${servers[@]}"; do
        log_message "INFO" "处理服务器: $server"
        
        # 测试 SSH 连接
        log_message "INFO" "测试连接到服务器: $server"
        ssh $SSH_OPTS "$server" "echo ok" &>/dev/null || {
            log_message "WARN" "无法连接到服务器: $server"
            continue
        }
        log_message "INFO" "成功连接到服务器: $server"
        
        # 执行 journalctl 命令，只获取前五条警告
        log_message "INFO" "执行远程 journalctl 命令: journalctl -p warning -n 5 --no-pager"
        local log_content=$(ssh $SSH_OPTS "$server" "journalctl -p warning -n 5 --no-pager" 2>&1)
        log_message "INFO" "远程 journalctl 命令执行结果长度: ${#log_content}"
        
        if [[ -n "$log_content" ]]; then
            log_message "INFO" "开始处理 journalctl 输出"
            local line_count=0
            
            # 处理输出，只取前五条
            while read -r line && [[ $line_count -lt 5 ]]; do
                line_count=$((line_count + 1))
                log_message "DEBUG" "第 $line_count 行: $line"
                
                # 提取时间戳
                local timestamp=$(echo "$line" | awk '{print $1, $2, $3}' | head -1)
                if [[ -z "$timestamp" ]]; then
                    timestamp=$(date +"%b %d %H:%M:%S")
                fi
                
                # 提取服务名
                local service=$(echo "$line" | awk '{print $5}' | head -1)
                if [[ "$service" == *":" ]]; then
                    service=$(echo "$service" | sed 's/:$//')
                fi
                
                # 提取详细信息
                local detail=$(echo "$line" | cut -d' ' -f6- 2>/dev/null || echo "$line")
                detail=$(clean_json_string "$detail")
                
                # 确定警告级别
                local level="WARNING"
                if [[ "$line" =~ "ERROR" || "$line" =~ "error" ]]; then
                    level="ERROR"
                elif [[ "$line" =~ "CRITICAL" || "$line" =~ "critical" ]]; then
                    level="CRITICAL"
                elif [[ "$line" =~ "ALERT" || "$line" =~ "alert" ]]; then
                    level="ALERT"
                fi
                
                # 计算优先级
                local priority=4
                case "$level" in
                    "CRITICAL") priority=1 ;;
                    "ERROR") priority=2 ;;
                    "ALERT") priority=3 ;;
                    "WARNING") priority=4 ;;
                    "WARN") priority=4 ;;
                    *) priority=5 ;;
                esac
                
                # 构建警告对象
                local warning=$(printf '{"timestamp":"%s","server":"%s","level":"%s","priority":%d,"service":"%s","detail":"%s","log_path":"journalctl","collected_at":"%s"}' "$timestamp" "$server" "$level" "$priority" "$service" "$detail" "$current_time")
                # 确保 warning 不为空
                if [[ -n "$warning" ]]; then
                    all_warnings+=($warning)
                fi
            done <<< "$log_content"
            
            log_message "INFO" "服务器 $server 处理完成，共收集到 $line_count 条警告"
            collected_count=$((collected_count + line_count))
        else
            log_message "INFO" "journalctl 输出为空"
        fi
    done
    
    log_message "INFO" "总共收集到 $collected_count 条警告"
    
    # 构建事件数组
    local events_array="[]"
    if [[ ${#all_warnings[@]} -gt 0 ]]; then
        # 确保数组中的每个元素都是有效的 JSON
        local valid_warnings=()
        for warn in "${all_warnings[@]}"; do
            if [[ -n "$warn" ]]; then
                valid_warnings+=($warn)
            fi
        done
        if [[ ${#valid_warnings[@]} -gt 0 ]]; then
            events_array="["$(IFS=","; echo "${valid_warnings[*]}")"]"
        fi
    fi
    
    # 加载现有事件数据
    local existing_events='{"events": []}'
    if [[ -f "$EVENTS_FILE" ]]; then
        existing_events=$(cat "$EVENTS_FILE" 2>/dev/null || echo '{"events": []}')
    fi
    
    # 提取现有事件
    local existing_array=$(echo "$existing_events" | jq '.events' 2>/dev/null || echo '[]')
    
    # 合并新事件和现有事件
    local combined_array
    if [[ ${#all_warnings[@]} -gt 0 ]]; then
        combined_array=$(echo "$existing_array" | jq --argjson new "$events_array" '. + $new' 2>/dev/null || echo "$existing_array")
    else
        combined_array="$existing_array"
    fi
    
    # 限制事件数量
    local limited_array=$(echo "$combined_array" | jq '.[-"$MAX_EVENTS":]' 2>/dev/null || echo "$combined_array")
    
    # 计算最终事件数量
    local final_count=$(echo "$limited_array" | jq '. | length' 2>/dev/null || echo 0)
    
    # 构建最终JSON
    local final_json=$(printf '{
        "events": %s,
        "total": %d,
        "last_updated": "%s"
    }' "$limited_array" "$final_count" "$current_time")
    
    # 保存数据
    echo "$final_json" > "$EVENTS_FILE"
    
    # 更新状态
    local status_json=$(printf '{
        "status": "completed",
        "message": "成功收集 %d 条警告信息，历史总计 %d 条",
        "last_run": "%s",
        "last_run_timestamp": %d
    }' "$collected_count" "$final_count" "$current_time" "$(date +%s)")
    echo "$status_json" > "$STATUS_FILE"
    
    # 记录完成日志
    log_message "INFO" "事件警告收集完成，共收集 $collected_count 条信息"
    
    # 轮转日志
    rotate_logs
    
    # 输出JSON结果（这是唯一的 stdout 输出，供调用方解析）
    echo "$final_json"
}

# 执行主函数，将 stderr 重定向到标准输出，以便查看完整的错误信息
main 2>&1