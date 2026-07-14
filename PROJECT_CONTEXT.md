# driver_check — PXE 部署后显卡驱动检测与静默安装

## 项目概述

- **文件**: `driver_check.py` (v6.2)
- **打包产物**: `driver_check.exe` (PyInstaller onefile, ~8.2 MB)
- **Git 仓库**: `https://github.com/weijun8421/output.git` (branch: `main`)
- **用途**: PXE 部署完成后自动检测 GPU 驱动状态，从 `C:\Drives\` 静默安装预置驱动
- **语言**: Python 3，零第三方依赖（仅标准库 + subprocess 调用 PowerShell）
- **平台**: Windows 10/11 x64

---

## 核心设计原则

1. **核显强制安装** — Intel iGPU 无论当前驱动状态如何，PXE 模式下始终重新安装
2. **独显按需安装** — NVIDIA dGPU 仅在检测到异常（ERR）时才安装
3. **HWID 分档匹配** — 通过 `PCI\VEN_xxxx&DEV_xxxx` 中的 DEV ID 精确匹配驱动包分档
4. **退出码不信任** — 驱动安装程序的退出码不可靠，始终以实际设备状态验证为准
5. **超时不阻塞** — 每个驱动包最多等待 10 分钟，超时后 taskkill 强杀进程树，继续下一个
6. **零网络依赖** — PXE 已处理网卡驱动，本脚本仅关注 Display 类设备

---

## GPU 识别逻辑

### 设备扫描方式

通过 PowerShell 子进程执行 WMI/CIM 查询（见 `PS_GPU_SCAN` 变量）：

| 数据源 | 用途 |
|--------|------|
| `Get-PnpDevice -Class Display -PresentOnly` | 获取所有 Display 类 PnP 设备 |
| `Get-CimInstance Win32_PnPEntity` | 获取 ConfigManagerErrorCode + HardwareID |
| `Get-CimInstance Win32_PnPSignedDriver` | 获取已签名驱动的版本/日期/供应商 |
| `Get-CimInstance Win32_VideoController` | 备用：从 PNPDeviceID 中提取 PCI VEN/DEV |

### 类型判定

```python
# 核显识别
if "VEN_8086" in HWID or name 含 "Intel"/"HD Graphics"/"UHD Graphics"/"Iris"
    → gpu_type = "核显"

# 独显识别
elif "VEN_10DE" in HWID or name 含 "NVIDIA"/"GeForce"/"RTX"/"GTX"/"Quadro"
    → gpu_type = "独显"

# 无法识别
else
    → gpu_type = "未知"  (跳过安装，记录日志)
```

### 特殊处理：Microsoft Basic Display Adapter

当显卡使用微软基本显示适配器时，WMI 返回 `ConfigManagerErrorCode = 0`，但实际驱动缺失。脚本自动检测并标记为错误码 28（驱动未安装）：

```python
if code == 0 and "Microsoft Basic Display" in name:
    code = 28  # 驱动未安装
```

---

## DEV ID 分档体系

### NVIDIA 双档

| 分档 | 覆盖范围 | 目录 |
|------|---------|------|
| **Low** | Fermi(GF108) → Pascal(GP107/GP108)，GT 630 ~ GTX 1050 Ti | `NVIDIA_Graphics_Driver\low\` |
| **High** | 其他所有 DEV ID（GTX 1060 及以上） | `NVIDIA_Graphics_Driver\high\` |

**匹配逻辑**（白名单 → Low，其余 → High）：

```python
def get_nvidia_pkg_key(hwid):
    m = re.search(r'DEV_(\w{4})', hwid)
    if m and m.group(1) in NVIDIA_LOW_END_DEVS:
        return "NvidiaGPU_Low"
    return "NvidiaGPU_High"
```

**Low 档 DEV ID 完整清单**（`NVIDIA_LOW_END_DEVS`）：

| 架构 | DEV ID | 代表型号 |
|------|--------|---------|
| Fermi GF108 | `0DE1 0DE2 0DE5 0DEA 0F00 0F01 0F02` | GT 430 / GT 530 / GT 630 |
| Kepler GK107/GK208 | `0FC0 0FC1 0FC2 0FC6 0FC7 0FC8 0FC9 0FCC 0FCD` | GT 630 ~ GT 740 |
| Kepler | `1280 1281 1282 1284 1287 1288 1289 128B` | GTX 650 ~ GTX 750 Ti |
| Maxwell GM107/GM108 | `1340 1341 1380 1381 1382 1389` | GTX 745 ~ GTX 950 |
| Maxwell v2 GM206 | `1401 1402` | GTX 950 / GTX 960 |
| Pascal GP107 | `1C81 1C82 1C8C 1C8D 1C8E 1C8F` | GTX 1050 / 1050 Ti |
| Pascal GP108 | `1D01 1D02` | GT 1030 |

### Intel 三档

| 分档 | 覆盖范围 | GPU 架构 | 目录 |
|------|---------|---------|------|
| **Legacy** | 6~10 代酷睿 (Skylake → Ice Lake) | 无 Xe | `Intel_Graphics_Driver\legacy\` |
| **Maintenance** | 11~14 代酷睿 (Tiger Lake → Raptor Lake) | Xe-LP | `Intel_Graphics_Driver\maintenance\` |
| **Modern** | Core Ultra (Meteor Lake 起) + Arc 独显 | Xe-LPG / Xe2 / DG2 / Battlemage | `Intel_Graphics_Driver\modern\` |

**匹配逻辑**（先查 Legacy，再查 Maintenance，其余 → Modern）：

```python
def get_intel_pkg_key(hwid):
    m = re.search(r'DEV_(\w{4})', hwid)
    if m:
        dev = m.group(1)
        if dev in INTEL_LEGACY_DEVS:      return "IntelGPU_Legacy"
        if dev in INTEL_MAINTENANCE_DEVS: return "IntelGPU_Maintenance"
    return "IntelGPU_Modern"
