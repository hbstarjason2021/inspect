import json
import re
import urllib.request
import logging
import os
from datetime import datetime
from utils import safe_json_parse, load_json_file, save_json_file, truncate_history
import config

logger = logging.getLogger(__name__)

def get_local_server_config_file():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), 'server_configs.json')

class AIAnalyzer:
    def __init__(self):
        pass

    def call_llm_api(self, prompt):
        try:
            payload = json.dumps({
                "messages": [
                    {"role": "system", "content": "你是服务器运维专家。请分析数据并返回指定JSON。"},
                    {"role": "user", "content": prompt}
                ],
                "max_tokens": 1500,
                "temperature": 0.1
            }).encode('utf-8')

            req = urllib.request.Request(
                config.AI_API_URL,
                data=payload,
                headers={'Content-Type': 'application/json'}
            )

            with urllib.request.urlopen(req, timeout=config.AI_TIMEOUT) as resp:
                result = json.loads(resp.read().decode())
                return result['choices'][0]['message']['content']

        except Exception as e:
            logger.error(f"AI API error: {e}")
            return json.dumps({"error": str(e)})

    def analyze(self, data):
        try:
            if not data.get('servers'):
                return {"success": False, "error": "暂无服务器数据"}

            # 1. 数据预处理和规则分析
            server_summary = self._prepare_server_summary(data)
            server_configs = load_json_file(get_local_server_config_file(), {})
            
            # 2. 基于规则的初步分析
            rule_based_results = self._rule_based_analysis(data, server_configs)
            
            # 3. AI分析
            prompt = self._build_prompt(server_summary)
            logger.info("Calling AI API...")
            llm_response = self.call_llm_api(prompt)
            cleaned_response = self._clean_llm_response(llm_response)

            json_match = self._extract_json(cleaned_response)
            if not json_match:
                raise ValueError("AI返回无效JSON")

            # 使用safe_json_parse处理可能的无效转义字符
            llm_json = safe_json_parse(json_match.group())
            if llm_json is None:
                raise ValueError("AI返回的JSON解析失败")
            
            # 4. 结果验证和融合
            validated_results = self._validate_and_merge_results(llm_json, rule_based_results, data, server_configs)
            merged_servers = self._merge_analysis_results(data, validated_results)
            analysis_result = {"success": True, "data": merged_servers}

            self._save_ai_history(analysis_result)
            return analysis_result

        except Exception as e:
            logger.error(f"AI analysis error: {e}", exc_info=True)
            return self._fallback_analysis(data, str(e))

    def _prepare_server_summary(self, data):
        server_summary = []
        # 加载历史数据
        ai_history = load_json_file(config.AI_HISTORY_FILE, {"records": []})
        history_by_host = {}
        
        # 按主机分组历史数据
        for record in reversed(ai_history.get("records", [])):
            for srv in record.get("servers", []):
                host = srv.get("host")
                if host not in history_by_host:
                    history_by_host[host] = []
                history_by_host[host].append({
                    "time": record.get("time"),
                    "cpu": srv.get("cpu"),
                    "mem_percent": srv.get("mem_percent"),
                    "disk_partitions": srv.get("disk_partitions", [])
                })

        for srv in data.get('servers', []):
            host = srv.get('host')
            disk_info = []
            for p in srv.get('disk_partitions', []):
                disk_info.append(f"{p.get('mount')}: {p.get('percent')}% (已用{p.get('used')}/总{p.get('total')})")
            disk_info_str = ", ".join(disk_info)
            network = srv.get('network', {})
            rx_rate = network.get('rx_rate_mbps', 0)
            tx_rate = network.get('tx_rate_mbps', 0)

            # 整合历史数据
            history_data = history_by_host.get(host, [])[:3]  # 取最近3条历史记录
            history_summary = []
            for hist in history_data:
                hist_disk = []
                for p in hist.get("disk_partitions", []):
                    hist_disk.append(f"{p.get('mount')}: {p.get('percent')}%")
                history_summary.append({
                    "time": hist.get("time"),
                    "cpu": hist.get("cpu"),
                    "mem_percent": hist.get("mem_percent"),
                    "disk": ", ".join(hist_disk)
                })

            server_summary.append({
                "host": host,
                "cpu": srv.get('cpu'),
                "mem_percent": srv.get('mem', {}).get('percent'),
                "mem_used": srv.get('mem', {}).get('used'),
                "mem_total": srv.get('mem', {}).get('total'),
                "disk": disk_info_str,
                "network_rx": rx_rate,
                "network_tx": tx_rate,
                "system": srv.get('system', 'unknown'),
                "history": history_summary
            })
        return server_summary

    def _build_prompt(self, server_summary):
        # 加载服务器配置
        server_configs = load_json_file(get_local_server_config_file(), {})
        
        # 构建提示词，包含配置信息
        prompt = f"""你是资深服务器运维专家，拥有10年以上生产环境经验。请基于以下服务器详细数据（包括当前现状和历史数据）进行全面分析，给出准确的风险等级、具体丰富的运维建议，以及每个磁盘分区的预计写满时间。

分析要求：

1. **风险等级评估标准（按优先级依次判定）**：
   - **重要系统分区**和**非重要分区**的定义根据每个服务器的配置确定。
   - **高风险**：满足以下任一条件
     * CPU使用率超过服务器配置的CPU预警阈值
     * 内存使用率超过服务器配置的内存预警阈值
     * 任一**重要分区**使用率超过服务器配置的磁盘预警阈值
     * 任一**重要分区**预计写满时间 < 7 天
     * CPU使用率超过75% **且** 内存使用率超过80% （组合负载过高）
     * 网络流量（rx_rate 或 tx_rate）持续超过服务器配置的网络预警阈值且伴随 CPU/内存高负载
     * 指标持续恶化（基于历史数据趋势）
   - **中风险**：满足以下任一条件（且不满足高风险）
     * CPU使用率在65%到服务器配置的CPU预警阈值之间
     * 内存使用率在75%到服务器配置的内存预警阈值之间
     * 任一**重要分区**使用率在80%到服务器配置的磁盘预警阈值之间
     * 任一**重要分区**预计写满时间 7 - 30 天
     * 任一**非重要分区**使用率 > 95% 且空间小于10GB（可能影响挂载点稳定性）
     * 网络流量 > 200 Mbps 但 CPU/内存正常
     * 指标有恶化趋势（基于历史数据）
   - **低风险**：不满足上述任何条件
   - 特别说明：非重要分区即使使用率很高，但只要不影响系统运行，**不直接提升风险等级**，仅在建议中提醒用户注意。

2. **建议内容要求（非常重要：请生成丰富、专业、可操作的运维建议，长度控制在150字左右）**：
   - 每条建议必须包含以下要素：
     * **问题定位**：明确指出哪个指标异常，可能导致什么影响，结合历史数据趋势分析。
     * **排查命令**：提供1-2条立即可执行的Linux命令（具体、完整）。
     * **解决措施**：给出2-3个具体的操作选项，区分临时缓解和长期根治。
     * **预期效果**：说明执行后大概能改善多少（例如"可释放5-10GB空间"、"CPU使用率下降20%"）。
     * **紧急程度**：标注"立即处理"或"计划内维护"。
   - 示例格式（内存过高）：
     "【问题】内存使用率88%，可能导致OOM杀进程风险。【排查】ps aux --sort=-%mem | head -10 查看Top10内存进程。【临时缓解】sync && echo 3 > /proc/sys/vm/drop_caches 清理缓存（预计释放5-8GB）。【长期根治】分析进程内存泄漏：使用valgrind或检查Java堆配置，增加-Xmx参数。【紧急程度】建议今天内处理。"
   - 如果服务器状态良好，建议也要给出积极确认和优化提示：
     "【状态】CPU、内存、磁盘均处于健康水位。【建议】继续保持，可执行例行巡检：df -h, top -b -n1。无紧急问题。"

4. **预计写满时间分析**：
   - 【重要】**忽略分区列表中的分区必须完全排除在分析之外**，不进行任何风险计算或建议生成。
   - 仅对**重要分区**进行严格风险计算和写满时间预测。
   - 非重要且非忽略的分区可粗略估算风险，但忽略分区必须跳过。
   - **必须基于历史数据与当前现状的结合分析**：
     * 计算磁盘使用率的历史增长率
     * 根据历史趋势预测未来增长
     * 结合服务器类型（通过 `system` 字段）的默认增长率进行调整
   - 若服务器类型已知，参考默认增长率：
     * 数据库服务器：每月 5-10% 增长
     * Web 服务器：每月 3-5% 增长
     * 日志服务器：每月 10-20% 增长
     * 普通应用服务器：每月 2-4% 增长
   - 缺乏历史数据时，按每月 5% 保守估算。
   - 输出格式：每个分区一行，格式为 `挂载点: 预计时间`。
   - 如果预计写满时间超过 2 年，显示 `充足`。

5. **综合分析**：
   - 关注组合风险（CPU+内存同时高）。
   - 网络流量异常若与磁盘 I/O 或 CPU 飙升同时出现，应提升风险等级。
   - **基于历史数据趋势**：分析指标的变化趋势，判断是否有持续恶化的风险。
   - **忽略分区列表（ignored）中的分区必须完全排除在分析之外**，在disk_fill_time中不要包含这些分区。
   - 输出 JSON 必须严格符合格式，不得包含额外文字。

数据: {json.dumps(server_summary, ensure_ascii=False)}

服务器配置信息:
{json.dumps(server_configs, ensure_ascii=False)}

注意：
- 对于每个服务器，请优先使用其在server_configs中的配置（如果存在）
- 如果服务器在server_configs中没有配置，则使用默认值：
  - CPU预警阈值：85%
  - 内存预警阈值：90%
  - 磁盘预警阈值：90%
  - 网络预警阈值：500 Mbps
  - 重要分区：["/", "/var", "/usr", "/etc", "/boot", "/opt", "/home"]
  - 忽略分区：["/mnt", "/media", "/backup", "/data", "/tmp"]

请严格按以下JSON格式返回，不要有任何其他文字：
{{"服务器IP": {{"risk_level": "高/中/低", "suggestion": "建议内容（150字左右，包含【问题】、【排查】、【缓解】、【根治】、【紧急程度】等标签）", "disk_fill_time": "每个分区的预计写满时间，每行一个"}}, ...}}

示例：
{{"10.96.140.66": {{"risk_level": "低", "suggestion": "【状态】CPU 12%，内存 35%，磁盘 / 使用率 42%。【建议】系统运行非常健康，无任何瓶颈。可定期执行 'sudo yum update -y' 保持安全补丁更新。【紧急程度】无需处理。", "disk_fill_time": "/: 充足\n/home: 2年"}}, "10.96.140.67": {{"risk_level": "中", "suggestion": "【问题】内存使用率82%，接近告警阈值。【排查】ps aux --sort=-%mem | head -10 找出高内存进程。【临时缓解】执行 'sync && echo 3 > /proc/sys/vm/drop_caches' 清理页缓存（预计释放3-5GB）。【长期根治】检查是否有内存泄漏（如Java应用增加 -Xmx 限制）。【紧急程度】建议今日处理，避免OOM。", "disk_fill_time": "/: 3个月\n/var/log: 2周"}}}}"""
        return prompt

    def _clean_llm_response(self, response):
        cleaned = response.strip()
        if cleaned.startswith("```json"):
            cleaned = cleaned[7:]
        elif cleaned.startswith("```"):
            cleaned = cleaned[3:]
        if cleaned.endswith("```"):
            cleaned = cleaned[:-3]
        return cleaned

    def _extract_json(self, response):
        return re.search(r'\{[\s\S]*\}', response)

    def _merge_analysis_results(self, data, llm_json):
        merged_servers = []
        for srv in data.get('servers', []):
            host = srv.get('host')
            ai_result = llm_json.get(host, {"risk_level": "未知", "suggestion": "AI未返回该服务器分析", "disk_fill_time": "无数据"})
            srv['ai_risk_level'] = ai_result.get('risk_level', '未知')
            srv['ai_suggestion'] = ai_result.get('suggestion', '无建议')
            srv['disk_fill_time'] = ai_result.get('disk_fill_time', '无数据')
            merged_servers.append(srv)
        return merged_servers

    def _save_ai_history(self, analysis_result):
        try:
            ai_history = load_json_file(config.AI_HISTORY_FILE, {"records": []})
            record = {
                "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "timestamp": datetime.now().timestamp(),
                "servers": []
            }

            for srv in analysis_result.get("data", []):
                network = srv.get('network', {})
                record["servers"].append({
                    "host": srv.get("host"),
                    "ai_risk_level": srv.get("ai_risk_level"),
                    "ai_suggestion": srv.get("ai_suggestion"),
                    "disk_fill_time": srv.get("disk_fill_time"),
                    "cpu": srv.get("cpu"),
                    "mem_percent": srv.get("mem", {}).get("percent"),
                    "mem_used": srv.get("mem", {}).get("used"),
                    "mem_total": srv.get("mem", {}).get("total"),
                    "disk_partitions": srv.get("disk_partitions", []),
                    "network_rx": network.get("rx_rate_mbps", 0),
                    "network_tx": network.get("tx_rate_mbps", 0),
                    "system": srv.get("system", "unknown")
                })

            ai_history["records"].append(record)
            ai_history = truncate_history(ai_history, config.MAX_HISTORY_RECORDS)
            save_json_file(config.AI_HISTORY_FILE, ai_history)

        except Exception as e:
            logger.error(f"Failed to save AI history: {e}")

    def _rule_based_analysis(self, data, server_configs):
        """基于规则的初步分析"""
        results = {}
        
        for srv in data.get('servers', []):
            host = srv.get('host')
            if not host:
                continue
            
            # 获取服务器配置
            server_config = server_configs.get(host, {})
            thresholds = server_config.get('thresholds', {
                'cpu': 85,
                'memory': 90,
                'disk': 90,
                'network': 500
            })
            
            # 获取关键指标
            cpu = float(srv.get('cpu', 0))
            mem_percent = float(srv.get('mem', {}).get('percent', 0))
            network = srv.get('network', {})
            rx_rate = float(network.get('rx_rate_mbps', 0))
            tx_rate = float(network.get('tx_rate_mbps', 0))
            
            # 风险等级评估
            risk_level = '低'
            risk_reasons = []
            
            # 检查CPU
            if cpu > thresholds['cpu']:
                risk_level = '高'
                risk_reasons.append(f"CPU使用率 {cpu}% 超过阈值 {thresholds['cpu']}%")
            elif cpu > 65:
                if risk_level != '高':
                    risk_level = '中'
                    risk_reasons.append(f"CPU使用率 {cpu}% 较高")
            
            # 检查内存
            if mem_percent > thresholds['memory']:
                risk_level = '高'
                risk_reasons.append(f"内存使用率 {mem_percent}% 超过阈值 {thresholds['memory']}%")
            elif mem_percent > 75:
                if risk_level != '高':
                    risk_level = '中'
                    risk_reasons.append(f"内存使用率 {mem_percent}% 较高")
            
            # 检查网络
            if max(rx_rate, tx_rate) > thresholds['network']:
                if risk_level != '高':
                    risk_level = '中'
                    risk_reasons.append(f"网络流量 {max(rx_rate, tx_rate)} Mbps 较高")
            
            # 检查磁盘
            disk_partitions = srv.get('disk_partitions', [])
            important_partitions = server_config.get('partitions', {}).get('important', ["/", "/var", "/usr", "/etc", "/boot", "/opt", "/home"])
            ignored_partitions = server_config.get('partitions', {}).get('ignored', ["/mnt", "/media", "/backup", "/data", "/tmp"])

            for partition in disk_partitions:
                mount = partition.get('mount')
                percent = float(partition.get('percent', 0))

                if mount in ignored_partitions:
                    continue

                if mount in important_partitions:
                    if percent > thresholds['disk']:
                        risk_level = '高'
                        risk_reasons.append(f"重要分区 {mount} 使用率 {percent}% 超过阈值 {thresholds['disk']}%")
                    elif percent > 80:
                        if risk_level != '高':
                            risk_level = '中'
                            risk_reasons.append(f"重要分区 {mount} 使用率 {percent}% 较高")
            
            # 生成规则基于的建议
            suggestion = self._generate_rule_based_suggestion(risk_level, risk_reasons, srv, thresholds)
            
            results[host] = {
                'risk_level': risk_level,
                'suggestion': suggestion,
                'rule_based': True
            }
        
        return results
    
    def _generate_rule_based_suggestion(self, risk_level, risk_reasons, server, thresholds):
        """生成基于规则的建议"""
        if risk_level == '高':
            suggestion = "【问题】服务器存在高风险问题。"
            suggestion += "【排查】"
            if any("CPU" in reason for reason in risk_reasons):
                suggestion += "top -b -n1 查看CPU占用高的进程。"
            if any("内存" in reason for reason in risk_reasons):
                suggestion += "ps aux --sort=-%mem | head -10 查看内存占用高的进程。"
            if any("网络" in reason for reason in risk_reasons):
                suggestion += "iftop 查看网络流量详情。"
            if any("磁盘" in reason for reason in risk_reasons):
                suggestion += "df -h 查看磁盘使用情况，du -h --max-depth=1 / 查看目录占用。"
            
            suggestion += "【临时缓解】根据排查结果采取相应措施，如关闭不必要的进程、清理临时文件等。"
            suggestion += "【长期根治】根据问题类型进行硬件升级或优化配置。"
            suggestion += "【紧急程度】立即处理，避免系统故障。"
        elif risk_level == '中':
            suggestion = "【问题】服务器存在中等风险问题。"
            suggestion += "【排查】"
            if any("CPU" in reason for reason in risk_reasons):
                suggestion += "top -b -n1 查看CPU使用情况。"
            if any("内存" in reason for reason in risk_reasons):
                suggestion += "ps aux --sort=-%mem | head -10 查看内存使用情况。"
            if any("网络" in reason for reason in risk_reasons):
                suggestion += "iftop 查看网络流量详情。"
            if any("磁盘" in reason for reason in risk_reasons):
                suggestion += "df -h 查看磁盘使用情况。"
            
            suggestion += "【临时缓解】优化系统配置，关闭不必要的服务。"
            suggestion += "【长期根治】评估硬件资源需求，必要时进行升级。"
            suggestion += "【紧急程度】计划内维护，近期处理。"
        else:
            suggestion = "【状态】服务器运行状态良好，无明显风险。"
            suggestion += "【建议】定期执行例行巡检，保持系统更新。"
            suggestion += "【紧急程度】无需处理。"
        
        return suggestion
    
    def _validate_and_merge_results(self, llm_json, rule_based_results, data, server_configs):
        """验证和融合AI分析结果与规则分析结果"""
        validated_results = {}
        
        for srv in data.get('servers', []):
            host = srv.get('host')
            if not host:
                continue
            
            # 获取AI分析结果
            ai_result = llm_json.get(host, {
                'risk_level': '未知',
                'suggestion': 'AI未返回该服务器分析',
                'disk_fill_time': '无数据'
            })
            
            # 获取规则分析结果
            rule_result = rule_based_results.get(host, {
                'risk_level': '低',
                'suggestion': '无规则分析结果',
                'rule_based': False
            })
            
            # 验证AI分析结果
            validated_risk_level = self._validate_risk_level(ai_result['risk_level'], rule_result['risk_level'])
            validated_suggestion = self._validate_suggestion(ai_result['suggestion'], rule_result['suggestion'], validated_risk_level)
            
            # 融合结果
            validated_results[host] = {
                'risk_level': validated_risk_level,
                'suggestion': validated_suggestion,
                'disk_fill_time': ai_result.get('disk_fill_time', '无数据')
            }
        
        return validated_results
    
    def _validate_risk_level(self, ai_risk, rule_risk):
        """验证风险等级"""
        # 风险等级优先级：高 > 中 > 低
        risk_priority = {'高': 3, '中': 2, '低': 1, '未知': 0}
        
        ai_priority = risk_priority.get(ai_risk, 0)
        rule_priority = risk_priority.get(rule_risk, 0)
        
        # 取较高的风险等级
        if ai_priority >= rule_priority:
            return ai_risk
        else:
            return rule_risk
    
    def _validate_suggestion(self, ai_suggestion, rule_suggestion, validated_risk):
        """验证建议内容"""
        # 如果AI建议包含所有必要要素，则使用AI建议
        required_elements = ['【问题】', '【排查】', '【临时缓解】', '【长期根治】', '【紧急程度】']
        has_all_elements = all(element in ai_suggestion for element in required_elements)
        
        if has_all_elements:
            return ai_suggestion
        else:
            # 否则使用规则基于的建议
            return rule_suggestion
    
    def _fallback_analysis(self, data, error_msg):
        fallback = []
        for srv in data.get('servers', []):
            srv['ai_risk_level'] = '未知'
            srv['ai_suggestion'] = 'AI分析失败，请稍后重试'
            srv['disk_fill_time'] = 'AI分析失败，无法计算'
            fallback.append(srv)
        return {"success": False, "error": error_msg, "data": fallback}

    def get_ai_history(self, host=None):
        try:
            ai_history = load_json_file(config.AI_HISTORY_FILE, {"records": []})
            if host:
                filtered = []
                for record in ai_history.get("records", []):
                    servers = [s for s in record.get("servers", []) if s.get("host") == host]
                    if servers:
                        filtered.append({
                            "time": record["time"],
                            "timestamp": record["timestamp"],
                            "servers": servers
                        })
                return {"records": filtered}
            return ai_history
        except Exception as e:
            logger.error(f"Failed to read AI history: {e}")
            return {"records": []}

ai_analyzer = AIAnalyzer()