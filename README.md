# dsh-grsai-image

调用 grsai 中转站 `gpt-image-2.5` 出图的命令行脚本（星鲸自用）。

## 快速开始

1. 把 API key 写进同目录的 `.grsai-key`（只要一行，不要加引号），或设置环境变量 `GRSAI_API_KEY`
2. 生成一张图：

```bat
生成图片.cmd "深海里的鲸鱼女仆，蓝长发，白蕾丝女仆装" -Ratio 2:3 -Out whale-maid.png
```

如果系统允许直接跑 PowerShell 脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File 生成图片.ps1 "提示词" -Ratio 1:1
```

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `-Prompt` | 提示词，必填 | — |
| `-Ratio` | 画幅：`1:1` `4:3` `3:4` `3:2` `2:3` `16:9` `9:16` | `1:1` |
| `-Model` | `gpt-image-2.5` / `gpt-image-2` | `gpt-image-2.5` |
| `-Out` | 输出文件名，统一落在 `gpt生成图片\` | 时间戳命名 |
| `-BaseUrl` | 中转站地址 | `https://grsai.dakka.com.cn` |

## 接口说明

- `POST /v1/draw/completions`，body：`{model, prompt, aspectRatio}`
- 响应是流式进度，最后一条 `status=succeeded`，图片地址在 `results[0].url`
- 流断了可 `POST /v1/draw/result`，body：`{id}` 轮询补取

## 注意

- 仓库里**不含任何密钥**，`.grsai-key` 请自行保管，勿提交
- `.ps1` 必须保存为 **UTF-8 with BOM**，否则 `powershell -File` 会按 ANSI 解码，中文变乱码并导致语法错误
- `.cmd` 里不要写中文（包括注释），否则 cmd 按 OEM 码页解析会报错
- 用 PowerShell 把中文 JSON 直接传给 `curl.exe` 会丢引号，必须写入文件后用 `-d @文件`