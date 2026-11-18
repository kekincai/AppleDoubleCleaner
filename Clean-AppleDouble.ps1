<#
.SYNOPSIS
  安全清理 Mac 在 exFAT / FAT 盘上留下的 AppleDouble "._" 文件。

.DESCRIPTION
  安全措施：
    1. 默认只预演，不改动任何文件。必须加 -Execute 才会动手，而且动手前要手动输入 YES。
    2. 只处理文件名以 "._" 开头的文件，不处理文件夹。
    3. 逐个读取文件头，只有确认是 AppleDouble 格式（魔数 00 05 16 07）才处理。
       名字碰巧以 ._ 开头的普通照片/视频，文件头对不上，一律跳过。
    4. 默认只允许 exFAT / FAT32 / FAT 盘，NTFS 盘（比如 C:）直接拒绝。
    5. 可选 -Quarantine：不删除，而是移到同盘根目录的隔离文件夹，确认没问题后再自己删。
    6. 每个文件的处理结果都写入 CSV 日志（默认在桌面的 "AppleDouble清理日志" 文件夹）。

.PARAMETER ListFile
  Everything 导出的清单（.txt 每行一个完整路径；也兼容 .efu / .csv，取第一列）。

.PARAMETER ScanDrives
  不用 Everything，直接扫描这些盘，例如 -ScanDrives D,E,F,G。机械硬盘上会比较慢。

.PARAMETER Execute
  真正执行。不加这个参数就只是预演。

.PARAMETER Quarantine
  与 -Execute 一起用：把文件移到 "X:\_AppleDouble隔离_时间\" 下（保留原目录结构），而不是删除。

.PARAMETER KeepOrphans
  跳过"孤儿"._ 文件（旁边没有对应原文件的）。默认会一起清理，因为文件头已确认是 Mac 元数据。

.EXAMPLE
  .\Clean-AppleDouble.ps1 -ListFile "$env:USERPROFILE\Desktop\dotunderscore.txt"
  预演：只统计、写日志，不动文件。

.EXAMPLE
  .\Clean-AppleDouble.ps1 -ListFile "$env:USERPROFILE\Desktop\dotunderscore.txt" -Execute
  真正删除（会先要求输入 YES）。
