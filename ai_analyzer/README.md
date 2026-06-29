# 服务器集群监控系统

基于Web的服务器集群监控平台，支持多系统管理、实时状态监控、流量趋势分析、AI诊断和事件警告功能。

## 功能特性

### 1. 多系统管理
- 支持按系统分组管理服务器（如：SPC系统、智能助手系统等）
- 系统选择器可动态筛选不同系统的服务器
- 支持添加新服务器到指定系统

### 2. 实时状态监控
- 实时显示服务器CPU、内存、磁盘使用率
- 显示网络流量（接收/发送速率）
- 服务器运行时间监控
- 支持为服务器添加描述信息

### 3. 流量趋势分析
- 历史流量数据图表展示
- 按时间轴显示流量变化趋势
- 支持按系统筛选流量数据

### 4. AI智能诊断
- 自动分析服务器健康状态
- 风险等级评估（高/中/低）
- 磁盘预计写满时间预测
- 个性化诊断建议

### 5. 事件警告管理
- 实时收集和分析系统事件
- 多级别警告分类（严重/错误/警告）
- 警告趋势图表展示
- 灵活的筛选功能（按时间、级别、系统）

## 目录结构

```
智能巡检/
├── server.py              # Web服务器主程序
├── config.py              # 配置文件
├── data_collector.py      # 数据收集模块
├── ai_analyzer.py         # AI分析模块
├── utils.py               # 工具函数
├── monitor.html           # 前端页面
├── servers.conf           # 服务器配置文件
├── static/
│   ├── css/
│   │   └── style.css      # 样式文件
│   └── js/
│       └── app.js         # 前端逻辑
└── README.md              # 说明文档
```

## 安装部署

### 环境要求
- Python 3.6+
- bash shell（Linux环境）
- 需要能访问远程服务器获取监控数据

### 配置服务器列表

编辑 `servers.conf` 文件，添加要监控的服务器：

```conf
# SPC系统服务器
10.96.140.66:spc
10.96.140.67:spc
10.96.140.68:spc
10.96.140.69:spc
10.96.140.70:spc

# 智能助手系统服务器
10.176.137.13:智能助手
```

格式说明：
- 每行一个服务器
- 格式：`IP地址:系统名称`
- `#`开头的行为注释

### 配置说明

编辑 `config.py` 文件：

```python
PORT = 9353                      # 服务器监听端口
AI_API_URL = "http://..."        # AI分析API地址
SCRIPT_DIR = "/mnt/data/..."    # 脚本目录
```

### 启动服务

```bash
# 进入项目目录
cd /path/to/智能巡检/1.8

# 启动服务器
python3 server.py

# 或后台运行
nohup python3 server.py &
```

服务启动后访问：`http://服务器IP:9353/monitor.html`

## 反向代理配置

### Nginx配置示例

```nginx
location /api/monitor/ {
    proxy_pass http://10.176.137.14:9353/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

### 注意事项
- 反向代理路径必须为 `/api/monitor/`
- 静态文件路径已调整为 `/api/monitor/static/`
- 服务器会自动处理路径前缀

## 使用指南

### 系统导航
- 页面顶部的系统选择器用于切换不同系统
- 选择"全部系统"可查看所有服务器
- 选择特定系统可筛选该系统下的服务器

### 添加服务器
1. 点击页面右上角的"➕ 添加服务器"按钮
2. 填写服务器信息：
   - IP地址（必填）
   - 所属系统（必填）
   - 服务器描述（可选）
3. 点击"添加"完成

### 服务器描述
- 在实时状态页面的每个服务器卡片下方
- 输入框可编辑服务器描述
- 描述会自动保存并同步到所有用户

### 刷新数据
- 点击"⟳ 刷新"按钮手动刷新数据
- 页面每5分钟自动刷新一次

### AI诊断
1. 点击"🤖 AI 诊断"按钮
2. 系统自动分析所有服务器状态
3. 查看风险等级和建议

## API接口

### 监控数据
- `GET /api/monitor/status` - 获取实时状态
- `GET /api/monitor/network_history` - 获取流量历史
- `GET /api/monitor/events` - 获取事件警告

### 服务器管理
- `GET /api/monitor/server_descriptions` - 获取服务器描述
- `POST /api/monitor/save_server_description` - 保存服务器描述
- `POST /api/monitor/add_server` - 添加服务器

### AI分析
- `POST /api/monitor/analyze` - AI健康诊断

### 其他
- `GET /api/monitor/health` - 健康检查
- `GET /api/monitor/servers` - 服务器列表

## 数据存储

- `servers.conf` - 服务器配置
- `server_descriptions.json` - 服务器描述
- `history.json` - 历史数据
- `ai_history.json` - AI分析历史
- `events/events.json` - 事件数据

## 故障排查

### 服务器无法启动
1. 检查Python环境：`python3 --version`
2. 检查端口占用：`netstat -tlnp | grep 9353`
3. 查看错误日志

### 无法获取数据
1. 检查远程服务器是否可达
2. 检查数据收集脚本是否正常执行
3. 检查配置文件路径是否正确

### 页面显示异常
1. 清除浏览器缓存
2. 检查网络请求是否正常（F12开发者工具）
3. 查看浏览器控制台错误信息

## 技术支持

如有问题，请检查：
1. 服务器日志输出
2. 浏览器控制台错误信息
3. 网络请求是否正常
