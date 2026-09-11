<#
.SYNOPSIS
    DevPocket 一键安装器（Windows，用户级安装，无需管理员权限）。

.DESCRIPTION
    安全取舍：请先把安装器下载到本地再执行，而不是 `irm <url> | iex`。
        irm https://github.com/lwtor/devpocket-release/releases/latest/download/install.ps1 -OutFile devpocket-install.ps1
        powershell -ExecutionPolicy Bypass -File .\devpocket-install.ps1
    这样可在执行前查看/审计脚本内容。本脚本只做「下载 -> 校验 -> 安装」。

    行为要点：
    - 只写入用户级目录（默认 $env:LOCALAPPDATA\DevPocket），不请求管理员权限，不写系统目录。
    - latest 会解析成明确版本，最终下载版本化不可变附件 devpocket-<version>.zip。
    - SHA-256 校验失败即 fail closed；manifest 缺字段 / 非法 JSON / 版本不一致一律拒绝安装。
    - 解压前逐条校验压缩包条目，拒绝 Zip Slip（路径穿越）；解压后拒绝符号链接/重解析点。
    - 升级失败完整回滚：恢复 current 指针、删除本次新建版本、还原入口脚本。
    - 绝不关闭 TLS 校验；绝不采集或上传宿主项目信息。

    退出码：0 成功 / 2 参数配置错误 / 3 下载失败 / 4 SHA-256 不匹配
            5 发布清单非法或版本不一致 / 6 解压失败（含路径穿越）/ 7 安装失败（已回滚）
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$BaseUrl = $env:DEVPOCKET_RELEASE_BASE_URL,
    [string]$InstallDir,
    [string]$BinDir,
    [switch]$NoPathUpdate,
    [switch]$NoInvoke
)

$Script:DefaultBaseUrl = 'https://github.com/lwtor/devpocket-release/releases/latest/download'
$Script:InstallerVersion = '1.0.0'
$Script:PathMarker = 'DevPocket'

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message) Write-Host $Message }
function Write-Err { param([string]$Message) Write-Host $Message -ForegroundColor Red }
function Fail { param([int]$Code, [string]$Message) Write-Err $Message; exit $Code }

# TLS：只提升到 TLS 1.2，绝不关闭证书校验。
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072) } catch { }
}

function Test-PlaceholderUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $true }
    if ($Url -match '<|>' -or $Url -match 'OWNER' -or $Url -match 'REPO') { return $true }
    return $false
}

function Test-DevPocketVersion {
    param([string]$Value)
    return ($Value -match '^[0-9]+\.[0-9]+\.[0-9]+$')
}

function Get-DevPocketDownload {
    param([string]$Uri, [string]$OutFile)
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
    } catch {
        throw "下载失败：$Uri（$($_.Exception.Message)）"
    }
    if (-not (Test-Path -LiteralPath $OutFile)) { throw "下载为空：$Uri" }
}

