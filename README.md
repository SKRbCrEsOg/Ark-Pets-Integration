# ArkPets 桌面集成

ArkPets 的桌面集成，为 ArkPets 提供了查询，控制窗口之类的接口。

目前包含以下内容：

* GNOME 集成扩展
* KWin 集成插件
* Rust Bootstrapper

## 安装

### KDE / KWin

1. 将预编译的 `ArkPetsIntegration2.so` 复制到 Qt 插件目录：

   ```bash
   sudo cp ArkPetsIntegration2.so "$(qtpaths6 --query QT_INSTALL_PLUGINS)/kwin/plugins/"
   ```

2. 注销并重新登录（或重启）一次，使 KWin 加载插件；ArkPets 启动时也会自动启用该插件。
3. 插件需与运行中的 KWin 版本 ABI 匹配（当前基于 Debian 13 / KWin 6.3.6 构建）。
4. 从源码构建见 [KWin/README.md](KWin/README.md)，依赖 `kwin-dev`、`extra-cmake-modules`、`cmake`、`qt6-base-dev`。