#>
[CmdletBinding()]
param(
    [string]$ListFile,
    [string[]]$ScanDrives,
    [switch]$Execute,
    [switch]$Quarantine,
    [switch]$KeepOrphans,
    [switch]$AllowNtfs,
    [switch]$AllExFat,   # 自动扫描所有已连接的 exFAT / FAT 盘
    [switch]$Yes,        # 与 -Execute 一起用：跳过输入 YES 的确认
    [switch]$Sequential, # 多块盘时一块一块处理（默认每块盘开一个窗口同时处理）
    [string]$LogDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AppleDouble清理日志')
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($AllExFat) {
    if ($ScanDrives) { throw '-AllExFat 和 -ScanDrives 不能同时使用。' }
    $ScanDrives = @([IO.DriveInfo]::GetDrives() |
        Where-Object { $_.IsReady -and @('exFAT', 'FAT32', 'FAT') -contains $_.DriveFormat } |
        ForEach-Object { $_.Name.Substring(0, 1) })
    if ($ScanDrives.Count -eq 0) { Write-Host '没有找到 exFAT / FAT 格式的盘，不需要清理。'; return }
    Write-Host ("找到 exFAT/FAT 盘：{0}" -f (($ScanDrives | ForEach-Object { "$($_):" }) -join ' '))
}

$hasList = -not [string]::IsNullOrWhiteSpace($ListFile)
$hasScan = [bool]$ScanDrives
if ($hasList -eq $hasScan) { throw '请指定 -ListFile 或 -ScanDrives 其中之一（只能选一个）。' }
if ($hasList -and -not (Test-Path -LiteralPath $ListFile -PathType Leaf)) { throw "找不到清单文件：$ListFile" }

$ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
$qPrefix    = '_AppleDouble隔离_'
$qName      = "$qPrefix$ts"
$okFs       = @('exFAT', 'FAT32', 'FAT')
if ($AllowNtfs) { $okFs += 'NTFS' }

# ---------- 工具函数 ----------

# 长路径：如果当前 PowerShell 支持 \\?\ 前缀就用（PowerShell 7 支持），
# Windows PowerShell 5.1 不支持，此时超过 260 字符的路径会被跳过并记入日志。
$script:LongOk = $true
try {
    $probe = New-Object IO.FileInfo ('\\?\' + [Environment]::GetFolderPath('Windows') + '\win.ini')
    if (-not $probe.Exists) { $script:LongOk = $false }
} catch { $script:LongOk = $false }
function ConvertTo-IoPath([string]$p) {
    if (-not $script:LongOk -or $p.StartsWith('\\?\')) { $p } else { '\\?\' + $p }
}
function ConvertFrom-IoPath([string]$p) { if ($p.StartsWith('\\?\')) { $p.Substring(4) } else { $p } }
function Test-TooLong([string]$p) { (-not $script:LongOk) -and $p.Length -ge 248 }

$fsCache = @{}
function Get-FsType([string]$letter) {
    $letter = $letter.ToUpper()
    if (-not $fsCache.ContainsKey($letter)) {
        try { $fsCache[$letter] = ([IO.DriveInfo]::new("$($letter):\")).DriveFormat } catch { $fsCache[$letter] = '未知' }
    }
    $fsCache[$letter]
}

# 读文件头 8 字节：AppleDouble = 00 05 16 07 + 版本 00 01/02 00 00
# 返回 $true / $false；读不了返回 $null
function Test-AppleDouble([string]$longPath) {
    try {
        $fs = [IO.File]::Open($longPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $b = New-Object byte[] 8
            $n = $fs.Read($b, 0, 8)
        } finally { $fs.Dispose() }
        return ($n -eq 8 -and $b[0] -eq 0x00 -and $b[1] -eq 0x05 -and $b[2] -eq 0x16 -and $b[3] -eq 0x07 -and
                $b[4] -eq 0x00 -and ($b[5] -eq 0x01 -or $b[5] -eq 0x02) -and $b[6] -eq 0x00 -and $b[7] -eq 0x00)
    } catch { return $null }
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { '{0:N2} MB' -f ($bytes / 1MB) }
    else { '{0:N0} KB' -f ($bytes / 1KB) }
}

# ---------- 取得路径 ----------

function Get-ListPaths {
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $ListFile).ProviderPath)) {
        $s = $line.Trim()
        if ($s.StartsWith('"')) {
            $end = $s.IndexOf('"', 1)
            if ($end -le 1) { continue }
            $s = $s.Substring(1, $end - 1)
        }
        if ($s -match '^[A-Za-z]:\\') { $s }
    }
}

function Get-ScanPaths([string[]]$letters) {
    foreach ($letter in $letters) {
        Write-Host "正在扫描 $($letter):\ ..."
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push("$($letter):\")
        $dirs = 0
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            $dirs++
            if ($dirs % 500 -eq 0) { Write-Progress -Activity "扫描 $($letter):\" -Status "已扫描 $dirs 个文件夹" }
            if (Test-TooLong $dir) { Write-Warning "路径过长，跳过文件夹：$dir"; continue }
            try {
                foreach ($f in [IO.Directory]::EnumerateFiles((ConvertTo-IoPath $dir), '._*')) { ConvertFrom-IoPath $f }
            } catch { Write-Warning "无法读取文件夹：$dir" }
            try {
                foreach ($sub in [IO.Directory]::EnumerateDirectories((ConvertTo-IoPath $dir))) {
                    $name = [IO.Path]::GetFileName($sub)
                    if ($name -eq 'System Volume Information' -or $name -eq '$RECYCLE.BIN' -or $name.StartsWith($qPrefix)) { continue }
                    $stack.Push((ConvertFrom-IoPath $sub))
                }
            } catch { Write-Warning "无法读取子文件夹：$dir" }
        }
        Write-Progress -Activity "扫描 $($letter):\" -Completed
    }
}

# ---------- 准备 ----------

if ($hasScan) {
    $letters = @()
    foreach ($d in ($ScanDrives -split '[,; ]+' | Where-Object { $_ })) {
        $l = $d.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
        if ($l -notmatch '^[A-Z]$') { throw "盘符格式不对：$d（应写成 D 或 D:）" }
        $fsType = Get-FsType $l
        if ($okFs -notcontains $fsType) { throw "$($l): 盘是 $fsType 格式，为安全起见拒绝处理（只允许 $($okFs -join '/')）。" }
        $letters += $l
    }

    # ----- 多块盘：每块盘开一个独立窗口同时处理，本窗口等待并汇总 -----
    if ($letters.Count -gt 1 -and -not $Sequential) {
        $driveText = ($letters | ForEach-Object { "$($_):" }) -join ' '
        if ($Execute -and -not $Yes) {
            $act = if ($Quarantine) { '移到隔离文件夹' } else { '永久删除' }
            Write-Host "即将同时清理 $driveText，确认是 AppleDouble 的 ._ 文件会被$act。" -ForegroundColor Red
            $answer = Read-Host '确认请输入大写 YES，输入其他内容取消'
            if ($answer -cne 'YES') { Write-Host '已取消，没有改动任何文件。'; return }
        }
        $runDir = Join-Path $LogDir "批次_$ts"
        [void][IO.Directory]::CreateDirectory($runDir)
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-LogDir', "`"$runDir`"")
        if ($Execute)     { $common += '-Execute', '-Yes' }
        if ($Quarantine)  { $common += '-Quarantine' }
        if ($KeepOrphans) { $common += '-KeepOrphans' }
        if ($AllowNtfs)   { $common += '-AllowNtfs' }

        Write-Host "同时处理 $driveText：每块盘会单独打开一个窗口显示进度，处理完自动关闭。"
        Write-Host '请不要关闭那些窗口，等全部完成后这里会显示汇总。'
        $start = Get-Date
        $jobs = foreach ($l in $letters) {
            $proc = Start-Process powershell.exe -ArgumentList (($common + @('-ScanDrives', $l)) -join ' ') -PassThru
            $null = $proc.Handle   # 保留句柄，才能拿到退出码
            [pscustomobject]@{ Letter = $l; Proc = $proc }
        }
        foreach ($j in $jobs) {
            $j.Proc.WaitForExit()
            Write-Host ("  {0}: 完成（{1:hh\:mm\:ss}）" -f $j.Letter, ((Get-Date) - $start))
        }

        Write-Host ''
        Write-Host '========== 汇总 ==========' -ForegroundColor Cyan
        $doneStatus = if (-not $Execute) { '待处理' } elseif ($Quarantine) { '已移到隔离' } else { '已删除' }
        $doneLabel  = if (-not $Execute) { '可清理' } elseif ($Quarantine) { '已隔离' } else { '已删除' }
        $sumDone = 0; $sumFail = 0
        foreach ($j in $jobs) {
            $csv = Get-ChildItem -LiteralPath $runDir -Filter "AppleDouble_*_$($j.Letter)_*.csv" | Select-Object -First 1
            if ($j.Proc.ExitCode -ne 0 -or -not $csv) {
                Write-Host ("{0}: 出错（退出码 {1}）。可以单独运行：CleanAppleDouble.bat -ScanDrives {0} 查看原因。" -f $j.Letter, $j.Proc.ExitCode) -ForegroundColor Red
                $sumFail++
                continue
            }
            $rows  = @(Import-Csv -LiteralPath $csv.FullName -Encoding UTF8)
            $nDone = @($rows | Where-Object { $_.'状态' -eq $doneStatus }).Count
            $nSkip = @($rows | Where-Object { $_.'状态' -eq '跳过' }).Count
            $nFail = @($rows | Where-Object { $_.'状态' -eq '失败' }).Count
            $sumDone += $nDone; $sumFail += $nFail
            $color = if ($nFail -gt 0) { 'Yellow' } else { 'Green' }
            Write-Host ("{0}:  {1} {2} 个，跳过 {3} 个，失败 {4} 个" -f $j.Letter, $doneLabel, $nDone, $nSkip, $nFail) -ForegroundColor $color
        }
        Write-Host ("合计{0} {1} 个，总耗时 {2:hh\:mm\:ss}" -f $doneLabel, $sumDone, ((Get-Date) - $start))
        if ($sumFail -gt 0) { Write-Host '有失败项，详情见日志中状态为"失败"的行。' -ForegroundColor Yellow }
        Write-Host "日志文件夹：$runDir"
        return
    }

    if ($letters.Count -eq 1) { try { $Host.UI.RawUI.WindowTitle = "清理 $($letters[0]):  ._ 文件" } catch { } }
    $paths = @(Get-ScanPaths $letters)
} else {
    Write-Host "读取清单：$ListFile"
    $paths = @(Get-ListPaths)
}
Write-Host "清单中共 $($paths.Count) 条路径，开始逐个检查..."

[void][IO.Directory]::CreateDirectory($LogDir)
$mode    = if (-not $Execute) { '预演' } elseif ($Quarantine) { '隔离' } else { '删除' }
$tag     = if ($hasScan) { ($letters -join '') + '_' } else { '' }
$logPath = Join-Path $LogDir "AppleDouble_${ts}_$tag$mode.csv"
$sw = New-Object IO.StreamWriter($logPath, $false, (New-Object Text.UTF8Encoding($true)))
$sw.AutoFlush = $true
$sw.WriteLine('状态,原因,大小(字节),有原文件,路径')
function Write-Log($status, $reason, $size, $hasOrig, [string]$path) {
    $sw.WriteLine(('"{0}","{1}",{2},{3},"{4}"' -f $status, $reason, $size, $hasOrig, $path.Replace('"', '""')))
}

try {
    # ---------- 第一遍：检查，只读 ----------
    $seen       = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $targets    = New-Object 'System.Collections.Generic.List[object]'
    $skipCounts = @{}
    $totalSize  = 0L
    $orphans    = 0
    $i = 0

    foreach ($p in $paths) {
        $i++
        if ($i % 1000 -eq 0) {
            Write-Progress -Activity '检查文件' -Status "$i / $($paths.Count)" -PercentComplete ([int](100 * $i / $paths.Count))
        }
        if (-not $seen.Add($p)) { continue }

        $reason = $null
        $size   = ''
        $name   = [IO.Path]::GetFileName($p)
        $fsType = Get-FsType $p.Substring(0, 1)

        if ($name.Length -le 2 -or -not $name.StartsWith('._')) {
            $reason = '文件名不是 ._ 开头'
        } elseif ($p -like "*\$qPrefix*") {
            $reason = '位于隔离文件夹内'
        } elseif ($okFs -notcontains $fsType) {
            $reason = "磁盘格式是 $fsType，不允许"
        } elseif (Test-TooLong $p) {
            $reason = '路径超过 260 字符，当前 PowerShell 无法安全处理'
        } else {
            $lp = ConvertTo-IoPath $p
            $fi = $null
            try { $fi = New-Object IO.FileInfo $lp } catch { $reason = '路径无法解析' }
            if ($reason) {
                # 已记录原因
            } elseif (-not $fi.Exists) {
                $reason = '文件不存在（可能已删除，或是文件夹）'
            } elseif ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $reason = '是链接/重解析点'
            } else {
                $size  = $fi.Length
                $magic = Test-AppleDouble $lp
                if ($null -eq $magic) {
                    $reason = '无法读取文件'
                } elseif (-not $magic) {
                    $reason = '文件头不是 AppleDouble，可能是正常文件'
                } else {
                    $twin    = [IO.Path]::Combine([IO.Path]::GetDirectoryName($p), $name.Substring(2))
                    $hasOrig = [IO.File]::Exists((ConvertTo-IoPath $twin)) -or [IO.Directory]::Exists((ConvertTo-IoPath $twin))
                    if (-not $hasOrig -and $KeepOrphans) {
                        $reason = '没有对应原文件（-KeepOrphans）'
                    } else {
                        $targets.Add([pscustomobject]@{ Path = $p; Size = $fi.Length; HasOrig = $hasOrig })
                        $totalSize += $fi.Length
                        if (-not $hasOrig) { $orphans++ }
                        Write-Log '待处理' '' $fi.Length $hasOrig $p
                    }
                }
            }
        }
        if ($reason) {
            if ($skipCounts.ContainsKey($reason)) { $skipCounts[$reason]++ } else { $skipCounts[$reason] = 1 }
            Write-Log '跳过' $reason $size '' $p
        }
    }
    Write-Progress -Activity '检查文件' -Completed

    # ---------- 汇总 ----------
    Write-Host ''
    Write-Host '========== 检查结果 ==========' -ForegroundColor Cyan
    Write-Host ("确认是 AppleDouble、可以清理：{0} 个，共 {1}" -f $targets.Count, (Format-Size $totalSize)) -ForegroundColor Green
    Write-Host ("  其中有对应原文件：{0} 个；孤儿（原文件已不在）：{1} 个" -f ($targets.Count - $orphans), $orphans)
    $skipTotal = 0; foreach ($v in $skipCounts.Values) { $skipTotal += $v }
    Write-Host ("跳过：{0} 个" -f $skipTotal) -ForegroundColor Yellow
    foreach ($k in $skipCounts.Keys) { Write-Host ("  {0}：{1}" -f $k, $skipCounts[$k]) }
    Write-Host "详细日志：$logPath"
    Write-Host ''

    if (-not $Execute) {
        Write-Host '这是预演，没有改动任何文件。' -ForegroundColor Cyan
        Write-Host '看过日志确认没问题后，加上 -Execute 再运行一次（想更保险就再加 -Quarantine）。'
        return
    }
    if ($targets.Count -eq 0) { Write-Host '没有需要处理的文件。'; return }

    # ---------- 第二遍：执行 ----------
    $action = if ($Quarantine) { "移到各盘根目录的 $qName 文件夹" } else { '永久删除（不进回收站，无法恢复）' }
    Write-Host "即将把 $($targets.Count) 个 ._ 文件$action。" -ForegroundColor Red
    if (-not $Yes) {
        $answer = Read-Host '确认请输入大写 YES，输入其他内容取消'
        if ($answer -cne 'YES') { Write-Host '已取消，没有改动任何文件。'; return }
    }

    $done = 0; $failed = 0; $j = 0
    foreach ($t in $targets) {
        $j++
        if ($j % 500 -eq 0) {
            Write-Progress -Activity '处理中' -Status "$j / $($targets.Count)" -PercentComplete ([int](100 * $j / $targets.Count))
        }
        $lp = ConvertTo-IoPath $t.Path
        try {
            if ($Quarantine) {
                $dest = $t.Path.Substring(0, 3) + $qName + '\' + $t.Path.Substring(3)
                [void][IO.Directory]::CreateDirectory((ConvertTo-IoPath ([IO.Path]::GetDirectoryName($dest))))
                [IO.File]::Move($lp, (ConvertTo-IoPath $dest))
                Write-Log '已移到隔离' '' $t.Size $t.HasOrig $t.Path
            } else {
                $attr = [IO.File]::GetAttributes($lp)
                if ($attr -band [IO.FileAttributes]::ReadOnly) {
                    [IO.File]::SetAttributes($lp, $attr -band (-bnot [IO.FileAttributes]::ReadOnly))
                }
                [IO.File]::Delete($lp)
                Write-Log '已删除' '' $t.Size $t.HasOrig $t.Path
            }
            $done++
        } catch {
            $failed++
            Write-Log '失败' $_.Exception.Message $t.Size $t.HasOrig $t.Path
        }
    }
    Write-Progress -Activity '处理中' -Completed

    Write-Host ''
    Write-Host ("完成：成功 {0} 个，失败 {1} 个。" -f $done, $failed) -ForegroundColor Green
    if ($failed -gt 0) { Write-Host '失败的文件在日志里状态为"失败"，可以稍后用同一份清单再跑一次。' -ForegroundColor Yellow }
    if ($Quarantine) {
        Write-Host "文件已移到各盘根目录的 $qName 文件夹。确认照片/视频都正常后，直接删除这些文件夹即可。"
    }
    Write-Host "日志：$logPath"
} finally {
    $sw.Dispose()
}
