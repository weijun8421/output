#!/usr/bin/env python3
"""
driver_check.py — PXE 部署后显卡驱动检测与静默安装 v6.2

两种使用模式:
  1. 检测模式 — 扫描核显/独显状态，输出报告
  2. PXE 无人值守模式 — 检测 + 静默安装 + 再检测，全程无需人工介入

用法:
  python driver_check.py                    仅检测，控制台输出
  python driver_check.py --save-txt          检测 + 生成 TXT 报告
  python driver_check.py --auto-install      PXE 无人值守安装
  python driver_check.py --auto-install --save-txt --wait   完整参数
"""

import argparse
import json
import os
import subprocess
import sys
import time
import socket
import traceback
from datetime import datetime

VERSION = "v6.2"

# ============================================================
# 驱动包配置
# ============================================================
# NVIDIA 独显按 GPU 型号分两档：
#   1\ — GTX 1050 Ti 及以下（GP107/GP108 + 更老的低端卡）
#   2\ — GTX 1060 及以上
# 通过 HWID 中的 DEV_xxxx 自动匹配。如需调整分档，修改 NVIDIA_LOW_END_DEVS。
# ============================================================
DRIVER_BASE = r"C:\Drives"
# GTX 1050 Ti 及以下的低端/亮机卡 DEV ID 集合（其余默认走 high\）
NVIDIA_LOW_END_DEVS = {
    # ----- Fermi (GF108) -----
    # GT 430 / GT 530 / GT 630
    "0DE1", "0DE2", "0DE5", "0DEA",
    "0F00", "0F01", "0F02",
    # ----- Kepler (GK107 / GK208) -----
    # GT 630 / GT 635 / GT 640 / GT 730 / GT 740 / GTX 650 / GTX 750 / GTX 750 Ti
    "0FC0", "0FC1", "0FC2", "0FC6", "0FC7", "0FC8", "0FC9", "0FCC", "0FCD",
    "1280", "1281", "1282", "1284", "1287", "1288", "1289", "128B",
    # ----- Maxwell (GM107 / GM108) -----
    # GTX 745 / GTX 750 / GTX 750 Ti / GTX 950
    "1340", "1341", "1380", "1381", "1382", "1389",
    # ----- Maxwell v2 (GM206) -----
    # GTX 950 / GTX 960
    "1401", "1402",
    # ----- Pascal (GP107 / GP108) -----
    # GT 1030 / GTX 1050 / GTX 1050 Ti
    "1C81", "1C82", "1C8C", "1C8D", "1C8E", "1C8F",
    "1D01", "1D02",
}

DRIVER_PACKAGES = {
    "IntelGPU": {
        "path":    os.path.join(DRIVER_BASE, "Intel_Graphics_Driver"),
        "pattern": "*.exe",
        "args":    "/S /quiet /norestart",
        "vendor":  "Intel",
    },
    # 独显低端 — 目录 NVIDIA_Graphics_Driver\low\
    "NvidiaGPU_Low": {
        "path":    os.path.join(DRIVER_BASE, "NVIDIA_Graphics_Driver", "low"),
        "pattern": "*.exe",
        "args":    "-s -noreboot",
        "vendor":  "NVIDIA",
    },
    # 独显高端 — 目录 NVIDIA_Graphics_Driver\high\
    "NvidiaGPU_High": {
        "path":    os.path.join(DRIVER_BASE, "NVIDIA_Graphics_Driver", "high"),
        "pattern": "*.exe",
        "args":    "-s -noreboot",
        "vendor":  "NVIDIA",
    },
}

def get_nvidia_pkg_key(hwid):
    """根据 HWID 中的 DEV_xxxx 返回对应的 NVIDIA 驱动包 key"""
    m = __import__('re').search(r'DEV_(\w{4})', hwid)
    if m and m.group(1) in NVIDIA_LOW_END_DEVS:
        return "NvidiaGPU_Low"
    return "NvidiaGPU_High"

ERROR_CODE_MAP = {
    1: "设备配置不正确",  3: "驱动损坏",      10: "无法启动",
    14: "需重启",        18: "需重新安装",    28: "驱动未安装",
    31: "驱动加载失败",  32: "驱动已禁用",    39: "驱动已损坏",
}

