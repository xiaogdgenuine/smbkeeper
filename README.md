# SMBKeep —— 一个保持常连的 SMB 文件系统

SMBKeep 是一个基于 Apple [FSKit](https://developer.apple.com/documentation/fskit) 框架实现的用户态 SMB 文件系统，目标是替代 macOS Finder 默认的 SMB 连接体验，让网络卷"挂上去就一直在"。

## 这个项目想解决什么

macOS 自带的 SMB 挂载在日常使用中有不少痛点：合盖休眠、切换网络、服务器短暂掉线之后，Finder 经常弹出"服务器连接已断开"的烦人提示，卷也需要手动重新连接。SMBKeep 把 SMB 客户端做进一个 FSKit 文件系统扩展里，自己管理连接和重连，尽量做到"无感保活"。

### 主要特性

- **替代 Finder 默认的 SMB 连接**：用自己的 FSKit 扩展挂载 SMB 共享，而不是依赖系统内置的 SMB 客户端。
- **开机自动挂载所有卷**：登录后自动把已保存的所有连接挂载好，无需手动操作。
- **自动重连 SMB 服务器**：连接中断后在后台自动恢复；即使笔记本合盖再打开，也不会再被"服务器已断开"的弹窗打扰。
- **凭据安全存储**：服务器密码保存在 macOS Keychain 中，仓库与配置文件里都没有明文凭据。

## 关于代码质量的说明

> 这个项目绝大部分代码都是由 AI "Vibe Coding" 生成的。

因此它**几乎肯定存在 bug**，不建议直接当作生产级软件依赖。它的主要价值在于作为一个**FSKit 的实用示例**——展示如何用 FSKit 实现一个真正能用、能挂载远程网络卷、并自行处理连接生命周期的文件系统，而不仅仅是官方文档里的最小 demo。

如果你正在研究 FSKit，希望它能帮你少走一些弯路。

## 开发与调试经验

在开发 FSKit 扩展的过程中，有几条命令和注意事项非常关键，记录在此供后来者参考。

### 刷新 FSKit 相关缓存

修改并重新构建文件系统扩展后，系统往往仍在使用旧的已注册版本，导致行为不符合预期（例如改了代码却没生效、挂载失败、扩展不被识别等）。这时可以重启 FSKit 相关的守护进程来强制刷新：

```bash
sudo killall pkd fskitd fskit_agent
```

- `pkd`：插件注册守护进程（PlugInKit daemon），负责发现和注册 App Extension。
- `fskitd` / `fskit_agent`：FSKit 的系统服务，管理文件系统模块的加载与挂载。

杀掉后系统会自动重启它们，从而重新扫描并加载最新构建的扩展。

### 重置 App 的用户授权（TCC）

调试涉及隐私权限（如完全磁盘访问、网络等）时，授权状态会被系统缓存。如果想从"干净状态"重新测试授权弹窗与流程，可以重置该 App 的所有 TCC 授权记录：

```bash
tccutil reset All <bundleID>
# 例如：
tccutil reset All com.example.apple-samplecode.SMBKeep
```

之后再次运行 App，系统会像首次安装一样重新请求相关权限。

### 打包（Archive / 导出）时的扩展冲突 ⚠️

这是一个很容易踩的坑：当你执行 **Archive** 时，生成的归档里包含了文件系统扩展（Extension），而 macOS 的 **LaunchServices 会扫描并识别归档内的这个 Extension**。这会和你最终导出的正式 App 包里的同一个 Extension 产生**注册冲突**，表现为扩展行为异常、挂载失败、或系统加载了错误版本的扩展。

建议的处理方式：

1. Archive 并导出 App 之后，**立即删除 Archive 归档**，确保系统里不残留被 LaunchServices 识别到的重复 Extension。
2. 在 Xcode 中 **清空 Build（Clean Build Folder，⇧⌘K）**，并清理 DerivedData，保证下一次构建是干净环境。
3. 如有必要，配合上面的 `sudo killall pkd fskitd fskit_agent` 重新刷新扩展注册。

保持"系统中同一时刻只有一份该 Extension 被注册"，是避免这类诡异问题的关键。

## 致谢与许可

- SMB 协议底层基于 [AMSMB2](deps/AMSMB2) / [libsmb2](deps/AMSMB2/Dependencies/libsmb2)。
- 本项目结构参考自 Apple 官方示例 [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)。
- 许可信息见 [LICENSE.txt](LICENSE.txt)。