```

**Legacy DEV ID** (`INTEL_LEGACY_DEVS`)：Gen6 Skylake → Gen10 Ice Lake，含 HD 630 / UHD 630 等

**Maintenance DEV ID** (`INTEL_MAINTENANCE_DEVS`)：Gen11 Tiger Lake → Gen14 Raptor Lake，含 Iris Xe / UHD Xe

**Modern**：不在上述集合中的所有 Intel DEV ID，含 Core Ultra (Xe-LPG/Xe2) + Arc A/B 系列独显

---

## 驱动包目录结构

```
C:\Drives\
├── Intel_Graphics_Driver\
│   ├── legacy\          *.exe    → 6~10代，无 Xe（非官方 dell 驱动）
│   ├── maintenance\     *.exe    → 11~14代，Xe-LP（驱动版本 7088）
│   └── modern\          *.exe    → Core Ultra + Arc 独显（驱动版本 8826）
└── NVIDIA_Graphics_Driver\
    ├── low\             *.exe    → GTX 1050 Ti 及以下
    └── high\            *.exe    → GTX 1060 及以上
```

- 每个目录取**最新修改时间**的 `.exe` 文件
- 按需检查：只检查实际需要安装的驱动包，缺一个不影响另一个

---

## 安装参数与行为

| 驱动包 | 安装参数 | 说明 |
|--------|---------|------|
| `IntelGPU_Legacy` | `/s` | 小写 s，非官方驱动包 |
| `IntelGPU_Maintenance` | `/S /quiet /norestart` | 官方驱动 |
| `IntelGPU_Modern` | `/S /quiet /norestart` | 官方驱动 |
| `NvidiaGPU_Low` | `-s -noreboot` | NVIDIA 用短横线 |
| `NvidiaGPU_High` | `-s -noreboot` | NVIDIA 用短横线 |

### 退出码处理策略

```python
SUCCESS_CODES = {0, 2, 1641, 3010}
```

| 退出码 | 含义 | 处理 |
|--------|------|------|
| `0` | 成功 | 等 3 秒 + `pnputil /scan-devices` → 返回成功 |
| `2` | 成功（需重启） | 同上 |
| `1641` | 成功（需重启） | 同上 |
| `3010` | 成功（需重启） | 同上 |
| 其他 | 非标准 | 等 30 秒 + 多次 `pnputil /scan-devices` + 设备状态验证 → 以验证结果为准 |

### 超时保护

- 每个驱动包 10 分钟硬超时
- 超时后 `taskkill /F /T /PID` 强杀进程树
- 超时不影响下一个驱动包的安装

### 安装方式

```python
proc = subprocess.Popen(
    [driver_exe] + pkg["args"].split(),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    creationflags=subprocess.CREATE_NO_WINDOW,  # 无窗口静默
)
```

---

## 命令行参数

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `--output-dir` | string | exe 所在目录 | TXT 报告输出路径 |
| `--save-txt` | flag | 关闭 | 生成 TXT 报告 |
| `--wait` | flag | 关闭 | 执行完毕后暂停 |
| `--auto-install` | flag | 关闭 | PXE 无人值守模式 |

### 典型用法

```bash
# 仅检测
driver_check.exe

# 检测 + TXT 报告
driver_check.exe --save-txt

# PXE 无人值守安装
driver_check.exe --auto-install

# 完整参数
driver_check.exe --auto-install --save-txt --wait
```

---

## 退出码

| 退出码 | 含义 |
|--------|------|
| `0` | 全部正常 / 安装后全部修复 |
| `1` | 存在异常设备 |
| `2` | AutoInstall 需要管理员权限 |
| `3` | WMI 查询失败 |
| `99` | 未预期的脚本异常 |
| `130` | 用户中断 (Ctrl+C) |

---

## TXT 报告命名规则

```
DriverCheck_{prefix}_{hostname}_{timestamp}.txt

示例:
  DriverCheck_v6_DESKTOP-ABC_20260714_153000.txt        # 安装前
  DriverCheck_v6_fixed_DESKTOP-ABC_20260714_153500.txt   # 安装后（含安装日志）
