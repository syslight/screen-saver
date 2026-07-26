# 授权音乐库

相册主乐库使用真实录制、明确授权的音乐，不从抖音、Bilibili、YouTube 普通视频抓取或提取音频。普通平台视频只有在内容属于用户本人，或权利人明确授权下载及在本项目使用时，才能进入曲库。

## 当前首批曲库

当前家庭 `home_agent` 服务器安装 12 首 Scott Buckley 的 MP3，每个情境 2 首：

| 情境 | 曲目 |
|---|---|
| 温暖日常 | Amberlight、Simplicity |
| 童年成长 | Childhood、Wonderful |
| 旅行远方 | Journeys、Soar |
| 岁月回忆 | Moonlight、With These Hands |
| 欢乐相聚 | Happiness、Tomorrow |
| 宁静风景 | Sleep、First Snow |

这些曲目均从作者官网的曲目页下载，遵循 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。作者的[使用说明](https://www.scottbuckley.com.au/library/using-this-music/)允许在项目中使用和改编，但必须署名，且不能把音乐作为独立商品转售或重新上传到流媒体平台。完整曲目来源和下载地址记录在 `tool/licensed_music_catalog.json`。

## 安装与更新

在运行 `home_agent` 的服务器上运行：

```bash
python3 tool/install_licensed_music.py \
  "$HOME/.local/share/family-home-agent/music"
```

安装器要求显式绝对路径，只新增或替换清单中的歌曲，不删除用户自己的音乐，并在目标目录写入 `ATTRIBUTION.txt`。服务端按 `warm`、`childhood`、`journey`、`memory`、`celebration`、`calm` 子目录识别情境并为设备选曲。曲库缺失时返回无曲目，display 保持静音，不进行本地合成。

## 后续在线搜索规则

- Agent 可以搜索曲目和推荐情境，但只有 CC0、Public Domain、CC BY 或已购买适用许可证的源文件可自动入库。
- 每首歌必须保存曲名、作者、来源页、源文件地址、许可证和署名文本。
- 不使用 `yt-dlp` 等工具绕过平台限制；用户自己的视频或权利人明确授权的链接可以走单独的“用户授权导入”流程。
- 原始曲库只保存在服务端；display 仅缓存服务端已选中的播放文件。
