# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格。

## [2.0.0] - 2026-10-18

首个公开版本。相对最初的单机手工操作，全部逻辑脚本化并补齐可移植性与还原安全性。

### Added

- `tools/MuMu-AdBlock.ps1`：单一脚本覆盖 Apply / Restore / Verify / Detect 四种模式
- 自动安装识别：注册表、布局键、常见路径、开始菜单与桌面快捷方式、限时深度搜索
- ADB 端点自动发现（读取实例 `vm_config.json` 的端口映射）
- 每次运行生成 `record.json` 与配置 sidecar，支持精确还原
- 提权子进程强制落日志到 `%LOCALAPPDATA%\MuMu-AdBlock\logs\`
- `-DryRun` / `-NoLaunch` / `-Strict` / `-BootTimeoutSec` / `-Transcript` 参数
- `tools/Start-MuMu-AdBlock.cmd` 双击菜单

### Changed

- 自动更新处理改为写入跳过名单，**不再重命名 exe**，避免签名校验与修复流程
- 日志与提示统一为 ASCII，避免不同代码页下的乱码

### Fixed

- `mumu-cli sh` 在管理面未就绪时无限重试导致脚本挂起 → 改为 adb 优先，CLI 仅作兜底并置于可杀任务中
- 管理员引擎进程无法读取 `ExecutablePath` 导致误判模拟器未运行 → 改用进程名 + 端口监听双判定
- `record.json` 反序列化为对象后写入新属性会终止脚本 → 统一走安全的字段写入辅助函数
- 提权时拼接字符串传参导致子进程为空壳 → 改为参数数组
- 单元素结果集 `.Count` 不可靠导致服务/自启判定错位 → 统一用数组包裹后计数
- 无记录还原时错误地裁剪更新跳过名单 → 无依据时不再改动配置
- hosts 块识别对 BOM 与历史标记不兼容 → 改为字节级读取 + 新标记 + 按域名兜底识别

### Known limitations

- 仅支持 Windows + MuMu Player 12
- 游戏中心模块需要模拟器运行
