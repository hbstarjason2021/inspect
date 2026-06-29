#!/bin/bash
#查看linux基础信息脚本
#系统名称；
os_type=$(uname -o | awk '{print " | "$0}')

#系统位数；32/64
os_bit=$(uname -m | awk '{print " | "$0}')

#内核发型版本
kernal_version=$(uname -r | awk '{print " | "$0}')

#系统版本信息
sys_info=$(cat /etc/issue | awk '{if($0 ~ /^\w/){print " | "$0}}')

#物理CPU个数：
cpu_actual_number=$(cat /proc/cpuinfo| grep "physical id"| sort| uniq| wc -l | awk '{print " | "$0}')

#逻辑cpu个数：
cpu_virtal_number=$(cat /proc/cpuinfo| grep "processor"| wc -l | awk '{print " | "$0}')

#cpu型号
cpu_version=$(cat /proc/cpuinfo | grep name | cut -f2 -d: | uniq -c | awk '{for(i=2; i<=NF; i++){printf $i" "}}' | awk '{print " | "$0}' )

#内存：
mem_info_total=$(free -h | awk '{print " | "$0}' )

#联网情况：
net_conditon=$(ping -c 1 baidu.com | grep ttl | wc -l)

#磁盘信息：
disk_info=$(fdisk -l | grep "Disk /dev" | awk '{print " | "$0}' )
disk_info_using=$(df -h)

#主机名称
htname=$(hostname | awk '{print " | "$0}')

#网卡列表
eth_list=$(ip addr | awk '{if($0 ~ /^[0-9]\:(.*)$/){print $2}}' | cut -d ":" -f 1 | awk '{print " | "$0}')

#IP信息
ip_list=$(ip addr | grep -E 'inet\b' | awk '{print $2}' | cut -d "/" -f 1 | awk '{print " | "$0}')
echo -e "\n\n"
echo " 系统基本信息"
echo "---------------------------------------------------------------------------------------"
echo "系统名称：$os_type"
echo "主机名称: $htname"
echo "系统位数: $os_bit"
echo "内核版本：$kernal_version"
echo "系统版本: $sys_info"
echo "物理CPU个数：$cpu_actual_number"
echo "逻辑CPU个数：$cpu_virtal_number"
echo "CPU型号：$cpu_version"
echo "网卡列表："
ip addr | awk '{if($0 ~ /^[0-9]\:(.*)$/){print $2}}' | cut -d ":" -f 1 | awk '{print " | "$0}'
echo "IP"
ip addr | grep -E 'inet\b' | awk '{print $2}' | cut -d "/" -f 1 | awk '{print " | "$0}'
echo "内存信息"
free -h | awk '{print " | "$0}'
echo "磁盘信息"
fdisk -l | grep "Disk /dev" | awk '{print " | "$0}'
df -h