SUCCESS_CODES = {0, 2, 1641, 3010}
TIMEOUT_MS = 600000  # 10 分钟

# ============================================================
# ANSI 颜色
# ============================================================
class Color:
    RED    = "\033[91m"
    GREEN  = "\033[92m"
    YELLOW = "\033[93m"
    CYAN   = "\033[96m"
    GRAY   = "\033[90m"
    RESET  = "\033[0m"

def cprint(text, color=None):
    if color:
        print(f"{color}{text}{Color.RESET}")
    else:
        print(text)

# ============================================================
# 工具函数
# ============================================================
def get_error_text(code):
    return ERROR_CODE_MAP.get(code, f"未知错误({code})")

def is_admin():
    try:
        import ctypes
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False

def run_ps_json(script, timeout=90):
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-Command", script],
            capture_output=True, text=True, timeout=timeout
        )
        stdout = result.stdout.strip()
        return json.loads(stdout) if stdout else None
    except (json.JSONDecodeError, subprocess.TimeoutExpired, Exception):
        return None

# ============================================================
# GPU 扫描 (仅 Display 类设备)
# ============================================================
PS_GPU_SCAN = r'''
$ErrorActionPreference = "SilentlyContinue"

$pnp = Get-CimInstance Win32_PnPEntity | ForEach-Object {
    [PSCustomObject]@{
        InstanceId = $_.DeviceID
        Name       = $_.Name
        ErrorCode  = $_.ConfigManagerErrorCode
        HWIDs      = @($_.HardwareID)
    }
}
$pnpIndex = @{}
foreach ($d in $pnp) { if ($d.InstanceId) { $pnpIndex[$d.InstanceId] = $d } }

$signed = Get-CimInstance Win32_PnPSignedDriver | ForEach-Object {
    [PSCustomObject]@{
        InstanceId = $_.DeviceID
        Version    = $_.DriverVersion
        Date       = $_.DriverDate
        Provider   = $_.DriverProviderName
    }
}
$drvIndex = @{}
foreach ($sd in $signed) {
    if ($sd.InstanceId -and $sd.Version) {
        $drvIndex[$sd.InstanceId] = @{Ver=$sd.Version; Date=$sd.Date; Prov=$sd.Provider}
    }
}

# 仅 Display 类设备
$allDev = Get-PnpDevice -Class Display -PresentOnly | ForEach-Object {
    $dev = $_
    $wmi = $pnpIndex[$dev.InstanceId]
    $drv = $drvIndex[$dev.InstanceId]

    $hid = ""
    if ($wmi -and $wmi.HWIDs) {
        foreach ($h in $wmi.HWIDs) {
            if ($h -match 'VEN_(\w+)&DEV_(\w+)') {
                $hid = "VEN_$($Matches[1])&DEV_$($Matches[2])"; break
            }
        }
    }

    $dateStr = ""
    if ($drv -and $drv.Date) {
        try { $dateStr = [DateTime]::Parse($drv.Date).ToString("yyyy-MM-dd") } catch {}
    }

    [PSCustomObject]@{
        InstanceId = $dev.InstanceId
        Name       = if ($dev.FriendlyName) { $dev.FriendlyName } else { "(未知设备)" }
        ErrorCode  = if ($wmi) { [int]$wmi.ConfigManagerErrorCode } else { -1 }
        Version    = if ($drv) { $drv.Ver } else { "" }
        DriverDate = $dateStr
        Provider   = if ($drv) { $drv.Prov } else { "" }
        HWID       = $hid
    }
}

$videoControllers = Get-CimInstance Win32_VideoController | ForEach-Object {
    [PSCustomObject]@{ PNPDeviceID = $_.PNPDeviceID }
}

@{
    Devices          = @($allDev)
    VideoControllers = @($videoControllers)
} | ConvertTo-Json -Depth 4 -Compress
'''

