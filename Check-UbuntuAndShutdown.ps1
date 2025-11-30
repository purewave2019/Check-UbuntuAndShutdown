param(
# 远程要执行的命令，默认是 poweroff
    [string]$RemoteCommand = "poweroff",

# 日志文件路径，默认当前目录下的 UbuntuMonitor.log
    [string]$LogFilePath = ".\UbuntuMonitor.log",

# 在线状态持久化文件（每天的在线时长）
    [string]$StateFilePath = ".\UbuntuOnlineState.json",

# SSH 私钥路径（相对脚本目录或绝对路径）
    [string]$SshKeyPath = ".\.ssh\id_rsa",

# 配置文件路径（相对脚本目录或绝对路径），包含每日阈值与时间窗口
    [string]$ConfigFilePath = ".\UbuntuMonitor.config.json"
)

# 基本参数配置
$ip       = "192.168.1.2"
$port     = 22
$username = "root"

$checkIntervalSeconds = 10       # 检查间隔 10 秒
$timeoutMilliseconds  = 5000     # 连接超时 5 秒

# 给私钥设置严格权限（关键步骤）
# /inheritance:r：去掉继承的权限；
# /grant:r 用户名:(R)：只给当前用户读取权限。
icacls ".\.ssh\id_rsa" /inheritance:r
icacls ".\.ssh\id_rsa" /grant:r "$($env:USERNAME):(R)"

# 规范化关键路径为绝对路径（允许相对脚本目录）
if (-not [System.IO.Path]::IsPathRooted($SshKeyPath)) {
    $SshKeyPath = Join-Path -Path $PSScriptRoot -ChildPath $SshKeyPath
}
if (-not [System.IO.Path]::IsPathRooted($LogFilePath)) {
    $LogFilePath = Join-Path -Path $PSScriptRoot -ChildPath $LogFilePath
}
if (-not [System.IO.Path]::IsPathRooted($StateFilePath)) {
    $StateFilePath = Join-Path -Path $PSScriptRoot -ChildPath $StateFilePath
}
if (-not [System.IO.Path]::IsPathRooted($ConfigFilePath)) {
    $ConfigFilePath = Join-Path -Path $PSScriptRoot -ChildPath $ConfigFilePath
}

# 确保日志文件存在（如果不存在就创建一个空文件）
if (-not (Test-Path -Path $LogFilePath)) {
    New-Item -ItemType File -Path $LogFilePath -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    # 控制台输出
    Write-Host $line

    # 追加写入日志文件
    Add-Content -Path $LogFilePath -Value $line
}

