<#
.SYNOPSIS
    PXE 部署后关键驱动检测与自动修复脚本 v4.0
.DESCRIPTION
    在 v3.0 基础上新增 -AutoFix 参数：检测到异常设备后，通过 Windows Update
    自动搜索并安装缺失的驱动更新，安装完成后重新检测并对比结果。

    检测范围：
      显卡 / 网卡 / 声卡 / 存储控制器 / USB / 主板芯片组
    核显识别：自动识别"Microsoft 基本显示适配器"（code=0 但实际缺驱动）

.PARAMETER OutputDir
    TXT 报告输出目录，默认当前目录。仅在 -SaveTxt 时生效。
.PARAMETER SaveTxt
    将检测结果保存为 TXT 文件。
.PARAMETER FullScan
    切换为全量扫描模式。
.PARAMETER ExtraClass
    追加额外的设备类（逗号分隔）。
.PARAMETER Wait
    执行完毕后暂停，按 Enter 键关闭窗口。
.PARAMETER AutoFix
    检测到异常设备后，通过 Windows Update 搜索并安装驱动更新。
    需要管理员权限。安装后自动重新检测并对比结果。
.PARAMETER Force
    配合 -AutoFix 使用，跳过确认直接安装驱动。
.EXAMPLE
    .\driver_check_v4.ps1
    仅控制台输出，不生成文件。
.EXAMPLE
    .\driver_check_v4.ps1 -AutoFix
    检测 + 自动搜索驱动更新，确认后安装。
.EXAMPLE
    .\driver_check_v4.ps1 -AutoFix -Force
    检测 + 自动安装驱动（跳过确认），完成后重新检测对比。
.EXAMPLE
    .\driver_check_v4.ps1 -AutoFix -SaveTxt -Wait
    检测 + 修复 + 保存报告 + 暂停。
.NOTES
    适用: Windows 10 / 11, Windows Server 2016+
    需要管理员权限才能使用 -AutoFix
    版本: 4.0
#>

param(
    [string]$OutputDir = $PSScriptRoot,
    [switch]$SaveTxt,
    [switch]$FullScan,
    [string]$ExtraClass = "",
    [switch]$Wait,
    [switch]$AutoFix,
    [switch]$Force
)

$ErrorActionPreference = "SilentlyContinue"
$ScriptVersion = "v4.0"

# ============================================================
# 权限检查
# ============================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($AutoFix -and -not $IsAdmin) {
    Write-Host "  AutoFix 需要管理员权限，请右键以管理员身份运行。" -ForegroundColor Red
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit 2
}

# ============================================================
# 筛选规则
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
# 错误码映射
# ============================================================
$ErrorCodeMap = @{
    1  = "设备配置不正确"
    3  = "驱动损坏"
    10 = "无法启动"
    14 = "需重启"
    18 = "需重新安装"
    19 = "注册表损坏"
    21 = "正在移除"
    22 = "已禁用"
    24 = "设备未找到"
    28 = "驱动未安装"
    29 = "设备已禁用"
    31 = "驱动加载失败"
    32 = "驱动已禁用"
    37 = "驱动初始化失败"
    38 = "驱动运行中"
    39 = "驱动已损坏"
    40 = "驱动服务无效"
    43 = "设备已被停止"
    47 = "设备被安全移除"
    48 = "驱动启动失败"
    52 = "驱动签名验证失败"
}

function GetErrorText($code) {
    if ($ErrorCodeMap.ContainsKey($code)) { return $ErrorCodeMap[$code] }
    return "未知错误($code)"
}

