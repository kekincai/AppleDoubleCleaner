<div align="center">

# 🧹 AppleDoubleCleaner

**在 Windows 上安全、快速地清理 Mac 留在 exFAT / FAT 硬盘上的 `._` 垃圾文件**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![No install](https://img.shields.io/badge/install-none-brightgreen)

双击即用 · 多盘并行 · 校验文件头，绝不误删真文件

[English](#english) · [快速开始](#-快速开始) · [安全机制](#-安全机制) · [常见问题](#-常见问题)

</div>

---

## 🤔 这是什么

macOS 往 **exFAT / FAT32** 格式的硬盘（移动硬盘、U 盘、SD 卡）复制文件时，会给每个文件额外生成一个 `._文件名` 的隐藏文件（AppleDouble 格式），用来保存 Finder 标签、扩展属性等 Mac 专用的元数据。

在 Windows 上，这些文件：

- 数量巨大：照片/视频盘上往往有**几万到十几万个**；
- 打不开、没用，还会干扰相册软件、视频剪辑软件和备份工具；
- 用资源管理器或 `Get-ChildItem -Recurse` 删除非常慢，按 4KB 大小筛选又容易误删。

AppleDoubleCleaner 用一个 `.bat` 双击解决：自动找出所有 exFAT/FAT 盘，**多块盘同时处理**，逐个校验文件头后删除，并写下完整日志。

> 实测：4 块机械硬盘（共约 20 TB 照片/视频）同时处理，**45 分钟清理 139,055 个 `._` 文件，0 失败**。

## ✨ 特性

| | |
|---|---|
| 🖱️ **双击即用** | 无需安装，无需管理员权限，Windows 自带 PowerShell 即可运行 |
| ⚡ **多盘并行** | 每块盘一个独立窗口同时处理，总耗时 ≈ 最慢那块盘的耗时 |
| 🔍 **文件头校验** | 只删除开头是 AppleDouble 魔数 `00 05 16 07` 的文件，名字碰巧以 `._` 开头的真照片/视频不会被删 |
| 🛡️ **只碰 exFAT / FAT** | NTFS 盘（如系统盘 C:）一律拒绝处理 |
| 📝 **完整日志** | 每个文件的处理结果都记录在 CSV 中，可用 Excel 打开 |
| 🧪 **预演 / 隔离模式** | 命令行下可先预演不删除，或先移到隔离文件夹，确认后再删 |
| 📏 **长路径支持** | 运行环境支持时可处理超过 260 字符的路径，否则安全跳过并记录 |

## 🚀 快速开始

1. 到 [Releases](../../releases) 下载压缩包（或 `git clone` 本仓库），解压到任意文件夹。
2. 双击 **`CleanAppleDouble.bat`**。

完成。它会：

1. 自动找出所有已连接的 exFAT / FAT 盘；
2. 每块盘打开一个窗口同时扫描并删除 `._` 文件（**不再询问确认**）；
3. 全部完成后在主窗口显示汇总，日志保存在同目录的 `logs\` 文件夹。

只想清理某一块盘？双击对应的 `CleanAppleDouble_D.bat` / `_E` / `_F` / `_G`。
盘符不一样的话，复制一份改掉最后一行的盘符即可：

```bat
call "%~dp0CleanAppleDouble.bat" -ScanDrives H
```

### 运行效果

```text
找到 exFAT/FAT 盘：D: E: F: G:
同时处理 D: E: F: G:：每块盘会单独打开一个窗口显示进度，处理完自动关闭。
  G: 完成（00:06:10）
  D: 完成（00:15:37）
  F: 完成（00:26:30）
  E: 完成（00:45:29）

========== 汇总 ==========
D:  已删除 33951 个，跳过 1 个，失败 0 个
E:  已删除 60271 个，跳过 0 个，失败 0 个
F:  已删除 33166 个，跳过 0 个，失败 0 个
G:  已删除 11667 个，跳过 0 个，失败 0 个
合计已删除 139055 个，总耗时 00:45:29
```

## 📦 文件说明

| 文件 | 作用 |
|---|---|
| `CleanAppleDouble.bat` | 双击清理**所有** exFAT/FAT 盘（并行、直接删除） |
| `CleanAppleDouble_D.bat` … `_G.bat` | 双击只清理对应的一块盘 |
| `Clean-AppleDouble.ps1` | 核心脚本，所有逻辑和安全检查都在这里，bat 只是调用它 |

## 🛡️ 安全机制

一个文件必须**同时满足**以下全部条件才会被删除：

1. 文件名以 `._` 开头，且是文件（不是文件夹、不是链接）；
2. 所在磁盘是 exFAT / FAT32 / FAT 格式；
3. 文件开头 8 字节是 AppleDouble 头：`00 05 16 07 00 0[1|2] 00 00`。

任何一条不满足都会跳过，并在日志里写明原因，例如：

```text
"跳过","文件头不是 AppleDouble，可能是正常文件",4096,,"D:\...\._mp4_ (1).mp4"
```

另外：

- 跳过 `System Volume Information`、`$RECYCLE.BIN` 等系统文件夹；
- 只读的 `._` 文件也能正常删除；
- 删除失败的文件记为"失败"，可以直接重跑，已删除的不会重复处理。

> ⚠️ bat 版本是**直接永久删除，不进回收站**。`._` 文件只含 Mac 元数据，删除后照片/视频本身不受影响，但在 Mac 上设置过的 Finder 彩色标签、注释等会丢失。想更谨慎，请使用下面的预演或隔离模式。

## ⚙️ 高级用法（命令行）

```powershell
# 预演：只统计和写日志，不改动任何文件
powershell -ExecutionPolicy Bypass -File .\Clean-AppleDouble.ps1 -AllExFat

# 执行删除（会要求输入 YES 确认）
powershell -ExecutionPolicy Bypass -File .\Clean-AppleDouble.ps1 -AllExFat -Execute

# 先移到每块盘根目录的隔离文件夹，确认没问题后再手动删除隔离文件夹
powershell -ExecutionPolicy Bypass -File .\Clean-AppleDouble.ps1 -ScanDrives E,F -Execute -Quarantine

# 使用 Everything 导出的路径清单（.txt，每行一个完整路径），省去扫盘时间
powershell -ExecutionPolicy Bypass -File .\Clean-AppleDouble.ps1 -ListFile .\list.txt -Execute
```

| 参数 | 说明 |
|---|---|
| `-AllExFat` | 自动处理所有已连接的 exFAT/FAT 盘 |
| `-ScanDrives D,E` | 只处理指定的盘 |
| `-ListFile <path>` | 从清单文件读取路径（如 Everything 导出的 `.txt` / `.efu` / `.csv`） |
| `-Execute` | 真正执行；不加则只预演 |
| `-Yes` | 跳过 `YES` 确认（bat 默认带上） |
| `-Quarantine` | 不删除，移到 `X:\_AppleDouble隔离_时间\`，保留原目录结构 |
| `-KeepOrphans` | 保留"孤儿" `._` 文件（旁边已没有对应原文件的） |
| `-Sequential` | 多块盘时一块一块处理，不并行 |
| `-LogDir <path>` | 日志目录，默认桌面的 `AppleDouble清理日志` |

## ❓ 常见问题

<details>
<summary><b>为什么不直接用 Everything 搜索后删除？</b></summary>

可以，`-ListFile` 就是为此准备的。但实际耗时的大头不是"找文件"，而是机械硬盘上每个文件的读取和删除（每次都要寻道）。Everything 只能省掉扫盘那一部分；而且 Everything 的排除目录、Mac 上新写入但尚未重新索引的文件都会被漏掉。在资源管理器里一次删除十几万个文件也很容易卡死。

</details>

<details>
<summary><b>用 Rust / C 重写会不会更快？</b></summary>

基本不会。瓶颈在硬盘寻道（约 10 ms / 次），脚本本身每个文件的开销只有几十微秒，不到 1%。真正有效的提速是多块盘并行——这已经默认开启。

</details>

<details>
<summary><b>以后怎么避免 Mac 再生成 <code>._</code> 文件？</b></summary>

macOS 的 Finder 往 exFAT 复制文件时一定会生成 `._` 文件，没有开关可以关闭（`DSDontWriteNetworkStores` 只管网络盘上的 `.DS_Store`）。可行的办法：

- 在 Mac 上复制完后运行 `dot_clean -m /Volumes/盘名`；
- 关闭该盘的 Spotlight 索引：`sudo mdutil -i off /Volumes/盘名`；
- 或者定期在 Windows 上双击本工具清理一次。

</details>

<details>
<summary><b>提示"无法加载，因为在此系统上禁止运行脚本"？</b></summary>

请通过 bat 运行，或在命令里加上 `-ExecutionPolicy Bypass`（如上面的示例）。这只对这一次运行生效，不会修改系统设置。

</details>

<details>
<summary><b>日志里的"孤儿"是什么意思？</b></summary>

指旁边已经没有对应原文件的 `._` 文件（比如原文件在 Windows 上被删除或改名了）。它们同样只是 Mac 元数据，默认会一起清理；加 `-KeepOrphans` 可以保留。

</details>

## 📄 许可证

[MIT](LICENSE)

---

<a id="english"></a>

## English

**AppleDoubleCleaner** removes the `._*` AppleDouble metadata files that macOS leaves on exFAT/FAT drives — safely and fast, from Windows.

- **Double-click** `CleanAppleDouble.bat` to clean every connected exFAT/FAT drive. No install, no admin rights.
- **Parallel**: each drive is processed in its own window at the same time.
- **Safe**: a file is deleted only if its name starts with `._`, it lives on an exFAT/FAT volume, **and** its header is the AppleDouble magic `00 05 16 07`. NTFS drives are never touched.
- **Logged**: every decision is written to a CSV in `logs\`.
- Command-line options for **dry run** (default without `-Execute`), **quarantine** instead of delete, and reading paths from an **Everything** export.

The UI messages are in Chinese; see the parameter table above for options.
