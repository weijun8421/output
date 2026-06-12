<#
.SYNOPSIS
    PXE 部署后驱动状态检测脚本
.DESCRIPTION
    扫描本机所有 PnP 设备，根据驱动安装状态分类输出报告。
    支持纯文本摘要、CSV 详细报告两种输出格式。
    通过 ConfigManagerErrorCode 精确判定每个设备的驱动健康状态，
    自动采集驱动版本号 (DriverVersion) 和驱动日期 (DriverDate)。
.PARAMETER OutputDir
    报告输出目录，默认为脚本所在目录。
.PARAMETER Format
    报告格式：Summary（纯文本摘要）、CSV（详细表格）、All（两者都输出），默认 All。
.PARAMETER ShowNormal
    是否在报告中展示正常设备，默认仅展示问题设备。
.EXAMPLE
    .\driver_check.ps1
    在当前目录生成 Summary 和 CSV 报告。
.EXAMPLE
    .\driver_check.ps1 -OutputDir C:\Reports -Format CSV -ShowNormal
    在 C:\Reports 生成包含所有设备（含驱动版本）的详细 CSV。
.NOTES
    适用: Windows 8 / 8.1 / 10 / 11, Windows Server 2012+ (内置 Get-PnpDevice)
    权限: 建议以管理员权限运行以获取完整信息
#>

param(
    [string]$OutputDir = $PSScriptRoot,
    [ValidateSet("Summary", "CSV", "All")]
    [string]$Format = "All",
    [switch]$ShowNormal
)

# ============================================================
# 0. 初始化
# ============================================================
$ErrorActionPreference = "SilentlyContinue"
$script:StartTime = Get-Date

# 确保输出目录存在
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Hostname  = $env:COMPUTERNAME

# ============================================================
# 1. ConfigManagerErrorCode 完整对照表
# ============================================================
$ErrorCodeMap = @{
    0  = "设备工作正常"
    1  = "设备未正确配置"
    2  = "Windows 无法加载此设备的驱动程序"
    3  = "驱动程序可能已损坏，或系统内存/资源不足"
    4  = "设备无法正常工作，驱动程序或注册表可能已损坏"
    5  = "驱动程序需要 Windows 无法管理的资源"
    6  = "设备的启动配置与其他设备冲突"
    7  = "无法筛选"
    8  = "缺少设备的驱动程序加载程序"
    9  = "控制固件错误地报告了设备资源"
    10 = "设备无法启动"
    11 = "设备故障"
    12 = "设备找不到足够的可用资源"
    13 = "Windows 无法验证设备资源"
    14 = "需要重启计算机才能使设备正常工作"
    15 = "由于可能的重新枚举问题，设备无法正常工作"
    16 = "Windows 无法识别设备使用的所有资源"
    17 = "设备正在请求未知资源类型"
    18 = "必须重新安装设备驱动程序"
    19 = "使用 VxD 加载程序失败"
    20 = "注册表可能已损坏"
    21 = "Windows 正在删除该设备"
    22 = "设备已禁用"
    23 = "系统故障，尝试更换驱动程序无效"
    24 = "设备不存在、无法正常工作或未安装所有驱动程序"
    25 = "Windows 仍在设置此设备"
    26 = "Windows 仍在设置此设备"
    27 = "设备没有有效的日志配置"
    28 = "未安装设备驱动程序"
    29 = "设备已禁用，固件未提供所需资源"
    30 = "设备使用了其他设备正在使用的中断请求(IRQ)"
    31 = "设备无法正常工作，因为 Windows 无法加载所需的驱动程序"
    32 = "此设备的驱动程序已禁用"
    33 = "Windows 无法确定此设备需要哪些资源"
    34 = "Windows 无法确定此设备的设置"
    35 = "计算机的系统固件未包含足够信息以正确配置和使用此设备"
    36 = "此设备正在请求 PCI 中断但配置为 ISA 中断"
    37 = "设备驱动程序初始化失败"
    38 = "设备驱动程序无法加载，因为先前版本的驱动程序仍在内存中"
    39 = "设备驱动程序可能已损坏或缺失"
    40 = "设备驱动程序无法访问，因为注册表或文件系统中的服务键信息无效"
    41 = "Windows 成功加载了设备驱动程序但找不到硬件设备"
    42 = "Windows 无法加载设备驱动程序，因为系统中已存在重复设备"
    43 = "Windows 已停止此设备，因为它报告了问题"
    44 = "应用程序或服务已关闭此硬件设备"
    45 = "设备当前未连接到计算机"
    46 = "Windows 无法访问此硬件设备，因为操作系统正在关闭"
    47 = "设备已准备好安全移除但尚未从计算机中移除"
    48 = "此设备的驱动程序已被阻止启动，因为已知它会导致 Windows 问题"
    49 = "Windows 无法启动新硬件设备，因为系统配置单元过大(超过注册表大小限制)"
    50 = "设备无法正常工作，需要重新安装驱动程序"
    51 = "此设备当前正在等待另一个设备或设备集启动"
    52 = "设备驱动程序未签名或签名验证失败"
}