# 读取配置（每日阈值与时间窗口），每次循环调用，第三方修改可实时生效
function Load-Config {
    param(
        [string]$Path
    )

    $default = [pscustomobject]@{
        DailyThresholdSeconds = 3600
        ActiveWindows         = @([pscustomobject]@{ StartHour = 9; EndHour = 21 })
        # 兼容旧字段（如果老配置里只有 ActiveStartHour / ActiveEndHour）
        ActiveStartHour       = 9
        ActiveEndHour         = 21
    }

    if (-not (Test-Path -Path $Path)) {
        try {
            # 写入新的多窗口结构（默认单窗口）
            ([pscustomobject]@{
                DailyThresholdSeconds = $default.DailyThresholdSeconds
                ActiveWindows         = $default.ActiveWindows
            }) | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
            Write-Log "配置文件不存在，已写入默认配置到：$Path" "WARN"
        }
        catch {
            Write-Log "创建默认配置文件失败：$($_.Exception.Message)" "ERROR"
        }
        return $default
    }

    try {
        $json = Get-Content -Path $Path -Raw
        if ([string]::IsNullOrWhiteSpace($json)) {
            Write-Log "配置文件内容为空，使用默认配置" "WARN"
            return $default
        }
        $cfg = $json | ConvertFrom-Json
        if ($null -eq $cfg) { return $default }

        # DailyThresholdSeconds 校验
        $DailyThresholdSeconds = [int]($cfg.DailyThresholdSeconds)
        if ($DailyThresholdSeconds -le 0) { $DailyThresholdSeconds = $default.DailyThresholdSeconds }

        # 构建窗口数组：优先使用 ActiveWindows；否则尝试旧字段 ActiveStartHour/ActiveEndHour
        $windows = @()
        if ($cfg.PSObject.Properties.Name -contains 'ActiveWindows' -and $cfg.ActiveWindows) {
            foreach ($w in $cfg.ActiveWindows) {
                try {
                    $sh = [int]$w.StartHour
                    $eh = [int]$w.EndHour
                    if ($sh -lt 0 -or $sh -gt 23 -or $eh -lt 0 -or $eh -gt 23) { continue }
                    $windows += [pscustomobject]@{ StartHour = $sh; EndHour = $eh }
                }
                catch { continue }
            }
        }
        elseif (($cfg.PSObject.Properties.Name -contains 'ActiveStartHour') -and ($cfg.PSObject.Properties.Name -contains 'ActiveEndHour')) {
            $sh = [int]$cfg.ActiveStartHour
            $eh = [int]$cfg.ActiveEndHour
            if ($sh -ge 0 -and $sh -le 23 -and $eh -ge 0 -and $eh -le 23) {
                $windows += [pscustomobject]@{ StartHour = $sh; EndHour = $eh }
            }
        }

        if ($windows.Count -eq 0) {
            Write-Log "未找到有效时间窗口配置，使用默认窗口" "WARN"
            $windows = $default.ActiveWindows
        }

        return [pscustomobject]@{
            DailyThresholdSeconds = $DailyThresholdSeconds
            ActiveWindows         = $windows
        }
    }
    catch {
        Write-Log "读取配置文件失败，使用默认配置。错误：$($_.Exception.Message)" "WARN"
        return $default
    }
}

function Test-TcpPort {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 5000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar  = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $wait = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $wait) {
            $client.Close()
            return $false
        }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    }
    catch {
        if ($client -ne $null) {
            $client.Close()
        }
        return $false
    }
}

# 加载/初始化在线时长状态
function Load-State {
    param(
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        # 始终返回 PSCustomObject，确保后续 Add-Member 与点号访问一致
        return [pscustomobject]@{}
    }

    try {
        $json = Get-Content -Path $Path -Raw
        if ([string]::IsNullOrWhiteSpace($json)) {
            return [pscustomobject]@{}
        }
        $data = $json | ConvertFrom-Json
        if ($null -eq $data) {
            # JSON 可能是 "null"，统一返回空对象
            return [pscustomobject]@{}
        }
        return $data
    }
    catch {
        Write-Log "读取状态文件失败，将重置状态文件。错误：$($_.Exception.Message)" "WARN"
        return [pscustomobject]@{}
    }
}

function Save-State {
    param(
        [object]$State,
        [string]$Path
    )

    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
    }
    catch {
        Write-Log "写入状态文件失败：$($_.Exception.Message)" "ERROR"
    }
}

