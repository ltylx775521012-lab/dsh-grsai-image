<#
  星鲸 · 文生图 / 图生图脚本（grsai 中转站 / gpt-image-2.5）
  ------------------------------------------------------------
  文生图（不给参考图）：
    .\生成图片.ps1 "深海里的鲸鱼女仆，蓝长发，白蕾丝女仆装"
    .\生成图片.ps1 "提示词" -Ratio 2:3 -Out 我的图.png

  图生图（给参考图，保持角色/风格）：
    .\生成图片.ps1 "让她坐在雪天长椅上，围红围巾" -Ref "立绘-鲸鱼娘.png" -Ratio 2:3
    .\生成图片.ps1 "换成水彩风格" -Ref "a.png","b.png" -Out 双图融合.png
    .\生成图片.ps1 "改姿势" -Ref "https://example.com/x.png"

  参数：
    -Prompt   提示词（必填）
    -Ref      参考图，可给多个：本地路径或 http(s) 链接；相对路径按脚本目录解析
    -Ratio    画幅：1:1 / 4:3 / 3:4 / 3:2 / 2:3 / 16:9 / 9:16
    -Model    默认 gpt-image-2.5，也可 gpt-image-2
    -Quality  可选：low / medium / high（只有模型支持时才生效）
    -Out      输出文件名；不给就按时间戳命名。都存进 gpt生成图片\
    -BaseUrl  中转站地址

  Key 从哪里读（按顺序）：
    1. 环境变量 GRSAI_API_KEY
    2. 同目录下的 .grsai-key 文件（只放一行 key，别加引号）
#>
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Prompt,
  [string[]]$Ref = @(),
  [string]$Ratio = '1:1',
  [string]$Model = 'gpt-image-2.5',
  [string]$Quality = '',
  [string]$Out = '',
  [string]$BaseUrl = 'https://grsai.dakka.com.cn',
  [string]$KeyFile = '',
  [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $KeyFile) { $KeyFile = Join-Path $root '.grsai-key' }
$outDir = Join-Path $root 'gpt生成图片'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$mime = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp' }

function Get-ApiKey {
  if ($env:GRSAI_API_KEY) { return $env:GRSAI_API_KEY.Trim() }
  if (Test-Path -LiteralPath $KeyFile) {
    $k = (Get-Content -LiteralPath $KeyFile -Raw).Trim()
    if ($k) { return $k }
  }
  throw "缺少 API Key：请设置环境变量 GRSAI_API_KEY，或把 key 写进 $KeyFile"
}

# 本地图过大时先缩小，避免请求体上兆
function ConvertTo-DataUrl {
  param([string]$path)
  if ($path -match '^https?://') { return $path }
  $p = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $root $path }
  if (-not (Test-Path -LiteralPath $p)) { throw "找不到参考图：$p" }
  $ext = [System.IO.Path]::GetExtension($p).ToLower()
  $m = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'image/png' }

  $bytes = [System.IO.File]::ReadAllBytes($p)
  if ($bytes.Length -gt 2MB) {
    try {
      Add-Type -AssemblyName System.Drawing
      $img = [System.Drawing.Image]::FromFile($p)
      $maxSide = 1280
      $scale = [Math]::Min(1.0, $maxSide / [Math]::Max($img.Width, $img.Height))
      $w = [int]($img.Width * $scale); $h = [int]($img.Height * $scale)
      $bmp = New-Object System.Drawing.Bitmap($w, $h)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($img, 0, 0, $w, $h)
      $g.Dispose(); $img.Dispose()
      $ms = New-Object System.IO.MemoryStream
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      $bytes = $ms.ToArray(); $ms.Dispose()
      $m = 'image/png'
      Write-Host "参考图较大，已缩到 ${w}x${h}"
    } catch {
      Write-Host "参考图缩小失败，按原图上传（$([math]::Round($bytes.Length/1MB,1)) MB）"
    }
  }
  return "data:$m;base64," + [Convert]::ToBase64String($bytes)
}

$key = Get-ApiKey
$base = $BaseUrl.TrimEnd('/')