# 驱动状态分类规则
function Get-DriverStatusCategory {
    param([int]$ErrorCode)
    switch ($ErrorCode) {
        0    { return "OK" }
        { $_ -in 14, 25, 26 } { return "PENDING" }
        { $_ -in 22, 29, 32, 44, 45, 47 } { return "DISABLED" }
        { $_ -in 21 } { return "REMOVING" }
        default { return "MISSING" }
    }
}

# ============================================================
# 2. 采集设备信息
# ============================================================
Write-Host "正在扫描本机 PnP 设备..." -ForegroundColor Cyan

# 获取所有 PnP 设备（含隐藏设备）
$AllDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue

# 用 WMI 做补充以获取更详细的属性（ConfigManagerErrorCode, HardwareID 等）
$WmiDevices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
    Select-Object Name, DeviceID, ConfigManagerErrorCode, Status, StatusInfo,
                  Manufacturer, Service, HardwareID, ClassGuid, Description, PNPClass

# 构建 DeviceID -> WMI 详细信息的索引
$WmiIndex = @{}
foreach ($w in $WmiDevices) {
    $key = $w.DeviceID
    if ($key -and -not $WmiIndex.ContainsKey($key)) {
        $WmiIndex[$key] = $w
    }
}

# ---------- 采集驱动版本信息（Win32_PnPSignedDriver）----------
# 通过 DeviceID 与 Win32_PnPEntity 做关联，获取 DriverVersion / DriverDate
$SignedDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Select-Object DeviceID, DeviceName, DriverVersion, DriverDate, DriverProviderName, InfName

$DriverVersionIndex = @{}
foreach ($sd in $SignedDrivers) {
    $key = $sd.DeviceID
    if ($key -and $sd.DriverVersion -and -not $DriverVersionIndex.ContainsKey($key)) {
        $DriverVersionIndex[$key] = @{
            Version  = $sd.DriverVersion
            Date     = $sd.DriverDate
            Provider = $sd.DriverProviderName
            InfName  = $sd.InfName
        }
    }
}

$TotalCount   = 0
$OkCount      = 0
$PendingCount = 0
$DisabledCount= 0
$MissingCount = 0
$RemovingCount= 0
$UnknownCount = 0

$ResultList = [System.Collections.Generic.List[PSObject]]::new()

