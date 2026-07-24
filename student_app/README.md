# 家庭学习助手（Android 学生端）

独立 Flutter Android App。平板通过家长生成的一次性码固定绑定一个孩子，只能查看、开始和
提交该孩子的作业，并查看家长给出的审核摘要；不能读取参考答案、评分标准或其他家庭成员数据。

## 开发与构建

```bash
/home/peidong/flutter/bin/flutter pub get
/home/peidong/flutter/bin/flutter analyze
/home/peidong/flutter/bin/flutter test
/home/peidong/flutter/bin/flutter build apk --debug
```

APK：`build/app/outputs/flutter-apk/app-debug.apk`。最低 Android 6.0（API 23）。应用需要网络和
相机权限；设备 key 使用 Android Keystore 支持的安全存储，应用数据备份已禁用。

## 联调

1. 服务器执行 `HOME_AGENT_HOST=0.0.0.0 uv run home-agent`。
2. 平板与服务器连接同一可信家庭 Wi-Fi，不要映射 8790 到公网。
3. 家长访问 `http://<服务器IP>:8790/parent/`，录入孩子并在“学生平板”生成一次性码。
4. 平板填写 `<服务器IP>:8790`、配对码和设备名称。
5. 家长布置任务后，学生端下拉刷新，开始任务并拍照提交。

当前允许 cleartext HTTP 只是家庭局域网原型决策；远程访问前必须给 Home Agent 配置 HTTPS。