def invoke_gpu_scan():
    """扫描所有 Display 类设备"""
    raw = run_ps_json(PS_GPU_SCAN, timeout=120)
    if not raw:
        cprint("错误: 无法获取 GPU 信息。请以管理员身份运行。", Color.RED)
        sys.exit(3)

    video_controllers = [vc["PNPDeviceID"] for vc in raw.get("VideoControllers", [])]
    result_list = []
    ok_count = 0
    problem_count = 0

    for dev in raw.get("Devices", []):
        name = dev.get("Name", "")
        err_code = dev.get("ErrorCode", -1)
        is_ok = (err_code == 0)

        # Microsoft Basic Display Adapter → 实际缺驱动
        if is_ok and ("Microsoft Basic Display" in name or "Microsoft 基本显示适配器" in name):
            is_ok = False
            err_code = 28

        hid = dev.get("HWID", "")

        # 判断 GPU 类型
        if "VEN_8086" in hid or any(k in name for k in ("Intel", "HD Graphics", "UHD Graphics", "Iris")):
            gpu_type = "核显"
        elif "VEN_10DE" in hid or any(k in name for k in ("NVIDIA", "GeForce", "RTX", "GTX", "Quadro")):
            gpu_type = "独显"
        else:
            gpu_type = "未知"

        result_list.append({
            "Name":       name,
            "Type":       gpu_type,
            "Status":     "OK" if is_ok else "ERR",
            "ErrCode":    err_code,
            "ErrText":    get_error_text(err_code) if not is_ok else "",
            "Version":    dev.get("Version", ""),
            "Date":       dev.get("DriverDate", ""),
            "Provider":   dev.get("Provider", ""),
            "HWID":       hid,
            "InstanceId": dev.get("InstanceId", ""),
        })

        if is_ok:
            ok_count += 1
        else:
            problem_count += 1

    return {
        "ResultList":   result_list,
        "OkCount":      ok_count,
        "ProblemCount": problem_count,
        "Total":        ok_count + problem_count,
        "VideoControllers": video_controllers,
    }

# ============================================================
# 控制台输出
# ============================================================
def write_result(scan_result):
    result_list = scan_result["ResultList"]
    ok_count = scan_result["OkCount"]
    problem_count = scan_result["ProblemCount"]
    total = scan_result["Total"]

    print()
    cprint(f"  显卡检测  {VERSION}", Color.CYAN)
    cprint(f"  主机: {socket.gethostname()}    检测 {total} 项    正常 {ok_count}    异常 {problem_count}")
    print()

    sorted_list = sorted(result_list, key=lambda r: (0 if r["Status"] == "ERR" else 1, r["Name"]))
    for r in sorted_list:
        color = Color.RED if r["Status"] == "ERR" else None
        line = f"    [{r['Status']}]  {r['Type']:<4}  {r['Name']:<42}  {r['Version']:<16}  {r['Date']:<10}  {r['Provider']:<16}"
        cprint(line, color)

    print()
    if problem_count == 0:
        cprint("  结果: 全部通过。显卡驱动均已正确安装。", Color.GREEN)
    else:
        cprint(f"  结果: 发现 {problem_count} 个问题设备，详情见上。", Color.RED)
    print()

