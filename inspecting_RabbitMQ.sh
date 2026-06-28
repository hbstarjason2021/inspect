#!/bin/bash
# ============================================
# RabbitMQ HTTP API 巡检脚本 (curl)
# Version: 1.0
# ============================================
 
# ---------- 基本配置 ----------
RMQ_HOST="127.0.0.1"
RMQ_PORT="15672"
RMQ_USER="guest"
RMQ_PASS="guest"
PROTO="http"
 
API_BASE="${PROTO}://${RMQ_HOST}:${RMQ_PORT}/api"
 
OUT="/tmp/rabbitmq_http_inspect_$(hostname)_$(date +%F_%H%M).txt"
 
CURL="curl -s -u ${RMQ_USER}:${RMQ_PASS}"
 
# ---------- Header ----------
{
echo "==================================="
echo " RabbitMQ 集群巡检报告 (HTTP API)"
echo "生成时间: $(date)"
echo "主机名: $(hostname)"
echo "API 地址: ${API_BASE}"
echo "==================================="
} | tee "$OUT"
 
# ---------- 工具函数 ----------
section () {
  echo -e "\n[$1] $2" | tee -a "$OUT"
}
 
sub () {
  echo -e "\n---- $1 ----" | tee -a "$OUT"
}
 
# ---------- 1. 概览 ----------
section 1 "集群总体概览"
$CURL "${API_BASE}/overview" | tee -a "$OUT"
 
# ---------- 2. 集群与节点 ----------
section 2 "集群与节点状态"
 
sub "节点列表"
$CURL "${API_BASE}/nodes" | tee -a "$OUT"
 
sub "集群名称"
$CURL "${API_BASE}/cluster-name" | tee -a "$OUT"
 
# ---------- 3. 队列与消息 ----------
section 3 "队列与消息状态"
 
sub "所有队列"
$CURL "${API_BASE}/queues" | tee -a "$OUT"
 
sub "死信队列 (DLX/DLQ)"
$CURL "${API_BASE}/queues" \
  | grep -Ei "dead|dlx|dlq" | tee -a "$OUT"
 
# ---------- 4. 交换机 ----------
section 4 "交换机信息"
 
$CURL "${API_BASE}/exchanges" | tee -a "$OUT"
 
# ---------- 5. 连接与通道 ----------
section 5 "连接与通道状态"
 
sub "Connections"
$CURL "${API_BASE}/connections" | tee -a "$OUT"
 
sub "Channels"
$CURL "${API_BASE}/channels" | tee -a "$OUT"
 
# ---------- 6. 绑定关系 ----------
section 6 "Bindings (Exchange ↔ Queue)"
 
$CURL "${API_BASE}/bindings" | tee -a "$OUT"
 
# ---------- 7. 虚拟主机 ----------
section 7 "Vhosts"
 
$CURL "${API_BASE}/vhosts" | tee -a "$OUT"
 
# ---------- 8. 用户与权限 ----------
section 8 "用户与权限"
 
sub "Users"
$CURL "${API_BASE}/users" | tee -a "$OUT"
 
sub "Permissions"
$CURL "${API_BASE}/permissions" | tee -a "$OUT"
 
# ---------- 9. 策略 ----------
section 9 "Policies"
 
$CURL "${API_BASE}/policies" | tee -a "$OUT"
 
# ---------- 10. 健康检查 ----------
section 10 "健康检查"
 
sub "Aliveness Test (/)"
$CURL -X GET "${API_BASE}/aliveness-test/%2F" | tee -a "$OUT"
 
# ---------- Footer ----------
{
echo -e "\n==================================="
echo " 巡检完成，报告文件路径: $OUT"
echo "==================================="
} | tee -a "$OUT"
