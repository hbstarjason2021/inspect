#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Linux 服务器自动巡检脚本
功能：检查 CPU、内存、磁盘、进程、网络端口状态，并生成报告和发送告警
"""

import os
import time
import psutil
import socket
import json
import requests
from datetime import datetime

# 告警配置
ALERT_CONFIG = {
    'type': 'dingtalk',  # 可选: 'dingtalk' 或 'wecom'
    'webhook': ''        # 告警 Webhook URL
}

# 要检查的进程和端口
CHECK_PROCESSES = ['sshd', 'nginx', 'mysql', 'redis']
CHECK_PORTS = [22, 80, 443, 3306, 6379]

# 要检查的关键服务
CHECK_SERVICES = ['sshd', 'cron', 'syslog-ng', 'rsyslog']

class ServerMonitor:
    def __init__(self):
        self.hostname = socket.gethostname()
        self.ip = self.get_local_ip()
        self.results = {}
        
    def get_local_ip(self):
        
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except:
            return '127.0.0.1'
    
    def check_cpu(self):
        """检查 CPU 使用率和负载"""
        cpu_percent = psutil.cpu_percent(interval=1)
        cpu_load = psutil.getloadavg()  # 获取CPU负载
        # 根据CPU核心数判断负载状态
        cpu_count = psutil.cpu_count()
        load_status = "正常"
        if cpu_load[0] > cpu_count * 0.8:  # 1分钟负载
            load_status = "警告"
        
        status = "正常" if cpu_percent < 80 else "警告"
        self.results['cpu'] = {
            '使用率': f"{cpu_percent}%",
            '1分钟负载': f"{cpu_load[0]:.2f}",
            '5分钟负载': f"{cpu_load[1]:.2f}",
            '15分钟负载': f"{cpu_load[2]:.2f}",
            '状态': status,
            '负载状态': load_status
        }
        return cpu_percent
    
    def check_memory(self):
        """检查内存使用率"""
        mem = psutil.virtual_memory()
        mem_percent = mem.percent
        status = "正常" if mem_percent < 80 else "警告"
        self.results['内存'] = {
            '使用率': f"{mem_percent}%",
            '总内存': f"{mem.total / 1024 / 1024 / 1024:.2f}GB",
            '可用内存': f"{mem.available / 1024 / 1024 / 1024:.2f}GB",
            '状态': status
        }
        return mem_percent
    
    def check_disk(self):
        """检查磁盘使用率"""
        disk_info = []
        for partition in psutil.disk_partitions():
            if partition.fstype:
                try:
                    usage = psutil.disk_usage(partition.mountpoint)
                    usage_percent = usage.percent
                    status = "正常" if usage_percent < 85 else "警告"
                    disk_info.append({
                        '挂载点': partition.mountpoint,
                        '文件系统': partition.fstype,
                        '使用率': f"{usage_percent}%",
                        '总空间': f"{usage.total / 1024 / 1024 / 1024:.2f}GB",
                        '可用空间': f"{usage.free / 1024 / 1024 / 1024:.2f}GB",
                        '状态': status
                    })
                except:
                    pass
        self.results['磁盘'] = disk_info
        return disk_info
    
    def check_disk_io(self):
        """检查磁盘IO状态"""
        import subprocess
        import platform
        
        # 检查操作系统类型
        if platform.system() == 'Linux':
            try:

                output = subprocess.check_output(
                    ['iostat', '-xd', '2', '2'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                
                lines = output.strip().split('\n')
                device_lines = []
                start_processing = False
                for line in lines:
                    if 'Device' in line:
                        start_processing = True
                        device_lines = []
                        continue
                    if start_processing and line.strip():
                        device_lines.append(line)
                
                disk_io_info = []
                for line in device_lines:
                    parts = line.strip().split()
                    if len(parts) >= 14:  
                        device = parts[0]
                        rrqm_percent = parts[1]  # %rrqm
                        wrqm_percent = parts[2]  # %wrqm
                        r_await = parts[9]  # r_await
                        w_await = parts[10]  # w_await
                        avgqu_sz = parts[11]  # avgqu-sz
                        util_percent = parts[13]  # %util
                        
                        io_status = "正常"
                        if float(util_percent) > 80: 
                            io_status = "警告"
                        
                        disk_io_info.append({
                            '设备': device,
                            '%rrqm': rrqm_percent,
                            '%wrqm': wrqm_percent,
                            'r_await': r_await,
                            'w_await': w_await,
                            'avgqu-sz': avgqu_sz,
                            '%util': util_percent,
                            '状态': io_status
                        })
                
                self.results['磁盘IO'] = disk_io_info
                return self.results['磁盘IO']
            except Exception as e:
                self.results['磁盘IO'] = {
                    '错误': f"无法获取磁盘IO信息: {str(e)}",
                    '状态': "警告"
                }
                return self.results['磁盘IO']
        else:

            disk_io = psutil.disk_io_counters()
            read_bytes = disk_io.read_bytes / 1024 / 1024  # MB
            write_bytes = disk_io.write_bytes / 1024 / 1024  # MB
            read_count = disk_io.read_count
            write_count = disk_io.write_count
            
            io_status = "正常"
            if read_bytes > 1000 or write_bytes > 1000:  # 假设1000MB为阈值
                io_status = "警告"
            
            self.results['磁盘IO'] = [{
                '设备': '总磁盘',
                '%rrqm': 'N/A',
                '%wrqm': 'N/A',
                'r_await': 'N/A',
                'w_await': 'N/A',
                'avgqu-sz': 'N/A',
                '%util': 'N/A',
                '读取字节': f"{read_bytes:.2f} MB",
                '写入字节': f"{write_bytes:.2f} MB",
                '读取次数': read_count,
                '写入次数': write_count,
                '状态': io_status
            }]
            return self.results['磁盘IO']
    
    def check_processes(self, process_names):
        """检查进程状态"""
        process_status = []
        for name in process_names:
            found = False
            for proc in psutil.process_iter(['name']):
                try:
                    if name.lower() in proc.info['name'].lower():
                        found = True
                        break
                except:
                    pass
            status = "运行中" if found else "未运行"
            process_status.append({
                '进程名': name,
                '状态': status
            })
        self.results['进程'] = process_status
        return process_status
    
    def check_top_processes(self):
        """检查CPU和内存使用最高的前5个进程"""
        import subprocess
        top_mem_processes = []
        try:
            output = subprocess.check_output(
                ['ps', '-eo', 'pid,comm,%mem', '--sort=-%mem'],
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            lines = output.strip().split('\n')[1:6]  
            for line in lines:
                parts = line.strip().split()
                if len(parts) >= 3:
                    pid = int(parts[0])
                    name = ' '.join(parts[1:-1]) 
                    mem_percent = float(parts[-1])
                    top_mem_processes.append({
                        'pid': pid,
                        'name': name,
                        'memory_percent': mem_percent
                    })
        except:
            pass
        
        # 使用 ps 命令获取CPU使用最高的前5个进程
        top_cpu_processes = []
        try:
            output = subprocess.check_output(
                ['ps', '-eo', 'pid,comm,%cpu', '--sort=-%cpu'],
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            lines = output.strip().split('\n')[1:6] 
            for line in lines:
                parts = line.strip().split()
                if len(parts) >= 3:
                    pid = int(parts[0])
                    name = ' '.join(parts[1:-1]) 
                    cpu_percent = float(parts[-1])
                    top_cpu_processes.append({
                        'pid': pid,
                        'name': name,
                        'cpu_percent': cpu_percent
                    })
        except:
            pass
        
        self.results['top_processes'] = {
            'cpu': top_cpu_processes,
            'memory': top_mem_processes
        }
        return self.results['top_processes']
    
    def check_ports(self, ports):
        """检查网络端口"""
        port_status = []
        for port in ports:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(2)
            result = sock.connect_ex((self.ip, port))
            status = "开放" if result == 0 else "关闭"
            sock.close()
            port_status.append({
                '端口': port,
                '状态': status
            })
        self.results['端口'] = port_status
        return port_status
    
    def check_uptime(self):
        """检查系统启动时间"""
        uptime_seconds = time.time() - psutil.boot_time()
        days = int(uptime_seconds // 86400)
        hours = int((uptime_seconds % 86400) // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        uptime_str = f"{days}天{hours}小时{minutes}分钟"
        boot_time = datetime.fromtimestamp(psutil.boot_time()).strftime("%Y-%m-%d %H:%M:%S")
        self.results['系统启动时间'] = {
            '运行时间': uptime_str,
            '启动时间': boot_time
        }
        return uptime_str
    
    def check_zombie_processes(self):
        """检查僵尸进程数量"""
        zombie_count = 0
        for proc in psutil.process_iter(['status']):
            try:
                if proc.info['status'] == psutil.STATUS_ZOMBIE:
                    zombie_count += 1
            except:
                pass
        status = "正常" if zombie_count == 0 else "警告"
        self.results['僵尸进程'] = {
            '数量': zombie_count,
            '状态': status
        }
        return zombie_count
    
    def check_network_status(self):
        """检查网络状态"""
        network_info = []
        net_io = psutil.net_io_counters()
        total_bytes_sent = net_io.bytes_sent / 1024 / 1024  
        total_bytes_recv = net_io.bytes_recv / 1024 / 1024 
        
        for interface, addrs in psutil.net_if_addrs().items():
            if interface != 'lo':  
                try:
                    interface_io = psutil.net_io_counters(pernic=True).get(interface, None)
                    if interface_io:
                        interface_sent = interface_io.bytes_sent / 1024 / 1024  
                        interface_recv = interface_io.bytes_recv / 1024 / 1024  
                    else:
                        interface_sent = 0.0
                        interface_recv = 0.0
                except:
                    interface_sent = 0.0
                    interface_recv = 0.0
                
                interface_info = {
                    '接口': interface,
                    '发送流量': f"{interface_sent:.2f} MB",
                    '接收流量': f"{interface_recv:.2f} MB"
                }
                network_info.append(interface_info)
        
        connections = psutil.net_connections()
        connection_count = len(connections)
        ping_result = self.ping_test('www.baidu.com')
        
        self.results['网络状态'] = {
            '接口信息': network_info,
            '总发送流量': f"{total_bytes_sent:.2f} MB",
            '总接收流量': f"{total_bytes_recv:.2f} MB",
            '连接数': connection_count,
            '网络延迟': f"{ping_result} ms",
            '状态': "正常" if ping_result < 100 else "警告"
        }
        return network_info
    
    def ping_test(self, host):
        """测试网络延迟"""
        import socket
        import time
        try:
            ip = socket.gethostbyname(host)
            print(f"解析主机 {host} 为 IP: {ip}")
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)            
            start_time = time.time()
            sock.connect((ip, 80))
            end_time = time.time()
            latency = round((end_time - start_time) * 1000, 1) 
            print(f"网络延迟: {latency:.1f} ms")
            sock.close()
            return latency
        except socket.gaierror as e:
            print(f"域名解析失败: {e}")
            return 9999
        except socket.timeout as e:
            print(f"连接超时: {e}")
            return 9999
        except Exception as e:
            print(f"网络测试失败: {e}")
            return 9999
    
    def check_security(self):
        """检查安全状态"""
        import platform
        import subprocess
        failed_login_count, failed_users = self.get_failed_login_count()
        recent_logins = self.get_recent_logins()
        critical_files = ['/etc/shadow', '/etc/sudoers'] 
        permission_issues = []
        for file_path in critical_files:
            if os.path.exists(file_path):
                try:
                    stat = os.stat(file_path)
                    if stat.st_mode & 0o007 != 0:  # 其他用户有写权限
                        permission_issues.append(f"{file_path} 权限过于宽松")
                except:
                    pass
        
        ssh_config = self.check_ssh_config()
        auto_update = self.check_auto_update()
        ips_status = self.check_ips()
        password_policy = self.check_password_policy()
        suid_files = self.check_suid_files()
        status = "正常" if failed_login_count < 5 and len(permission_issues) == 0 else "警告"
        self.results['安全状态'] = {
            '登录失败次数': failed_login_count,
            '登录失败的用户': failed_users,
            '最近登录': recent_logins,
            '权限问题': permission_issues,
            'SSH配置': ssh_config,
            '自动更新': auto_update,
            '入侵防御系统': ips_status,
            '密码策略': password_policy,
            'SUID文件': suid_files,
            '状态': status
        }
        return status
    
    def check_ssh_config(self):
        """检查SSH配置"""
        ssh_config = {
            'Root登录': '允许 (安全风险)',
            '密码认证': '启用',
            'SSH端口': '默认端口 (建议更改)'
        }
        
        try:
            sshd_config_path = '/etc/ssh/sshd_config'
            if os.path.exists(sshd_config_path):
                with open(sshd_config_path, 'r') as f:
                    content = f.read()
                import re
                root_login_match = re.search(r'^PermitRootLogin\s+(\w+)', content, re.MULTILINE)
                if root_login_match:
                    root_login = root_login_match.group(1)
                    if root_login == 'no':
                        ssh_config['Root登录'] = '已禁用'
                    else:
                        ssh_config['Root登录'] = '允许 (安全风险)'
                
                password_auth_match = re.search(r'^PasswordAuthentication\s+(\w+)', content, re.MULTILINE)
                if password_auth_match:
                    password_auth = password_auth_match.group(1)
                    if password_auth == 'no':
                        ssh_config['密码认证'] = '已禁用 (推荐)'
                    else:
                        ssh_config['密码认证'] = '启用'
                
                port_match = re.search(r'^Port\s+(\d+)', content, re.MULTILINE)
                if port_match:
                    port = port_match.group(1)
                    if port != '22':
                        ssh_config['SSH端口'] = port
                    else:
                        ssh_config['SSH端口'] = '默认端口 (建议更改)'
        except:
            pass
        
        return ssh_config
    
    def check_auto_update(self):
        """检查自动更新"""
        auto_update = "未配置 (建议启用)"
        
        try:
            import platform
            if platform.system() == 'Linux':
                if os.path.exists('/etc/apt/apt.conf.d/20auto-upgrades'):
                    auto_update = "已配置"
                elif os.path.exists('/etc/sysconfig/yum-cron'):
                    auto_update = "已配置"
        except:
            pass
        
        return auto_update
    
    def check_ips(self):
        """检查入侵防御系统"""
        ips_status = "未安装"
        
        try:
            import subprocess
            # 检查 fail2ban
            if subprocess.call(['which', 'fail2ban-client'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) == 0:
                output = subprocess.check_output(
                    ['systemctl', 'status', 'fail2ban'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                if 'active (running)' in output:
                    ips_status = "Fail2ban 运行中"
                else:
                    ips_status = "Fail2ban 已安装但未运行"
            # 检查 crowdsec
            elif subprocess.call(['which', 'crowdsec'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) == 0:
                output = subprocess.check_output(
                    ['systemctl', 'status', 'crowdsec'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                if 'active (running)' in output:
                    ips_status = "CrowdSec 运行中"
                else:
                    ips_status = "CrowdSec 已安装但未运行"
        except:
            pass
        
        return ips_status
    
    def check_password_policy(self):
        """检查密码策略"""
        password_policy = {
            '最小长度': '未配置',
            '复杂度要求': '未配置'
        }
        
        try:
            if os.path.exists('/etc/login.defs'):
                with open('/etc/login.defs', 'r') as f:
                    content = f.read()
                
                import re
                minlen_match = re.search(r'^PASS_MIN_LEN\s+(\d+)', content, re.MULTILINE)
                if minlen_match:
                    minlen = minlen_match.group(1)
                    if int(minlen) >= 12:
                        password_policy['最小长度'] = f"{minlen} (符合要求)"
                    else:
                        password_policy['最小长度'] = f"{minlen} (建议至少12位)"
                else:
                    password_policy['最小长度'] = "8 (建议至少12位)"
            
            if os.path.exists('/etc/security/pwquality.conf'):
                with open('/etc/security/pwquality.conf', 'r') as f:
                    content = f.read()
                
                has_upper = re.search(r'^ucredit\s*=\s*(-?\d+)', content, re.MULTILINE)
                has_lower = re.search(r'^lcredit\s*=\s*(-?\d+)', content, re.MULTILINE)
                has_digit = re.search(r'^dcredit\s*=\s*(-?\d+)', content, re.MULTILINE)
                has_special = re.search(r'^ocredit\s*=\s*(-?\d+)', content, re.MULTILINE)
                
                if has_upper and has_lower and has_digit and has_special:
                    password_policy['复杂度要求'] = '已配置'
                else:
                    password_policy['复杂度要求'] = '未配置'
        except:
            password_policy['最小长度'] = "8 (建议至少12位)"
            password_policy['复杂度要求'] = '未配置'
        
        return password_policy
    
    def check_suid_files(self):
        """检查SUID文件"""
        suspicious_suid_files = 0
        
        try:
            import subprocess
            output = subprocess.check_output(
                ['find', '/', '-type', 'f', '-perm', '-4000', '-not', '-path', '*/proc/*', '-not', '-path', '*/sys/*', '-not', '-path', '*/dev/*'],
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            
            common_suid_files = ['/usr/bin/ping', '/usr/bin/sudo', '/usr/bin/mount', '/usr/bin/umount', '/usr/bin/su', '/usr/bin/passwd', '/usr/bin/chsh', '/usr/bin/newgrp', '/usr/bin/gpasswd', '/usr/bin/chfn']
            suid_files = [f for f in output.strip().split('\n') if f and f not in common_suid_files]
            suspicious_suid_files = len(suid_files)
        except:
            pass
        
        if suspicious_suid_files == 0:
            status = '未发现可疑的SUID文件'
        else:
            status = f'发现 {suspicious_suid_files} 个可疑的SUID文件 (建议检查)'
        
        return {
            '状态': status
        }
    
    def check_selinux(self):
        """检查 SELinux 状态"""
        try:
            import subprocess
            output = subprocess.check_output(
                ['getenforce'],
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            selinux_status = output.strip()
            if selinux_status == 'Enforcing':
                selinux_status_cn = "开启"
            elif selinux_status == 'Permissive':
                selinux_status_cn = "宽松"
            else:
                selinux_status_cn = "关闭"
            status = "正常"
        except:
            selinux_status_cn = "未安装或不可用"
            status = "警告"
        
        self.results['SELinux'] = {
            '状态': selinux_status_cn
        }
        return self.results['SELinux']
    
    def get_system_summary(self):
        """获取系统信息摘要"""
        import platform
        import subprocess
        os_info = platform.platform()
        kernel_version = platform.release()
        cpu_cores = psutil.cpu_count()
        cpu_model = "未知"
        try:
            if platform.system() == 'Linux':
                output = subprocess.check_output(
                    ['cat', '/proc/cpuinfo'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                for line in output.split('\n'):
                    if 'model name' in line:
                        cpu_model = line.split(':')[1].strip()
                        break
            elif platform.system() == 'Windows':
                cpu_model = platform.processor()
        except:
            pass
        mem = psutil.virtual_memory()
        total_memory = f"{mem.total / 1024 / 1024 / 1024:.2f}GB"
        total_disk = "未知"
        try:
            if platform.system() == 'Linux':
                output = subprocess.check_output(
                    ['df', '-h', '/'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                lines = output.strip().split('\n')
                if len(lines) > 1:
                    total_disk = lines[1].split()[1]
            elif platform.system() == 'Windows':
                # 获取C盘总空间
                for partition in psutil.disk_partitions():
                    if partition.mountpoint == 'C:':
                        usage = psutil.disk_usage(partition.mountpoint)
                        total_disk = f"{usage.total / 1024 / 1024 / 1024:.2f}GB"
                        break
        except:
            pass
        
        public_ip = "无法获取"
        try:
            response = requests.get('https://api.ipify.org', timeout=3)
            if response.status_code == 200:
                public_ip = response.text.strip()
        except:
            pass
        load_average = "未知"
        try:
            if platform.system() == 'Linux':
                load = psutil.getloadavg()
                load_average = f"{load[0]:.2f}, {load[1]:.2f}, {load[2]:.2f}"
        except:
            pass
        
        self.results['系统信息摘要'] = {
            '操作系统': os_info,
            '内核版本': kernel_version,
            'CPU型号': cpu_model,
            'CPU核心数': cpu_cores,
            '总内存': total_memory,
            '总磁盘空间': total_disk,
            '公网IP': public_ip,
            '负载平均值': load_average
        }
        return self.results['系统信息摘要']
    
    def check_services(self):
        """检查系统服务状态"""
        import platform
        import subprocess
        
        running_services = 0
        total_services = 0
        critical_services = []
        service_status = {}
        try:
            if platform.system() == 'Linux':
                if subprocess.call(['which', 'systemctl'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) == 0:
                    output = subprocess.check_output(
                        ['systemctl', 'list-units', '--type=service', '--state=running'],
                        stderr=subprocess.STDOUT,
                        universal_newlines=True
                    )
                    running_services = len([line for line in output.split('\n') if 'loaded active running' in line])
                    output = subprocess.check_output(
                        ['systemctl', 'list-units', '--type=service'],
                        stderr=subprocess.STDOUT,
                        universal_newlines=True
                    )
                    total_services = len([line for line in output.split('\n') if 'loaded' in line])
                    critical_service_list = CHECK_SERVICES
                    for service in critical_service_list:
                        try:
                            output = subprocess.check_output(
                                ['systemctl', 'status', service],
                                stderr=subprocess.STDOUT,
                                universal_newlines=True
                            )
                            if 'active (running)' in output:
                                critical_services.append({'服务名': service, '状态': '运行中'})
                            else:
                                critical_services.append({'服务名': service, '状态': '未运行'})
                        except:
                            critical_services.append({'服务名': service, '状态': '未安装'})
        except:
            pass
        
        self.results['系统服务'] = {
            '运行的服务数量': running_services,
            '总服务数量': total_services,
            '关键服务状态': critical_services
        }
        return self.results['系统服务']
    
    def check_firewall(self):
        """检查防火墙状态和允许的端口/协议"""
        firewall_status = "未运行"
        allowed_ports = []
        status = "正常"
        
        try:
            import subprocess
            checked = False
            try:
                subprocess.check_output(
                    ['which', 'firewalld'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                output = subprocess.check_output(
                    ['systemctl', 'status', 'firewalld'],
                    stderr=subprocess.STDOUT,
                    universal_newlines=True
                )
                if 'active (running)' in output:
                    firewall_status = "运行中 (firewalld)"
                    try:
                        output = subprocess.check_output(
                            ['firewall-cmd', '--list-all'],
                            stderr=subprocess.STDOUT,
                            universal_newlines=True
                        )
                        for line in output.split('\n'):
                            if 'ports:' in line:
                                ports = line.split('ports:')[1].strip()
                                if ports:
                                    allowed_ports.extend(ports.split())
                            elif 'services:' in line:
                                services = line.split('services:')[1].strip()
                                if services:
                                    allowed_ports.extend(services.split())
                    except:
                        pass
                checked = True
            except:
                pass
            if not checked:
                try:
                    subprocess.check_output(
                        ['which', 'ufw'],
                        stderr=subprocess.STDOUT,
                        universal_newlines=True
                    )
                    output = subprocess.check_output(
                        ['ufw', 'status'],
                        stderr=subprocess.STDOUT,
                        universal_newlines=True
                    )
                    if 'active' in output:
                        firewall_status = "运行中 (ufw)"
                        for line in output.split('\n'):
                            if '/' in line and ('ALLOW' in line or 'allow' in line):
                                parts = line.split()
                                if parts:
                                    allowed_ports.append(parts[0])
                    checked = True
                except:
                    pass
            
            if not checked:
                try:
                    subprocess.check_output(
                        ['which', 'iptables'],
                        stderr=subprocess.STDOUT,
                        universal_newlines=True
                    )
                    try:
                        output = subprocess.check_output(
                            ['systemctl', 'status', 'iptables'],
                            stderr=subprocess.STDOUT,
                            universal_newlines=True
                        )
                        if 'active (running)' in output:
                            firewall_status = "运行中 (iptables)"
                    except:
                        output = subprocess.check_output(
                            ['iptables', '-L'],
                            stderr=subprocess.STDOUT,
                            universal_newlines=True
                        )
                        non_default_rules = False
                        for line in output.split('\n'):
                            if 'ACCEPT' in line and ('dpt:' in line or 'sport:' in line):
                                non_default_rules = True
                                parts = line.split()
                                for part in parts:
                                    if 'dpt:' in part:
                                        port = part.split(':')[1]
                                        allowed_ports.append(port)
                        if non_default_rules:
                            firewall_status = "运行中 (iptables)"
                except:
                    pass
        except:
            pass
        
        self.results['防火墙'] = {
            '状态': firewall_status,
            '允许的端口/服务': allowed_ports
        }
        return self.results['防火墙']
    
    def get_failed_login_count(self):
        """获取登录失败次数和失败的用户"""
        import subprocess
        try:
            log_files = ['/var/log/auth.log', '/var/log/secure']
            failed_count = 0
            failed_users = []
            
            for log_file in log_files:
                if os.path.exists(log_file):
                    try:
                        output = subprocess.check_output(
                            ['grep', 'Failed password', log_file],
                            stderr=subprocess.STDOUT,
                            universal_newlines=True
                        )
                        lines = output.split('\n')
                        failed_count += len(lines) - 1
                        for line in lines:
                            if 'for' in line and 'from' in line:
                                parts = line.split()
                                if 'for' in parts:
                                    user_index = parts.index('for') + 1
                                    if user_index < len(parts):
                                        if parts[user_index] == 'invalid' and user_index + 1 < len(parts) and parts[user_index + 1] == 'user':
                                            if user_index + 2 < len(parts):
                                                user = parts[user_index + 2]
                                                if user not in failed_users:
                                                    failed_users.append(user)
                                        else:
                                            user = parts[user_index]
                                            if user not in failed_users:
                                                failed_users.append(user)
                    except:
                        pass
            return failed_count, failed_users
        except:
            return 0, []
    
    def get_recent_logins(self):
        """获取最近登录记录"""
        import subprocess
        try:
            output = subprocess.check_output(
                ['last', '-n', '5'],
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            login_records = []
            for line in output.split('\n'):
                if line and not line.startswith('wtmp begins'):
                    parts = line.split()
                    if len(parts) >= 5:
                        user = parts[0]
                        ip = parts[-1] if parts[-1].count('.') == 3 else "本地登录"
                        if len(parts) >= 10:
                            time_info = ' '.join(parts[3:9])
                            login_records.append(f"用户: {user}, IP: {ip}, 时间: {time_info}")
            return '\n'.join(login_records) if login_records else "无登录记录"
        except:
            return "无法获取登录记录"
    
    def generate_report(self):
        """生成巡检报告"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        report = f"""===========================================