# ============================================================
# TXT 报告
# ============================================================
def save_txt_report(scan_result, prefix, install_log=None, output_dir=None):
    if output_dir is None:
        return

    os.makedirs(output_dir, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    hostname = socket.gethostname()
    txt_path = os.path.join(output_dir, f"DriverCheck_{prefix}_{hostname}_{ts}.txt")

    result_list = scan_result["ResultList"]
    ok_count = scan_result["OkCount"]
    problem_count = scan_result["ProblemCount"]
    total = scan_result["Total"]

    lines = []
    lines.append(f"显卡检测 {VERSION}")
    lines.append("=" * 60)
    lines.append(f"主机: {hostname}    检测 {total} 项    正常 {ok_count}    异常 {problem_count}")
    lines.append("")
    lines.append(f"{'状态':<6} {'类型':<6} {'设备名称':<42} {'驱动版本':<18} {'驱动日期':<12} {'供应商':<18}")
    lines.append("-" * 106)

    sorted_list = sorted(result_list, key=lambda r: (0 if r["Status"] == "ERR" else 1, r["Name"]))
    for r in sorted_list:
        name_trunc = r["Name"][:42]
        lines.append(f"{r['Status']:<6} {r['Type']:<6} {name_trunc:<42} {r['Version']:<18} {r['Date']:<12} {r['Provider']:<18}")

    lines.append("")
    if problem_count == 0:
        lines.append("结果: 全部通过。")
    else:
        lines.append(f"结果: 发现 {problem_count} 个问题设备。")

    if install_log:
        lines.append("")
        lines.append("--- 驱动安装日志 ---")
        for log in install_log:
            lines.append(f"  {log}")

    with open(txt_path, "w", encoding="utf-8-sig") as f:
        f.write("\r\n".join(lines))

    cprint(f"  TXT 报告: {txt_path}", Color.GRAY)

# ============================================================
# 驱动包检查与安装
# ============================================================
def test_driver_package(pkg):
    p = pkg["path"]
    if not os.path.isdir(p):
        cprint(f"  驱动包目录不存在: {p}", Color.YELLOW)
        return False
    exes = [f for f in os.listdir(p)
            if f.lower().endswith(".exe") and os.path.isfile(os.path.join(p, f))]
    if not exes:
        cprint(f"  驱动包目录为空: {p}", Color.YELLOW)
        return False
    return True

def install_driver_package(pkg, device_name):
    vendor = pkg["vendor"]
    cprint(f"  正在安装 {vendor} 驱动: {device_name}", Color.CYAN)

    p = pkg["path"]
    exes = sorted(
        [f for f in os.listdir(p) if f.lower().endswith(".exe") and os.path.isfile(os.path.join(p, f))],
        key=lambda f: os.path.getmtime(os.path.join(p, f)),
        reverse=True
    )
    if not exes:
        cprint("  未找到可执行文件", Color.RED)
        return False

    driver_exe = os.path.join(p, exes[0])
    cprint(f"    执行: {driver_exe}", Color.GRAY)
    cprint(f"    参数: {pkg['args']}", Color.GRAY)

    try:
        proc = subprocess.Popen(
            [driver_exe] + pkg["args"].split(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

        try:
            exit_code = proc.wait(timeout=TIMEOUT_MS / 1000)
        except subprocess.TimeoutExpired:
            cprint(f"    安装超时（超过 {TIMEOUT_MS // 60000} 分钟），正在强制终止...", Color.RED)
            try:
                proc.kill()
            except Exception:
                pass
            time.sleep(2)
            if proc.poll() is None:
                try:
                    subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                                   capture_output=True, timeout=10)
                except Exception:
                    pass
            cprint("    安装已被终止", Color.YELLOW)
            return False

        if exit_code in SUCCESS_CODES:
            cprint(f"    安装程序返回: {exit_code}（成功）", Color.GREEN)
            cprint("    等待驱动安装完成...", Color.GRAY)
            for _ in range(12):
                time.sleep(5)
                try:
                    subprocess.run(["pnputil", "/scan-devices"], capture_output=True, timeout=15)
                except Exception:
                    pass

            cprint("    验证设备状态...", Color.GRAY)
            try:
                result = subprocess.run(
                    ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                     r"$d = Get-PnpDevice -Class Display -PresentOnly | "
                     r"Where-Object { (Get-CimInstance Win32_PnPEntity -Filter \"DeviceID='$($_.InstanceId -replace \"'\", \"''\")'\" -ErrorAction SilentlyContinue).ConfigManagerErrorCode -eq 0 } | "
                     r"Where-Object { $_.FriendlyName -notmatch 'Microsoft.*Basic Display' } | "
                     r"Select-Object -First 1; if ($d) { $d.FriendlyName } else { '' }"],
                    capture_output=True, text=True, timeout=30
                )
                verified_name = result.stdout.strip()
                if verified_name and "Microsoft" not in verified_name:
                    cprint(f"    设备状态: OK — {verified_name}", Color.GREEN)
                    return True
            except Exception:
                pass

            cprint("    驱动安装程序已成功完成，但设备状态尚未更新（可能需要重启）", Color.YELLOW)
            return True
        else:
            cprint(f"    安装失败，退出码: {exit_code}", Color.RED)
            return False

    except Exception as e:
        cprint(f"    执行异常: {e}", Color.RED)
        return False

# ============================================================
# 自动安装
# ============================================================
def invoke_auto_install(err_devices, video_controllers=None):
    print()
    cprint("  " + "═" * 46, Color.YELLOW)
    cprint("    AutoInstall：静默安装显卡驱动", Color.YELLOW)
    cprint("  " + "═" * 46, Color.YELLOW)
    print()

    if video_controllers is None:
        video_controllers = []

    need_intel = False
    need_nvidia = False
    for gpu in err_devices:
        gpu_type = gpu.get("Type", "")
        if gpu_type == "核显":
            need_intel = True
        elif gpu_type == "独显":
            need_nvidia = True

    # 备用检测
    if not need_intel and not need_nvidia:
        for vc_id in video_controllers:
            if "VEN_8086" in vc_id:
                need_intel = True
            if "VEN_10DE" in vc_id:
                need_nvidia = True

    install_log = []
    any_success = False
    needed_pkgs = []

    if need_intel:
        if test_driver_package(DRIVER_PACKAGES["IntelGPU"]):
            needed_pkgs.append("IntelGPU")
        else:
            cprint("  警告: Intel 核显驱动包不可用，跳过", Color.YELLOW)
            install_log.append("核显: Intel 驱动包不可用")

    if need_nvidia:
        # 根据 DEV ID 确定需要哪些 NVIDIA 驱动包
        nvidia_pkg_keys = set()
        for gpu in err_devices:
            if gpu.get("Type") == "独显":
                nvidia_pkg_keys.add(get_nvidia_pkg_key(gpu.get("HWID", "")))
        for nk in nvidia_pkg_keys:
            if test_driver_package(DRIVER_PACKAGES[nk]):
                needed_pkgs.append(nk)
            else:
                cprint(f"  警告: NVIDIA 独显驱动包不可用 ({nk})，跳过", Color.YELLOW)
                install_log.append(f"独显: NVIDIA 驱动包不可用 ({nk})")

    if not needed_pkgs:
        cprint("  所有需要的驱动包均不可用，无法执行安装。", Color.RED)
        cprint("  请检查 C:\\Drives 目录结构。", Color.RED)
        return {"success": False, "log": install_log}

    print()

    for gpu in err_devices:
        gpu_type = gpu.get("Type", "")
        name = gpu["Name"]
        hwid = gpu.get("HWID", "")
        cprint(f"    - {name} ({gpu['ErrText']})  [{hwid}]", Color.YELLOW)

        if gpu_type == "核显" and "IntelGPU" in needed_pkgs:
            if install_driver_package(DRIVER_PACKAGES["IntelGPU"], name):
                install_log.append(f"核显({name}): Intel 驱动安装成功")
                any_success = True
            else:
                install_log.append(f"核显({name}): Intel 驱动安装失败")
        elif gpu_type == "独显":
            nk = get_nvidia_pkg_key(hwid)
            if nk in needed_pkgs:
                tier = "Low(≤1050Ti)" if nk == "NvidiaGPU_Low" else "High(>1050Ti)"
                if install_driver_package(DRIVER_PACKAGES[nk], name):
                    install_log.append(f"独显({name}): NVIDIA-{tier} 驱动安装成功")
                    any_success = True
                else:
                    install_log.append(f"独显({name}): NVIDIA-{tier} 驱动安装失败")
            else:
                install_log.append(f"独显({name}): 驱动包不可用，跳过")
        else:
            install_log.append(f"显卡({name}): 无可用的驱动包，跳过")

    print()

    if install_log:
        cprint("  安装日志:", Color.CYAN)
        for log in install_log:
            cprint(f"    - {log}", Color.GRAY)
        print()

    return {"success": any_success, "log": install_log}

# ============================================================
# 主流程
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description=f"driver_check.py {VERSION} — PXE 部署后显卡驱动检测与安装",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  driver_check.exe                          仅检测
  driver_check.exe --save-txt               检测 + TXT 报告
  driver_check.exe --auto-install           PXE 无人值守安装
  driver_check.exe --auto-install --save-txt --wait   完整参数
        """
    )
    parser.add_argument("--output-dir", default=None, help="TXT 报告输出目录")
    parser.add_argument("--save-txt", action="store_true", help="生成 TXT 报告")
    parser.add_argument("--wait", action="store_true", help="执行完毕暂停")
    parser.add_argument("--auto-install", action="store_true", help="PXE 无人值守模式")

    args = parser.parse_args()

    if args.auto_install and not is_admin():
        cprint("  AutoInstall 需要管理员权限，请右键以管理员身份运行。", Color.RED)
        if args.wait:
            input("按 Enter 键退出")
        sys.exit(2)

    output_dir = args.output_dir
    if args.save_txt and not output_dir:
        if getattr(sys, 'frozen', False):
            output_dir = os.path.dirname(os.path.abspath(sys.executable))
        else:
            output_dir = os.path.dirname(os.path.abspath(__file__))

    # ============================================================
    # 第一次扫描
    # ============================================================
    scan1 = invoke_gpu_scan()
    write_result(scan1)

    if scan1["ProblemCount"] == 0:
        if args.save_txt:
            save_txt_report(scan1, "v6", output_dir=output_dir)
        if args.wait:
            input("按 Enter 键退出")
        sys.exit(0)

    if not args.auto_install:
        if args.save_txt:
            save_txt_report(scan1, "v6", output_dir=output_dir)
        if args.wait:
            input("按 Enter 键退出")
        sys.exit(min(scan1["ProblemCount"], 1))

    # ============================================================
    # AutoInstall
    # ============================================================
    err_devices = [d for d in scan1["ResultList"] if d["Status"] == "ERR"]
    cprint(f"  异常设备: {len(err_devices)} 个", Color.YELLOW)
    for d in err_devices:
        hwid_info = f"  [{d['HWID']}]" if d.get("HWID") else ""
        cprint(f"    - [{d['Type']}] {d['Name']}  ({d['ErrText']}){hwid_info}", Color.YELLOW)
    print()

    if args.save_txt:
        save_txt_report(scan1, "v6", output_dir=output_dir)

    install_result = invoke_auto_install(err_devices, scan1.get("VideoControllers", []))
    install_log = install_result["log"]

    # ============================================================
    # 重新扫描并对比
    # ============================================================
    cprint("  正在重新检测驱动状态...", Color.CYAN)
    scan2 = invoke_gpu_scan()

    before_err_ids = {d["InstanceId"] for d in scan1["ResultList"] if d["Status"] == "ERR"}
    after_err_ids = {d["InstanceId"] for d in scan2["ResultList"] if d["Status"] == "ERR"}

    still_err = len(before_err_ids & after_err_ids)
    fixed_count = len(before_err_ids - after_err_ids)
    new_err = len(after_err_ids - before_err_ids)

    if fixed_count > 0 and still_err == 0 and new_err == 0:
        cprint("  全部异常已修复！", Color.GREEN)
    elif fixed_count > 0:
        msg = f"  已修复: {fixed_count} 个。仍异常: {still_err} 个"
        if new_err > 0:
            msg += f"，新增异常: {new_err} 个"
        cprint(msg, Color.GREEN)
    elif new_err > 0:
        cprint(f"  未能修复原有异常，且新增 {new_err} 个异常设备", Color.YELLOW)
    else:
        cprint(f"  未能修复。异常数仍为 {scan2['ProblemCount']} 个。", Color.YELLOW)
    print()

    remaining_err = [d for d in scan2["ResultList"] if d["Status"] == "ERR"]
    if remaining_err:
        cprint("  --- 修复后仍有异常的设备 ---", Color.YELLOW)
        for d in remaining_err:
            hwid_info = f"  [{d['HWID']}]" if d.get("HWID") else ""
            new_tag = " [新增]" if (d["InstanceId"] in after_err_ids and
                                     d["InstanceId"] not in before_err_ids) else ""
            cprint(f"    - [{d['Type']}] {d['Name']}  ({d['ErrText']}){hwid_info}{new_tag}", Color.YELLOW)
        print()

    if args.save_txt:
        save_txt_report(scan2, "v6_fixed", install_log, output_dir=output_dir)
    write_result(scan2)

    if args.wait:
        print()
        input("按 Enter 键退出")

    sys.exit(min(scan2["ProblemCount"], 1) if scan2["ProblemCount"] > 0 else 0)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n  用户中断。")
        sys.exit(130)
    except Exception as e:
        cprint(f"\n  未预期的错误: {e}", Color.RED)
        traceback.print_exc()
        if "--wait" in sys.argv:
            input("按 Enter 键退出")
        sys.exit(99)