# 封装 SSH 执行逻辑
function Invoke-RemoteCommand {
    param(
        [string]$Command
    )

    # 检查私钥是否存在
    if (-not (Test-Path -Path $SshKeyPath)) {
        Write-Log "SSH 私钥不存在：$SshKeyPath，请检查路径配置。" "ERROR"
        return
    }

    # 使用私钥登录执行远程命令（RemoteCommand 直接作为命令和参数）
    $sshCommand = "ssh -i `"$SshKeyPath`" -o StrictHostKeyChecking=no $username@$ip $Command"
    Write-Log "执行命令：$sshCommand"

    try {
        cmd.exe /c $sshCommand
        Write-Log "远程命令已发送，本轮结束，继续监控。"
    }
    catch {
        Write-Log "执行远程命令时发生错误：$($_.Exception.Message)" "ERROR"
    }
}

# 判断当前小时是否处在配置的时间窗口内（支持跨日）
function Test-IsWithinAnyWindow {
    param(
        [int]$Hour,
        [array]$Windows
    )
    foreach ($w in $Windows) {
        $StartHour = [int]$w.StartHour
        $EndHour   = [int]$w.EndHour
        if ($StartHour -eq $EndHour) { return $true }
        elseif ($StartHour -lt $EndHour) {
            if ($Hour -ge $StartHour -and $Hour -lt $EndHour) { return $true }
        }
        else {
            if ($Hour -ge $StartHour -or $Hour -lt $EndHour) { return $true }
        }
    }
    return $false
}

# 当前日期（用于跨天检测）
$currentDateKey = (Get-Date -Format 'yyyy-MM-dd')

# 首次读取配置
$config = Load-Config -Path $ConfigFilePath

Write-Log "开始监控 ${ip}:${port}"
Write-Log "每 $checkIntervalSeconds 秒检查一次，超过阈值将通过 SSH（密钥：$SshKeyPath）执行远程命令：'$RemoteCommand'"
Write-Log "日志文件路径：$LogFilePath"
Write-Log "状态文件路径：$StateFilePath"
Write-Log "配置文件路径：$ConfigFilePath"
Write-Log "注意：每次循环都会从配置文件和状态文件重新加载"


while ($true) {
    # 每次循环都从文件重新加载状态与配置，第三方修改实时生效
    $state  = Load-State  -Path $StateFilePath
    $config = Load-Config -Path $ConfigFilePath

    # 每次循环输出当前配置
    Write-Log ("当前配置 DailyThresholdSeconds = $($config.DailyThresholdSeconds) 秒 (" + [math]::Round($config.DailyThresholdSeconds/60, 2) + " 分钟)")
    Write-Log ("当前时间窗口：" + (($config.ActiveWindows | ForEach-Object { "$($_.StartHour):00-$($_.EndHour):00" }) -join ', '))
    if ($config.ActiveWindows | Where-Object { $_.StartHour -eq $_.EndHour }) {
        Write-Log "检测到 StartHour==EndHour 的窗口（全天有效），窗口内按阈值判断" "WARN"
    }

    $nowDateKey = (Get-Date -Format 'yyyy-MM-dd')

    # 如果跨天了，切换到新日期
    if ($nowDateKey -ne $currentDateKey) {
        Write-Log "检测到日期变更：$currentDateKey -> $nowDateKey，开始新一天的统计"
        $currentDateKey = $nowDateKey
    }

    # 确保当前日期的键存在
    if (-not ($state.PSObject.Properties.Name -contains $currentDateKey)) {
        $state | Add-Member -NotePropertyName $currentDateKey -NotePropertyValue 0 -Force
    }

    # 读取当前日期已累计的在线秒数
    $dailyOnlineSeconds = [int]$state.$currentDateKey

    $isOnline = Test-TcpPort -TargetHost $ip -Port $port -TimeoutMs $timeoutMilliseconds
    if ($isOnline) {
        # 增加在线时长
        $dailyOnlineSeconds += $checkIntervalSeconds

        # 更新状态
        $state.$currentDateKey = $dailyOnlineSeconds

        Write-Log "$ip 在线，当天累计在线时间：$dailyOnlineSeconds 秒"
        Save-State -State $state -Path $StateFilePath

        # 时间窗口：处在窗口内按阈值；窗口之外立即执行
        $now = Get-Date
        $isWithinWindow = Test-IsWithinAnyWindow -Hour $now.Hour -Windows $config.ActiveWindows
        if (-not $isWithinWindow) {
            Write-Log "当前时间 $($now.ToString('HH:mm')) 不在任何配置的窗口内，立即执行远程命令：'$RemoteCommand'"
            Invoke-RemoteCommand -Command $RemoteCommand
        }
        elseif ($dailyOnlineSeconds -ge $config.DailyThresholdSeconds) {
            Write-Log "$ip 在 $currentDateKey 当天累计在线时间已超过 $([math]::Round($config.DailyThresholdSeconds/60,2)) 分钟（窗口内），准备通过 SSH 执行远程命令：'$RemoteCommand'"
            Invoke-RemoteCommand -Command $RemoteCommand
        }
    }
    else {
        Write-Log "$ip 当前不在线" "WARN"
        # 当天累计时长不清零，只不过这一轮不增加
        Save-State -State $state -Path $StateFilePath
    }

    Start-Sleep -Seconds $checkIntervalSeconds
}
