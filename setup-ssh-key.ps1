# ============================================================
# SSH 密钥配置脚本
# ============================================================
# 目标服务器: 112.91.233.162:9998
# 创建时间: 2025-11-23 14:32:42 UTC
# 创建用户: purewave2019
# ============================================================

$ServerIp = "192.168.1.2"
$ServerPort = 22
$ServerUser = "root"
$SshKeyPath = ".\.ssh\id_rsa"
$PubKeyPath = ".\.ssh\id_rsa.pub"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           SSH 密钥自动配置脚本                             ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  ? 服务器: ${ServerIp}" -ForegroundColor Cyan
Write-Host "  ? 端口: ${ServerPort}" -ForegroundColor Cyan
Write-Host "  ? 用户: ${ServerUser}" -ForegroundColor Cyan
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""

# ============================================================
# 步骤 1: 检查和生成密钥
# ============================================================

Write-Host "[步骤 1/4] 检查 SSH 密钥..." -ForegroundColor Blue
Write-Host ""

if (Test-Path $SshKeyPath) {
    Write-Host "? 发现现有 SSH 密钥: $SshKeyPath" -ForegroundColor Green
    Write-Host ""
    $generate = Read-Host "是否重新生成密钥？(Y/N，默认N)"

    if ($generate -eq "Y" -or $generate -eq "y") {
        Write-Host ""
        Write-Host "? 重新生成 SSH 密钥..." -ForegroundColor Yellow
        ssh-keygen -t rsa -b 4096 -f $SshKeyPath -N '""'

        if ($LASTEXITCODE -eq 0) {
            Write-Host "? 密钥生成成功！" -ForegroundColor Green
        } else {
            Write-Host "? 密钥生成失败！" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "? 使用现有密钥" -ForegroundColor Yellow
    }
} else {
    Write-Host "? 生成新的 SSH 密钥..." -ForegroundColor Yellow
    Write-Host ""

    # 确保 .ssh 目录存在
    $sshDir = ".\.ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    ssh-keygen -t rsa -b 4096 -f $SshKeyPath -N '""'

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "? 密钥生成成功！" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "? 密钥生成失败！" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""

# ============================================================
# 步骤 2: 读取公钥
# ============================================================

Write-Host "[步骤 2/4] 读取公钥内容..." -ForegroundColor Blue
Write-Host ""

if (Test-Path $PubKeyPath) {
    $pubKey = Get-Content $PubKeyPath -Raw
    $pubKey = $pubKey.Trim()

    Write-Host "? 公钥内容：" -ForegroundColor Green
    Write-Host ""
    Write-Host $pubKey -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Host "? 未找到公钥文件: $PubKeyPath" -ForegroundColor Red
    exit 1
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""

# 给私钥设置严格权限（关键步骤）
# /inheritance:r：去掉继承的权限；
# /grant:r 用户名:(R)：只给当前用户读取权限。
icacls ".\.ssh\id_rsa" /inheritance:r
icacls ".\.ssh\id_rsa" /grant:r "$($env:USERNAME):(R)"

# ============================================================
# 步骤 3: 上传公钥到服务器
# ============================================================

Write-Host "[步骤 3/4] 上传公钥到服务器..." -ForegroundColor Blue
Write-Host ""

$serverInfo = "${ServerUser}@${ServerIp}:${ServerPort}"
Write-Host "  ? 目标服务器: $serverInfo" -ForegroundColor Cyan
Write-Host "  ??  请在SSH提示中输入服务器密码..." -ForegroundColor Yellow
Write-Host ""

# 转义公钥中的特殊字符
$escapedPubKey = $pubKey -replace "'", "'\\''"

# 构建远程命令
$remoteCommand = @"
mkdir -p ~/.ssh && \
chmod 700 ~/.ssh && \
echo '$escapedPubKey' >> ~/.ssh/authorized_keys && \
chmod 600 ~/.ssh/authorized_keys && \
restorecon -R -v ~/.ssh 2>/dev/null || true && \
echo '? 公钥配置成功！'
"@

# 执行SSH命令
ssh -p $ServerPort -o StrictHostKeyChecking=no "${ServerUser}@${ServerIp}" "$remoteCommand"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "? 公钥已成功上传并配置！" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "? 公钥上传失败！退出代码: $LASTEXITCODE" -ForegroundColor Red
    Write-Host ""
    Write-Host "可能的原因：" -ForegroundColor Yellow
    Write-Host "  1. 密码输入错误" -ForegroundColor Gray
    Write-Host "  2. 网络连接问题" -ForegroundColor Gray
    Write-Host "  3. 服务器端权限问题" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""

# ============================================================
# 步骤 4: 测试免密登录
# ============================================================

Write-Host "[步骤 4/4] 测试免密登录..." -ForegroundColor Blue
Write-Host ""
Write-Host "  ? 尝试免密连接到服务器..." -ForegroundColor Cyan
Write-Host ""

ssh -p $ServerPort -i .\.ssh\id_rsa -o BatchMode=yes -o ConnectTimeout=10 "${ServerUser}@${ServerIp}" "echo '? 免密登录测试成功！'"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║               ? 配置完成！免密登录已启用！              ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "? 配置信息：" -ForegroundColor Cyan
    Write-Host "  私钥位置: $SshKeyPath" -ForegroundColor White
    Write-Host "  公钥位置: $PubKeyPath" -ForegroundColor White
    Write-Host "  服务器: ${ServerUser}@${ServerIp}:${ServerPort}" -ForegroundColor White
    Write-Host ""
    Write-Host "? 现在可以使用免密登录：" -ForegroundColor Green
    Write-Host "  ssh -p $ServerPort ${ServerUser}@${ServerIp}" -ForegroundColor Gray
    Write-Host ""
    Write-Host "? 运行部署脚本将不再需要输入密码！" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║        ??  免密登录测试失败！                            ║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "? 故障排查步骤：" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. 手动登录服务器检查配置：" -ForegroundColor Cyan
    Write-Host "   ssh -p $ServerPort ${ServerUser}@${ServerIp}" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. 在服务器上执行以下命令：" -ForegroundColor Cyan
    Write-Host "   ls -la ~/.ssh/" -ForegroundColor Gray
    Write-Host "   cat ~/.ssh/authorized_keys" -ForegroundColor Gray
    Write-Host "   chmod 700 ~/.ssh" -ForegroundColor Gray
    Write-Host "   chmod 600 ~/.ssh/authorized_keys" -ForegroundColor Gray
    Write-Host "   restorecon -R -v ~/.ssh" -ForegroundColor Gray
    Write-Host ""
    Write-Host "3. 检查SSH服务配置：" -ForegroundColor Cyan
    Write-Host "   grep 'PubkeyAuthentication' /etc/ssh/sshd_config" -ForegroundColor Gray
    Write-Host "   systemctl restart sshd" -ForegroundColor Gray
    Write-Host ""
    Write-Host "4. 查看SSH日志：" -ForegroundColor Cyan
    Write-Host "   tail -f /var/log/secure" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""