服务器巡检报告
===========================================
主机名: {self.hostname}
IP地址: {self.ip}
巡检时间: {timestamp}

【系统信息摘要】
操作系统: {self.results['系统信息摘要']['操作系统']}
内核版本: {self.results['系统信息摘要']['内核版本']}
CPU型号: {self.results['系统信息摘要']['CPU型号']}
CPU核心数: {self.results['系统信息摘要']['CPU核心数']}
总内存: {self.results['系统信息摘要']['总内存']}
总磁盘空间: {self.results['系统信息摘要']['总磁盘空间']}
公网IP: {self.results['系统信息摘要']['公网IP']}
负载平均值: {self.results['系统信息摘要']['负载平均值']}

【CPU 状态】
使用率: {self.results['cpu']['使用率']}
1分钟负载: {self.results['cpu']['1分钟负载']}
5分钟负载: {self.results['cpu']['5分钟负载']}
15分钟负载: {self.results['cpu']['15分钟负载']}
负载状态: {self.results['cpu']['负载状态']}

【内存状态】
使用率: {self.results['内存']['使用率']}
总内存: {self.results['内存']['总内存']}
可用内存: {self.results['内存']['可用内存']}
状态: {self.results['内存']['状态']}

【磁盘状态】
"""
        
        for disk in self.results['磁盘']:
            report += f"挂载点: {disk['挂载点']}\n"
            report += f"文件系统: {disk['文件系统']}\n"
            report += f"使用率: {disk['使用率']}\n"
            report += f"总空间: {disk['总空间']}\n"
            report += f"可用空间: {disk['可用空间']}\n"
            report += f"状态: {disk['状态']}\n\n"
        
        report += "【磁盘IO状态】\n"
        if isinstance(self.results['磁盘IO'], list):
            for device in self.results['磁盘IO']:
                report += f"设备: {device['设备']}\n"
                report += f"  %rrqm: {device['%rrqm']}\n"
                report += f"  %wrqm: {device['%wrqm']}\n"
                report += f"  r_await: {device['r_await']}\n"
                report += f"  w_await: {device['w_await']}\n"
                report += f"  avgqu-sz: {device['avgqu-sz']}\n"
                report += f"  %util: {device['%util']}\n"
                report += f"  状态: {device['状态']}\n\n"
        else:
            report += f"错误: {self.results['磁盘IO'].get('错误', '未知错误')}\n"
            report += f"状态: {self.results['磁盘IO']['状态']}\n\n"
        
        report += "【进程状态】\n"
        for process in self.results['进程']:
            report += f"进程名: {process['进程名']}\n"
            report += f"状态: {process['状态']}\n"
        
        report += "\n【系统服务状态】\n"
        report += f"运行的服务数量: {self.results['系统服务']['运行的服务数量']}\n"
        report += f"总服务数量: {self.results['系统服务']['总服务数量']}\n"
        report += "关键服务状态:\n"
        for service in self.results['系统服务']['关键服务状态']:
            report += f"  - {service['服务名']}: {service['状态']}\n"
        
        report += "\n【CPU使用最高的前5个进程】\n"
        for proc in self.results['top_processes']['cpu']:
            report += f"PID: {proc['pid']}, 进程名: {proc['name']}, CPU使用率: {proc['cpu_percent']}%\n"
        
        report += "\n【内存使用最高的前5个进程】\n"
        for proc in self.results['top_processes']['memory']:
            report += f"PID: {proc['pid']}, 进程名: {proc['name']}, 内存使用率: {proc['memory_percent']}%\n"
        
        report += "\n【网络与安全状态】\n"
        
        report += "端口状态:\n"
        for port in self.results['端口']:
            report += f"  - 端口: {port['端口']}, 状态: {port['状态']}\n"
        
        report += "\n防火墙状态:\n"
        report += f"  - 状态: {self.results['防火墙']['状态']}\n"
        if self.results['防火墙']['允许的端口/服务']:
            report += f"  - 允许的端口/服务: {', '.join(self.results['防火墙']['允许的端口/服务'])}\n"
        
        report += "\nSELinux 状态:\n"
        report += f"  - 状态: {self.results['SELinux']['状态']}\n"
        
        report += "\n系统启动时间:\n"
        report += f"  - 运行时间: {self.results['系统启动时间']['运行时间']}\n"
        report += f"  - 启动时间: {self.results['系统启动时间']['启动时间']}\n"
        
        report += "\n僵尸进程:\n"
        report += f"  - 数量: {self.results['僵尸进程']['数量']}\n"
        report += f"  - 状态: {self.results['僵尸进程']['状态']}\n"
        
        report += "\n网络状态:\n"
        report += f"  - 连接数: {self.results['网络状态']['连接数']}\n"
        report += f"  - 网络延迟: {self.results['网络状态']['网络延迟']}\n"
        report += f"  - 总发送流量: {self.results['网络状态']['总发送流量']}\n"
        report += f"  - 总接收流量: {self.results['网络状态']['总接收流量']}\n"
        report += f"  - 状态: {self.results['网络状态']['状态']}\n"
        report += "  - 接口信息:\n"
        for interface in self.results['网络状态']['接口信息']:
            report += f"    - {interface['接口']}: 发送 {interface['发送流量']}, 接收 {interface['接收流量']}\n"
        
        report += "\n安全状态:\n"
        
        report += "  - SSH配置检查:\n"
        report += f"    - Root登录: {self.results['安全状态']['SSH配置']['Root登录']}\n"
        report += f"    - 密码认证: {self.results['安全状态']['SSH配置']['密码认证']}\n"
        report += f"    - SSH端口: {self.results['安全状态']['SSH配置']['SSH端口']}\n"
        
        report += "  - 自动更新检查:\n"
        report += f"    - 自动更新: {self.results['安全状态']['自动更新']}\n"
        
        report += "  - 入侵防御系统检查:\n"
        report += f"    - 状态: {self.results['安全状态']['入侵防御系统']}\n"
        
        report += "  - 密码策略检查:\n"
        report += f"    - 密码最小长度: {self.results['安全状态']['密码策略']['最小长度']}\n"
        report += f"    - 密码复杂度要求: {self.results['安全状态']['密码策略']['复杂度要求']}\n"
        
        report += "  - SUID文件检查:\n"
        report += f"    - 状态: {self.results['安全状态']['SUID文件']['状态']}\n"
        
        report += f"  - 登录失败次数: {self.results['安全状态']['登录失败次数']}\n"
        if self.results['安全状态']['登录失败的用户']:
            report += f"  - 登录失败的用户: {', '.join(self.results['安全状态']['登录失败的用户'])}\n"
        if self.results['安全状态']['权限问题']:
            report += "  - 权限问题:\n"
            for issue in self.results['安全状态']['权限问题']:
                report += f"    - {issue}\n"
        
        report += f"  - 安全状态: {self.results['安全状态']['状态']}\n"
        
        report += f"  - 最近登录:\n{self.results['安全状态']['最近登录']}\n"
        
        report += "==========================================="
        
        report_file = f"server_monitor_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        with open(report_file, 'w') as f:
            f.write(report)
        
        return report, report_file
    
    def generate_table_report(self):
        """生成表格格式的巡检报告"""
        import csv
        import os
        
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        table_file = f"server_monitor_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
        
        with open(table_file, 'w', newline='', encoding='utf-8') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow(['服务器巡检报告', '', ''])
            writer.writerow(['主机名', self.hostname, ''])
            writer.writerow(['IP地址', self.ip, ''])
            writer.writerow(['巡检时间', timestamp, ''])
            writer.writerow([])  
            writer.writerow(['系统信息摘要', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['操作系统', self.results['系统信息摘要']['操作系统'], '正常'])
            writer.writerow(['内核版本', self.results['系统信息摘要']['内核版本'], '正常'])
            writer.writerow(['CPU型号', self.results['系统信息摘要']['CPU型号'], '正常'])
            writer.writerow(['CPU核心数', self.results['系统信息摘要']['CPU核心数'], '正常'])
            writer.writerow(['总内存', self.results['系统信息摘要']['总内存'], '正常'])
            writer.writerow(['总磁盘空间', self.results['系统信息摘要']['总磁盘空间'], '正常'])
            writer.writerow(['公网IP', self.results['系统信息摘要']['公网IP'], '正常'])
            writer.writerow(['负载平均值', self.results['系统信息摘要']['负载平均值'], '正常'])
            writer.writerow([])  
            writer.writerow(['CPU 状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['CPU 使用率', self.results['cpu']['使用率'], '正常'])
            writer.writerow(['1分钟负载', self.results['cpu']['1分钟负载'], self.results['cpu']['负载状态']])
            writer.writerow(['5分钟负载', self.results['cpu']['5分钟负载'], '正常'])
            writer.writerow(['15分钟负载', self.results['cpu']['15分钟负载'], '正常'])
            writer.writerow([]) 
            writer.writerow(['内存状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['内存使用率', self.results['内存']['使用率'], self.results['内存']['状态']])
            writer.writerow(['总内存', self.results['内存']['总内存'], '正常'])
            writer.writerow(['可用内存', self.results['内存']['可用内存'], '正常'])
            writer.writerow([]) 
            writer.writerow(['磁盘状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            for disk in self.results['磁盘']:
                writer.writerow([disk['挂载点'], f"文件系统: {disk['文件系统']}, 总空间: {disk['总空间']}, 可用空间: {disk['可用空间']}", disk['状态']])
            writer.writerow([]) 
            writer.writerow(['磁盘IO状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            if isinstance(self.results['磁盘IO'], list):
                for device in self.results['磁盘IO']:
                    writer.writerow([device['设备'], f"%rrqm: {device['%rrqm']}, %wrqm: {device['%wrqm']}, r_await: {device['r_await']}, w_await: {device['w_await']}, avgqu-sz: {device['avgqu-sz']}, %util: {device['%util']}", device['状态']])
            else:
                writer.writerow(['错误', self.results['磁盘IO'].get('错误', '未知错误'), self.results['磁盘IO']['状态']])
            writer.writerow([]) 
            writer.writerow(['进程状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            for process in self.results['进程']:
                writer.writerow([process['进程名'], '', process['状态']])
            writer.writerow([])  
            writer.writerow(['系统服务状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['运行的服务数量', self.results['系统服务']['运行的服务数量'], '正常'])
            writer.writerow(['总服务数量', self.results['系统服务']['总服务数量'], '正常'])
            writer.writerow(['关键服务状态', '', ''])
            for service in self.results['系统服务']['关键服务状态']:
                writer.writerow(['', f"{service['服务名']}: {service['状态']}", '正常' if service['状态'] == '运行中' else '警告'])
            writer.writerow([])  
            writer.writerow(['CPU使用最高的前5个进程', '', ''])
            writer.writerow(['排名', '进程信息', '状态'])
            for i, proc in enumerate(self.results['top_processes']['cpu']):
                writer.writerow([f"{i+1}", f"PID: {proc['pid']}, 进程名: {proc['name']}, CPU使用率: {proc['cpu_percent']}%", '正常'])
            writer.writerow([])  
            writer.writerow(['内存使用最高的前5个进程', '', ''])
            writer.writerow(['排名', '进程信息', '状态'])
            for i, proc in enumerate(self.results['top_processes']['memory']):
                writer.writerow([f"{i+1}", f"PID: {proc['pid']}, 进程名: {proc['name']}, 内存使用率: {proc['memory_percent']}%", '正常'])
            writer.writerow([])  
            writer.writerow(['端口状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            for port in self.results['端口']:
                writer.writerow([f"{port['端口']}", '', port['状态']])
            writer.writerow([])  
            writer.writerow(['系统启动时间', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['运行时间', self.results['系统启动时间']['运行时间'], '正常'])
            writer.writerow(['启动时间', self.results['系统启动时间']['启动时间'], '正常'])
            writer.writerow([])  
            writer.writerow(['僵尸进程', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['数量', str(self.results['僵尸进程']['数量']), self.results['僵尸进程']['状态']])
            writer.writerow([])  
            writer.writerow(['网络状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['连接数', str(self.results['网络状态']['连接数']), '正常'])
            writer.writerow(['网络延迟', self.results['网络状态']['网络延迟'], self.results['网络状态']['状态']])
            writer.writerow(['总发送流量', self.results['网络状态']['总发送流量'], '正常'])
            writer.writerow(['总接收流量', self.results['网络状态']['总接收流量'], '正常'])
            writer.writerow(['接口信息', '', ''])
            for interface in self.results['网络状态']['接口信息']:
                writer.writerow([interface['接口'], f"发送: {interface['发送流量']}, 接收: {interface['接收流量']}", '正常'])
            writer.writerow([])  
            writer.writerow(['安全状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['登录失败次数', str(self.results['安全状态']['登录失败次数']), self.results['安全状态']['状态']])
            if self.results['安全状态']['登录失败的用户']:
                writer.writerow(['登录失败的用户', ', '.join(self.results['安全状态']['登录失败的用户']), '警告'])
            if self.results['安全状态']['权限问题']:
                writer.writerow(['权限问题', '', ''])
                for issue in self.results['安全状态']['权限问题']:
                    writer.writerow(['', issue, '警告'])

            writer.writerow(['SSH配置', '', ''])
            writer.writerow(['Root登录', self.results['安全状态']['SSH配置']['Root登录'], '正常' if '已禁用' in self.results['安全状态']['SSH配置']['Root登录'] else '警告'])
            writer.writerow(['密码认证', self.results['安全状态']['SSH配置']['密码认证'], '正常' if '已禁用' in self.results['安全状态']['SSH配置']['密码认证'] else '警告'])
            writer.writerow(['SSH端口', self.results['安全状态']['SSH配置']['SSH端口'], '正常' if '默认端口' not in self.results['安全状态']['SSH配置']['SSH端口'] else '警告'])
            writer.writerow(['自动更新', self.results['安全状态']['自动更新'], '正常' if '已配置' in self.results['安全状态']['自动更新'] else '警告'])
            
            writer.writerow(['入侵防御系统', self.results['安全状态']['入侵防御系统'], '正常' if '运行中' in self.results['安全状态']['入侵防御系统'] else '警告'])
            writer.writerow(['密码策略', '', ''])
            writer.writerow(['密码最小长度', self.results['安全状态']['密码策略']['最小长度'], '正常' if '符合要求' in self.results['安全状态']['密码策略']['最小长度'] else '警告'])
            writer.writerow(['密码复杂度要求', self.results['安全状态']['密码策略']['复杂度要求'], '正常' if self.results['安全状态']['密码策略']['复杂度要求'] == '已配置' else '警告'])

            writer.writerow(['SUID文件', self.results['安全状态']['SUID文件']['状态'], '正常' if '未发现' in self.results['安全状态']['SUID文件']['状态'] else '警告'])
            
            writer.writerow([])  
            writer.writerow(['SELinux 状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['状态', self.results['SELinux']['状态'], '正常'])
            writer.writerow([])  
            writer.writerow(['防火墙状态', '', ''])
            writer.writerow(['检查项', '详细信息', '状态'])
            writer.writerow(['状态', self.results['防火墙']['状态'], '正常'])
            if self.results['防火墙']['允许的端口/服务']:
                writer.writerow(['允许的端口/服务', ', '.join(self.results['防火墙']['允许的端口/服务']), '正常'])
        
        md_file = f"server_monitor_{datetime.now().strftime('%Y%m%d_%H%M%S')}.md"
        with open(md_file, 'w', encoding='utf-8') as mdfile:
            mdfile.write(f"# 服务器巡检报告\n\n")
            mdfile.write(f"**主机名**: {self.hostname}\n")
            mdfile.write(f"**IP地址**: {self.ip}\n")
            mdfile.write(f"**巡检时间**: {timestamp}\n\n")
            
            mdfile.write("## 系统信息摘要\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 操作系统 | {self.results['系统信息摘要']['操作系统']} | 正常 |\n")
            mdfile.write(f"| 内核版本 | {self.results['系统信息摘要']['内核版本']} | 正常 |\n")
            mdfile.write(f"| CPU型号 | {self.results['系统信息摘要']['CPU型号']} | 正常 |\n")
            mdfile.write(f"| CPU核心数 | {self.results['系统信息摘要']['CPU核心数']} | 正常 |\n")
            mdfile.write(f"| 总内存 | {self.results['系统信息摘要']['总内存']} | 正常 |\n")
            mdfile.write(f"| 总磁盘空间 | {self.results['系统信息摘要']['总磁盘空间']} | 正常 |\n")
            mdfile.write(f"| 公网IP | {self.results['系统信息摘要']['公网IP']} | 正常 |\n")
            mdfile.write(f"| 负载平均值 | {self.results['系统信息摘要']['负载平均值']} | 正常 |\n\n")
            
            mdfile.write("## CPU 状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| CPU 使用率 | {self.results['cpu']['使用率']} | 正常 |\n")
            mdfile.write(f"| 1分钟负载 | {self.results['cpu']['1分钟负载']} | {self.results['cpu']['负载状态']} |\n")
            mdfile.write(f"| 5分钟负载 | {self.results['cpu']['5分钟负载']} | 正常 |\n")
            mdfile.write(f"| 15分钟负载 | {self.results['cpu']['15分钟负载']} | 正常 |\n\n")
            
            mdfile.write("## 内存状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 使用率 | {self.results['内存']['使用率']} | {self.results['内存']['状态']} |\n")
            mdfile.write(f"| 总内存 | {self.results['内存']['总内存']} | 正常 |\n")
            mdfile.write(f"| 可用内存 | {self.results['内存']['可用内存']} | 正常 |\n\n")
            
            mdfile.write("## 磁盘状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            for disk in self.results['磁盘']:
                mdfile.write(f"| {disk['挂载点']} | 文件系统: {disk['文件系统']}, 总空间: {disk['总空间']}, 可用空间: {disk['可用空间']} | {disk['状态']} |\n")
            mdfile.write("\n")
            
            mdfile.write("## 磁盘IO状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            if isinstance(self.results['磁盘IO'], list):
                for device in self.results['磁盘IO']:
                    mdfile.write(f"| {device['设备']} | %rrqm: {device['%rrqm']}, %wrqm: {device['%wrqm']}, r_await: {device['r_await']}, w_await: {device['w_await']}, avgqu-sz: {device['avgqu-sz']}, %util: {device['%util']} | {device['状态']} |\n")
            else:
                mdfile.write(f"| 错误 | {self.results['磁盘IO'].get('错误', '未知错误')} | {self.results['磁盘IO']['状态']} |\n")
            mdfile.write("\n")
            
            mdfile.write("## 进程状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            for process in self.results['进程']:
                mdfile.write(f"| {process['进程名']} | | {process['状态']} |\n")
            mdfile.write("\n")
            
            mdfile.write("## 系统服务状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 运行的服务数量 | {self.results['系统服务']['运行的服务数量']} | 正常 |\n")
            mdfile.write(f"| 总服务数量 | {self.results['系统服务']['总服务数量']} | 正常 |\n")
            for service in self.results['系统服务']['关键服务状态']:
                status = '正常' if service['状态'] == '运行中' else '警告'
                mdfile.write(f"| 关键服务 | {service['服务名']} | {service['状态']} |\n")
            mdfile.write("\n")
            
            mdfile.write("## CPU使用最高的前5个进程\n")
            mdfile.write("| 排名 | 进程信息 | 状态 |\n")
            mdfile.write("|------|----------|------|\n")
            for i, proc in enumerate(self.results['top_processes']['cpu']):
                mdfile.write(f"| {i+1} | PID: {proc['pid']}, 进程名: {proc['name']}, CPU使用率: {proc['cpu_percent']}% | 正常 |\n")
            mdfile.write("\n")
            
            mdfile.write("## 内存使用最高的前5个进程\n")
            mdfile.write("| 排名 | 进程信息 | 状态 |\n")
            mdfile.write("|------|----------|------|\n")
            for i, proc in enumerate(self.results['top_processes']['memory']):
                mdfile.write(f"| {i+1} | PID: {proc['pid']}, 进程名: {proc['name']}, 内存使用率: {proc['memory_percent']}% | 正常 |\n")
            mdfile.write("\n")
            
            mdfile.write("## 网络与安全状态\n")
            
            mdfile.write("### 端口状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            for port in self.results['端口']:
                mdfile.write(f"| {port['端口']} | | {port['状态']} |\n")
            mdfile.write("\n")
            
            mdfile.write("### 防火墙状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 防火墙状态 | {self.results['防火墙']['状态']} | 正常 |\n")
            if self.results['防火墙']['允许的端口/服务']:
                mdfile.write(f"| 允许的端口/服务 | {', '.join(self.results['防火墙']['允许的端口/服务'])} | 正常 |\n")
            mdfile.write("\n")
            
            mdfile.write("### SELinux 状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| SELinux 状态 | {self.results['SELinux']['状态']} | 正常 |\n\n")
            
            mdfile.write("### 系统启动时间\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 运行时间 | {self.results['系统启动时间']['运行时间']} | 正常 |\n")
            mdfile.write(f"| 启动时间 | {self.results['系统启动时间']['启动时间']} | 正常 |\n\n")
            
            mdfile.write("### 僵尸进程\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 数量 | {self.results['僵尸进程']['数量']} | {self.results['僵尸进程']['状态']} |\n\n")
            
            mdfile.write("### 网络状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 连接数 | {self.results['网络状态']['连接数']} | 正常 |\n")
            mdfile.write(f"| 网络延迟 | {self.results['网络状态']['网络延迟']} | {self.results['网络状态']['状态']} |\n")
            mdfile.write(f"| 总发送流量 | {self.results['网络状态']['总发送流量']} | 正常 |\n")
            mdfile.write(f"| 总接收流量 | {self.results['网络状态']['总接收流量']} | 正常 |\n")
            for interface in self.results['网络状态']['接口信息']:
                mdfile.write(f"| {interface['接口']} | 发送: {interface['发送流量']}, 接收: {interface['接收流量']} | 正常 |\n")
            mdfile.write("\n")
            
            mdfile.write("### 安全状态\n")
            mdfile.write("| 检查项 | 详细信息 | 状态 |\n")
            mdfile.write("|--------|----------|------|\n")
            mdfile.write(f"| 登录失败次数 | {self.results['安全状态']['登录失败次数']} | {self.results['安全状态']['状态']} |\n")
            if self.results['安全状态']['登录失败的用户']:
                mdfile.write(f"| 登录失败的用户 | {', '.join(self.results['安全状态']['登录失败的用户'])} | 警告 |\n")
            if self.results['安全状态']['权限问题']:
                for issue in self.results['安全状态']['权限问题']:
                    mdfile.write(f"| 权限问题 | {issue} | 警告 |\n")
            
            mdfile.write("| SSH配置 | | |\n")
            root_login_status = '正常' if '已禁用' in self.results['安全状态']['SSH配置']['Root登录'] else '警告'
            password_auth_status = '正常' if '已禁用' in self.results['安全状态']['SSH配置']['密码认证'] else '警告'
            ssh_port_status = '正常' if '默认端口' not in self.results['安全状态']['SSH配置']['SSH端口'] else '警告'
            mdfile.write(f"| Root登录 | {self.results['安全状态']['SSH配置']['Root登录']} | {root_login_status} |\n")
            mdfile.write(f"| 密码认证 | {self.results['安全状态']['SSH配置']['密码认证']} | {password_auth_status} |\n")
            mdfile.write(f"| SSH端口 | {self.results['安全状态']['SSH配置']['SSH端口']} | {ssh_port_status} |\n")
            
            auto_update_status = '正常' if '已配置' in self.results['安全状态']['自动更新'] else '警告'
            mdfile.write(f"| 自动更新 | {self.results['安全状态']['自动更新']} | {auto_update_status} |\n")
            
            ips_status = '正常' if '运行中' in self.results['安全状态']['入侵防御系统'] else '警告'
            mdfile.write(f"| 入侵防御系统 | {self.results['安全状态']['入侵防御系统']} | {ips_status} |\n")
            
            mdfile.write("| 密码策略 | | |\n")
            minlen_status = '正常' if '符合要求' in self.results['安全状态']['密码策略']['最小长度'] else '警告'
            complexity_status = '正常' if self.results['安全状态']['密码策略']['复杂度要求'] == '已配置' else '警告'
            mdfile.write(f"| 密码最小长度 | {self.results['安全状态']['密码策略']['最小长度']} | {minlen_status} |\n")
            mdfile.write(f"| 密码复杂度要求 | {self.results['安全状态']['密码策略']['复杂度要求']} | {complexity_status} |\n")
            
            suid_status = '正常' if '未发现' in self.results['安全状态']['SUID文件']['状态'] else '警告'
            mdfile.write(f"| SUID文件 | {self.results['安全状态']['SUID文件']['状态']} | {suid_status} |\n")
            
            mdfile.write("\n")
            mdfile.write(f"## 最近登录\n\n```\n{self.results['安全状态']['最近登录']}\n```\n")
        
        return table_file, md_file
    
    def send_dingtalk_alert(self, webhook, report):
        """发送钉钉告警"""
        try:
            message = {
                "msgtype": "text",
                "text": {
                    "content": f"服务器巡检异常\n{report}"
                }
            }
            response = requests.post(webhook, json=message, timeout=5)
            return response.status_code == 200
        except:
            return False
    
    def send_wecom_alert(self, webhook, report):
        """发送企业微信告警"""
        try:
            message = {
                "msgtype": "text",
                "text": {
                    "content": f"服务器巡检异常\n{report}"
                }
            }
            response = requests.post(webhook, json=message, timeout=5)
            return response.status_code == 200
        except:
            return False
    
    def run(self, process_names=None, ports=None, alert_config=None):
        """执行巡检"""
        if process_names is None:
            process_names = ['sshd', 'nginx', 'mysql']
        if ports is None:
            ports = [22, 80, 443]
        
        self.get_system_summary()
        self.check_cpu()
        self.check_memory()
        self.check_disk()
        self.check_disk_io()
        self.check_processes(process_names)
        self.check_services()
        self.check_top_processes()
        self.check_ports(ports)
        self.check_uptime()
        self.check_zombie_processes()
        self.check_network_status()
        self.check_security()
        self.check_selinux()
        self.check_firewall()
        
        report, report_file = self.generate_report()
        print(report)
        print(f"报告已保存至: {report_file}")
        
        table_file, md_file = self.generate_table_report()
        print(f"表格报告已保存至: {table_file}")
        print(f"Markdown 表格报告已保存至: {md_file}")
        
        has_alert = False
        alert_message = ""
        
        if self.results['cpu']['状态'] == "警告":
            has_alert = True
            alert_message += f"CPU 使用率异常: {self.results['cpu']['使用率']}\n"
        
        if self.results['内存']['状态'] == "警告":
            has_alert = True
            alert_message += f"内存使用率异常: {self.results['内存']['使用率']}\n"
        
        for disk in self.results['磁盘']:
            if disk['状态'] == "警告":
                has_alert = True
                alert_message += f"磁盘 {disk['挂载点']} 使用率异常: {disk['使用率']}\n"
        
        for process in self.results['进程']:
            if process['状态'] == "未运行":
                has_alert = True
                alert_message += f"进程 {process['进程名']} 未运行\n"
        
        for port in self.results['端口']:
            if port['状态'] == "关闭":
                has_alert = True
                alert_message += f"端口 {port['端口']} 未开放\n"
        
        if self.results['僵尸进程']['状态'] == "警告":
            has_alert = True
            alert_message += f"僵尸进程数量异常: {self.results['僵尸进程']['数量']}\n"
        
        if self.results['网络状态']['状态'] == "警告":
            has_alert = True
            alert_message += f"网络状态异常: 延迟 {self.results['网络状态']['网络延迟']}\n"
        
        if self.results['安全状态']['状态'] == "警告":
            has_alert = True
            alert_message += f"安全状态异常: 登录失败 {self.results['安全状态']['登录失败次数']} 次\n"
            if self.results['安全状态']['登录失败的用户']:
                alert_message += f"  - 登录失败的用户: {', '.join(self.results['安全状态']['登录失败的用户'])}\n"
            if self.results['安全状态']['权限问题']:
                for issue in self.results['安全状态']['权限问题']:
                    alert_message += f"  - {issue}\n"
        
        if has_alert and alert_config:
            if alert_config.get('type') == 'dingtalk' and alert_config.get('webhook'):
                success = self.send_dingtalk_alert(alert_config['webhook'], alert_message)
                print(f"钉钉告警发送{'成功' if success else '失败'}")
            elif alert_config.get('type') == 'wecom' and alert_config.get('webhook'):
                success = self.send_wecom_alert(alert_config['webhook'], alert_message)
                print(f"企业微信告警发送{'成功' if success else '失败'}")
        
        return has_alert

if __name__ == '__main__':
    monitor = ServerMonitor()
    monitor.run(
        process_names=CHECK_PROCESSES,
        ports=CHECK_PORTS,
        alert_config=ALERT_CONFIG
    )