foreach ($dev in $AllDevices) {
    $TotalCount++

    # 尝试从 WMI 获取详细属性
    $InstanceId = $dev.InstanceId
    $wmiDetail  = $WmiIndex[$InstanceId]

    $ErrorCode = if ($wmiDetail) { [int]$wmiDetail.ConfigManagerErrorCode } else { -1 }
    $Category  = if ($ErrorCode -ge 0) { Get-DriverStatusCategory -ErrorCode $ErrorCode } else { "UNKNOWN" }
    $ErrorDesc = if ($ErrorCodeMap.ContainsKey($ErrorCode)) { $ErrorCodeMap[$ErrorCode] } else { "未知错误" }
    $Status    = "$($dev.Status)"

    # 提取硬件 ID 信息
    $HardwareIDs = @()
    if ($wmiDetail -and $wmiDetail.HardwareID) {
        $HardwareIDs = @($wmiDetail.HardwareID)
    }

    # 提取 VID/PID (USB) 或 VEN/DEV (PCI) 关键标识
    $VidPid   = ""
    $VenDev   = ""
    $IdentStr = ""
    foreach ($hid in $HardwareIDs) {
        if ($hid -match 'VID_(\w+)&PID_(\w+)') {
            $VidPid = "VID_$($Matches[1])&PID_$($Matches[2])"
            $IdentStr = $VidPid
            break
        }
        elseif ($hid -match 'VEN_(\w+)&DEV_(\w+)') {
            $VenDev = "VEN_$($Matches[1])&DEV_$($Matches[2])"
            $IdentStr = $VenDev
            break
        }
    }

    # 设备大类
    $PnpClass = if ($dev.Class) { $dev.Class } else { "Unknown" }

    # 制造商
    $Manufacturer = if ($wmiDetail -and $wmiDetail.Manufacturer) { $wmiDetail.Manufacturer } else { "" }

    # 驱动版本信息：优先从 Win32_PnPSignedDriver 取，补充尝试 Win32_PnPEntity
    $DrvVer  = ""
    $DrvDate = ""
    $DrvProv = ""
    $DrvInf  = ""
    if ($DriverVersionIndex.ContainsKey($InstanceId)) {
        $di = $DriverVersionIndex[$InstanceId]
        $DrvVer  = $di.Version
        $DrvDate = if ($di.Date) { (Get-Date $di.Date -Format "yyyy-MM-dd") } else { "" }
        $DrvProv = $di.Provider
        $DrvInf  = $di.InfName
    }
    elseif ($wmiDetail -and $wmiDetail.DriverVersion) {
        # 兜底：Win32_PnPEntity 本身的 DriverVersion
        $DrvVer = $wmiDetail.DriverVersion
    }

    $Item = [PSCustomObject]@{
        FriendlyName    = if ($dev.FriendlyName) { $dev.FriendlyName } else { $dev.Name }
        Status          = $Status
        ErrorCode       = $ErrorCode
        ErrorDesc       = if ($ErrorCode -eq 0) { "" } else { $ErrorDesc }
        Category        = $Category
        PnpClass        = $PnpClass
        Manufacturer    = $Manufacturer
        DriverVersion   = $DrvVer
        DriverDate      = $DrvDate
        DriverProvider  = $DrvProv
        HardwareID      = $IdentStr
        InstanceId      = $InstanceId
        AllHardwareIDs  = ($HardwareIDs -join "; ")
    }

    $ResultList.Add($Item)

    switch ($Category) {
        "OK"        { $OkCount++ }
        "PENDING"   { $PendingCount++ }
        "DISABLED"  { $DisabledCount++ }
        "MISSING"   { $MissingCount++ }
        "REMOVING"  { $RemovingCount++ }
        "UNKNOWN"   { $UnknownCount++ }
    }
}

$Elapsed = ((Get-Date) - $script:StartTime).TotalSeconds
Write-Host "扫描完成，共 $TotalCount 个设备，耗时 $([math]::Round($Elapsed, 1)) 秒" -ForegroundColor Green

# ============================================================
# 3. 分类统计
# ============================================================
$ProblemDevices = @($ResultList | Where-Object { $_.Category -ne "OK" })
$OkDevices      = @($ResultList | Where-Object { $_.Category -eq "OK" })

