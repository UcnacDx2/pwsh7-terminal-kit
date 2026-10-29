# PowerShell 7 + Windows Terminal 一键配置

把 Windows 的默认终端换成 **Windows Terminal**，把用户日常能点到的 "Windows PowerShell" 入口换成 **PowerShell 7**，并附带一键卸载。

系统自带的 `powershell.exe`（System32 / SysWOW64）**不做任何改动**——只替换用户真正会接触到的入口。

---

## 安装后会发生什么

| 项目 | 安装前 | 安装后 |
| --- | --- | --- |
| 默认终端 | 控制台主机（conhost） | Windows Terminal |
| 开始菜单 "Windows PowerShell" | powershell.exe（5.1） | pwsh.exe（PowerShell 7） |
| 开始菜单 "Windows PowerShell (x86)" | SysWOW64 的 5.1 | pwsh.exe（PowerShell 7） |
| Shift + 右键 "在此处打开 PowerShell 窗口" | 显示 | 隐藏 |
| PATH 中的 `WindowsPowerShell\v1.0` | 存在 | 移除 |
| 双击 `.msix` / `.appx` / `.msixbundle` / `.appxbundle` | 系统默认处理 | 用本套件的 `Install-Appx.ps1` 安装 |

安装的 MSIX 应用：

- **PowerShell 7.6.7**（`Microsoft.PowerShell_8wekyb3d8bbwe`）
- **Windows Terminal 1.25.2733.0**（`Microsoft.WindowsTerminal_8wekyb3d8bbwe`）

两者都会 `Add-AppxProvisionedPackage` 预配给所有用户，新用户首次登录即可使用。

---

## 快速开始

1. 下载本仓库（`Code` → `Download ZIP`，或 `git clone`）。
2. 双击 **`Install.cmd`**。
3. 在 UAC 对话框点"是"，按提示等待完成。

安装脚本会自动从 GitHub 下载两个 MSIX 包并校验 Authenticode 签名（签名者必须是 Microsoft）。下载失败时脚本会提示改用本地文件参数。

已经手动下载好安装包？可以跳过联网下载：

```powershell
.\Install.cmd -PowerShellPackage "D:\pkg\PowerShell-7.6.7.msixbundle" -TerminalPackage "D:\pkg\Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msix"
```

只想看看当前状态、不做任何修改：

```powershell
.\Install.cmd -Verify
```

---

## 参数

### Install.ps1

| 参数 | 说明 |
| --- | --- |
| `-PowerShellPackage <路径>` | 使用本地 PowerShell 7 的 `.msixbundle`，不下载 |
| `-TerminalPackage <路径>` | 使用本地 Windows Terminal 的 `.msix` / `.msixbundle`，不下载 |
| `-NoProvision` | 不为所有用户预配，只安装给当前用户 |
| `-NoAssociations` | 不注册 `.msix` / `.appx` 文件关联 |
| `-KeepWindowsPowerShellPath` | 保留 PATH 中的 `WindowsPowerShell\v1.0` |
| `-SkipSignatureCheck` | 跳过签名校验（不建议） |
| `-Verify` | 只打印当前配置状态，不做修改，不需要管理员权限 |
| `-StatePath <路径>` | 状态文件位置，默认 `C:\ProgramData\AppxInstaller\state.json` |
| `-NoPause` | 结束后不等待按键（用于自动化） |

### Uninstall.ps1

| 参数 | 说明 |
| --- | --- |
| `-KeepPackages` | 不卸载 PowerShell 7 与 Windows Terminal，只还原配置 |
| `-KeepProvisioned` | 不撤销所有用户的预配，只还原当前用户配置 |
| `-StatePath <路径>` | 指定状态文件，默认 `C:\ProgramData\AppxInstaller\state.json` |
| `-NoPause` | 结束后不等待按键 |

---

## 会修改哪些位置

每一项修改前，脚本都会把原值记录到 `C:\ProgramData\AppxInstaller\state.json`，卸载时据此精确还原。

