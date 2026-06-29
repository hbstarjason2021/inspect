#!/usr/bin/env python3

import sqlite3
import os

# 数据库文件路径
db_path = 'monitor.db'

# 连接数据库
conn = sqlite3.connect(db_path)
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

# 关闭连接
conn.close()

print(f"数据库初始化完成，文件路径: {db_path}")
