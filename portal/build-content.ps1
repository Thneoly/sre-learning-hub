# build-content.ps1 —— 把全部 16 个模块目录的 Markdown 打包为 portal/content.js
# 用法（在 portal 目录下，或任意位置指定路径执行）：
#   powershell -ExecutionPolicy Bypass -File .\build-content.ps1
# 兼容 Windows PowerShell 5.1（不使用 PS7 独有语法；$PSScriptRoot 为空时自动兜底）。
#
# 收集范围：learning-hub 根目录下 16 个模块（含 labs 子目录里的 task.md / solution.md，
# 以及 11-middleware / 12-data-streaming 的子目录结构，键为相对根目录的完整路径）：
#   01-linux / 02-programming / 03-docker / 04-k8s-fundamentals / 05-cka /
#   06-cicd-iac-gitops / 07-cks / 08-pca / 09-otel / 10-logging /
#   11-middleware / 12-data-streaming / 13-sre-methodology / 14-cloud / 15-aiops-llm /
#   16-bigdata
# 另外打包根目录的全局文档（键名用原文件名，如 "SCENARIOS.md"）：SCENARIOS.md / README.md / ROADMAP.md，
# 场景速查页与阅读器可直接用 #/read/SCENARIOS.md 这样的路径打开它们。
# 目录不存在时跳过并告警，不中断；如需纳入更多模块，改下方 $modules 数组即可。
#
# 产物：portal/content.js，UTF-8（带 BOM，避免浏览器按本地码页误判），结构：
#   window.HUB_CONTENT = { "相对路径": "Markdown 原文", ... };
# 键为相对 learning-hub 根目录的正斜杠路径，与 index.html 里的清单一一对应。
# 生成后刷新 portal/index.html，即可在内置阅读器中离线阅读全部章节。

$ErrorActionPreference = 'Stop'

# 尽力把控制台切到 UTF-8，避免中文提示在简体中文 Windows 控制台乱码；失败不影响功能
try {
    $null = & cmd /c 'chcp 65001 > nul'
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

# 脚本所在目录（portal）；PS 3.0+ 支持 $PSScriptRoot，为空时用 $MyInvocation / 当前目录兜底
$portalDir = $PSScriptRoot
if (-not $portalDir) {
    $portalDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $portalDir) {
    $portalDir = (Get-Location).Path
}
$rootDir = Split-Path -Parent $portalDir
$outFile = Join-Path $portalDir 'content.js'

# 全部模块目录（相对 learning-hub 根目录，按教学顺序排列）
$modules = @(
    '01-linux', '02-programming', '03-docker', '04-k8s-fundamentals', '05-cka',
    '06-cicd-iac-gitops', '07-cks', '08-pca', '09-otel', '10-logging',
    '11-middleware', '12-data-streaming', '13-sre-methodology', '14-cloud', '15-aiops-llm',
    '16-bigdata'
)

# 源文件统一按 UTF-8 读入（ReadAllText 会自动剥掉可能存在的 BOM）；写出带 BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)

# 手写 JSON 字符串转义，不依赖 ConvertTo-Json（规避 PS5.1 的转义与格式化差异）：
# 反斜杠与引号先转义，换行统一为 \n，其余控制字符输出 \u00XX，非 ASCII 原样保留（文件本身是 UTF-8）
function ConvertTo-JsonString {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $s = $Text.Replace('\', '\\').Replace('"', '\"')
    $s = $s.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", '\n').Replace("`t", '\t')
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $code = [int]$s[$i]
        if ($code -lt 0x20) {
            [void]$sb.Append('\u' + $code.ToString('x4'))
        } else {
            [void]$sb.Append($s[$i])
        }
    }
    return $sb.ToString()
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// content.js -- 由 build-content.ps1 生成，请勿手工编辑')
[void]$sb.AppendLine('// 键 = 相对 learning-hub 根目录的正斜杠路径；值 = Markdown 原文')
[void]$sb.Append('window.HUB_CONTENT = {')

$count = 0
$failed = 0

foreach ($m in $modules) {
    $dir = Join-Path $rootDir $m
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Warning ("跳过不存在的目录: {0}" -f $dir)
        continue
    }
    # 递归收集 *.md（含 labs 子目录的 task.md 与 solution.md），按路径排序保证产物稳定
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -Recurse -File | Sort-Object FullName)
    if ($files.Count -eq 0) {
        Write-Warning ("目录内没有 Markdown 文件: {0}" -f $dir)
        continue
    }
    Write-Host ("== {0} ({1} 个文件)" -f $m, $files.Count)
    foreach ($f in $files) {
        # 相对 learning-hub 根的正斜杠路径，同时是 index.html 阅读器使用的键
        $rel = $f.FullName.Substring($rootDir.Length + 1).Replace('\', '/')
        try {
            $raw = [System.IO.File]::ReadAllText($f.FullName, $utf8NoBom)
        } catch {
            Write-Warning ("读取失败，已跳过: {0} ({1})" -f $rel, $_.Exception.Message)
            $failed++
            continue
        }
        if ($count -gt 0) { [void]$sb.Append(',') }
        [void]$sb.AppendLine()
        [void]$sb.Append('  "')
        [void]$sb.Append((ConvertTo-JsonString $rel))
        [void]$sb.Append('": "')
        [void]$sb.Append((ConvertTo-JsonString $raw))
        [void]$sb.Append('"')
        $count++
        Write-Host ("  + {0}" -f $rel)
    }
}

# 根目录的全局文档也打包进来（键名用原文件名，如 "SCENARIOS.md"）：
# 模块目录扫描之外额外纳入，阅读器/场景速查页可用 #/read/SCENARIOS.md 打开
$rootFiles = @('SCENARIOS.md', 'README.md', 'ROADMAP.md')
Write-Host ("== 根目录文档 ({0} 个文件)" -f $rootFiles.Count)
foreach ($rf in $rootFiles) {
    $p = Join-Path $rootDir $rf
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Warning ("跳过不存在的根目录文件: {0}" -f $p)
        continue
    }
    try {
        $raw = [System.IO.File]::ReadAllText($p, $utf8NoBom)
    } catch {
        Write-Warning ("读取失败，已跳过: {0} ({1})" -f $rf, $_.Exception.Message)
        $failed++
        continue
    }
    if ($count -gt 0) { [void]$sb.Append(',') }
    [void]$sb.AppendLine()
    [void]$sb.Append('  "')
    [void]$sb.Append((ConvertTo-JsonString $rf))
    [void]$sb.Append('": "')
    [void]$sb.Append((ConvertTo-JsonString $raw))
    [void]$sb.Append('"')
    $count++
    Write-Host ("  + {0}" -f $rf)
}

[void]$sb.AppendLine()
[void]$sb.Append('};')
[void]$sb.AppendLine()

# 防御：内容若含 </script> 字样会提前闭合 script 标签；JSON 里 \/ 等价于 /
$content = $sb.ToString().Replace('</', '<\/')

[System.IO.File]::WriteAllText($outFile, $content, $utf8Bom)

if ($count -eq 0) {
    Write-Warning '没有收集到任何 Markdown 文件，请确认脚本位于 learning-hub/portal 目录下（已生成空的 content.js）。'
}

$kb = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1KB, 1)
Write-Host ''
Write-Host ("完成: {0} 个文件 -> {1} ({2} KB)" -f $count, $outFile, $kb)
if ($failed -gt 0) {
    Write-Warning ("有 {0} 个文件读取失败被跳过，详见上方警告。" -f $failed)
}
Write-Host '刷新 portal/index.html，即可在内置阅读器中打开各章节。'