| 项目 | 位置 | 生效范围 |
| --- | --- | --- |
| 应用安装 | MSIX 包注册 | 当前用户（管理员） |
| 应用预配 | `Add-AppxProvisionedPackage` | 所有用户、新建用户 |
| 开始菜单快捷方式 | `ProgramData\...\Windows PowerShell\`、各用户 `AppData\Roaming\...\Windows PowerShell\`、`C:\Users\Default\...` | 所有用户、新建用户 |
| 快捷方式备份 | 同目录 `*.lnk.bak` | — |
| 右键菜单隐藏 | `Software\Classes\{Directory\Background,Directory,Drive}\shell\Powershell` 的 `HideBasedOnVelocityId = 0x639BC8` | 当前用户 + 其他用户 + Default |
| 默认终端 | `Console\%%Startup` 的 `DelegationConsole` / `DelegationTerminal` | 当前用户 + 其他用户 + Default |
| 用户 PATH | `HKCU\Environment` | 当前用户 |
| 系统 PATH | `HKLM\SYSTEM\...\Environment` | 所有用户 |
| 文件关联 | `HKCU\Software\Classes`、`HKLM\SOFTWARE\Classes` | 当前用户 + 所有用户 |

其他用户与 `C:\Users\Default` 的配置通过临时加载 `NTUSER.DAT` 完成，处理完立即卸载，不会影响正在登录的会话。

### 不会修改的内容

```
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe
```

这两个文件保持原样，`powershell.exe` 仍可被显式路径调用。

---

## 卸载

双击 **`Uninstall.cmd`**，UAC 点"是"。

- 有状态文件时：逐项还原安装前的原始值（包括原来的 PATH、原来的快捷方式、原来的右键菜单与默认终端）。
- 没有状态文件时：只清理"当前值等于本套件写入值"的项，做到尽力而为。
- **安装前就存在的应用不会被卸载**：脚本记录了安装前的版本，如果检测到之前已有 PowerShell 7 / Windows Terminal，只还原配置并保留应用（避免把用户原有的东西删掉）。

卸载后重新打开终端即可生效；已经打开着的窗口不受影响。

---

## 文件关联：Install-Appx.ps1

套件自带一个包安装器，`Install.ps1` 会把它复制到 `C:\ProgramData\AppxInstaller\Install-Appx.ps1` 并注册关联。

- 双击任意 `.msix` / `.msixbundle` / `.appx` / `.appxbundle` / `.appinstaller`
- 弹出确认框，显示包名、版本、发布者、架构、大小
- 确认后调用 `Add-AppxPackage` 安装

单独使用（不装整套配置）时：

```powershell
.\Install-Appx.ps1 -Register          # 注册当前用户的关联
.\Install-Appx.ps1 -Register -AllUsers # 管理员身份下另行注册所有用户
```

> Windows 不允许程序静默改写"默认应用"（`UserChoice` 带系统校验哈希，且算法随版本变化）。
> 本套件只注册 ProgId 与扩展名的默认处理程序；在没有 `UserChoice` 的情况下，资源管理器会使用这份注册，双击 `.msix` 依然由 `Install-Appx.ps1` 接手。
> 如果某个扩展名之前被你手动指定过其他程序，需要在"打开方式 → 选择其他应用"里选一次"始终使用"。若系统后来重置了关联，重新运行 `-Register` 即可。

---

## 系统要求

- Windows 10 21H2（build 19044）及以上，或 Windows 11（19044 已实测可用）
- 管理员权限（安装与卸载）
- 系统自带的 Windows PowerShell 5.1
- 首次安装需要能访问 GitHub（或手动提供 MSIX 包）

### 已验证环境

- Windows 10 IoT Enterprise LTSC 2021（10.0.19044）
- PowerShell 7.6.7（MSIX，x64）
- Windows Terminal 1.25.2733.0
- 安装、状态检查、卸载回滚（临时状态文件）均已实际跑通

---

## 注意事项

**PowerShell 7 是 MSIX 版，没有 `C:\Program Files\PowerShell\7`。**
这是刻意的：MSIX 包可以预配给所有用户，并随系统更新。终端配置、快捷方式都指向：

```
%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe
```

**移除 PATH 中的 `WindowsPowerShell\v1.0` 后，`powershell.exe` 不再是 PATH 命令。**
依赖 `powershell.exe` 的旧脚本、安装程序或计划任务，请改用 `pwsh.exe`，或在调用时写全路径。需要保留时用 `-KeepWindowsPowerShellPath`。

**默认终端在 Windows 10 上是"转交给 Windows Terminal 打开"。**
如果 Terminal 进程未运行，系统会先启动它；刚装完的第一个控制台可能仍由 conhost 打开，之后再打开就稳定了。Windows Terminal 设置里的"默认终端应用程序"会显示为 Windows Terminal。

**公司/域环境可能拦截。**
`Add-AppxProvisionedPackage` 需要 `AppXSvc`、`ClipSVC`、`StateRepository` 正常；组策略可能禁止预配或脚本执行。被拦截时脚本会给出具体错误并保存进度，修正后重跑即可（已完成的步骤不会重复备份）。

**之前装过 MSI 版 PowerShell 7 的话**，两者会并存（不同的安装位置和 AppID）。建议先卸载 MSI 版，避免开始菜单里出现两个 PowerShell。

**首次运行前建议先 `-Verify`**，确认脚本判断的状态符合你的预期。

**为什么脚本坚持用 Windows PowerShell 5.1 执行？**

本套件的安装、检查和卸载都依赖 `Appx` 模块。该模块的清单虽然声明 `CompatiblePSEditions = @('Desktop','Core')`，但它实际加载的 `ModuleToProcess` 是 GAC 中的 .NET Framework 程序集 `Microsoft.Windows.Appx.PackageManager.Commands`。在 PowerShell 7（.NET Core 运行时）下导入时，PowerShell 反射程序集导出类型就会抛出：

```
System.PlatformNotSupportedException (0x80131539)
   at System.Reflection.RuntimeAssembly.GetExportedTypes()
   at System.Management.Automation.Runspaces.PSSnapInHelpers.GetAssemblyTypes(...)
```

`Import-Module Appx -SkipEditionCheck` 同样失败；`-UseWindowsPowerShell` 可以绕过，但拿到的是反序列化对象，行为和错误信息都会走样。因此 `Install.cmd` / `Uninstall.cmd` 直接调用 5.1，直接用 pwsh 7 运行 `.ps1` 时脚本也会自动切换到 5.1 并提示。新版本 Windows 上的 Appx 模块可能已经能在 Core 下工作，但脚本不依赖这一点。

**在已经手工配置过的机器上安装时**，状态文件记录的是"运行 Install.ps1 那一刻"的值，而不是出厂值。想验证完整回滚，建议在干净的虚拟机或新用户配置里测试。

---

## 目录结构

```
pwsh7-terminal-kit/
├─ Install.cmd            双击安装入口
├─ Install.ps1            安装逻辑（支持参数、自动提权）
├─ Uninstall.cmd          双击卸载入口
├─ Uninstall.ps1          回滚逻辑（按状态文件精确还原）
├─ Install-Appx.ps1       .msix/.appx 安装器 + 文件关联
├─ lib/
│  └─ Common.ps1          公共函数（提权、注册表、配置单元、快捷方式、状态）
├─ README.md
└─ LICENSE
```

---

## 许可

MIT