# ============================================================
# 采集
# ============================================================
function Invoke-DriverScan {
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

        $keep = $false
        if ($FullScan) { $keep = $true }
        elseif ($class -and $TargetClasses -contains $class) { $keep = $true }
        elseif (($class -eq "System" -or $wmiClass -eq "System") -and $name) {
            foreach ($kw in $SystemKeywordFilter) { if ($name -match $kw) { $keep = $true; break } }
        }
        if (-not $keep) { continue }

        $errCode = if ($wmi) { [int]$wmi.ConfigManagerErrorCode } else { -1 }
        $isOk    = ($errCode -eq 0)

        $iGpuFakeOk = ($class -eq "Display") -and $isOk -and ($name -match 'Microsoft.*基本显示适配器|Microsoft.*Basic Display')
        if ($iGpuFakeOk) { $isOk = $false; $errCode = 28 }

        $di = $DrvIndex[$dev.InstanceId]
        $ver  = if ($di) { $di.Ver } else { "" }
        $prov = if ($di) { $di.Prov } else { "" }
        $date = if ($di -and $di.Date) {
            try { [DateTime]::Parse($di.Date).ToString("yyyy-MM-dd") } catch { "" }
        } else { "" }

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
            ErrText  = if ($isOk) { "" } else { GetErrorText $errCode }
            Version  = $ver
            Date     = $date
            Provider = $prov
            HWID     = $hid
        })

        if ($isOk) { $OkCount++ } else { $ProblemCount++ }
    }

    return @{
        ResultList   = $ResultList
        OkCount      = $OkCount
        ProblemCount = $ProblemCount
        Total        = ($OkCount + $ProblemCount)
    }
}

