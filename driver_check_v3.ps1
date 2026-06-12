<#
.SYNOPSIS
    PXE 部署后关键驱动状态检测脚本 v3.0 (控制台版)
.DESCRIPTION
    与 v2.0 相同的关键设备检测范围。v3.0 默认仅在控制台以表格形式输出，
    不生成任何文件。使用 -SaveTxt 可将结果同时保存为 TXT 文件。

    检测范围：
      显卡 / 网卡 / 声卡 / 存储控制器 / USB / 主板芯片组
.PARAMETER OutputDir
    TXT 报告输出目录，默认当前目录。仅在 -SaveTxt 时生效。
.PARAMETER SaveTxt
    将检测结果保存为 TXT 文件。
.PARAMETER FullScan
    切换为全量扫描模式。
.PARAMETER ExtraClass
    追加额外的设备类（逗号分隔）。
.PARAMETER Wait
    执行完毕后暂停，按 Enter 键关闭窗口。手动双击运行脚本时使用。
    用于 PXE 自动化时不加此参数，以免阻塞部署流程。
.EXAMPLE
    .\driver_check_v3.ps1
    仅控制台输出，不生成文件。
.EXAMPLE
    .\driver_check_v3.ps1 -SaveTxt
    控制台输出并保存 TXT 报告到脚本所在目录。
.EXAMPLE
    .\driver_check_v3.ps1 -SaveTxt -Wait
    控制台输出、保存 TXT，完成后暂停等待按键。
.NOTES
    适用: Windows 8 / 8.1 / 10 / 11, Windows Server 2012+
    版本: 3.0
#>

param(
    [string]$OutputDir = $PSScriptRoot,
    [switch]$SaveTxt,
    [switch]$FullScan,
    [string]$ExtraClass = "",
    [switch]$Wait
)

$ErrorActionPreference = "SilentlyContinue"

