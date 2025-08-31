# =====================================================================================
# FFmpeg 批量转码命令生成器
# 版本: 1.1 (已修正路径处理逻辑)
# 环境: Windows 10 / PowerShell 5.1+
# 功能: 自动扫描视频文件,根据用户参数生成FFmpeg命令,并重建目录结构。
# =====================================================================================

# --- 脚本配置 ---
# 定义支持的视频文件扩展名
$videoExtensions = @("*.mp4", "*.mkv", "*.mov", "*.avi", "*.flv", "*.webm", "*.ts", "*.wmv")

# --- 函数定义 ---

# 函数: 获取用户输入的参数
function Get-UserConfiguration {
    Write-Host "--- FFmpeg 命令生成器 (V1.1) ---" -ForegroundColor Yellow
    Write-Host "请根据提示输入参数，或直接按回车使用默认值。"

    # 1. 获取源路径
    $sourcePath = Read-Host -Prompt "请输入源视频文件或文件夹的完整路径"
    while (-not (Test-Path $sourcePath)) {
        Write-Host "错误: 指定的路径不存在, 请重新输入。" -ForegroundColor Red
        $sourcePath = Read-Host -Prompt "请输入源视频文件或文件夹的完整路径"
    }

    # 2. 获取输出路径
    $outputPath = Read-Host -Prompt "请输入输出文件夹路径 (可选, 默认在源目录的同级创建 'encode' 文件夹)"

    # 3. 获取编码参数
    $encoder = Read-Host -Prompt "请输入视频编码器 [hevc_nvenc / av1_nvenc] (默认: hevc_nvenc)"
    if ([string]::IsNullOrWhiteSpace($encoder)) { $encoder = "hevc_nvenc" }

    $qp = Read-Host -Prompt "请输入视频质量 QP 值 (数字越小质量越高) (默认: 22)"
    if ([string]::IsNullOrWhiteSpace($qp)) { $qp = "22" }

    $preset = Read-Host -Prompt "请输入编码预设 [slow, medium, fast 等] (默认: medium)"
    if ([string]::IsNullOrWhiteSpace($preset)) { $preset = "medium" }

    # 返回一个包含所有配置的对象
    return [PSCustomObject]@{
        SourcePath = $sourcePath.TrimEnd('\')
        OutputPath = $outputPath
        Encoder    = $encoder
        QP         = $qp
        Preset     = $preset
    }
}

# --- 主脚本逻辑 ---

# 清理屏幕
Clear-Host

# 1. 获取用户配置
$config = Get-UserConfiguration

# 2. 获取源对象信息
$sourceItem = Get-Item -Path $config.SourcePath
$isSingleFile = -not $sourceItem.PSIsContainer

# 3. 【关键改动】定义用于计算相对路径的基准位置 (源的父目录)
$baseLocation = Split-Path $sourceItem.FullName -Parent

# 4. 处理和创建输出路径
$defaultOutputPathBase = if ($isSingleFile) { $baseLocation } else { $sourceItem.FullName }
if ([string]::IsNullOrWhiteSpace($config.OutputPath)) {
    # 如果用户未提供输出路径, 则使用默认路径
    $outputPath = Join-Path -Path $defaultOutputPathBase -ChildPath "encode"
} else {
    $outputPath = $config.OutputPath
}

# 如果输出目录不存在, 则创建它
if (-not (Test-Path $outputPath)) {
    Write-Host "输出文件夹不存在, 正在创建: $outputPath" -ForegroundColor Cyan
    New-Item -Path $outputPath -ItemType Directory | Out-Null
}

# 5. 初始化变量
$videoFiles = @()
$ffmpegCommands = @()

# 6. 核心处理逻辑
if ($isSingleFile) {
    # --- 单文件处理模式 ---
    Write-Host "检测到单个文件模式。" -ForegroundColor Green
    $videoFiles += $sourceItem
}
else {
    # --- 文件夹处理模式 ---
    Write-Host "检测到文件夹模式, 开始扫描视频文件..." -ForegroundColor Green
    
    # 递归扫描所有视频文件
    $videoFiles = Get-ChildItem -Path $config.SourcePath -Recurse -Include $videoExtensions
    
    if ($videoFiles.Count -eq 0) {
        Write-Host "在 '$($config.SourcePath)' 及其子目录中未找到任何视频文件。" -ForegroundColor Yellow
        exit
    }
    
    Write-Host "共找到 $($videoFiles.Count) 个视频文件。"

    # --- 保存并重建目录结构 ---
    Write-Host "正在分析并保存源目录结构..."
    $allDirsToCreate = @()
    # 首先添加根目录本身
    $allDirsToCreate += $sourceItem.FullName.Substring($baseLocation.Length).TrimStart('\')
    
    # 然后添加所有子目录
    Get-ChildItem -Path $config.SourcePath -Recurse -Directory | ForEach-Object {
        $allDirsToCreate += $_.FullName.Substring($baseLocation.Length).TrimStart('\')
    }

    # 将目录结构保存为JSON文件
    $jsonPath = Join-Path -Path $outputPath -ChildPath "directory_structure.json"
    $allDirsToCreate | ConvertTo-Json -Depth 100 | Out-File -FilePath $jsonPath -Encoding utf8
    Write-Host "目录结构已保存至: $jsonPath" -ForegroundColor Cyan
    
    # 在输出目录中重建文件树
    Write-Host "正在输出目录中重建文件树..."
    foreach ($subDir in $allDirsToCreate) {
        $newDir = Join-Path -Path $outputPath -ChildPath $subDir
        if (-not (Test-Path $newDir)) {
            New-Item -Path $newDir -ItemType Directory | Out-Null
        }
    }
    Write-Host "文件树重建完成。"
}

# 7. 生成FFmpeg命令
Write-Host "正在为每个视频文件生成FFmpeg命令..."
foreach ($file in $videoFiles) {
    # 【关键改动】使用新的基准位置计算相对路径
    $relativeFilePath = $file.FullName.Substring($baseLocation.Length).TrimStart('\')
    
    # 构建输出文件的完整路径, 并确保扩展名为.mp4
    $outputFileFullName = Join-Path -Path $outputPath -ChildPath $relativeFilePath
    $outputFileFullName = [io.path]::ChangeExtension($outputFileFullName, ".mp4")

    # 构建FFmpeg命令字符串, 注意路径用双引号包裹
    $command = "ffmpeg -hwaccel cuvid -i `"$($file.FullName)`" -c:v $($config.Encoder) -preset $($config.Preset) -qp $($config.QP) -c:a copy `"$($outputFileFullName)`""
    
    # 将生成的命令添加到数组
    $ffmpegCommands += $command
}

# 8. 将命令写入文件
$commandsFilePath = Join-Path -Path $outputPath -ChildPath "ffmpeg_commands.txt"
$ffmpegCommands | Out-File -FilePath $commandsFilePath -Encoding utf8

# 9. 完成并提示用户
Write-Host "========================================================================" -ForegroundColor Green
Write-Host "处理完成!" -ForegroundColor Green
Write-Host "所有 FFmpeg 命令已成功生成并保存至:"
Write-Host "$commandsFilePath" -ForegroundColor Yellow
Write-Host ""
Write-Host "下一步操作:" -ForegroundColor Cyan
Write-Host "1. 检查 '$commandsFilePath' 文件中的命令是否正确。"
Write-Host "2. 打开一个新的终端 (CMD 或 PowerShell) 并导航到输出目录 '$outputPath'。"
Write-Host "3. 复制文件中的命令并粘贴到终端中执行, 或者创建一个 .bat 文件来批量执行。"
Write-Host "提醒: 请确保您的系统中已正确安装FFmpeg并配置了环境变量。"
Write-Host "========================================================================" -ForegroundColor Green
