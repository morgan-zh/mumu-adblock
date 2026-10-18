# MuMu 模拟器去广告工具（可移植版）

自动识别 MuMu 模拟器安装位置 → 一键去广告 → 随时完整还原。可直接拿到别的电脑上用。

## 文件

| 文件 | 作用 |
| --- | --- |
| `MuMu-AdBlock.ps1` | 主脚本，全部功能在这里 |
| `Start-MuMu-AdBlock.cmd` | 双击即用的菜单（英文提示，任何系统都不乱码） |

两个文件放同一目录，**拷到别的电脑时两个一起拷**。

## 快速开始

推荐：双击 `Start-MuMu-AdBlock.cmd`，按菜单选 `1`（去广告）。

命令行也可以：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MuMu-AdBlock.ps1
```

首次运行会弹 **UAC 提权确认**，点"是"即可（改 hosts、停服务、改注册表都需要管理员权限）。

## 四种模式

| 命令 | 作用 |
| --- | --- |
| `-Action Apply`（默认） | 去广告 |
| `-Action Verify` | 只读检查，报告各项是否生效（不改任何东西，无需管理员） |
| `-Action Restore` | 还原到去广告之前 |
| `-Action Detect` | 只显示检测到的安装位置、端口、服务、自启状态（不改任何东西） |

其它参数：

| 参数 | 说明 |
| --- | --- |
| `-DryRun` | 预览模式，只打印将要做什么，**不写任何文件** |
| `-NoLaunch` | 不要自动启动模拟器（模拟器没开时跳过"游戏中心"这一步） |
| `-Strict` | 额外禁用 `com.netease.nie.yosemite`（网易推广组件，默认不动） |
| `-BootTimeoutSec 180` | 等待模拟器开机完成的秒数 |
| `-Transcript <路径>` | 把本次运行日志写到指定文件 |

## 它到底改了什么

1. **屏蔽广告与遥测域名**：往 `hosts` 追加 8 条 `0.0.0.0` 记录（带专属标记，便于精确移除）
2. **冻结游戏中心**：通过 ADB 执行 `pm disable-user com.mumu.store`，并清缓存、强制停止
3. **抑制自动更新**：把当前版本号写入 MuMu 自带的 `nx_updater_config.json` 跳过名单（**不改 exe 文件名**，避免签名校验与修复流程）
4. **停用后台服务**：`MuMuRemoteService` 停止并设为手动启动；内核服务 `MuMuNxSup` **保持不动**（停了模拟器起不来）
5. **移除登录自启**：删掉 `HKCU\...\Run` 里的 `MuMuPlayerService`

## 怎么保证能还原

每次 Apply 都会在 `%LOCALAPPDATA%\MuMu-AdBlock\<计算机名>-<时间戳>\` 下写一份 `record.json`，记录改动前的原始状态（服务启动类型、注册表值、哪些包原本就是禁用的……）。

- `-Action Restore` 会读取最近一份记录，**按记录精确还原**。
- 更新配置文件还有第二重保险：Apply 时在配置旁留 `nx_updater_config.json.mumu-adblock.orig`，即使记录丢了也能还原。
- **找不到任何原始依据时，脚本不会瞎猜**——比如不会随意从更新跳过名单里删版本号，只会提示你手动处理。

备份目录和日志位于：

```
%LOCALAPPDATA%\MuMu-AdBlock\
├─ DESKTOP-XXXX-20261018-110155\   ← 每次 Apply 一份
│   ├─ record.json                 ← 还原依据
│   ├─ nx_updater_config.json.orig
│   └─ apply.log
└─ logs\                           ← 提权子进程的完整输出（排错用）
```

## 跨机器能自动识别什么

脚本不写死任何一台机器的路径、端口、服务名或包名，运行时依次尝试：

1. 注册表卸载信息（32/64 位 + 当前用户）
2. 注册表布局提示（`HKLM\SOFTWARE\MuMuPlayer` 等）
3. 常见相对路径（各盘符的 `Program Files`、`Games`、`MuMuPlayer` 等）
4. **开始菜单与桌面快捷方式**的目标路径（自定义安装目录主要靠这条命中）
5. 浅层目录扫描 + **限时 20 秒、深度 3** 的兜底搜索（不会卡死在大硬盘上）
6. ADB 端口：优先读实例配置 `vm_config.json` 的 `nat.port_forward.adb.host_port`，读不到再从监听端口反查

识别结果会先做结构校验（同时存在 `nx_main`、`nx_device`、`vms` 才算有效安装），避免把同名文件夹误判成 MuMu。

## 已知限制

- **仅支持 Windows + MuMu Player 12**（含 Android 12 / 15 内核）。旧版 MuMu 6 目录结构不同，脚本会识别失败并明确提示。
- 每次 Apply 时的 ADB 操作需要模拟器处于运行状态；没开且未加 `-NoLaunch` 时会自动启动并等开机完成。**其余 4 项不需要模拟器运行**。
- 若局域网/公司策略强制使用自建 DNS 且忽略 hosts，则第 1 项可能无效（脚本会在 Verify 里如实报告）。
- 管理员提权依赖 UAC 可用；在组策略禁用 UAC 的机器上需先手动以管理员身份运行。

## 排错

| 现象 | 处理 |
| --- | --- |
| 提示找不到 MuMu | 先跑 `-Action Detect` 看识别过程；确认装的是 MuMu 12 且目录内含 `nx_main`/`nx_device` |
| 改了但广告还在 | 重启模拟器；`-Action Verify` 看哪一项没生效 |
| 游戏中心没关掉 | 模拟器需在运行；检查 ADB 端口是否被改（`-Action Detect` 会显示） |
| 想彻底恢复 | `Start-MuMu-AdBlock.cmd` → `3`，或 `-Action Restore` |
| 提权后窗口一闪而过 | 看 `%LOCALAPPDATA%\MuMu-AdBlock\logs\` 下最新的日志文件 |

## 提示

- 脚本只做"禁用"，不卸载、不删文件，所有改动均可逆。
- 去广告后如需在模拟器内使用游戏中心/模拟器商店，先 `-Action Restore`。
- 本工具不处理模拟器内的第三方应用广告（那些属于应用自身行为）。
