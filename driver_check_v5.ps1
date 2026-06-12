<#
.SYNOPSIS
    PXE 部署后关键驱动检测与本地驱动自动安装脚本 v5.1
.DESCRIPTION
    检测网卡/核显/独显驱动是否安装完毕，若未安装则从 C:\Drives
    自动静默安装预置驱动包，安装完成后重新检测并对比结果。

    两种使用模式：
      1. 检测模式 — 仅扫描驱动状态，输出表格/报告
      2. PXE 无人值守模式 — 扫描 + 静默安装 + 再扫描，全程无需人工介入

    驱动包预置路径：C:\Drives
      网卡驱动：Intel 网卡驱动包、Realtek 网卡驱动包
      核显驱动：Intel 核显驱动包
      独显驱动：NVIDIA 独显驱动包

.PARAMETER OutputDir
    TXT 报告输出目录，默认脚本所在目录。仅在 -SaveTxt 时生效。
.PARAMETER SaveTxt
    将检测结果保存为 TXT 文件。
.PARAMETER FullScan
    切换为全量扫描模式。
.PARAMETER ExtraClass
    追加额外的设备类（逗号分隔）。
.PARAMETER Wait
    执行完毕后暂停，按 Enter 键关闭窗口。
.PARAMETER AutoInstall
    检测到网卡/核显/独显驱动未安装时，自动从 C:\Drives 静默安装预置驱动。
    需要管理员权限。安装后自动重新检测并对比结果。
.EXAMPLE
    .\driver_check_v5.ps1
    检测模式：仅扫描驱动状态，控制台输出表格。
.EXAMPLE
    .\driver_check_v5.ps1 -SaveTxt -OutputDir "D:\Reports"
    检测模式：扫描并保存 TXT 报告到指定目录。
.EXAMPLE
    .\driver_check_v5.ps1 -AutoInstall
    PXE 无人值守模式：检测 + 静默安装 + 重新检测。
.EXAMPLE
    .\driver_check_v5.ps1 -AutoInstall -SaveTxt -Wait
    PXE 模式 + 保存两份报告 + 执行完毕暂停。
.NOTES
    适用: Windows 10 / 11, Windows Server 2016+
    需要管理员权限才能使用 -AutoInstall
    安装超时：每个驱动包最长等待 10 分钟，超时自动终止防止卡死
    版本: 5.1
#>

param(
    [string]$OutputDir = $PSScriptRoot,
    [switch]$SaveTxt,
    [switch]$FullScan,
    [string]$ExtraClass = "",
    [switch]$Wait,
    [switch]$AutoInstall
)

$ScriptVersion = "v5.1"

# ============================================================
# 权限检查
# ============================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($AutoInstall -and -not $IsAdmin) {
    Write-Host "  AutoInstall 需要管理员权限，请右键以管理员身份运行。" -ForegroundColor Red
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit 2
}