function Invoke-CurlPost {
  param([string]$Url, [string]$Json)
  $f = Join-Path $env:TEMP ('grsai-body-' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($f, $Json, $utf8NoBom)
  $o = Join-Path $env:TEMP ('grsai-out-' + [guid]::NewGuid().ToString('N') + '.txt')
  & curl.exe -s --max-time $TimeoutSec -o $o -X POST $Url `
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "@$f"
  Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $o) -or (Get-Item -LiteralPath $o).Length -eq 0) {
    throw "接口没有返回内容（超时或网络不通）"
  }
  $text = Get-Content -LiteralPath $o -Raw -Encoding UTF8
  Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue
  return $text
}

$t0 = Get-Date
$useRef = ($Ref.Count -gt 0)

if ($useRef) {
  # ---------- 图生图：/v1/api/generate 异步 + /v1/api/result 轮询 ----------
  $images = @()
  foreach ($r in $Ref) { $images += (ConvertTo-DataUrl $r) }
  Write-Host "正在生成（参考图 $($images.Count) 张）：$Prompt"
  Write-Host "模型 $Model ／ 画幅 $Ratio"

  $payload = @{ model = $Model; prompt = $Prompt; aspectRatio = $Ratio; replyType = 'async'; images = $images }
  if ($Quality) { $payload['quality'] = $Quality }

  $resp = Invoke-CurlPost -Url "$base/v1/api/generate" -Json ($payload | ConvertTo-Json -Depth 4 -Compress)
  $job = $resp.Trim() | ConvertFrom-Json
  if (-not $job.id) { throw "提交失败：$resp" }
  $taskId = $job.id

  $final = $null
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $pjText = Invoke-CurlPost -Url "$base/v1/api/result" -Json (@{ id = $taskId } | ConvertTo-Json -Compress)
    $pj = $null
    try { $pj = $pjText.Trim() | ConvertFrom-Json } catch { continue }
    if ($pj.status -eq 'succeeded' -or $pj.status -eq 'failed') { $final = $pj; break }
  }
  if (-not $final) { throw "等待超时（${TimeoutSec}s），任务 id：$taskId" }
  if ($final.status -eq 'failed') { throw "生成失败：$($final.failure_reason) $($final.error)" }
  $url = @($final.results)[0].url
  if (-not $url) { throw "没有拿到图片地址：$($final | ConvertTo-Json -Compress)" }

} else {
  # ---------- 文生图：/v1/draw/completions 流式 ----------
  Write-Host "正在生成：$Prompt"
  Write-Host "模型 $Model ／ 画幅 $Ratio ／ 预计 30～120 秒"
  $payload = @{ model = $Model; prompt = $Prompt; aspectRatio = $Ratio }
  if ($Quality) { $payload['quality'] = $Quality }

  $text = Invoke-CurlPost -Url "$base/v1/draw/completions" -Json ($payload | ConvertTo-Json -Compress)
  $objects = @()
  foreach ($ln in ($text -split "`r?`n")) {
    $s = $ln.Trim()
    if ($s -match '^data:\s*(\{.*\})\s*$') {
      try { $objects += ($matches[1] | ConvertFrom-Json) } catch { }
    }
  }
  if ($objects.Count -eq 0) { throw "没解析到返回数据：$($text.Substring(0,[Math]::Min(300,$text.Length)))" }
  $last = $objects[-1]
  if ($last.status -eq 'failed') { throw "生成失败：$($last.failure_reason) $($last.error)" }
  $url = $null
  if ($last.results) { $url = @($last.results)[0].url }
  if (-not $url) { $url = $last.url }
  if (-not $url) { throw "没有拿到图片地址：$($last | ConvertTo-Json -Compress)" }
}

# ---------- 下载落盘 ----------
$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
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
  Write-Host "图片地址（下载失败，可手动打开）：$url"
  throw "下载图片失败"
}

$f = Get-Item -LiteralPath $path
Write-Host "完成，用时 ${secs}s"
Write-Host "已保存：$($f.FullName)  ($([math]::Round($f.Length / 1KB, 1)) KB)"