# ============================================================
# 控制台输出（CJK 宽度感知表格）
# ============================================================
function Write-ResultTable($ResultList, $OkCount, $ProblemCount, $Total) {
    $W_Stat  = 5
    $W_Class = 10
    $W_Name  = 40
    $W_Ver   = 16
    $W_Date  = 10
    $W_Prov  = 16

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

    $H = [string]::new([char]0x2500, 1)
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

    function DataRow($stat, $class, $name, $ver, $date, $prov) {
        $cells = @(
            @{Text = $stat; W = $W_Stat;  Color = if ($stat -eq "ERR") { "Red" } elseif ($stat -eq "OK") { "Green" } else { $null }},
            @{Text = $class; W = $W_Class; Color = $null},
            @{Text = $name;  W = $W_Name;  Color = $null},
            @{Text = $ver;   W = $W_Ver;   Color = $null},
            @{Text = $date;  W = $W_Date;  Color = $null},
            @{Text = $prov;  W = $W_Prov;  Color = $null}
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

    Write-Host ""
    Write-Host "  驱动检测  $ScriptVersion" -ForegroundColor Cyan
    Write-Host ("  主机: {0}    检测 {1} 项    正常 {2}    异常 {3}" -f $env:COMPUTERNAME, $Total, $OkCount, $ProblemCount)
    Write-Host ""

    Top
    DataRow "状态" "类别" "设备名称" "驱动版本" "驱动日期" "供应商"
    Sep

    $Sorted = $ResultList | Sort-Object { if ($_.Status -eq "ERR") { 0 } else { 1 } }, Class, Name
    $prevStatus = ""
    foreach ($r in $Sorted) {
        if ($prevStatus -eq "ERR" -and $r.Status -eq "OK") { Sep }
        $prevStatus = $r.Status
        DataRow $r.Status ($r.Class) ($r.Name) ($r.Version) ($r.Date) ($r.Provider)
    }
    Bottom
    Write-Host ""

    if ($ProblemCount -eq 0) {
        Write-Host "  结果: 全部通过。所有关键驱动均已正确安装。" -ForegroundColor Green
    }
    else {
        Write-Host "  结果: 发现 $ProblemCount 个问题设备，详情见上。" -ForegroundColor Red
    }
    Write-Host ""
}

# ============================================================
# TXT 保存
# ============================================================
function Save-TxtReport($scan, $prefix) {
    if (-not $SaveTxt -or -not $OutputDir) { return }
    if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $TxtPath = Join-Path $OutputDir "DriverCheck_${prefix}_${env:COMPUTERNAME}_${ts}.txt"

    $ResultList   = $scan.ResultList
    $OkCount      = $scan.OkCount
    $ProblemCount = $scan.ProblemCount
    $Total        = $scan.Total

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("驱动检测 $ScriptVersion")
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
}

# ============================================================
# 第一次扫描
# ============================================================
$Scan1 = Invoke-DriverScan
Write-ResultTable $Scan1.ResultList $Scan1.OkCount $Scan1.ProblemCount $Scan1.Total

# 如果没有异常设备，直接结束
if ($Scan1.ProblemCount -eq 0) {
    Save-TxtReport $Scan1 "v4"
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit 0
}

# 如果没有 AutoFix，按 v3 模式结束
if (-not $AutoFix) {
    Save-TxtReport $Scan1 "v4"
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit [Math]::Min($Scan1.ProblemCount, 1)
}

# ============================================================
# AutoFix：异常设备摘要
# ============================================================
Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "    AutoFix：启动 Windows Update 驱动搜索" -ForegroundColor Yellow
Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

$ErrDevices = $Scan1.ResultList | Where-Object { $_.Status -eq "ERR" }
Write-Host "  异常设备: $($ErrDevices.Count) 个" -ForegroundColor Yellow
foreach ($d in $ErrDevices) {
    $hwidInfo = if ($d.HWID) { "  [$($d.HWID)]" } else { "" }
    Write-Host ("    - [{0}] {1}  ({2}){3}" -f $d.Class, $d.Name, $d.ErrText, $hwidInfo) -ForegroundColor Yellow
}
Write-Host ""

# ============================================================
# AutoFix：搜索 Windows Update 驱动
# ============================================================
Write-Host "  正在连接 Windows Update 搜索驱动更新..." -ForegroundColor Cyan
Write-Host ""

try {
    $ErrorActionPreference = "Stop"

    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    $UpdateSearcher.ServerSelection = 2  # Windows Update

    Write-Host "  正在搜索 (可能需要 1-3 分钟)..." -ForegroundColor DarkGray
    $SearchResult = $UpdateSearcher.Search("IsInstalled=0 and Type='Driver'")

    $ErrorActionPreference = "SilentlyContinue"

    $DriverUpdates = @($SearchResult.Updates)
    if ($DriverUpdates.Count -eq 0) {
        Write-Host "  Windows Update 未找到可用的驱动更新。" -ForegroundColor Yellow
        Write-Host "  建议访问设备制造商官网手动下载驱动。" -ForegroundColor Yellow
        Save-TxtReport $Scan1 "v4"
        if ($Wait) { Read-Host "按 Enter 键退出" }
        exit 3
    }

    Write-Host ("  找到 {0} 个驱动更新:" -f $DriverUpdates.Count) -ForegroundColor Green
    Write-Host ""

    # 展示驱动列表
    $idx = 0
    foreach ($drv in $DriverUpdates) {
        $idx++
        $kb = ""
        foreach ($id in $drv.KBArticleIDs) { $kb = $id; break }
        $sizeMB = if ($drv.MaxDownloadSize) { [math]::Round($drv.MaxDownloadSize / 1MB, 1) } else { "?" }
        $title = $drv.Title
        if ($title.Length -gt 70) { $title = $title.Substring(0, 67) + "..." }
        Write-Host ("    {0,2}. {1}" -f $idx, $title) -ForegroundColor White
        Write-Host ("        大小: {0} MB  |  KB: {1}  |  分类: {2}" -f $sizeMB, $kb, $drv.Categories[0].Name) -ForegroundColor DarkGray
    }
    Write-Host ""

    # 确认
    if (-not $Force) {
        $choice = Read-Host "  是否安装以上驱动? [Y/n]"
        if ($choice -match '^[Nn]') {
            Write-Host "  已取消。" -ForegroundColor Yellow
            Save-TxtReport $Scan1 "v4"
            if ($Wait) { Read-Host "按 Enter 键退出" }
            exit 0
        }
    }

    # ============================================================
    # 下载驱动
    # ============================================================
    Write-Host "  正在下载驱动..." -ForegroundColor Cyan

    $UpdatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $DriverUpdates) {
        [void]$UpdatesToDownload.Add($update)
    }

    $Downloader = $UpdateSession.CreateUpdateDownloader()
    $Downloader.Updates = $UpdatesToDownload
    $DownloadResult = $Downloader.Download()

    $downloadedCount = 0; $failedCount = 0
    foreach ($update in $DriverUpdates) {
        if ($update.IsDownloaded) { $downloadedCount++ } else { $failedCount++ }
    }
    Write-Host ("  下载完成: 成功 {0} / 失败 {1}" -f $downloadedCount, $failedCount) -ForegroundColor $(if ($failedCount -eq 0) { "Green" } else { "Yellow" })

    if ($downloadedCount -eq 0) {
        Write-Host "  没有驱动可以安装。" -ForegroundColor Red
        Save-TxtReport $Scan1 "v4"
        if ($Wait) { Read-Host "按 Enter 键退出" }
        exit 4
    }
    Write-Host ""

    # ============================================================
    # 安装驱动
    # ============================================================
    Write-Host "  正在安装驱动 (请勿关闭窗口)..." -ForegroundColor Cyan

    $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $DriverUpdates) {
        if ($update.IsDownloaded) {
            [void]$UpdatesToInstall.Add($update)
        }
    }

    $Installer = $UpdateSession.CreateUpdateInstaller()
    $Installer.Updates = $UpdatesToInstall
    $InstallResult = $Installer.Install()

    $installedCount = 0; $installFailed = 0
    foreach ($update in $DriverUpdates) {
        if ($update.IsDownloaded) {
            if ($update.IsInstalled) { $installedCount++ } else { $installFailed++ }
        }
    }

    Write-Host ("  安装完成: 成功 {0} / 失败 {1}" -f $installedCount, $installFailed) -ForegroundColor $(if ($installFailed -eq 0) { "Green" } else { "Yellow" })

    $RebootRequired = $InstallResult.RebootRequired
    if ($RebootRequired) {
        Write-Host "  *** 需要重启系统以完成驱动安装 ***" -ForegroundColor Magenta
    }
    Write-Host ""

    # ============================================================
    # 重新扫描并对比
    # ============================================================
    Write-Host "  正在重新检测驱动状态..." -ForegroundColor Cyan
    $Scan2 = Invoke-DriverScan

    $fixed = $Scan1.ProblemCount - $Scan2.ProblemCount
    if ($fixed -gt 0) {
        Write-Host ("  已修复: {0} 个设备。异常数 {1} → {2}" -f $fixed, $Scan1.ProblemCount, $Scan2.ProblemCount) -ForegroundColor Green
    } elseif ($fixed -eq 0 -and $Scan2.ProblemCount -gt 0) {
        Write-Host ("  未能修复。异常数仍为 {0} 个。" -f $Scan2.ProblemCount) -ForegroundColor Yellow
    } else {
        Write-Host "  全部异常已修复！" -ForegroundColor Green
    }
    Write-Host ""

    # 展示修复后结果
    if ($Scan2.ProblemCount -gt 0) {
        Write-Host "  --- 修复后仍有异常的设备 ---" -ForegroundColor Yellow
        $RemainingErr = $Scan2.ResultList | Where-Object { $_.Status -eq "ERR" }
        foreach ($d in $RemainingErr) {
            $hwidInfo = if ($d.HWID) { "  [$($d.HWID)]" } else { "" }
            Write-Host ("    - [{0}] {1}  ({2}){3}" -f $d.Class, $d.Name, $d.ErrText, $hwidInfo) -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Save-TxtReport $Scan2 "v4_fixed"
    Write-ResultTable $Scan2.ResultList $Scan2.OkCount $Scan2.ProblemCount $Scan2.Total

    if ($RebootRequired) {
        Write-Host "  *** 请重启系统后再次运行检测确认 ***" -ForegroundColor Magenta
    }

    if ($Scan2.ProblemCount -gt 0) { exit [Math]::Min($Scan2.ProblemCount, 1) } else { exit 0 }

}
catch {
    Write-Host "  AutoFix 失败: $_" -ForegroundColor Red
    Write-Host "  可能原因: 无网络连接、Windows Update 服务异常。" -ForegroundColor Red
    Save-TxtReport $Scan1 "v4"
    exit 5
}

# 等待用户按键
if ($Wait) {
    Write-Host ""
    Read-Host "按 Enter 键退出"
}