```

- `--auto-install` 模式生成 2 份报告（安装前 v6 + 安装后 v6_fixed）
- `v6_fixed` 报告末尾附 `--- 驱动安装日志 ---`
- 编码：UTF-8-BOM（`utf-8-sig`）

---

## 关键代码结构

```
driver_check.py
├── 配置区 (L28-132)
│   ├── DRIVER_BASE = r"C:\Drives"
│   ├── NVIDIA_LOW_END_DEVS       — 低端 NVIDIA DEV ID 白名单
│   ├── INTEL_LEGACY_DEVS         — Intel 6-10代 DEV ID
│   ├── INTEL_MAINTENANCE_DEVS    — Intel 11-14代 DEV ID
│   ├── DRIVER_PACKAGES           — 5 个驱动包配置(path/pattern/args/vendor)
│   ├── get_nvidia_pkg_key(hwid)  — DEV ID → "NvidiaGPU_Low" / "NvidiaGPU_High"
│   ├── get_intel_pkg_key(hwid)   — DEV ID → "IntelGPU_Legacy" / "Maintenance" / "Modern"
│   ├── SUCCESS_CODES = {0,2,1641,3010}
│   └── TIMEOUT_MS = 600000
│
├── 工具函数 (L137-174)
│   ├── Color / cprint()           — ANSI 控制台颜色
│   ├── is_admin()                 — ctypes IsUserAnAdmin
│   └── run_ps_json()              — PowerShell → JSON 通用执行器
│
├── GPU 扫描 (L179-305)
│   ├── PS_GPU_SCAN               — PowerShell 脚本（WMI/CIM 查询）
│   └── invoke_gpu_scan()         — 解析 JSON → 结构化的 GPU 列表
│
├── 控制台输出 (L310-332)
│   └── write_result()            — 格式化控制台表格
│
├── TXT 报告 (L337-379)
│   └── save_txt_report()         — 写入 UTF-8-BOM TXT 文件
│
├── 驱动安装 (L384-478)
│   ├── test_driver_package()     — 检查目录 + .exe 是否存在
│   └── install_driver_package()  — subprocess 静默安装 + 超时保护 + 退出码处理
│
├── 自动安装编排 (L483-585)
│   └── invoke_auto_install()     — 核显强制安装 + 独显按需安装 + 日志汇总
│
└── 主流程 main() (L590-723)
    ├── arg 解析
    ├── 第一次扫描 → 输出
    ├── [AutoInstall] 核显强制 + 独显ERR → 安装
    ├── 第二次扫描 → 对比修复前后
    └── TXT 报告 / --wait 暂停
```

---

## 打包说明

使用 PyInstaller 打包为单文件 exe：

```bash
pip install pyinstaller
pyinstaller --onefile --console --name driver_check driver_check.py
```

### 路径处理（重要）

PyInstaller onefile 模式下，`__file__` 指向临时解压目录而非 exe 所在目录。脚本通过 `sys.frozen` 判断：

```python
if getattr(sys, 'frozen', False):
    exe_dir = os.path.dirname(os.path.abspath(sys.executable))
else:
    exe_dir = os.path.dirname(os.path.abspath(__file__))
```

---

## 已知问题与注意事项

1. **PowerShell 依赖** — 脚本通过 `subprocess` 调用 PowerShell 执行 WMI 查询，因此系统必须有 PowerShell 5.1+
2. **管理员权限** — `--auto-install` 模式需要管理员权限，使用 `ctypes.windll.shell32.IsUserAnAdmin()` 检测（不依赖 Server 服务）
3. **编码** — 所有中文输出使用 UTF-8；TXT 报告使用 UTF-8-BOM（Windows 记事本兼容）
4. **进程创建** — 使用 `subprocess.Popen` + `CREATE_NO_WINDOW` 实现真正无窗口静默安装
5. **退出码不可靠** — 经验表明 NVIDIA 驱动可能返回 `3825205280`（溢出）等非标准码但实际安装成功，因此以设备状态验证为准
6. **CJK 编码注意事项** — 编辑 Python 文件中的中文字符串时，确保编辑器使用 UTF-8 编码
7. **Bash vs PowerShell** — 在 Git Bash 中执行 PowerShell 命令时需注意 `$` 和 `@` 字符转义问题

---

## 版本历史

| 版本 | 变更 |
|------|------|
| v6.2 | Intel 三档分选 (legacy/maintenance/modern) + 核显强制安装；NVIDIA 双档；退出码智能判断 |
| v6.1 | 精简为纯显卡检测安装，移除网卡及其他设备类 |
| v6.0 | Python 重写，修复 PowerShell 版 6 个问题 |
| v5.1 | PowerShell 版，两种模式，超时保护 |

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `driver_check.py` | 主脚本 |
| `driver_check.exe` | PyInstaller 打包的独立可执行文件 |
| `完整运行规则.txt` | 面向用户的完整使用说明 |
| `PROJECT_CONTEXT.md` | 本文档 — 面向开发/AI 的项目上下文 |
| `debug_driver.ps1` | 诊断 PowerShell 脚本 |
| `driver_check.ps1` | PowerShell v5 原版（已弃用） |

---

> **最后更新**: 2026-07-14
> **Git**: `git@github.com:weijun8421/output.git` (main)