# ============================================================
# 驱动包配置（用户可修改）
# ============================================================
$DriverBasePath = "C:\Drives"
$DriverPackages = @{
    # 网卡驱动
    "IntelNet" = @{
        Path = Join-Path $DriverBasePath "Intel_Network_Driver"
        Pattern = "*.exe"
        InstallArgs = "/S /quiet /norestart"
        Vendor = "Intel"
    }
    "RealtekNet" = @{
        Path = Join-Path $DriverBasePath "Realtek_Network_Driver"
        Pattern = "*.exe"
        InstallArgs = "/S /quiet /norestart"
        Vendor = "Realtek"
    }
    # 核显驱动
    "IntelGPU" = @{
        Path = Join-Path $DriverBasePath "Intel_Graphics_Driver"
        Pattern = "*.exe"
        InstallArgs = "/S /quiet /norestart"
        Vendor = "Intel"
    }
    # 独显驱动
    "NvidiaGPU" = @{
        Path = Join-Path $DriverBasePath "NVIDIA_Graphics_Driver"
        Pattern = "*.exe"
        InstallArgs = "/s /norestart /noeula /clean"
        Vendor = "NVIDIA"
    }
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
# 驱动包检查与安装
# ============================================================
function Test-DriverPackage($pkg) {
    if (-not (Test-Path $pkg.Path)) {
        Write-Host "  驱动包目录不存在: $($pkg.Path)" -ForegroundColor Yellow
        return $false
    }
    $files = Get-ChildItem -Path $pkg.Path -Filter $pkg.Pattern -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) {
        Write-Host "  驱动包目录为空或未找到匹配文件: $($pkg.Path)" -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Install-DriverPackage($pkg, $deviceName) {
    Write-Host ("  正在安装 {0} 驱动: {1}" -f $pkg.Vendor, $deviceName) -ForegroundColor Cyan
    $files = Get-ChildItem -Path $pkg.Path -Filter $pkg.Pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) {
        Write-Host "  未找到可执行文件" -ForegroundColor Red
        return $false
    }

    $driverExe = $files[0].FullName
    Write-Host ("    执行: {0}" -f $driverExe) -ForegroundColor DarkGray
    Write-Host ("    参数: {0}" -f $pkg.InstallArgs) -ForegroundColor DarkGray

    try {
        # 使用 System.Diagnostics.Process 以支持超时控制，防止安装程序卡死阻塞后续脚本
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $driverExe
        $psi.Arguments = $pkg.InstallArgs
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) {
            Write-Host "    无法启动安装程序" -ForegroundColor Red
            return $false
        }

        $timeoutMs = 600000  # 10 分钟硬超时
        $exited = $proc.WaitForExit($timeoutMs)

        if (-not $exited) {
            Write-Host ("    安装超时（超过 {0} 分钟），正在强制终止..." -f ($timeoutMs / 60000)) -ForegroundColor Red
            try { $proc.Kill() } catch {}
            Start-Sleep -Seconds 2
            if (-not $proc.HasExited) {
                # 强制终止整个进程树
                try { taskkill /F /T /PID $proc.Id *>$null } catch {}
            }
            Write-Host "    安装已被终止，继续下一个驱动" -ForegroundColor Yellow
            return $false
        }

        $exitCode = $proc.ExitCode

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED
        # 0     = ERROR_SUCCESS
        # 1641  = ERROR_SUCCESS_REBOOT_INITIATED
        $successCodes = @(0, 3010, 1641)
        if ($exitCode -in $successCodes) {
            Write-Host ("    安装程序返回: {0}（成功）" -f $exitCode) -ForegroundColor Green

            # 等待驱动完成安装，触发 PnP 重新扫描
            Start-Sleep -Seconds 5
            try { pnputil /scan-devices *>$null } catch {}
            Start-Sleep -Seconds 3

            # 验证设备状态
            $updatedDev = Get-PnpDevice -FriendlyName $deviceName -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -ne 'Unknown' } |
                Select-Object -First 1
            if ($updatedDev) {
                $escapedId = $updatedDev.InstanceId -replace "'", "''"
                $wmiCheck = Get-CimInstance -ClassName Win32_PnPEntity -Filter "DeviceID='$escapedId'" -ErrorAction SilentlyContinue
                $errCode = if ($wmiCheck) { [int]$wmiCheck.ConfigManagerErrorCode } else { -1 }
                if ($errCode -eq 0) {
                    Write-Host ("    设备状态: OK，驱动已成功安装") -ForegroundColor Green
                    return $true
                } else {
                    Write-Host ("    设备状态: 错误码 {0}，可能需要重启" -f $errCode) -ForegroundColor Yellow
                    return $true  # 安装程序成功，但设备可能需要重启
                }
            } else {
                Write-Host "    无法验证设备状态，但安装程序已成功完成" -ForegroundColor Yellow
                return $true
            }
        } else {
            Write-Host ("    安装失败，退出码: {0}" -f $exitCode) -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host ("    执行异常: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Invoke-AutoInstall($ErrDevices) {
    Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "    AutoInstall：开始静默安装预置驱动" -ForegroundColor Yellow
    Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    
    # 检查驱动包目录
    Write-Host "  检查驱动包目录..." -ForegroundColor Cyan
    $allPkgsOk = $true
    foreach ($key in $DriverPackages.Keys) {
        if (-not (Test-DriverPackage $DriverPackages[$key])) {
            $allPkgsOk = $false
        }
    }
    if (-not $allPkgsOk) {
        Write-Host "  部分驱动包缺失，请检查 C:\Drives 目录结构。" -ForegroundColor Red
        return $false
    }
    Write-Host ""
    
    # 分类异常设备
    $netCards = $ErrDevices | Where-Object { $_.Class -eq "网卡" }
    $gpuCards = $ErrDevices | Where-Object { $_.Class -eq "显卡" }
    
    $installLog = @()
    $anySuccess = $false
    
    # 1. 网卡驱动安装
    if ($netCards.Count -gt 0) {
        Write-Host "  网卡驱动安装:" -ForegroundColor Yellow
        foreach ($net in $netCards) {
            Write-Host ("    - {0} ({1})" -f $net.Name, $net.ErrText) -ForegroundColor Yellow
            
            # 尝试 Intel 网卡驱动
            $intelResult = Install-DriverPackage $DriverPackages["IntelNet"] $net.Name
            if ($intelResult) {
                $installLog += "网卡($($net.Name)): Intel 驱动安装成功"
                $anySuccess = $true
                continue
            }

            # 尝试 Realtek 网卡驱动
            $realtekResult = Install-DriverPackage $DriverPackages["RealtekNet"] $net.Name
            if ($realtekResult) {
                $installLog += "网卡($($net.Name)): Realtek 驱动安装成功"
                $anySuccess = $true
            } else {
                $installLog += "网卡($($net.Name)): 驱动安装失败"
            }
        }
        Write-Host ""
    }
    
    # 2. 显卡驱动安装
    if ($gpuCards.Count -gt 0) {
        Write-Host "  显卡驱动安装:" -ForegroundColor Yellow
        foreach ($gpu in $gpuCards) {
            Write-Host ("    - {0} ({1})" -f $gpu.Name, $gpu.ErrText) -ForegroundColor Yellow
            
            # 判断是核显还是独显
            $isIntel = $gpu.Name -match 'Intel|HD Graphics|UHD Graphics|Iris'
            $isNvidia = $gpu.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro'
            
            if ($isIntel) {
                # 核显
                $igpuResult = Install-DriverPackage $DriverPackages["IntelGPU"] $gpu.Name
                if ($igpuResult) {
                    $installLog += "核显($($gpu.Name)): Intel 驱动安装成功"
                    $anySuccess = $true
                } else {
                    $installLog += "核显($($gpu.Name)): Intel 驱动安装失败"
                }
            }
            elseif ($isNvidia) {
                # 独显
                $dgpuResult = Install-DriverPackage $DriverPackages["NvidiaGPU"] $gpu.Name
                if ($dgpuResult) {
                    $installLog += "独显($($gpu.Name)): NVIDIA 驱动安装成功"
                    $anySuccess = $true
                } else {
                    $installLog += "独显($($gpu.Name)): NVIDIA 驱动安装失败"
                }
            }
            else {
                # 未知显卡类型
                Write-Host "      未知显卡类型，跳过安装" -ForegroundColor Yellow
                $installLog += "显卡($($gpu.Name)): 未知类型，跳过"
            }
        }
        Write-Host ""
    }
    
    # 安装日志
    if ($installLog.Count -gt 0) {
        Write-Host "  安装日志:" -ForegroundColor Cyan
        foreach ($log in $installLog) {
            Write-Host "    - $log" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    
    return $anySuccess
}

# ============================================================
# 第一次扫描
# ============================================================
$Scan1 = Invoke-DriverScan
Write-ResultTable $Scan1.ResultList $Scan1.OkCount $Scan1.ProblemCount $Scan1.Total

# 如果没有异常设备，直接结束
if ($Scan1.ProblemCount -eq 0) {
    Save-TxtReport $Scan1 "v5"
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit 0
}

# 如果没有 AutoInstall，按 v3 模式结束
if (-not $AutoInstall) {
    Save-TxtReport $Scan1 "v5"
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit [Math]::Min($Scan1.ProblemCount, 1)
}

# ============================================================
# AutoInstall：异常设备摘要
# ============================================================
$ErrDevices = $Scan1.ResultList | Where-Object { $_.Status -eq "ERR" }
Write-Host "  异常设备: $($ErrDevices.Count) 个" -ForegroundColor Yellow
foreach ($d in $ErrDevices) {
    $hwidInfo = if ($d.HWID) { "  [$($d.HWID)]" } else { "" }
    Write-Host ("    - [{0}] {1}  ({2}){3}" -f $d.Class, $d.Name, $d.ErrText, $hwidInfo) -ForegroundColor Yellow
}
Write-Host ""

# 筛选出需要关注的设备：网卡、显卡
$TargetErrDevices = $ErrDevices | Where-Object { $_.Class -in @("网卡", "显卡") }
if ($TargetErrDevices.Count -eq 0) {
    Write-Host "  没有需要安装驱动的网卡/显卡设备。" -ForegroundColor Yellow
    Save-TxtReport $Scan1 "v5"
    if ($Wait) { Read-Host "按 Enter 键退出" }
    exit 0
}

Write-Host "  需要安装驱动的设备: $($TargetErrDevices.Count) 个" -ForegroundColor Yellow
foreach ($d in $TargetErrDevices) {
    Write-Host ("    - [{0}] {1}" -f $d.Class, $d.Name) -ForegroundColor Yellow
}
Write-Host ""

# 执行安装（PXE 无人值守，直接安装无需确认）
$null = Invoke-AutoInstall $TargetErrDevices

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

Save-TxtReport $Scan2 "v5_fixed"
Write-ResultTable $Scan2.ResultList $Scan2.OkCount $Scan2.ProblemCount $Scan2.Total

# 等待用户按键
if ($Wait) {
    Write-Host ""
    Read-Host "按 Enter 键退出"
}

if ($Scan2.ProblemCount -gt 0) { exit [Math]::Min($Scan2.ProblemCount, 1) } else { exit 0 }