# 用 .NET 直接计算，避免依赖 Get-FileHash（部分受限宿主/精简环境中
# Microsoft.PowerShell.Utility 未提供该 cmdlet）。
function Get-DevPocketSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# PATH 幂等拼接（纯函数，便于单测；命中即原样返回）
function Add-DevPocketPathEntry {
    param([string]$Existing, [string]$Entry)
    if ([string]::IsNullOrWhiteSpace($Existing)) { return $Entry }
    $target = $Entry.TrimEnd('\')
    foreach ($part in ($Existing -split ';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if ($part.Trim().TrimEnd('\') -ieq $target) { return $Existing }
    }
    $trimmed = $Existing.TrimEnd(';')
    return ($Entry + ';' + $trimmed)
}

function Update-DevPocketUserPath {
    param([string]$Entry)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $next = Add-DevPocketPathEntry -Existing $current -Entry $Entry
    if ($next -ne $current) {
        [Environment]::SetEnvironmentVariable('Path', $next, 'User')
        return $true
    }
    return $false
}

# 安全解压：逐条校验条目名，拒绝绝对路径、反斜杠与 .. 穿越；解压后拒绝重解析点。
# 发布包内含深层 maven 目录（dist/devpocket-gradle-plugin/...），叠加临时目录后很容易
# 超过 Windows MAX_PATH(260)，因此对超长路径改用 \\?\ 扩展长度前缀，并自行流式写出。
function Expand-DevPocketArchive {
    param([string]$ZipPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destRoot = [IO.Path]::GetFullPath($Destination)
    if (-not $destRoot.EndsWith('\')) { $destRoot = $destRoot + '\' }

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -match '^\s*[A-Za-z]:' -or $name.StartsWith('/') -or $name.StartsWith('\')) {
                throw "压缩包含绝对路径条目，拒绝解压：$name"
            }
            if ($name -match '\\') {
                throw "压缩包含反斜杠条目，拒绝解压：$name"
            }
            if ($name -eq '..' -or $name -like '../*' -or $name -like '*/../*' -or $name -like '*/..') {
                throw "压缩包含路径穿越条目（Zip Slip），拒绝解压：$name"
            }
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $full = [IO.Path]::GetFullPath((Join-Path $destRoot $name))
            if (-not $full.StartsWith($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "条目解析后越出目标目录，拒绝解压：$name"
            }
            $parent = [IO.Path]::GetDirectoryName($full)
            $useExtended = ($full.Length -ge 240)
            $targetPath = if ($useExtended) { '\\?\' + $full } else { $full }
            $parentPath = if ($useExtended) { '\\?\' + $parent } else { $parent }
            [void][IO.Directory]::CreateDirectory($parentPath)
            if ($full.EndsWith('\')) { continue }
            try {
                $src = $entry.Open()
                try {
                    $fs = New-Object IO.FileStream($targetPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $src.CopyTo($fs) } finally { $fs.Dispose() }
                } finally { $src.Dispose() }
            } catch {
                throw "解压发布包条目失败：$name（$($_.Exception.Message)）"
            }
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }

    $reparse = @(Get-ChildItem -LiteralPath $destRoot -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparse.Count -gt 0) {
        throw "解压后出现符号链接/重解析点，拒绝安装：$($reparse[0].FullName)"
    }
}

function Invoke-DevPocketInstall {
    # ---------------------------------------------------------------- 参数
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $Script:DefaultBaseUrl }
    if (Test-PlaceholderUrl -Url $BaseUrl) {
        Fail 2 "Release Base URL 仍为占位符（$BaseUrl）。请通过 -BaseUrl 或环境变量 DEVPOCKET_RELEASE_BASE_URL 指定真实地址。"
    }
    $BaseUrl = $BaseUrl.TrimEnd('/')

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $InstallDir = Join-Path $env:LOCALAPPDATA 'DevPocket' }
        else { $InstallDir = Join-Path $HOME '.local/share/devpocket' }
    }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    if ([string]::IsNullOrWhiteSpace($BinDir)) { $BinDir = Join-Path $InstallDir 'bin' }
    $BinDir = [IO.Path]::GetFullPath($BinDir)

    if (-not [string]::IsNullOrWhiteSpace($Version) -and -not (Test-DevPocketVersion $Version)) {
        Fail 2 "版本号必须是 x.y.z：$Version"
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("devpocket-install-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $prevVersion = ''
    $createdNew = $false
    $shimBackup = ''
    $shimCreated = $false
    $target = ''

    $rollback = {
        param($Ctx)
        if ($Ctx.CreatedNew -and $Ctx.Target -and (Test-Path -LiteralPath $Ctx.Target)) {
            Remove-Item -LiteralPath $Ctx.Target -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($Ctx.PrevVersion) {
            Set-Content -LiteralPath $Ctx.CurrentFile -Value $Ctx.PrevVersion -Encoding ASCII
        } elseif (Test-Path -LiteralPath $Ctx.CurrentFile) {
            Remove-Item -LiteralPath $Ctx.CurrentFile -Force -ErrorAction SilentlyContinue
        }
        if ($Ctx.ShimBackup -and (Test-Path -LiteralPath $Ctx.ShimBackup)) {
            Copy-Item -LiteralPath $Ctx.ShimBackup -Destination $Ctx.ShimPath -Force -ErrorAction SilentlyContinue
        } elseif ($Ctx.ShimCreated -and (Test-Path -LiteralPath $Ctx.ShimPath)) {
            Remove-Item -LiteralPath $Ctx.ShimPath -Force -ErrorAction SilentlyContinue
        }
        if ($Ctx.BashShimBackup -and (Test-Path -LiteralPath $Ctx.BashShimBackup)) {
            Copy-Item -LiteralPath $Ctx.BashShimBackup -Destination $Ctx.BashShimPath -Force -ErrorAction SilentlyContinue
        } elseif ($Ctx.BashShimCreated -and (Test-Path -LiteralPath $Ctx.BashShimPath)) {
            Remove-Item -LiteralPath $Ctx.BashShimPath -Force -ErrorAction SilentlyContinue
        }
    }
    $ctx = [ordered]@{
        Target = ''; CurrentFile = (Join-Path $InstallDir 'current')
        PrevVersion = ''; CreatedNew = $false
        ShimPath = (Join-Path $BinDir 'devpocket.cmd'); ShimBackup = ''; ShimCreated = $false
        BashShimPath = (Join-Path $BinDir 'devpocket'); BashShimBackup = ''; BashShimCreated = $false
    }

    try {
        # ------------------------------------------------------------ 1) 发布清单
        if ([string]::IsNullOrWhiteSpace($Version)) {
            $manifestUrl = "$BaseUrl/release-manifest.json"
        } else {
            $manifestUrl = "$BaseUrl/devpocket-$Version.release-manifest.json"
        }
        $manifestFile = Join-Path $tmp 'release-manifest.json'
        Write-Log "读取发布清单：$manifestUrl"
        try { Get-DevPocketDownload -Uri $manifestUrl -OutFile $manifestFile }
        catch { Fail 3 $_.Exception.Message }

        # 显式按 UTF-8 读取：Windows PowerShell 5.1 对无 BOM 文件按 ANSI(GBK) 解码，
        # 会把多字节序列错配并吞掉引号，导致合法 JSON 被判为非法。
        try { $manifest = [IO.File]::ReadAllText($manifestFile, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
        catch { Fail 5 'release-manifest.json 不是合法 JSON。' }

        $required = @('schemaVersion', 'toolVersion', 'archive', 'sha256', 'minimumPowerShell', 'supportedPlatforms', 'createdAt')
        foreach ($key in $required) {
            $prop = $manifest.PSObject.Properties[$key]
            if ($null -eq $prop) { Fail 5 "release-manifest.json 缺少字段：$key" }
            if ($key -eq 'supportedPlatforms') {
                if ($null -eq $prop.Value -or @($prop.Value).Count -eq 0) { Fail 5 "release-manifest.json 字段为空：supportedPlatforms" }
            } elseif ([string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                Fail 5 "release-manifest.json 缺少字段或字段为空：$key"
            }
        }
        if ($manifest.schemaVersion -ne '1.0') { Fail 5 "不支持的 manifest schemaVersion：$($manifest.schemaVersion)（期望 1.0）。" }
        $toolVersion = [string]$manifest.toolVersion
        if (-not (Test-DevPocketVersion $toolVersion)) { Fail 5 "manifest.toolVersion 非法：$toolVersion" }

        if (-not [string]::IsNullOrWhiteSpace($Version)) {
            if ($toolVersion -ne $Version) { Fail 5 "请求版本 $Version 与发布清单版本 $toolVersion 不一致，拒绝安装。" }
        } else {
            $Version = $toolVersion
        }
        Write-Log "已解析安装版本：$Version"

        $expectedArchive = "devpocket-$Version.zip"
        if ([string]$manifest.archive -ne $expectedArchive) {
            Fail 5 "manifest.archive($($manifest.archive)) 与版本化附件名($expectedArchive) 不一致，拒绝安装。"
        }

        # ------------------------------------------------------------ 2) 下载 + 校验
        $zipFile = Join-Path $tmp $expectedArchive
        Write-Log "下载发布包：$BaseUrl/$expectedArchive"
        try { Get-DevPocketDownload -Uri "$BaseUrl/$expectedArchive" -OutFile $zipFile }
        catch { Fail 3 $_.Exception.Message }

        $sidecar = Join-Path $tmp "$expectedArchive.sha256"
        $sidecarOk = $true
        try { Get-DevPocketDownload -Uri "$BaseUrl/$expectedArchive.sha256" -OutFile $sidecar } catch { $sidecarOk = $false }
        if ($sidecarOk) {
            $sideSha = ((Get-Content -LiteralPath $sidecar -Raw) -split '\s+')[0].ToLowerInvariant()
            if ($sideSha -ne ([string]$manifest.sha256).ToLowerInvariant()) {
                Fail 4 "$expectedArchive.sha256($sideSha) 与 release-manifest.json($($manifest.sha256)) 不一致，拒绝安装。"
            }
        }

        $actual = Get-DevPocketSha256 -Path $zipFile
        if ($actual -ne ([string]$manifest.sha256).ToLowerInvariant()) {
            Fail 4 "SHA-256 不匹配：期望 $($manifest.sha256)，实际 $actual。已放弃安装（fail closed）。"
        }
        Write-Log "SHA-256 校验通过：$actual"

        # ------------------------------------------------------------ 3) 安全解压
        $extract = Join-Path $tmp 'extract'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        try { Expand-DevPocketArchive -ZipPath $zipFile -Destination $extract }
        catch { Fail 6 $_.Exception.Message }

        $src = Join-Path $extract "devpocket-$Version"
        if (-not (Test-Path -LiteralPath $src)) { Fail 6 "压缩包缺少顶层目录 devpocket-$Version/。" }
        if (-not (Test-Path -LiteralPath (Join-Path $src 'VERSION'))) { Fail 6 '发布包缺少 VERSION 文件。' }
        $pkgVersion = (Get-Content -LiteralPath (Join-Path $src 'VERSION') -Raw).Trim()
        if ($pkgVersion -ne $Version) { Fail 5 "包内 VERSION($pkgVersion) 与安装版本($Version) 不一致，拒绝安装。" }
        if (-not (Test-Path -LiteralPath (Join-Path $src 'devpocket.cmd'))) { Fail 6 '发布包缺少 Windows 入口 devpocket.cmd。' }

        if ($env:DEVPOCKET_TEST_FAIL_AFTER_EXTRACT -eq '1') {
            Fail 7 '测试注入：解压后失败（DEVPOCKET_TEST_FAIL_AFTER_EXTRACT）。'
        }

        # ------------------------------------------------------------ 4) 安装
        $versionsDir = Join-Path $InstallDir 'versions'
        $target = Join-Path $versionsDir $Version
        $ctx.Target = $target
        New-Item -ItemType Directory -Path $versionsDir -Force | Out-Null

        if (Test-Path -LiteralPath $ctx.CurrentFile) {
            $ctx.PrevVersion = (Get-Content -LiteralPath $ctx.CurrentFile -Raw).Trim()
        }

        if (Test-Path -LiteralPath $target) {
            Write-Log "版本 $Version 已存在，保留现有安装（幂等重装）。"
        } else {
            $staging = "$target.staging"
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            Move-Item -LiteralPath $src -Destination $staging -Force
            Move-Item -LiteralPath $staging -Destination $target -Force
            $ctx.CreatedNew = $true
        }

        if ($env:DEVPOCKET_TEST_FAIL_AFTER_SWITCH -eq '0') { }

        try {
            Set-Content -LiteralPath ($ctx.CurrentFile + '.tmp') -Value $Version -Encoding ASCII -ErrorAction Stop
            Move-Item -LiteralPath ($ctx.CurrentFile + '.tmp') -Destination $ctx.CurrentFile -Force -ErrorAction Stop
        } catch {
            Write-Err "写入 current 指针失败，开始回滚：$($_.Exception.Message)"
            & $rollback $ctx
            Fail 7 '安装失败并已回滚。'
        }

        if ($env:DEVPOCKET_TEST_FAIL_AFTER_SWITCH -eq '1') {
            Write-Err '测试注入：切换后失败（DEVPOCKET_TEST_FAIL_AFTER_SWITCH）。'
            & $rollback $ctx
            Fail 7 '安装失败并已回滚。'
        }

        # 入口 shim
        try {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
        $shim = @(
            '@echo off'
            'setlocal'
            "set `"DP_ROOT=$InstallDir`""
            'if not exist "%DP_ROOT%\current" ('
            '  echo DevPocket is not installed correctly: missing %DP_ROOT%\current 1>&2'
            '  exit /b 1'
            ')'
            'set /p DP_VER=<"%DP_ROOT%\current"'
            'if not exist "%DP_ROOT%\versions\%DP_VER%\devpocket.cmd" ('
            '  echo DevPocket version %DP_VER% is missing. 1>&2'
            '  exit /b 1'
            ')'
            'call "%DP_ROOT%\versions\%DP_VER%\devpocket.cmd" %*'
            'exit /b %ERRORLEVEL%'
        ) -join "`r`n"

        if (Test-Path -LiteralPath $ctx.ShimPath) {
            $existing = (Get-Content -LiteralPath $ctx.ShimPath -Raw -ErrorAction SilentlyContinue)
            if ($existing -ne $shim) {
                $ctx.ShimBackup = Join-Path $tmp 'devpocket.cmd.bak'
                Copy-Item -LiteralPath $ctx.ShimPath -Destination $ctx.ShimBackup -Force
                Set-Content -LiteralPath $ctx.ShimPath -Value $shim -Encoding ASCII
            }
        } else {
            Set-Content -LiteralPath $ctx.ShimPath -Value $shim -Encoding ASCII
            $ctx.ShimCreated = $true
        }

        # Git Bash does not apply Windows PATHEXT, so `devpocket` does not resolve
        # to devpocket.cmd. Install an extensionless Bash shim in the same PATH dir.
        $bashShim = @'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
"$SCRIPT_DIR/devpocket.cmd" "$@"
exit $?
'@
        $bashShim = $bashShim.TrimStart("`r", "`n") -replace "`r`n", "`n"
        if (Test-Path -LiteralPath $ctx.BashShimPath) {
            $existingBashShim = [IO.File]::ReadAllText($ctx.BashShimPath)
            if ($existingBashShim -ne $bashShim) {
                $ctx.BashShimBackup = Join-Path $tmp 'devpocket.bak'
                Copy-Item -LiteralPath $ctx.BashShimPath -Destination $ctx.BashShimBackup -Force
                [IO.File]::WriteAllText($ctx.BashShimPath, $bashShim, [Text.UTF8Encoding]::new($false))
            }
        } else {
            [IO.File]::WriteAllText($ctx.BashShimPath, $bashShim, [Text.UTF8Encoding]::new($false))
            $ctx.BashShimCreated = $true
        }

        if ($env:DEVPOCKET_TEST_FAIL_AFTER_SHIMS -eq '1') {
            throw '测试注入：双入口写入后失败（DEVPOCKET_TEST_FAIL_AFTER_SHIMS）。'
        }

        } catch {
            Write-Err "写入命令入口失败，开始回滚：$($_.Exception.Message)"
            & $rollback $ctx
            Fail 7 '安装失败并已回滚。'
        }

        # PATH（用户级，幂等）
        if (-not $NoPathUpdate) {
            try {
                $changed = Update-DevPocketUserPath -Entry $BinDir
                if ($changed) { Write-Log "已把 $BinDir 写入用户 PATH（新开终端生效）。" }
                else { Write-Log "$BinDir 已在用户 PATH 中，未重复追加。" }
            } catch {
                Write-Err "写入用户 PATH 失败，开始回滚：$($_.Exception.Message)"
                & $rollback $ctx
                Fail 7 '安装失败并已回滚。'
            }
        }

        Write-Log ''
        Write-Log "DevPocket $Version 安装完成。"
        Write-Log "  安装目录：$InstallDir"
        Write-Log "  当前版本：$target"
        Write-Log "  PowerShell/CMD 入口：$($ctx.ShimPath)"
        Write-Log "  Git Bash 入口：$($ctx.BashShimPath)"
        if ($NoPathUpdate) {
            Write-Log "  提示：未修改 PATH。可手动把 $BinDir 加入 PATH 后使用 devpocket 命令。"
        }
        Write-Log '  验证：devpocket capability'
        return 0
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if (-not $NoInvoke) {
    exit (Invoke-DevPocketInstall)
}