# ============================================================
# 4. 输出报告
# ============================================================

# ---------- 摘要报告 ----------
if ($Format -in @("Summary", "All")) {
    $SummaryPath = Join-Path $OutputDir "DriverCheck_${Hostname}_${Timestamp}.txt"

    $SummaryLines = @()
    $SummaryLines += "=" * 70
    $SummaryLines += "          PXE 部署后驱动状态检测报告"
    $SummaryLines += "=" * 70
    $SummaryLines += "  主机名:     $Hostname"
    $SummaryLines += "  检测时间:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $SummaryLines += "  操作系统:   $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)"
    $SummaryLines += "  系统版本:   [Version]$(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Version)"
    $SummaryLines += "-" * 70
    $SummaryLines += "  设备总数:           $TotalCount"
    $SummaryLines += "  正常设备:           $OkCount     (绿色)"
    $SummaryLines += "  ─────────────────────────────────"
    $SummaryLines += "  驱动缺失/异常:      $MissingCount     (红色 - 驱动程序未安装或加载失败)"
    $SummaryLines += "  设备已禁用:         $DisabledCount     (灰色 - 用户或策略禁用)"
    $SummaryLines += "  等待重启生效:       $PendingCount     (黄色 - 需重启后完成安装)"
    $SummaryLines += "  正在移除:           $RemovingCount     (蓝色 - Windows 正在删除)"
    $SummaryLines += "  状态未知:           $UnknownCount"
    $SummaryLines += "-" * 70

    # ----- 已安装驱动清单（按大类分组） -----
    if ($OkDevices.Count -gt 0) {
        $SummaryLines += ""
        $SummaryLines += ">>> 已安装驱动清单 (共 $($OkDevices.Count) 个设备) <<<"
        $SummaryLines += ""

        # 按 PnpClass 分组
        $OkGrouped = $OkDevices | Group-Object -Property PnpClass | Sort-Object Count -Descending

        foreach ($classGroup in $OkGrouped) {
            $className = if ($classGroup.Name) { $classGroup.Name } else { "未分类" }
            $SummaryLines += "  [$className] ($($classGroup.Count) 个)"
            foreach ($dev in $classGroup.Group) {
                $name = if ($dev.FriendlyName) { $dev.FriendlyName } else { "(未命名设备)" }
                $ver  = if ($dev.DriverVersion) { $dev.DriverVersion } else { "-" }
                $date = if ($dev.DriverDate) { $dev.DriverDate } else { "-" }
                $prov = if ($dev.DriverProvider) { $dev.DriverProvider } else { "-" }
                $SummaryLines += "    $name"
                $SummaryLines += "      驱动版本: $ver  |  日期: $date  |  供应商: $prov"
            }
            $SummaryLines += ""
        }
    }

    # ----- 问题设备详情 -----
    if ($ProblemDevices.Count -gt 0) {
        $SummaryLines += "-" * 70
        $SummaryLines += ""
        $SummaryLines += ">>> 需要关注的问题设备 (共 $($ProblemDevices.Count) 个) <<<"
        $SummaryLines += ""

        $Grouped = $ProblemDevices | Group-Object -Property Category
        foreach ($group in $Grouped) {
            $groupLabel = switch ($group.Name) {
                "MISSING"  { "[驱动缺失/异常]" }
                "DISABLED" { "[已禁用]" }
                "PENDING"  { "[等待重启]" }
                "REMOVING" { "[正在移除]" }
                "UNKNOWN"  { "[状态未知]" }
            }
            $SummaryLines += "  $groupLabel ($($group.Count) 个设备)"
            foreach ($dev in $group.Group) {
                $name = $dev.FriendlyName
                if (-not $name) { $name = "(未知设备)" }
                $SummaryLines += "    - $name"
                if ($dev.DriverVersion) {
                    $SummaryLines += "      驱动版本: $($dev.DriverVersion)  ($($dev.DriverDate)) | 供应商: $($dev.DriverProvider)"
                }
                if ($dev.ErrorDesc) {
                    $SummaryLines += "      错误码: $($dev.ErrorCode) | $($dev.ErrorDesc)"
                }
                if ($dev.HardwareID) {
                    $SummaryLines += "      硬件ID: $($dev.HardwareID)"
                }
            }
            $SummaryLines += ""
        }
    }
    else {
        $SummaryLines += ""
        $SummaryLines += "  [OK] 所有设备驱动均已正常安装，未发现问题。"
    }

    $SummaryLines += "=" * 70
    $SummaryLines += "  报告结束 | 驱动检测脚本 v1.0"
    $SummaryLines += "=" * 70

    $SummaryContent = $SummaryLines -join "`r`n"
    Set-Content -Path $SummaryPath -Value $SummaryContent -Encoding UTF8

    Write-Host "摘要报告: $SummaryPath" -ForegroundColor Yellow
}