# ============================================================
# 筛选规则（同 v2.0）
# ============================================================
if ($FullScan) {
    $TargetClasses = $null
    $SystemKeywordFilter = $null
}
else {
    $TargetClasses = @("Display", "Net", "Media", "HDC", "SCSIAdapter", "USB", "Computer")
    if ($ExtraClass) {
        $TargetClasses += ($ExtraClass -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $SystemKeywordFilter = @(
        "Chipset", "SMBus", "LPC", "Management Engine",
        "PCI Express", "DRAM", "Memory Controller", "Host Bridge",
        "ISA Bridge", "Root Complex", "Thermal Subsystem"
    )
}

# ============================================================
# 类别中文映射
# ============================================================
$ClassLabel = @{
    Display      = "显卡"
    Net          = "网卡"
    Media        = "声卡"
    HDC          = "SATA控制器"
    SCSIAdapter  = "存储控制器"
    USB          = "USB控制器"
    Computer     = "计算机"
    System       = "主板芯片组"
}

# ============================================================
# 采集
# ============================================================
$WmiDevices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
    Select-Object Name, DeviceID, ConfigManagerErrorCode, HardwareID, Manufacturer
$WmiIndex = @{}
foreach ($w in $WmiDevices) { if ($w.DeviceID) { $WmiIndex[$w.DeviceID] = $w } }

$SignedDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Select-Object DeviceID, DriverVersion, DriverDate, DriverProviderName
$DrvIndex = @{}
foreach ($sd in $SignedDrivers) {
    if ($sd.DeviceID -and $sd.DriverVersion) {
        $DrvIndex[$sd.DeviceID] = @{ Ver = $sd.DriverVersion; Date = $sd.DriverDate; Prov = $sd.DriverProviderName }
    }
}

$AllDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue

# ============================================================
# 过滤 + 构建结果
# ============================================================
$ResultList = [System.Collections.Generic.List[PSObject]]::new()
$OkCount = 0; $ProblemCount = 0

foreach ($dev in $AllDevices) {
    $class = $dev.Class
    $name  = $dev.FriendlyName
    $wmi   = $WmiIndex[$dev.InstanceId]
    $wmiClass = if ($wmi -and $wmi.PNPClass) { $wmi.PNPClass } else { "" }

    # 筛选
    $keep = $false
    if ($FullScan) { $keep = $true }
    elseif ($class -and $TargetClasses -contains $class) { $keep = $true }
    elseif (($class -eq "System" -or $wmiClass -eq "System") -and $name) {
        foreach ($kw in $SystemKeywordFilter) { if ($name -match $kw) { $keep = $true; break } }
    }
    if (-not $keep) { continue }

    # 错误码
    $errCode = if ($wmi) { [int]$wmi.ConfigManagerErrorCode } else { -1 }
    $isOk    = ($errCode -eq 0)

    # 核显未装驱动时显示为"Microsoft 基本显示适配器"，code=0 但实际异常
    $iGpuFakeOk = ($class -eq "Display") -and $isOk -and ($name -match 'Microsoft.*基本显示适配器|Microsoft.*Basic Display')
    if ($iGpuFakeOk) { $isOk = $false; $errCode = 28 }

    # 驱动版本
    $di = $DrvIndex[$dev.InstanceId]
    $ver  = if ($di) { $di.Ver } else { "" }
    $prov = if ($di) { $di.Prov } else { "" }
    $date = if ($di -and $di.Date) {
        try { [DateTime]::Parse($di.Date).ToString("yyyy-MM-dd") } catch { "" }
    } else { "" }

    # 硬件ID
    $hid = ""
    if ($wmi -and $wmi.HardwareID) {
        foreach ($h in $wmi.HardwareID) {
            if ($h -match 'VID_(\w+)&PID_(\w+)') { $hid = "VID_$($Matches[1])&PID_$($Matches[2])"; break }
            elseif ($h -match 'VEN_(\w+)&DEV_(\w+)') { $hid = "VEN_$($Matches[1])&DEV_$($Matches[2])"; break }
        }
    }

    $label = if ($ClassLabel.ContainsKey($class)) { $ClassLabel[$class] } else { $class }

    $ResultList.Add([PSCustomObject]@{
        Name     = if ($name) { $name } else { "(未知设备)" }
        Class    = $label
        Status   = if ($isOk) { "OK" } else { "ERR" }
        ErrCode  = $errCode
        Version  = $ver
        Date     = $date
        Provider = $prov
        HWID     = $hid
    })

    if ($isOk) { $OkCount++ } else { $ProblemCount++ }
}

$Total = $OkCount + $ProblemCount

# ============================================================
# 控制台输出
# ============================================================

# --- 列宽 (可视宽度) ---
$W_Stat = 5      #  OK / ERR
$W_Class = 10    #  主板芯片组
$W_Name = 40     #  设备名
$W_Ver = 16      #  版本号 (最长 10.0.19041.5794 = 15w)
$W_Date = 10     #  驱动日期
$W_Prov = 16     #  供应商

# --- CJK 宽度感知的 Pad / Trunc ---
function VWidth($s) {
    $len = 0
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -gt 0x2E80) { $len += 2 } else { $len++ }
    }
    return $len
}
function VPad($s, $w) {
    $vw = VWidth $s
    if ($vw -gt $w) {
        # 逐字截断，预留 1 宽度给 "…"
        $out = ""; $cur = 0
        foreach ($ch in $s.ToCharArray()) {
            $cw = if ([int]$ch -gt 0x2E80) { 2 } else { 1 }
            if ($cur + $cw + 1 -gt $w) { $out += "…"; break }
            $out += $ch; $cur += $cw
        }
        return $out
    }
    return $s + (" " * ($w - $vw))
}
function VTrunc($s, $w) { VPad $s $w }

# --- 边框线 ---
$H = [string]::new([char]0x2500, 1)  # ─
function BLine($L, $T, $R) {
    $cols = @($W_Stat, $W_Class, $W_Name, $W_Ver, $W_Date, $W_Prov)
    $line = "  " + $L
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $line += ([string]::new($H, $cols[$i] + 2))
        if ($i -lt $cols.Count - 1) { $line += $T }
    }
    $line += $R
    Write-Host $line -ForegroundColor DarkGray
}
function Top    { BLine ([char]0x250C) ([char]0x252C) ([char]0x2510) }
function Sep    { BLine ([char]0x251C) ([char]0x253C) ([char]0x2524) }
function Bottom { BLine ([char]0x2514) ([char]0x2534) ([char]0x2518) }

