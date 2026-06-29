#!/usr/bin/env python3

import http.server
import socketserver
import json
import urllib.parse
import time
import logging
import signal
import sys
import os

import config
import utils
from data_collector import data_collector
from ai_analyzer import ai_analyzer

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

class MonitorHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        logger.info(f"{self.address_string()} - {format % args}")

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        # 记录所有请求路径
        logger.info(f"Received GET request for: {self.path}")
        
        # 处理静态文件请求 - 检查是否包含/api/monitor前缀
        if self.path.startswith('/api/monitor/static/'):
            # 移除/api/monitor前缀，使用原始路径处理静态文件
            logger.info(f"Handling static file with api prefix: {self.path}")
            static_path = self.path[len('/api/monitor'):]
            logger.info(f"Static file path after removing api prefix: {static_path}")
            # 直接读取并返回静态文件
            try:
                # 构建文件路径
                file_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), static_path.lstrip('/'))
                logger.info(f"Trying to serve file: {file_path}")
                
                # 检查文件是否存在
                if os.path.exists(file_path) and os.path.isfile(file_path):
                    # 根据文件扩展名设置Content-Type
                    content_type = 'application/octet-stream'
                    if file_path.endswith('.js'):
                        content_type = 'application/javascript'
                    elif file_path.endswith('.css'):
                        content_type = 'text/css'
                    elif file_path.endswith('.html'):
                        content_type = 'text/html'
                    
                    # 读取文件内容
                    with open(file_path, 'rb') as f:
                        content = f.read()
                    
                    # 发送响应
                    self.send_response(200)
                    self.send_header('Content-type', content_type)
                    self.send_header('Content-length', str(len(content)))
                    self.end_headers()
                    self.wfile.write(content)
                    logger.info(f"Successfully served static file: {static_path}")
                else:
                    logger.error(f"File not found: {file_path}")
                    self.send_response(404)
                    self.end_headers()
            except Exception as e:
                logger.error(f"Error serving static file: {e}")
                self.send_response(500)
                self.end_headers()
            return
        elif self.path.startswith('/static/'):
            # 直接使用父类的do_GET方法处理静态文件
            logger.info(f"Handling static file: {self.path}")
            try:
                http.server.SimpleHTTPRequestHandler.do_GET(self)
                logger.info(f"Successfully served static file: {self.path}")
            except Exception as e:
                logger.error(f"Error serving static file: {e}")
                self.send_response(500)
                self.end_headers()
            return
        
        # 移除/api/monitor前缀，以适应反向代理配置
        path = self.path
        if path.startswith('/api/monitor'):
            logger.info(f"Removing api prefix from path: {path}")
            path = path[len('/api/monitor'):]
        
        if path == '/status':
            self._handle_status()
        elif path == '/network_history':
            self._handle_network_history()
        elif path == '/events':
            self._handle_events()
        elif path == '/event_status':
            self._handle_event_status()
        elif path == '/servers':
            self._handle_servers()
        elif path.startswith('/ai_history'):
            self._handle_ai_history()
        elif path == '/health':
            self._handle_health()
        elif path == '/server_descriptions':
            self._handle_server_descriptions()
        elif path == '/config':
            self._handle_get_config()
        elif path in ['/', '/index.html', '/monitor.html']:
            logger.info(f"Handling monitor.html request")
            self.path = '/monitor.html'
            try:
                http.server.SimpleHTTPRequestHandler.do_GET(self)
                logger.info(f"Successfully served monitor.html")
            except Exception as e:
                logger.error(f"Error serving monitor.html: {e}")
                self.send_response(500)
                self.end_headers()
        else:
            logger.info(f"404 for path: {self.path}")
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        # 记录所有POST请求路径
        logger.info(f"Received POST request for: {self.path}")
        
        # 移除/api/monitor前缀，以适应反向代理配置
        path = self.path
        if path.startswith('/api/monitor'):
            logger.info(f"Removing api prefix from path: {path}")
            path = path[len('/api/monitor'):]
        
        if path == '/analyze':
            self._handle_analyze()
        elif path == '/save_server_description':
            content_length = int(self.headers['Content-Length'])
            content = self.rfile.read(content_length).decode('utf-8')
            self._handle_save_server_description(content)
        elif path == '/add_server':
            content_length = int(self.headers['Content-Length'])
            content = self.rfile.read(content_length).decode('utf-8')
            self._handle_add_server(content)
        elif path == '/save_config':
            content_length = int(self.headers['Content-Length'])
            content = self.rfile.read(content_length).decode('utf-8')
            self._handle_save_config(content)
        else:
            logger.info(f"404 for POST path: {self.path}")
            self.send_response(404)
            self.end_headers()

    def _handle_status(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        data = data_collector.get_cached_data()
        self.wfile.write(json.dumps(data).encode())

    def _handle_network_history(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        history = utils.load_json_file(config.HISTORY_FILE, {"records": []})
        records = history.get("records", [])[-50:]
        network_history = self._process_network_history(records)
        self.wfile.write(json.dumps(network_history).encode())

    def _process_network_history(self, records):
        network_history = {}
        for record in records:
            for srv in record.get("servers", []):
                host = srv.get("host")
                if host not in network_history:
                    network_history[host] = {"labels": [], "rx_rate": [], "tx_rate": [], "rx_gb": [], "tx_gb": []}

                prev_rx = network_history[host]["rx_gb"][-1] if network_history[host]["rx_gb"] else srv.get("rx_gb", 0)
                prev_tx = network_history[host]["tx_gb"][-1] if network_history[host]["tx_gb"] else srv.get("tx_gb", 0)
                curr_rx = srv.get("rx_gb", 0)
                curr_tx = srv.get("tx_gb", 0)
                time_interval = 1200
                rx_rate = max(0, (curr_rx - prev_rx) * 8 * 1000 / time_interval) if network_history[host]["rx_gb"] else 0
                tx_rate = max(0, (curr_tx - prev_tx) * 8 * 1000 / time_interval) if network_history[host]["tx_gb"] else 0

                network_history[host]["labels"].append(record.get("time", "")[11:16])
                network_history[host]["rx_rate"].append(round(rx_rate, 2))
                network_history[host]["tx_rate"].append(round(tx_rate, 2))
                network_history[host]["rx_gb"].append(round(curr_rx, 2))
                network_history[host]["tx_gb"].append(round(curr_tx, 2))
        return network_history

    def _handle_events(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        event_data = data_collector.collect_event_data()
        self.wfile.write(json.dumps(event_data).encode())

    def _handle_event_status(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        status_data = data_collector.get_event_status()
        self.wfile.write(json.dumps(status_data).encode())

    def _handle_servers(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({
            "servers": data_collector.server_info,
            "count": len(data_collector.server_info)
        }).encode())

    def _handle_ai_history(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        host = params.get('host', [None])[0]
        history = ai_analyzer.get_ai_history(host)
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(history).encode())

    def _handle_health(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok", "timestamp": time.time()}).encode())

    def _handle_server_descriptions(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        descriptions = utils.load_json_file('server_descriptions.json', {})
        self.wfile.write(json.dumps(descriptions).encode())

    def _handle_save_server_description(self, content):
        try:
            data = json.loads(content)
            host = data.get('host')
            description = data.get('description')
            if not host:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing host"}).encode())
                return
            
            descriptions = utils.load_json_file('server_descriptions.json', {})
            descriptions[host] = description
            utils.save_json_file('server_descriptions.json', descriptions)
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode())
        except Exception as e:
            logger.error(f"Error saving server description: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Internal server error"}).encode())

    def _handle_add_server(self, content):
        try:
            data = json.loads(content)
            ip = data.get('ip')
            system = data.get('system')
            description = data.get('description')
            
            if not ip:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing IP address"}).encode())
                return
            
            if not system:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing system"}).encode())
                return
            
            # 读取现有配置
            servers = []
            if os.path.exists(config.CONFIG_FILE):
                with open(config.CONFIG_FILE, 'r', encoding='utf-8') as f:
                    servers = f.readlines()
            
            # 检查服务器是否已存在
            for line in servers:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split(':', 1)
                    if len(parts) > 0 and parts[0].strip() == ip:
                        self.send_response(400)
                        self.end_headers()
                        self.wfile.write(json.dumps({"error": "Server already exists"}).encode())
                        return
            
            # 添加新服务器
            new_server = f"{ip}:{system}\n"
            servers.append(new_server)
            
            # 写回配置文件
            with open(config.CONFIG_FILE, 'w', encoding='utf-8') as f:
                f.writelines(servers)
            
            # 重新加载服务器列表
            data_collector.load_servers()
            
            # 如果有描述，保存描述
            if description:
                descriptions = utils.load_json_file('server_descriptions.json', {})
                descriptions[ip] = description
                utils.save_json_file('server_descriptions.json', descriptions)
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode())
        except Exception as e:
            logger.error(f"Error adding server: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Internal server error"}).encode())

    def _handle_analyze(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        data = data_collector.get_cached_data()
        analysis = ai_analyzer.analyze(data)
        self.wfile.write(json.dumps(analysis).encode())

    def _handle_get_config(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        local_config_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'server_configs.json')
        config_data = utils.load_json_file(local_config_file, {})
        self.wfile.write(json.dumps(config_data).encode())

    def _handle_save_config(self, content):
        try:
            data = json.loads(content)
            local_config_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'server_configs.json')
            utils.save_json_file(local_config_file, data)
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode())
        except Exception as e:
            logger.error(f"Error saving config: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Internal server error"}).encode())

def signal_handler(sig, frame):
    logger.info("Shutting down...")
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    socketserver.TCPServer.allow_reuse_address = True
    # 使用当前目录作为工作目录，而不是依赖于config.py中的SCRIPT_DIR
    current_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(current_dir)
    logger.info("=" * 50)
    logger.info("Monitor server started (refactored)")
    logger.info(f"Working directory: {current_dir}")
    logger.info(f"Config: {config.CONFIG_FILE}")
    logger.info(f"Servers: {data_collector.server_list}")
    logger.info(f"URL: http://0.0.0.0:{config.PORT}")
    logger.info("=" * 50)
    try:
        with socketserver.TCPServer(("", config.PORT), MonitorHandler) as httpd:
            httpd.serve_forever()
    except OSError as e:
        if e.errno == 98:
            logger.error(f"Port {config.PORT} already in use")
        else:
            raise e