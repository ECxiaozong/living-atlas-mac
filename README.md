# Living Atlas for Mac

Living Atlas 把笔记、PDF 和围绕原文的问答放在一张可缩放的画布上。可以从选中的段落继续追问，再从回答回到当时引用的文档版本。项目保存在本机。

**[下载 macOS Beta · Apple Silicon（约 44 MiB）](https://github.com/ECxiaozong/living-atlas-mac/releases/download/v0.1.0-beta.1/Living-Atlas-0.1.0-beta.1-macOS-arm64.zip)** · [版本说明](https://github.com/ECxiaozong/living-atlas-mac/releases/tag/v0.1.0-beta.1)

## 首次打开

1. 下载上面的 ZIP，解压，把 **Living Atlas.app** 拖进「应用程序」，双击打开。
2. 按 **⌘N** 新建项目，或按 **⌘O** 打开已有项目文件夹。
3. 需要 AI 问答或整理时，按 **⌘,** 打开模型设置，连接已登录的本机 Codex CLI，或填写自己的服务地址和 API 密钥。本机检索可以离线使用。

此 Beta 为 Apple Silicon（arm64）构建，部署目标为 macOS 14，已在 macOS 27.2.1 实测。安装包使用本机签名，未经 Apple 公证。如果首次打开时提示无法验证开发者，请先确认下载来自本仓库；信任此版本时，可在「系统设置 → 隐私与安全性」中对这个 App 选择「仍要打开」。[Apple 的首次打开说明](https://support.apple.com/zh-cn/102445)

## 从源码构建

在 Mac 上安装包含 Swift 6.1 或更新版本的 Xcode 或命令行工具。在仓库根目录执行以下命令。首次构建会下载锁定版本的 GRDB。

```sh
./Tools/构建应用.sh
open 'dist/Living Atlas.app'
```

运行随源码提供的请求构造和传输测试：

```sh
./Tools/运行测试.sh -c release
```

应用使用的字体、Markdown 渲染库和本机中文检索模型的许可随对应资源提供。
