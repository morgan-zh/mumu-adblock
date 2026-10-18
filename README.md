# MuMu 模拟器去广告工具（可移植版）

> 自动识别 MuMu 模拟器安装位置 → 一键去广告 → 随时完整还原。  
> 纯 PowerShell 实现，不修改模拟器可执行文件，所有改动可逆。**支持任意 Windows 电脑，不写死路径。**

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue)]()
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## 这是什么

MuMu 模拟器自带游戏中心开屏广告、遥测上报、自动更新弹窗与常驻后台服务。本项目通过 5 个相对独立的模块去掉这些打扰，并把每一处改动记录在案，支持一键还原。

**设计原则**

- **不删文件、不卸载、不改 exe** —— 只做禁用与配置调整，全部可逆
- **不写死环境** —— 安装路径、ADB 端口、服务名、包名全部运行时探测
- **不瞎猜** —— 缺少原始依据时宁可如实报告，也不凭猜测"还原"

## 快速开始

```powershell
# 下载后进入目录，直接双击菜单（推荐）
Start-MuMu-AdBlock.cmd
```

或命令行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MuMu-AdBlock.ps1
```

首次运行会弹 **UAC 提权确认**（改 hosts、停服务、改注册表需要管理员权限）。

## 文件结构

```
.
├─ tools/
│  ├─ MuMu-AdBlock.ps1          主脚本，全部功能
│  ├─ Start-MuMu-AdBlock.cmd    双击菜单（纯 ASCII，任何系统不乱码）
│  └─ README-MuMu-AdBlock.md    详细中文说明（参数、机制、排错）
├─ LICENSE
└─ README.md
```

## 四种模式

| 模式 | 命令 | 说明 |
| --- | --- | --- |
| 去广告 | `-Action Apply`（默认） | 执行全部 5 个模块 |
| 检查 | `-Action Verify` | 只读校验各项是否生效，无需管理员 |
| 还原 | `-Action Restore` | 依据记录精确撤销 |
| 检测 | `-Action Detect` | 只显示识别到的安装位置/端口/服务状态 |

其它参数：

| 参数 | 说明 |
| --- | --- |
| `-DryRun` | 预览模式，只打印将做什么，不写任何文件 |
| `-NoLaunch` | 不自动启动模拟器（未启动时跳过游戏中心模块） |
| `-Strict` | 额外禁用 `com.netease.nie.yosemite`（网易推广组件，默认不动） |
| `-BootTimeoutSec n` | 等待模拟器开机完成的秒数（默认 180） |
| `-Transcript <path>` | 将本次运行日志写到指定文件 |

## 改了什么

| # | 模块 | 具体动作 | 需要模拟器运行 |
| --- | --- | --- | --- |
| 1 | hosts 屏蔽 | 追加 8 条 `0.0.0.0` 广告/遥测域名，带专属标记便于精确移除 | 否 |
| 2 | 游戏中心 | ADB 执行 `pm disable-user com.mumu.store`，清缓存并强制停止 | **是** |
| 3 | 自动更新 | 当前版本号写入 `nx_updater_config.json` 跳过名单 | 否 |
| 4 | 后台服务 | `MuMuRemoteService` 停止 + 改为手动启动 | 否 |
| 5 | 登录自启 | 移除 `HKCU\...\Run` 下的 `MuMuPlayerService` | 否 |

> 内核服务 `MuMuNxSup` **始终保持不动** —— 禁用会导致模拟器无法启动。

## 还原机制

每次 Apply 会在 `%LOCALAPPDATA%\MuMu-AdBlock\<计算机名>-<时间戳>\` 生成：

```
record.json                        # 改动前原始状态（服务启动类型、注册表值、原本已禁用的包）
nx_updater_config.json.orig        # 更新配置文件的原件
apply.log                          # 本次操作日志
```

还原时的三道保险：

1. **首选**：读取 `record.json` + 备份文件，精确回滚
2. **次选**：更新配置旁还留了 `nx_updater_config.json.mumu-adblock.orig` sidecar
3. **无依据时**：只提示、不改动 —— 例如不会从更新跳过名单里随意删版本号

提权子进程的完整输出落在 `%LOCALAPPDATA%\MuMu-AdBlock\logs\`，便于排查。

## 跨机器识别

按优先级依次探测，命中即止：

1. 注册表卸载信息（32/64 位 + 当前用户）
2. 注册表布局键（`HKLM\SOFTWARE\MuMuPlayer` 等）
3. 常见相对路径（各盘 `Program Files` / `Games` / `MuMuPlayer` …）
4. **开始菜单与桌面快捷方式的目标路径** —— 自定义安装目录主要靠这条
5. 浅层扫描 + 限时 20 秒、深度 3 的兜底搜索（不会卡死在大硬盘上）

候选目录还要通过结构校验（`nx_main` / `nx_device` / `vms` 至少命中两项）才被认定为有效安装。

ADB 端口优先读取实例配置 `vm_config.json` 的 `nat.port_forward.adb.host_port`，读不到再从监听端口反查。

## 已知限制

- 仅支持 **Windows + MuMu Player 12**（Android 12 / 15 内核）。旧版 MuMu 6 目录结构不同，会识别失败并明确提示。
- 游戏中心模块需要模拟器运行；未运行时脚本会自动启动并等待开机完成（可用 `-NoLaunch` 关闭该行为）。
- 若网络策略强制自建 DNS 且忽略 hosts，hosts 模块可能无效（`Verify` 会如实报告）。
- 需要 UAC 可用；组策略禁用 UAC 的机器请手动以管理员身份运行。

## 排错

| 现象 | 处理 |
| --- | --- |
| 提示找不到 MuMu | 先跑 `-Action Detect` 看识别过程；确认是 MuMu 12 且目录含 `nx_main`/`nx_device` |
| 改了广告还在 | 重启模拟器；`-Action Verify` 定位未生效项 |
| 游戏中心没关掉 | 确认模拟器在运行；`-Action Detect` 检查 ADB 端口 |
| 想彻底恢复 | `-Action Restore` |
| 提权窗口一闪而过 | 查看 `%LOCALAPPDATA%\MuMu-AdBlock\logs\` 最新日志 |

## 免责声明

本项目仅修改本机配置以改善使用体验，不修改、不破解、不重新分发 MuMu 模拟器任何文件。  
hosts 屏蔽与 ADB 禁用均属可逆的本地设置调整，请自行评估并承担使用风险。  
"MuMu"、"网易" 等名称归其权利人所有，本项目与之无关联。

## 许可

[MIT](LICENSE)
