# dsh-grsai-image

调用 grsai 中转站 `gpt-image-2.5` 出图的命令行脚本（星鲸自用），支持**文生图**和**图生图（参考图）**。

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

## 图生图（带参考图）

```bat
生成图片.cmd "让她坐在雪天长椅上，围着红色围巾" -Ref "立绘.png" -Ratio 2:3
生成图片.cmd "换成水彩风格" -Ref "a.png","b.png" -Out merge.png
```

- `-Ref` 可给多张：本地路径或 `http(s)` 链接，相对路径按脚本目录解析
- 本地图超过 2MB 会自动缩到最长边 1280，避免请求体过大
- 实测能稳定保住参考图的角色：脸型、发色、鳍耳、服装、尾巴

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `-Prompt` | 提示词，必填 | — |
| `-Ref` | 参考图，可多个 | 无（纯文生图） |
| `-Ratio` | `1:1` `4:3` `3:4` `3:2` `2:3` `16:9` `9:16` | `1:1` |
| `-Model` | `gpt-image-2.5` / `gpt-image-2` | `gpt-image-2.5` |
| `-Quality` | `low` / `medium` / `high` | 不传 |
| `-Out` | 输出文件名，统一落在 `gpt生成图片\` | 时间戳命名 |
| `-BaseUrl` | 中转站地址 | `https://grsai.dakka.com.cn` |

## 接口说明

这套中转站有**两个**不同形态的接口，别用错：

| 用途 | 端点 | 形态 | 关键字段 |
|---|---|---|---|
| 文生图 | `/v1/draw/completions` | 流式，最后一条带 `results[0].url` | `model` `prompt` `aspectRatio` |
| 图生图 | `/v1/api/generate` → `/v1/api/result` | 异步，返回 `id` 后轮询 | + `images`（数组，data URL 或链接）、`replyType:"async"` |

坑：`/v1/draw/completions` **不接受**参考图，传了 `images` 也会被忽略，模型会回一句「请上传原图」。

## 注意

- 仓库里**不含任何密钥**，`.grsai-key` 请自行保管，勿提交
- `.ps1` 必须保存为 **UTF-8 with BOM**，否则 `powershell -File` 会按 ANSI 解码，中文变乱码并导致语法错误
- `.cmd` 里不要写中文（包括注释），否则 cmd 按 OEM 码页解析会报错
- 用 PowerShell 把中文 JSON 直接传给 `curl.exe` 会丢引号，必须写入文件后用 `-d @文件`