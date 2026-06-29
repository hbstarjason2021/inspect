import json
import re
import os
import logging
from functools import wraps
from datetime import datetime

logger = logging.getLogger(__name__)

def safe_json_parse(raw_str):
    if not raw_str:
        return None
    cleaned = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]', '', raw_str)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        cleaned = re.sub(r',\s*}', '}', cleaned)
        cleaned = re.sub(r',\s*]', ']', cleaned)
        try:
            return json.loads(cleaned)
        except:
            return None

def load_json_file(file_path, default=None):
    if default is None:
        default = {}
    try:
        if os.path.exists(file_path):
            with open(file_path, 'r', encoding='utf-8') as f:
                return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load JSON from {file_path}: {e}")
    return default

def save_json_file(file_path, data):
    try:
        os.makedirs(os.path.dirname(file_path), exist_ok=True)
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        logger.error(f"Failed to save JSON to {file_path}: {e}")
        return False

def truncate_history(history, max_records):
    if len(history.get("records", [])) > max_records:
        history["records"] = history["records"][-max_records:]
    return history