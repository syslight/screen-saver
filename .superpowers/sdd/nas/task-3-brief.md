### Task 3: NasPhotoSource（WebDAV 封装）

**Files:**
- Modify: `pubspec.yaml`（dependencies 加 `webdav_client: ^1.2.2`）
- Create: `lib/services/nas_photo_source.dart`
- Test: `test/nas_photo_source_test.dart`（新建）

**Interfaces:**
- Consumes: `nasPhotoAllowed`（Task 2）、`PhotoService.imageExts`
- Produces（Task 4 依赖）:
  - `class NasPhotoRef { final String path; final int size; final DateTime? mtime; String get name; }`（path 为 WebDAV 远程路径）
  - `class NasPhotoSource { void configure({required String url, required String user, required String password, required String remoteDir}); Future<void> ping(); Future<List<NasPhotoRef>> listPhotos(); Future<void> downloadTo(String remotePath, String savePath); }`
  - 未 configure 或 remoteDir 为空时 `listPhotos()` 返回 `[]`

- [ ] **Step 1: 加依赖**：pubspec.yaml dependencies 加 `webdav_client: ^1.2.2`，`env -u ... /home/peidong/flutter/bin/flutter pub get`
- [ ] **Step 2: 写失败测试** `test/nas_photo_source_test.dart`：
  - 用 `dart:io HttpServer` 起假 WebDAV（参考 `test/control_server_test.dart` 起真实服务器的模式）：
    - PROPFIND（method='PROPFIND'）对 `/photo/` 返回 207 + multistatus XML：两个文件 `a.jpg`(1000B)、`b.png`(2000B)、一个子目录 `sub/`；对 `/photo/sub/` 返回 `Screenshot_1.png`(500B)、`c.jpg`(3000B)
    - GET `/photo/a.jpg` 返回 1000 字节
  - 用例：递归列出 3 张（a.jpg、b.png、c.jpg；Screenshot_1.png 被 nasPhotoAllowed 过滤——keywords 用默认）；downloadTo 写盘内容长度正确；401 响应时 ping 抛异常；未配置 remoteDir 时 listPhotos 返回空
  - multistatus XML 样例（放在测试文件里）：
    ```xml
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/photo/a.jpg</D:href><D:propstat><D:prop><D:getcontentlength>1000</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
    </D:multistatus>
    ```
  - 注意：先实际跑通一次假服务器+webdav_client 的解析（webdav_client 用 dio 发 PROPFIND），XML 细节以客户端真实能解析为准，可在实现时微调样例
- [ ] **Step 3: 跑测试确认失败** → 编译错误（类不存在）
- [ ] **Step 4: 实现** `nas_photo_source.dart`：
  - `configure` 里 `newClient(url, user: user, password: password)`，`setConnectTimeout(8000)`/`setReceiveTimeout(60000)`
  - `listPhotos`：递归 `readDir`（目录项 `isDir` 则递归，文件按 `PhotoService.imageExts` 扩展名 + `nasPhotoAllowed` 过滤），每文件构造 NasPhotoRef（size 来自 webdav File.size，mtime 来自 File.mTime）
  - `downloadTo`：`read2File(remotePath, savePath)`
  - 错误不内部吞掉（ping/listPhotos 抛出让调用方处理——Task 4 的降级逻辑负责捕获）
- [ ] **Step 5: 跑测试确认通过** + 全量回归