# ---------- CSV 详细报告 ----------
if ($Format -in @("CSV", "All")) {
    $CsvPath = Join-Path $OutputDir "DriverCheck_${Hostname}_${Timestamp}.csv"

    # 按类别排序：问题设备在前
    $SortOrder = @{ MISSING=0; DISABLED=1; PENDING=2; REMOVING=3; UNKNOWN=4; OK=5 }
    $Sorted = $ResultList | Sort-Object {
        $cat = $_.Category
        if ($SortOrder.ContainsKey($cat)) { $SortOrder[$cat] } else { 99 }
    }, FriendlyName

    $Sorted | Select-Object Category, ErrorCode, ErrorDesc, FriendlyName, PnpClass,
                            Manufacturer, DriverVersion, DriverDate, DriverProvider,
                            HardwareID, Status, InstanceId |
              Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    Write-Host "CSV 报告: $CsvPath" -ForegroundColor Yellow
}

# ============================================================
# 5. 控制台摘要
# ============================================================
Write-Host ""
Write-Host "============ 扫描结果摘要 ============" -ForegroundColor Cyan
Write-Host "  总数: $TotalCount | 正常: $OkCount | 问题: $($ProblemDevices.Count)" -ForegroundColor White
if ($MissingCount -gt 0)  { Write-Host "  [!!] 驱动缺失/异常: $MissingCount 个" -ForegroundColor Red }
if ($DisabledCount -gt 0) { Write-Host "  [--] 设备已禁用:    $DisabledCount 个" -ForegroundColor DarkGray }
if ($PendingCount -gt 0)  { Write-Host "  [..] 等待重启:      $PendingCount 个" -ForegroundColor Yellow }
Write-Host "======================================" -ForegroundColor Cyan

# 如果有缺失驱动，直接列出前 10 个
if ($MissingCount -gt 0) {
    Write-Host ""
    Write-Host "驱动缺失/异常的设备 (前 10 个):" -ForegroundColor Red
    $MissingList = $ResultList | Where-Object { $_.Category -eq "MISSING" } | Select-Object -First 10
    $idx = 0
    foreach ($m in $MissingList) {
        $idx++
        $name = if ($m.FriendlyName) { $m.FriendlyName } else { "(未知设备)" }
        Write-Host "  [$idx] $name" -ForegroundColor White
        Write-Host "      ErrorCode=$($m.ErrorCode) | $($m.ErrorDesc)" -ForegroundColor DarkYellow
        if ($m.HardwareID) {
            Write-Host "      HWID=$($m.HardwareID)" -ForegroundColor Gray
        }
    }
    if ($MissingCount -gt 10) {
        Write-Host "  ... 还有 $($MissingCount - 10) 个，详见报告文件。" -ForegroundColor DarkGray
    }
}

# 退出码：有问题设备时返回非零，方便集成到 PXE 工作流
if ($ProblemDevices.Count -gt 0) {
    exit 1
}
else {
    exit 0
}