# --- 渲染一行 ---
function DataRow($stat, $class, $name, $ver, $date, $prov) {
    $cells = @(
        @{Text = $stat; W = $W_Stat;  Color = if ($stat -eq "ERR") { "Red" } elseif ($stat -eq "OK") { "Green" } else { $null }},
        @{Text = $class; W = $W_Class;  Color = $null},
        @{Text = $name;  W = $W_Name;   Color = $null},
        @{Text = $ver;   W = $W_Ver;    Color = $null},
        @{Text = $date;  W = $W_Date;   Color = $null},
        @{Text = $prov;  W = $W_Prov;   Color = $null}
    )
    Write-Host "  │" -NoNewline -ForegroundColor DarkGray
    for ($i = 0; $i -lt $cells.Count; $i++) {
        $c = $cells[$i]
        $padded = VPad $c.Text $c.W
        if ($c.Color) {
            Write-Host (" " + $padded + " ") -NoNewline -ForegroundColor $c.Color
        } else {
            Write-Host (" " + $padded + " ") -NoNewline
        }
        Write-Host "│" -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
}

# --- 标题 ---
Write-Host ""
Write-Host "  驱动检测  v3.0" -ForegroundColor Cyan
Write-Host ("  主机: {0}    检测 {1} 项    正常 {2}    异常 {3}" -f $env:COMPUTERNAME, $Total, $OkCount, $ProblemCount)
Write-Host ""

# --- 表头 ---
Top
DataRow "状态" "类别" "设备名称" "驱动版本" "驱动日期" "供应商"
Sep

# --- 排序: ERR 在前 ---
$Sorted = $ResultList | Sort-Object { if ($_.Status -eq "ERR") { 0 } else { 1 } }, Class, Name

$prevStatus = ""
foreach ($r in $Sorted) {
    # ERR->OK 分界线
    if ($prevStatus -eq "ERR" -and $r.Status -eq "OK") { Sep }
    $prevStatus = $r.Status
    DataRow $r.Status ($r.Class) ($r.Name) ($r.Version) ($r.Date) ($r.Provider)
}
Bottom
Write-Host ""

# --- 结果摘要 ---
if ($ProblemCount -eq 0) {
    Write-Host "  结果: 全部通过。所有关键驱动均已正确安装。" -ForegroundColor Green
}
else {
    Write-Host "  结果: 发现 $ProblemCount 个问题设备，详情见上。" -ForegroundColor Red
}
Write-Host ""

# ============================================================
# TXT 输出（仅在 -SaveTxt 时）
# ============================================================
if ($SaveTxt -and $OutputDir) {
    if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $TxtPath = Join-Path $OutputDir "DriverCheck_v3_${env:COMPUTERNAME}_${ts}.txt"

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("驱动检测 v3.0")
    [void]$sb.AppendLine("==============================================================")
    [void]$sb.AppendLine(("主机: {0}    检测 {1} 项    正常 {2}    异常 {3}" -f $env:COMPUTERNAME, $Total, $OkCount, $ProblemCount))
    [void]$sb.AppendLine("")

    $header = ("{0,-5}  {1,-10}  {2,-42}  {3,-18}  {4,-12}  {5,-18}" -f "状态", "类别", "设备名称", "驱动版本", "驱动日期", "供应商")
    [void]$sb.AppendLine($header)
    [void]$sb.AppendLine(("-" * 110))

    $Sorted = $ResultList | Sort-Object { if ($_.Status -eq "ERR") { 0 } else { 1 } }, Class, Name
    foreach ($r in $Sorted) {
        $line = ("{0,-5}  {1,-10}  {2,-42}  {3,-18}  {4,-12}  {5,-18}" -f $r.Status, $r.Class, ($r.Name.Substring(0, [Math]::Min(42, $r.Name.Length))), $r.Version, $r.Date, $r.Provider)
        [void]$sb.AppendLine($line)
    }

    [void]$sb.AppendLine("")
    if ($ProblemCount -eq 0) {
        [void]$sb.AppendLine("结果: 全部通过。")
    } else {
        [void]$sb.AppendLine("结果: 发现 $ProblemCount 个问题设备。")
    }

    [System.IO.File]::WriteAllText($TxtPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($true))
    Write-Host ("  TXT 报告: " + $TxtPath) -ForegroundColor DarkGray
    Write-Host ""
}

if ($ProblemCount -gt 0) { exit 1 } else { exit 0 }

# 等待用户按键（仅手动运行时使用，不加 -Wait 则直接退出）
if ($Wait) {
    Write-Host ""
    Read-Host "按 Enter 键退出"
}
