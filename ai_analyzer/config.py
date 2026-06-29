import os

PORT = 9353
AI_API_URL = "http://10.176.137.14:9857/v1/chat/completions"
SCRIPT_DIR = "/mnt/data/ican/assistant-deploy/check-page"
COLLECT_SCRIPT = SCRIPT_DIR + "/shujushouji.sh"
EVENT_SCRIPT = SCRIPT_DIR + "/event_collector.sh"
HISTORY_FILE = SCRIPT_DIR + "/history.json"
CONFIG_FILE = SCRIPT_DIR + "/servers.conf"
EVENTS_DIR = SCRIPT_DIR + "/events"
EVENTS_FILE = EVENTS_DIR + "/events.json"
STATUS_FILE = EVENTS_DIR + "/status.json"
AI_HISTORY_FILE = SCRIPT_DIR + "/ai_history.json"
SERVER_CONFIG_FILE = SCRIPT_DIR + "/server_configs.json"

CACHE_TIMEOUT = 30
MAX_NET_CACHE = 100
MAX_HISTORY_RECORDS = 200
AI_TIMEOUT = 120
COLLECT_TIMEOUT = 60
EVENT_COLLECT_TIMEOUT = 120

# 默认预警阈值
DEFAULT_THRESHOLDS = {
    "cpu": 85,
    "memory": 90,
    "disk": 90,
    "network": 500
}

# 默认分区设置
DEFAULT_PARTITION_SETTINGS = {
    "important": ["/", "/var", "/usr", "/etc", "/boot", "/opt", "/home"],
    "ignored": ["/mnt", "/media", "/backup", "/data", "/tmp"]
}