# =====================================================================================
# FFmpeg 智能命令执行器 V3.2 (最终稳定版)
# 环境: Windows 10 / PowerShell 5.1+
# 描述: 根据最终需求规划(V2)编写，并优化路径输入逻辑。微进度改为换行实时显示。
# 功能:
#   - 自动检测 ffmpeg 和 ffprobe 环境。
#   - 用户可指定命令文件路径或其所在文件夹路径。
#   - 支持断点续传 ([DONE] 标识)。
#   - 自动处理输出文件重名问题。
#   - 显示单文件实时进度(换行)和任务整体进度。
#   - 动态预估任务剩余时间。
#   - 稳定可靠的后台事件处理和实时进度刷新。
# =====================================================================================

# --- 辅助函数定义 ---

# 函数: 将秒数格式化为 HH:MM:SS
function Format-TimeSpanFromSeconds {
    param([double]$Seconds)
    return ([timespan]::FromSeconds($Seconds).ToString("hh\:mm\:ss"))
}

# 函数: 显示整体任务进度条
function Show-OverallProgress {
    param(
        [double]$ProcessedSeconds,
        [double]$TotalSeconds,
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    if ($TotalSeconds -eq 0) { return }

    $percentage = ($ProcessedSeconds / $TotalSeconds)
    $progressChars = 20
    $filledChars = [math]::Floor($percentage * $progressChars)
    $emptyChars = $progressChars - $filledChars
    $progressBar = "[{0}{1}]" -f ('█' * $filledChars), ('░' * $emptyChars)

    $elapsedTimeStr = Format-TimeSpanFromSeconds $Stopwatch.Elapsed.TotalSeconds

    $etaStr = "计算中..."
    if ($ProcessedSeconds -gt 0 -and $Stopwatch.Elapsed.TotalSeconds -gt 1) {
        $speed = $ProcessedSeconds / $Stopwatch.Elapsed.TotalSeconds
        $remainingSeconds = $TotalSeconds - $ProcessedSeconds
        $etaSeconds = $remainingSeconds / $speed
        $etaStr = Format-TimeSpanFromSeconds $etaSeconds
    }

    $processedTimeStr = Format-TimeSpanFromSeconds $ProcessedSeconds
    $totalTimeStr = Format-TimeSpanFromSeconds $TotalSeconds

    $progressText = "整体进度: {0} {1:P1} | 已处理: {2}/{3} | 已耗时: {4} | 预计剩余: {5}" -f `
        $progressBar, $percentage, $processedTimeStr, $totalTimeStr, $elapsedTimeStr, $etaStr

    Write-Host $progressText -ForegroundColor Green
}


# --- 脚本主逻辑 ---

# 1. 启动与环境检查
Write-Host "--- FFmpeg 智能命令执行器 V3.2 ---" -ForegroundColor Yellow
Write-Host "正在检查运行环境..."

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "错误: 未找到 ffmpeg 或 ffprobe 命令。" -ForegroundColor Red
    Write-Host "请确保已正确安装 FFmpeg 并将其添加至系统环境变量 PATH 中。" -ForegroundColor Red
    Read-Host "按任意键退出..."
    exit
}
Write-Host "环境检查通过。" -ForegroundColor Green

# 2. 获取任务文件 (已修改)
$userInputPath = Read-Host "请输入 'ffmpeg_commands.txt' 文件的完整路径，或其所在的文件夹路径"
$commandsFilePath = ""

if (Test-Path $userInputPath -PathType Leaf) {
    # 用户直接输入了文件路径
    $commandsFilePath = $userInputPath
}
elseif (Test-Path $userInputPath -PathType Container) {
    # 用户输入了文件夹路径，在此路径下查找 ffmpeg_commands.txt
    $potentialPath = Join-Path -Path $userInputPath -ChildPath "ffmpeg_commands.txt"
    if (Test-Path $potentialPath -PathType Leaf) {
        $commandsFilePath = $potentialPath
    }
}

# 检查最终确定的文件路径是否有效
if (-not ($commandsFilePath) -or -not (Test-Path $commandsFilePath -PathType Leaf)) {
    Write-Host "错误: 在指定路径下未找到 'ffmpeg_commands.txt' 文件，请检查后重试。" -ForegroundColor Red
    Read-Host "按任意键退出..."
    exit
}

Write-Host "命令文件加载成功: $commandsFilePath" -ForegroundColor Green


# 3. 任务初始化与总览计算
Write-Host "正在初始化任务，请稍候..."
# 修正: 使用更稳健的方式读取和清理命令文件，彻底移除`r字符
$fileContent = Get-Content $commandsFilePath -Raw -Encoding utf8
$allCommands = ($fileContent -replace "`r", "") -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }


$pendingTasks = @()
$totalDurationSeconds = 0

foreach ($command in $allCommands) {
    $cleanCommand = $command.Trim()
    if ($cleanCommand -and -not $cleanCommand.StartsWith("[DONE]")) {
        # 修正: 使用更精确的正则表达式 `([^"]+)` 防止路径内包含引号导致解析错误
        $inputFileMatch = [regex]::Match($cleanCommand, '-i "([^"]+)"')
        if ($inputFileMatch.Success) {
            $inputFilePath = $inputFileMatch.Groups[1].Value
            if (Test-Path $inputFilePath) {
                try {
                    $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$inputFilePath"
                    $duration = [double]::Parse($durationStr, [System.Globalization.CultureInfo]::InvariantCulture)
                    $totalDurationSeconds += $duration
                    $pendingTasks += [PSCustomObject]@{
                        Command  = $cleanCommand
                        Duration = $duration
                    }
                } catch {
                    Write-Warning "无法获取文件 '$inputFilePath' 的时长，将跳过此任务的统计。"
                }
            } else {
                Write-Warning "源文件 '$inputFilePath' 不存在，将跳过此任务。"
            }
        }
    }
}

if ($pendingTasks.Count -eq 0) {
    Write-Host "所有任务均已完成，无需执行操作。" -ForegroundColor Green
    Read-Host "按任意键退出..."
    exit
}

$totalDurationStr = Format-TimeSpanFromSeconds $totalDurationSeconds
Write-Host ("-" * 60)
Write-Host "任务初始化完成！" -ForegroundColor Cyan
Write-Host "本次需要处理 $($pendingTasks.Count) 个视频，总时长: $totalDurationStr"
Write-Host ("-" * 60)
Read-Host "准备就绪, 按回车键开始执行任务..."

# 4. 核心执行循环
$processedDurationSeconds = 0
$mainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt $allCommands.Count; $i++) {
    $currentCommand = $allCommands[$i].Trim()
    if (-not $currentCommand -or $currentCommand.StartsWith("[DONE]")) {
        continue
    }

    # 从预处理列表中找到当前任务
    $currentTask = $pendingTasks | Where-Object { $_.Command -eq $currentCommand } | Select-Object -First 1
    if (-not $currentTask) { continue }
    
    # 显示当前任务信息
    $taskIndex = ($pendingTasks.IndexOf($currentTask)) + 1
    Write-Host ""
    Write-Host "==> [任务 $taskIndex/$($pendingTasks.Count)] 开始处理..." -ForegroundColor Yellow
    Write-Host $currentCommand
    
    # 模块二: 文件冲突处理 (增加Try-Catch以提高稳定性)
    try {
        # 修正: 使用更精确的正则表达式 `([^"]+)` 来捕获输出文件路径
        $outputFileMatch = [regex]::Match($currentCommand, '"([^"]+)"\s*$')
        if ($outputFileMatch.Success) {
            $outputFilePath = $outputFileMatch.Groups[1].Value
            # 修正: 增加 -ErrorAction Stop 以确保try-catch能捕获Test-Path的路径错误
            if (Test-Path $outputFilePath -ErrorAction Stop) {
                Write-Warning "输出文件已存在: $outputFilePath"
                $dir = [System.IO.Path]::GetDirectoryName($outputFilePath)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($outputFilePath)
                $extension = [System.IO.Path]::GetExtension($outputFilePath)
                $renameCounter = 1
                do {
                    $newFileName = "{0}_old_{1}{2}" -f $baseName, $renameCounter, $extension
                    $newFilePath = Join-Path -Path $dir -ChildPath $newFileName
                    $renameCounter++
                } while (Test-Path $newFilePath)
                
                Write-Host "正在将旧文件重命名为: $newFileName" -ForegroundColor Cyan
                Rename-Item -Path $outputFilePath -NewName $newFileName
            }
        }
    } catch {
        Write-Host "错误: 处理输出文件路径 '$outputFilePath' 时失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "跳过当前任务，请检查命令: $currentCommand" -ForegroundColor Red
        continue # 跳到下一个任务
    }


    # 模块三: 执行并显示单文件进度
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "ffmpeg"
    $startInfo.Arguments = $currentCommand.Substring($currentCommand.IndexOf(' ') + 1)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $ffmpegProcess = New-Object System.Diagnostics.Process
    $ffmpegProcess.StartInfo = $startInfo
    $ffmpegProcess.EnableRaisingEvents = $true

    $progressState = [System.Collections.Hashtable]::Synchronized(@{ lastMessage = "" })

    $evtSubscriber = Register-ObjectEvent -InputObject $ffmpegProcess -EventName ErrorDataReceived -Action {
        param([object]$sender, [System.Diagnostics.DataReceivedEventArgs]$e)

        if ($e.Data) {
            $timeMatch = [regex]::Match($e.Data, "time=(\d{2}):(\d{2}):(\d{2})\.\d{2}")
            if ($timeMatch.Success) {
                $taskDuration = $Event.MessageData.Duration
                $state = $Event.MessageData.State

                $hours = [int]$timeMatch.Groups[1].Value
                $minutes = [int]$timeMatch.Groups[2].Value
                $seconds = [int]$timeMatch.Groups[3].Value
                $currentSeconds = ($hours * 3600) + ($minutes * 60) + $seconds
                
                if ($taskDuration -gt 0) {
                    $filePercentage = $currentSeconds / $taskDuration
                } else {
                    $filePercentage = 0
                }
                
                $speedMatch = [regex]::Match($e.Data, "speed=\s*([\d\.]+)x")
                $speed = if ($speedMatch.Success) { $speedMatch.Groups[1].Value + "x" } else { "N/A" }
                
                # 修正: 移除 `r 字符，实现换行打印
                $progressMessage = "    微进度: [{0:P0}] | 速度: {1}" -f $filePercentage, $speed
                
                if ($progressMessage -ne $state.lastMessage) {
                    # 修正: 使用 WriteLine 实现换行打印
                    [System.Console]::WriteLine($progressMessage)
                    $state.lastMessage = $progressMessage
                }
            }
        }
    } -MessageData @{ Duration = $currentTask.Duration; State = $progressState }

    $ffmpegProcess.Start() | Out-Null
    $ffmpegProcess.BeginErrorReadLine()
    
    # 修正: 使用非阻塞循环替代 WaitForExit()，以允许事件处理程序的输出能够实时刷新到控制台。
    while (-not $ffmpegProcess.HasExited) {
        Start-Sleep -Milliseconds 100
    }
    
    Unregister-Event -SubscriptionId $evtSubscriber.Id
    # 修正: Remove-Job 使用 -Id 参数，而不是 -SubscriptionId
    Remove-Job -Id $evtSubscriber.Id -ErrorAction SilentlyContinue

    # 此处不再需要额外的 WriteLine，因为进度信息已自带换行
    # [System.Console]::WriteLine()

    if ($ffmpegProcess.ExitCode -eq 0) {
        Write-Host "任务成功完成！" -ForegroundColor Green
        # 模块一: 回写[DONE]标识
        $allCommands[$i] = "[DONE] " + $allCommands[$i]
        $allCommands | Set-Content -Path $commandsFilePath -Encoding utf8

        # 更新整体进度
        $processedDurationSeconds += $currentTask.Duration
        Show-OverallProgress $processedDurationSeconds $totalDurationSeconds $mainStopwatch

    } else {
        Write-Host "任务失败！FFmpeg 返回错误代码: $($ffmpegProcess.ExitCode)" -ForegroundColor Red
        Write-Host "请检查命令或FFmpeg日志。"
    }
}

$mainStopwatch.Stop()
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "所有任务均已处理完毕！" -ForegroundColor Green
Write-Host "总耗时: $(Format-TimeSpanFromSeconds $mainStopwatch.Elapsed.TotalSeconds)" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Read-Host "按任意键退出..."

