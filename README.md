# MuMu 模拟器去广告工具

一个基于 PowerShell 的 MuMu Player 12 去广告工具，支持自动识别安装路径、一键应用设置和恢复原状。

支持 Windows 10/11、PowerShell 5.1+。不修改模拟器的 EXE 文件，所有修改均有记录，方便还原。

## 快速开始

下载项目后，进入 `tools` 目录，双击 `Start-MuMu-AdBlock.cmd`，按菜单提示操作。

也可以在项目根目录用命令行运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\MuMu-AdBlock.ps1
```

首次应用设置时，需要管理员权限，系统会弹出 UAC 确认窗口。

## 功能说明

| 模块 | 操作 |
|---|---|
| Hosts 屏蔽 | 添加 8 条广告及遥测域名屏蔽规则 |
| 游戏中心 | 通过 ADB 禁用 `com.mumu.store`，清理缓存并停止运行 |
| 自动更新 | 将当前版本写入更新跳过名单 |
| 后台服务 | 停止 `MuMuRemoteService`，并将启动类型改为手动 |
| 登录自启 | 移除当前用户注册表中的 `MuMuPlayerService` 自启动项 |

内核服务 `MuMuNxSup` 不做修改，以免影响模拟器启动。

### 注意：禁用游戏中心后的影响

**禁用游戏中心后，MuMu 自带的游戏中心将无法正常使用。**

之后如果需要下载或安装游戏，可以通过 MT 管理器等其他工具获取安装包，再自行安装。请在操作前确认自己能够接受这一变化。

游戏中心模块需要模拟器运行。如果模拟器尚未启动，脚本默认会尝试启动模拟器，并等待其完成初始化。

## 运行模式

通过 `-Action` 指定操作：

| 模式 | 参数 | 说明 |
|---|---|---|
| 去广告 | `Apply` | 应用全部设置，默认模式 |
| 检查 | `Verify` | 检查各项设置是否生效，不主动修改配置 |
| 还原 | `Restore` | 根据备份恢复修改前的状态 |
| 检测 | `Detect` | 显示识别到的安装路径、ADB 端口和服务状态 |

### 常用命令

```powershell
# 应用设置
.\tools\MuMu-AdBlock.ps1 -Action Apply

# 检查设置
.\tools\MuMu-AdBlock.ps1 -Action Verify

# 还原设置
.\tools\MuMu-AdBlock.ps1 -Action Restore

# 检测模拟器
.\tools\MuMu-AdBlock.ps1 -Action Detect

# 预览操作，不实际修改配置
.\tools\MuMu-AdBlock.ps1 -DryRun

# 不自动启动模拟器
.\tools\MuMu-AdBlock.ps1 -NoLaunch

# 额外禁用网易推广组件
.\tools\MuMu-AdBlock.ps1 -Strict

# 将启动等待时间设为 240 秒
.\tools\MuMu-AdBlock.ps1 -BootTimeoutSec 240

# 将运行日志写入指定文件
.\tools\MuMu-AdBlock.ps1 -Transcript "C:\Temp\mumu.log"
```

### 其他参数

| 参数 | 说明 |
|---|---|
| `-DryRun` | 预览将执行的操作 |
| `-NoLaunch` | 不自动启动模拟器 |
| `-Strict` | 额外禁用 `com.netease.nie.yosemite`，默认不处理 |
| `-BootTimeoutSec n` | 等待模拟器启动的秒数，默认 180 秒 |
| `-Transcript path` | 将运行日志写入指定文件 |

## 安装路径识别

脚本会依次尝试以下方式定位模拟器：

1. 查询 32 位、64 位及当前用户的卸载注册表信息。
2. 查询 MuMu 相关注册表项。
3. 检查常见安装目录。
4. 从开始菜单和桌面快捷方式获取目标路径。
5. 在限定深度和时间内扫描目录。

找到的目录还需通过结构检查，至少包含 `nx_main`、`nx_device`、`vms` 中的两项，才会被认定为有效安装目录。

ADB 端口优先从实例的 `vm_config.json` 中读取；无法读取时，再尝试通过监听端口识别。

## 还原与备份

每次执行 `Apply` 时，脚本会在以下目录创建本次操作的记录：

```text
%LOCALAPPDATA%\MuMu-AdBlock\<计算机名>-<时间戳>\
```

主要文件：

| 文件 | 用途 |
|---|---|
| `record.json` | 保存修改前的服务、注册表及应用状态 |
| `nx_updater_config.json.orig` | 更新配置文件的原始备份 |
| `apply.log` | 记录本次操作 |

更新配置旁还会保留 `.mumu-adblock.orig` 备份文件，供还原时使用。

执行 `Restore` 时，脚本优先依据操作记录和备份恢复原状。如果缺少足够的原始信息，会提示用户，而不会猜测原值或随意删除更新跳过名单中的版本号。

提权子进程的输出日志保存在：

```text
%LOCALAPPDATA%\MuMu-AdBlock\logs\
```

**注意：** 还原功能依赖操作记录和备份文件。建议保留这些文件，不要在还原前手动删除。

## 兼容性与限制

- 支持 Windows 10/11、PowerShell 5.1+。
- 仅支持 MuMu Player 12（Android 12/15 内核），不支持 MuMu 6。
- 修改 hosts、服务和注册表需要管理员权限。
- 游戏中心模块依赖 ADB 连接及模拟器正常运行。
- 如果网络环境使用忽略系统 hosts 的 DNS 方案，域名屏蔽可能无法生效。
- `-Strict` 会额外禁用网易推广组件，可能影响相关功能。

## 常见问题

**找不到模拟器**

运行 `-Action Detect` 查看识别结果，并确认安装目录包含必要的模拟器文件。

**广告仍然出现**

重启模拟器后运行 `-Action Verify`，检查哪些设置未生效。

**游戏中心无法使用**

这是禁用游戏中心模块后的预期结果。如果需要下载或安装游戏，可以使用 MT 管理器等其他工具获取安装包。

**想恢复游戏中心**

运行 `-Action Restore`，恢复此前记录的应用状态。实际恢复结果取决于备份是否完整。

**提权窗口闪退**

检查 `%LOCALAPPDATA%\MuMu-AdBlock\logs\` 中的日志。

## 项目结构

```text
.
├─ tools/
│  ├─ MuMu-AdBlock.ps1
│  ├─ Start-MuMu-AdBlock.cmd
│  └─ README-MuMu-AdBlock.md
├─ LICENSE
└─ README.md
```

## 免责声明

本工具通过修改本机 hosts、应用状态、服务和注册表配置来减少广告及后台活动，不修改模拟器可执行文件。

使用前请自行评估风险，并保留必要的备份。项目与 MuMu、网易及其关联公司无关。

## 许可证

本项目采用 [GNU GPL v3.0](https://gitee.com/grandbeast/mumu-adblock/blob/main/LICENSE)。

修改和再分发时，请遵守 GPL-3.0 的相关条款。
