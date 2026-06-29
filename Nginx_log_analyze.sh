#!/bin/bash
# Nginx日志自动化分析脚本 - 运维项目Demo
# 功能：分析PV/UV、状态码、热门接口、异常IP

# 配置项
LOG_FILE="/var/log/nginx/access.log"  # 你的Nginx日志路径
REPORT_DIR="./nginx_report"
mkdir -p $REPORT_DIR

# 1. PV/UV统计
echo "=== 1. PV/UV统计 ===" > $REPORT_DIR/nginx_analysis.txt
PV=$(wc -l < $LOG_FILE)
UV=$(awk '{print $1}' $LOG_FILE | sort -u | wc -l)
echo "PV: $PV" >> $REPORT_DIR/nginx_analysis.txt
echo "UV: $UV" >> $REPORT_DIR/nginx_analysis.txt

# 2. HTTP状态码分布
echo -e "\n=== 2. HTTP状态码分布 ===" >> $REPORT_DIR/nginx_analysis.txt
awk '{print $9}' $LOG_FILE | grep -E '^[0-9]{3}$' | sort | uniq -c | sort -nr >> $REPORT_DIR/nginx_analysis.txt

# 3. 热门访问接口（Top 10）
echo -e "\n=== 3. 热门访问接口（Top 10） ===" >> $REPORT_DIR/nginx_analysis.txt
awk '{print $7}' $LOG_FILE | grep -v '^-' | sort | uniq -c | sort -nr | head -10 >> $REPORT_DIR/nginx_analysis.txt

# 4. 异常访问IP（请求次数>100次，疑似爬虫/攻击）
echo -e "\n=== 4. 高频访问IP（疑似异常） ===" >> $REPORT_DIR/nginx_analysis.txt
awk '{print $1}' $LOG_FILE | sort | uniq -c | sort -nr | awk '$1 > 100 {print $2 " - " $1 "次请求"}' >> $REPORT_DIR/nginx_analysis.txt

# 5. 5xx错误接口统计
echo -e "\n=== 5. 5xx错误接口统计 ===" >> $REPORT_DIR/nginx_analysis.txt
awk '$9 ~ /^5../ {print $7}' $LOG_FILE | sort | uniq -c | sort -nr >> $REPORT_DIR/nginx_analysis.txt

echo "分析完成，报告已生成: $REPORT_DIR/nginx_analysis.txt"
