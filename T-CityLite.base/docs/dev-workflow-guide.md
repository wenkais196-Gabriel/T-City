# T-City Lite 开发工作流指南

## 📂 目录结构说明

```
D:\                          # 你的硬盘
├── server\                  # FiveM 服务端二进制（不动）
│   └── FXServer.exe
│
├── txData\                  # ← 你的工作目录（Git 仓库根目录）
│   ├── .git\                # Git 仓库（别动）
│   ├── .gitignore
│   ├── T-CityLite.base\     # ← 服务器文件（你改这个目录）
│   │   ├── server.cfg       # 真实配置（.gitignore 排除，不上传）
│   │   ├── server.cfg.template  # 模板配置（上传到 GitHub）
│   │   ├── configs\modules\     # 14 个模块 CFG
│   │   ├── resources\           # 资源文件
│   │   └── tests\               # 测试脚本
│   ├── PROJECT_PROGRESS.md
│   └── manage_progress.py
│
└── T-City\                  # 🔜 如果你克隆到别处（新机器）
    └── T-CityLite.base\
        └── server.cfg       # 需要从 template 复制 + 填入真实数据
```

**关键点**：
- 你平时就在 `D:\txData\` 里工作，**不需要搬任何东西**
- `server.cfg`（含 License Key / DB 密码）不上传 GitHub，但本地完好
- 克隆到新机器时，复制 `server.cfg.template` → `server.cfg`，填入你的真实值即可

---

## 🌿 分支策略

建议用最轻量的方式：

```
main  ← 稳定发布版（当前 = v0.4 完成状态）
 │
 ├── v0.5-crime    ← 🚧 当前开发分支（犯罪玩法系统）
 │
 ├── v0.6-economy  ← ⏳ 未来开发分支（民间经济）
 │
 └── hotfix-xxx    ← 🔧 紧急修复分支（出问题时用）
```

### 日常开发流程

```bash
# 1. 切到开发分支（首次）
git checkout -b v0.5-crime

# 2. 日常改代码
#    ... 修改 T-CityLite.base/resources/[custom]/custom-crime/ ...
#    ... 修改 T-CityLite.base/configs/modules/crime.cfg ...

# 3. 跑测试验证
python T-CityLite.base/tests/run_all.py

# 4. 提交
git add T-CityLite.base/resources/[custom]/custom-crime/
git add T-CityLite.base/configs/modules/crime.cfg
git commit -m "feat(crime): 调整抢劫冷却时间为 30 分钟"

# 5. 推送（第一次要设 upstream）
git push -u origin v0.5-crime

# 之后每次只需
git push
```

### 版本发布流程

```bash
# v0.5 开发完成后，合并到 main
git checkout main
git merge v0.5-crime
git tag v0.5
git push origin main --tags
```

---

## 🚀 启动服务器的两种方式

### 方式 A：直接启动（推荐开发用）

`D:\txData\` 里新建 `start_server.bat`：

```bat
@echo off
D:\server\FXServer.exe +exec T-CityLite.base/server.cfg
pause
```

双击这个文件就启动了。可以把它固定到任务栏方便日常用。

### 方式 B：txAdmin 管理面板（推荐生产用）

在 txAdmin 中设置：
- **Server Path**: `D:\txData\T-CityLite.base`
- **CFG File**: `server.cfg`

---

## 🔐 敏感文件管理

| 文件 | 是否上传 GitHub | 克隆后怎么处理 |
|------|----------------|--------------|
| `server.cfg` | ❌ `.gitignore` 排除 | 复制 `server.cfg.template` → `server.cfg`，填入你的 License Key / DB 密码 |
| `configs/modules/economy.cfg` | ✅ 已脱敏 | 填入你的 Discord Webhook URL（可选） |
| `configs/modules/security.cfg` | ✅ 已脱敏 | 同上 |
| `default/data/` | ❌ `.gitignore` 排除 | 服务器运行时会自动生成 |

**安全备份建议**：把你的真实 `server.cfg` 内容存在密码管理器（如 Bitwarden）里，这样在任何机器上克隆后都能快速恢复。

---

## 📋 Git 日常速查

```bash
# 看看当前在哪个分支、改了什么
git branch          # 当前分支
git status          # 改了什么文件
git diff            # 具体改了啥

# 提交
git add <文件>       # 添加某文件
git commit -m "信息" # 提交
git push             # 推送到 GitHub

# 分支操作
git branch v0.5-crime              # 创建分支
git checkout v0.5-crime            # 切换分支
git checkout -b v0.5-crime         # 创建并切换（一步到位）
git merge v0.5-crime               # 合并到当前分支
git branch -d v0.5-crime           # 删除分支（已合并后）

# 拉取最新（在其他机器上）
git pull

# 看历史
git log --oneline --graph --all
```
