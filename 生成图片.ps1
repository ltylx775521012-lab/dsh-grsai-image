<#
  星鲸 · 文生图脚本（grsai 中转站 / gpt-image-2.5）
  ------------------------------------------------------------
  用法：
    .\生成图片.ps1 "深海里的鲸鱼女仆，蓝长发，白蕾丝女仆装"
    .\生成图片.ps1 "提示词" -Ratio 2:3 -Out 我的图.png
    .\生成图片.ps1 "提示词" -Model gpt-image-2 -Ratio 16:9

  参数：
    -Prompt   提示词（必填；中文英文都行）
    -Ratio    画幅，如 1:1 / 3:4 / 4:3 / 2:3 / 3:2 / 9:16 / 16:9
    -Model    默认 gpt-image-2.5，也可 gpt-image-2
    -Out      输出文件名；不给就按时间戳自动命名。都存进 gpt生成图片\ 子目录
    -BaseUrl  中转站地址，默认 https://grsai.dakka.com.cn

  Key 从哪里读（按顺序）：
    1. 环境变量 GRSAI_API_KEY
    2. 同目录下的 .grsai-key 文件（只放一行 key，别加引号）
#>
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Prompt,
  [string]$Ratio = '1:1',
  [string]$Model = 'gpt-image-2.5',
  [string]$Out = '',
  [string]$BaseUrl = 'https://grsai.dakka.com.cn',
  [string]$KeyFile = '',
  [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
# 被 -File 调用时 $PSScriptRoot 有值；被内存脚本块调用时为空，退回当前目录
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $KeyFile) { $KeyFile = Join-Path $root '.grsai-key' }
# 生成的图片统一放这个子目录，不和记忆文件混在一起
$outDir = Join-Path $root 'gpt生成图片'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-ApiKey {
  if ($env:GRSAI_API_KEY) { return $env:GRSAI_API_KEY.Trim() }
  if (Test-Path -LiteralPath $KeyFile) {
    $k = (Get-Content -LiteralPath $KeyFile -Raw).Trim()
    if ($k) { return $k }
  }
  throw "缺少 API Key：请设置环境变量 GRSAI_API_KEY，或把 key 写进 $KeyFile"
}

$key = Get-ApiKey
$base = $BaseUrl.TrimEnd('/')

# 1) 提交任务（接口是流式返回进度，最后一条带 results）
$payload = @{ model = $Model; prompt = $Prompt; aspectRatio = $Ratio } | ConvertTo-Json -Compress
$bodyFile = Join-Path $env:TEMP ('grsai-body-' + [guid]::NewGuid().ToString('N') + '.json')
$respFile = Join-Path $env:TEMP ('grsai-resp-' + [guid]::NewGuid().ToString('N') + '.txt')
[System.IO.File]::WriteAllText($bodyFile, $payload, $utf8NoBom)

"正在生成：$Prompt"
"模型 $Model ／ 画幅 $Ratio ／ 预计 30～120 秒"
$t0 = Get-Date

& curl.exe -s --max-time $TimeoutSec -o $respFile -X POST "$base/v1/draw/completions" `
  -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "@$bodyFile"

if (-not (Test-Path -LiteralPath $respFile) -or (Get-Item -LiteralPath $respFile).Length -eq 0) {
  throw "接口没有返回内容（可能超时或网络不通）"
}

$lines = Get-Content -LiteralPath $respFile -Encoding UTF8
$objects = @()
foreach ($ln in $lines) {
  $s = $ln.Trim()
  if ($s -match '^data:\s*(\{.*\})\s*$') {
    try { $objects += ($matches[1] | ConvertFrom-Json) } catch { }
  }
}

if ($objects.Count -eq 0) {
  throw "没解析到返回数据：" + ($lines | Select-Object -First 3 | Out-String)
}

$last = $objects[-1]
$taskId = if ($last.id) { $last.id } else { $last.task_id }

# 2) 若流式被截断（没有成功状态），用任务 id 去查结果
if ($last.status -ne 'succeeded' -and $taskId) {
  "流式返回未完成（最后状态：$($last.status)），改为轮询结果…"
  $pollBody = Join-Path $env:TEMP ('grsai-poll-' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($pollBody, (@{ id = $taskId } | ConvertTo-Json -Compress), $utf8NoBom)
  for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -Seconds 5
    $pollOut = Join-Path $env:TEMP ('grsai-pollout-' + [guid]::NewGuid().ToString('N') + '.txt')
    & curl.exe -s --max-time 60 -o $pollOut -X POST "$base/v1/draw/result" `
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "@$pollBody"
    $ptxt = Get-Content -LiteralPath $pollOut -Raw -Encoding UTF8
    if ($ptxt -match '^data:\s*(\{.*\})') {
      try { $pj = $matches[1] | ConvertFrom-Json } catch { $pj = $null }
      if ($pj) {
        $last = $pj
        if ($pj.status -eq 'succeeded' -or $pj.status -eq 'failed') { break }
      }
    }
  }
}

if ($last.status -eq 'failed') {
  throw "生成失败：$($last.failure_reason) $($last.error)"
}

$url = $null
if ($last.results) { $url = @($last.results)[0].url }
if (-not $url) { $url = $last.url }
if (-not $url) { throw "没有拿到图片地址，返回内容：" + ($last | ConvertTo-Json -Compress) }

$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

# 3) 下载落盘
if ($Out) {
  $path = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $outDir $Out }
} else {
  $path = Join-Path $outDir ("生成图-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.png')
}
$dl = 0
for ($attempt = 1; $attempt -le 3; $attempt++) {
  & curl.exe -s --max-time 180 -o $path $url
  if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1000) { $dl = 1; break }
  Start-Sleep -Seconds 2
}
if (-not $dl) {
  "图片地址（下载失败，可手动打开）：$url"
  throw "下载图片失败"
}

$f = Get-Item -LiteralPath $path
"完成，用时 ${secs}s"
"已保存：$($f.FullName)  ($([math]::Round($f.Length / 1KB, 1)) KB)"
Remove-Item -LiteralPath $bodyFile, $respFile -Force -ErrorAction SilentlyContinue
