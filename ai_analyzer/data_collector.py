import subprocess
import os
import time
import logging
import sqlite3
from collections import OrderedDict
from datetime import datetime
from utils import safe_json_parse, load_json_file, save_json_file, truncate_history
import config

logger = logging.getLogger(__name__)

last_net_stats = OrderedDict()

class DataCollector:
    def __init__(self):
        self.last_data = None
        self.last_update_time = 0
        self.server_list = []
        self.server_info = []
        self.load_servers()
        self.init_database()

    def get_db_connection(self):
        """获取数据库连接"""
        return sqlite3.connect('monitor.db')

    def init_database(self):
        """初始化数据库"""
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()
            
            # 创建服务器表
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS servers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ip TEXT UNIQUE NOT NULL,
                system TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            ''')
            
            # 创建服务器描述表
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS server_descriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_ip TEXT NOT NULL,
                description TEXT,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (server_ip) REFERENCES servers(ip) ON DELETE CASCADE
            )
            ''')
            
            # 创建网络历史表
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS network_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_ip TEXT NOT NULL,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                rx_rate REAL,
                tx_rate REAL,
                rx_gb REAL,
                tx_gb REAL,
                FOREIGN KEY (server_ip) REFERENCES servers(ip) ON DELETE CASCADE
            )
            ''')
            
            # 创建事件表
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_ip TEXT NOT NULL,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                level TEXT NOT NULL,
                service TEXT,
                detail TEXT NOT NULL,
                log_path TEXT,
                collected_at TIMESTAMP,
                FOREIGN KEY (server_ip) REFERENCES servers(ip) ON DELETE CASCADE
            )
            ''')
            
            # 创建AI分析历史表
            cursor.execute('''
            CREATE TABLE IF NOT EXISTS ai_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_ip TEXT NOT NULL,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                cpu REAL,
                mem_percent REAL,
                disk_percent REAL,
                ai_risk_level TEXT,
                disk_fill_time TEXT,
                ai_suggestion TEXT,
                FOREIGN KEY (server_ip) REFERENCES servers(ip) ON DELETE CASCADE
            )
            ''')
            
            # 创建索引以提高查询性能
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_network_history_server_ip ON network_history(server_ip)')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_network_history_timestamp ON network_history(timestamp)')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_events_server_ip ON events(server_ip)')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_ai_history_server_ip ON ai_history(server_ip)')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_ai_history_timestamp ON ai_history(timestamp)')
            
            # 提交更改
            conn.commit()
            conn.close()
            logger.info("数据库初始化完成")
        except Exception as e:
            logger.error(f"数据库初始化失败: {e}")

    def load_servers(self):
        self.server_list, self.server_info = self._load_servers_from_config()

    def _load_servers_from_config(self):
        servers = []
        server_info = []
        try:
            if os.path.exists(config.CONFIG_FILE):
                with open(config.CONFIG_FILE, 'r', encoding='utf-8') as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith('#') and not line.startswith('//'):
                            parts = line.split(':', 1)
                            ip = parts[0].strip()
                            if ip:
                                servers.append(ip)
                                system = parts[1].strip() if len(parts) > 1 else 'unknown'
                                server_info.append({"ip": ip, "system": system})
                logger.info(f"Loaded {len(servers)} servers from {config.CONFIG_FILE}")
            else:
                logger.warning(f"Config file {config.CONFIG_FILE} not found")
        except Exception as e:
            logger.error(f"Failed to read config: {e}")

        if not servers:
            servers = ["10.96.140.66", "10.96.140.67", "10.96.140.68"]
            server_info = [{"ip": ip, "system": "unknown"} for ip in servers]
            logger.warning(f"Using default servers: {servers}")

        # 更新数据库中的服务器信息
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()
            
            # 先清空服务器表
            cursor.execute('DELETE FROM servers')
            
            # 插入新的服务器信息
            for info in server_info:
                cursor.execute('''
                INSERT OR REPLACE INTO servers (ip, system) VALUES (?, ?)
                ''', (info['ip'], info['system']))
            
            conn.commit()
            conn.close()
            logger.info("数据库服务器信息更新完成")
        except Exception as e:
            logger.error(f"更新数据库服务器信息失败: {e}")

        return servers, server_info

    def collect_monitor_data(self):
        logger.info("Collecting monitor data...")
        try:
            env = self._prepare_env()
            cmd = f"cd {config.SCRIPT_DIR} && bash {config.COLLECT_SCRIPT}"
            logger.info(f"Executing: {cmd}")

            result = subprocess.run(
                ['bash', '-c', cmd],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=config.COLLECT_TIMEOUT,
                env=env
            )

            output = result.stdout.strip()
            if result.returncode != 0:
                logger.error(f"Collect script error: {result.stderr}")
                return self._empty_response()

            if not output:
                logger.error("No output from collect script")
                return self._empty_response()

            data = safe_json_parse(output)
            if data is None:
                logger.error(f"JSON parse failed: {output[:500]}")
                return self._empty_response()

            if not data.get('servers'):
                logger.warning("No 'servers' field in data")
                return self._empty_response()

            self._process_network_stats(data)
            self._normalize_data(data)
            self._save_history(data)

            logger.info(f"Collected {len(data['servers'])} servers")
            return data

        except subprocess.TimeoutExpired:
            logger.error("Collect script timeout (60s)")
            return self._empty_response()
        except Exception as e:
            logger.error(f"Collect exception: {e}", exc_info=True)
            return self._empty_response()

    def collect_event_data(self):
        logger.info("Collecting event data...")
        try:
            os.makedirs(config.EVENTS_DIR, exist_ok=True)
            env = self._prepare_env()
            cmd = f"cd {config.SCRIPT_DIR} && bash {config.EVENT_SCRIPT}"
            logger.info(f"Executing event collector: {cmd}")

            result = subprocess.run(
                ['bash', '-c', cmd],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=config.EVENT_COLLECT_TIMEOUT,
                env=env
            )

            output = result.stdout.strip()
            if result.returncode != 0:
                logger.error(f"Event script error: {result.stderr}")
                return self._load_cached_events()

            if not output:
                logger.error("No output from event script")
                return self._load_cached_events()

            data = safe_json_parse(output)
            if data is None:
                logger.error(f"Event JSON parse failed: {output[:500]}")
                return self._load_cached_events()

            # 保存事件数据到数据库
            try:
                conn = self.get_db_connection()
                cursor = conn.cursor()
                
                for event in data.get('events', []):
                    cursor.execute('''
                    INSERT INTO events (server_ip, timestamp, level, service, detail, log_path, collected_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ''', (
                        event.get('server'),
                        event.get('timestamp'),
                        event.get('level'),
                        event.get('service'),
                        event.get('detail'),
                        event.get('log_path'),
                        event.get('collected_at')
                    ))
                
                conn.commit()
                conn.close()
                logger.info("事件数据保存到数据库完成")
            except Exception as e:
                logger.error(f"保存事件数据到数据库失败: {e}")

            logger.info(f"Collected {data.get('total', 0)} events")
            return data

        except subprocess.TimeoutExpired:
            logger.error("Event script timeout (120s)")
            return self._load_cached_events()
        except Exception as e:
            logger.error(f"Event collection exception: {e}", exc_info=True)
            return self._load_cached_events()

    def get_event_status(self):
        return load_json_file(config.STATUS_FILE, {"status": "unknown", "message": "No status data", "last_run": "Never"})

    def _prepare_env(self):
        env = os.environ.copy()
        env['HOME'] = '/root'
        env['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        env['MONITOR_SERVERS'] = ','.join(self.server_list)
        return env

    def _process_network_stats(self, data):
        now_ts = time.time()
        for srv in data.get('servers', []):
            host = srv.get('host')
            net = srv.get('network', {})
            rx_bytes = net.get('rx_bytes', 0)
            tx_bytes = net.get('tx_bytes', 0)

            if len(last_net_stats) > config.MAX_NET_CACHE:
                last_net_stats.popitem(last=False)

            if host in last_net_stats:
                last = last_net_stats[host]
                dt = now_ts - last['timestamp']
                if dt <= 0:
                    dt = 1
                elif dt < 1:
                    dt = 1

                if dt < 120:
                    rx_rate_mbps = ((rx_bytes - last['rx_bytes']) * 8) / 1e6 / dt
                    tx_rate_mbps = ((tx_bytes - last['tx_bytes']) * 8) / 1e6 / dt
                    rx_rate_mbps = max(0.0, rx_rate_mbps)
                    tx_rate_mbps = max(0.0, tx_rate_mbps)
                else:
                    rx_rate_mbps = 0.0
                    tx_rate_mbps = 0.0
            else:
                rx_rate_mbps = 0.0
                tx_rate_mbps = 0.0

            net['rx_rate_mbps'] = round(rx_rate_mbps, 2)
            net['tx_rate_mbps'] = round(tx_rate_mbps, 2)
            srv['network'] = net

            last_net_stats[host] = {
                'rx_bytes': rx_bytes,
                'tx_bytes': tx_bytes,
                'timestamp': now_ts
            }

    def _normalize_data(self, data):
        for srv in data.get('servers', []):
            if 'mem' not in srv or not srv['mem']:
                srv['mem'] = {"total": 0, "used": 0, "percent": 0}
            else:
                srv['mem']['total'] = float(srv['mem'].get('total', 0))
                srv['mem']['used'] = float(srv['mem'].get('used', 0))
                srv['mem']['percent'] = float(srv['mem'].get('percent', 0))

            if 'disk_partitions' not in srv:
                srv['disk_partitions'] = []

            system_info = next((item for item in self.server_info if item['ip'] == srv.get('host')), None)
            if system_info:
                srv['system'] = system_info['system']
            else:
                srv['system'] = 'unknown'

    def _save_history(self, data):
        try:
            # 保存到SQLite数据库
            conn = self.get_db_connection()
            cursor = conn.cursor()
            
            for srv in data.get("servers", []):
                host = srv.get("host")
                if not host:
                    continue
                
                # 插入网络历史数据
                cursor.execute('''
                INSERT INTO network_history (server_ip, timestamp, rx_rate, tx_rate, rx_gb, tx_gb)
                VALUES (?, ?, ?, ?, ?, ?)
                ''', (
                    host,
                    datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    srv.get("network", {}).get("rx_rate_mbps", 0),
                    srv.get("network", {}).get("tx_rate_mbps", 0),
                    srv.get("network", {}).get("rx_gb", 0),
                    srv.get("network", {}).get("tx_gb", 0)
                ))
            
            # 保持JSON文件作为备份
            history = load_json_file(config.HISTORY_FILE, {"records": []})
            record = {
                "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "timestamp": datetime.now().timestamp(),
                "servers": []
            }

            for srv in data.get("servers", []):
                record["servers"].append({
                    "host": srv.get("host"),
                    "cpu": srv.get("cpu", 0),
                    "cpu_peak": srv.get("cpu", 0),
                    "mem_used": srv.get("mem", {}).get("used", 0),
                    "mem_total": srv.get("mem", {}).get("total", 0),
                    "mem_percent": srv.get("mem", {}).get("percent", 0),
                    "disk_partitions": srv.get("disk_partitions", []),
                    "rx_gb": srv.get("network", {}).get("rx_gb", 0),
                    "tx_gb": srv.get("network", {}).get("tx_gb", 0),
                })

            history["records"].append(record)
            history = truncate_history(history, config.MAX_HISTORY_RECORDS)
            save_json_file(config.HISTORY_FILE, history)
            
            conn.commit()
            conn.close()
            logger.info("历史数据保存到数据库完成")
        except Exception as e:
            logger.error(f"Failed to save history: {e}")

    def _empty_response(self):
        return {"time": datetime.now().strftime("%H:%M:%S"), "servers": []}

    def _load_cached_events(self):
        return load_json_file(config.EVENTS_FILE, {"events": [], "total": 0, "last_updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S")})

    def get_cached_data(self):
        current_time = time.time()
        if self.last_data and (current_time - self.last_update_time) < config.CACHE_TIMEOUT:
            logger.info("Using cached data")
            return self.last_data
        data = self.collect_monitor_data()
        self.last_data = data
        self.last_update_time = current_time
        return data

data_collector = DataCollector()