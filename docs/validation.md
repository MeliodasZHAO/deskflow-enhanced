<!-- SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors -->
<!-- SPDX-License-Identifier: MIT -->

# 验证记录 · Validation

此版本以 Deskflow 上游 `c4eb0426f61e54278bf6d140411c5d218ea100e5` 为基线。2026 年 11 月的修改涉及连接界面、首次设置、配对、屏幕排列和共享核心的恢复。上游代码、构建说明及许可证随源码保留，公开历史从这一源码快照开始。

## 真机验证

| 验证项 | 结果 |
| --- | --- |
| Windows 键鼠 → Mac | 用户使用实际设备确认鼠标移动、单击、文本输入通过。 |
| Mac 核心仍在但失去响应 | 暂停共享子进程模拟卡死，约 19 秒内替换核心，自动恢复与 Windows 的连接和生效排列。 |
| 强制结束 Mac 界面进程 | 核心随界面退出。通过正常入口重新打开后，重新连接并恢复屏幕排列。 |
| 主动断开 | 观察约 26 秒，核心保持停止。手动连接后正常恢复。 |

以上实际使用方向为 Windows → Mac。反向物理输入、真实 Windows 重启与 Mac 内存压力同时发生的组合、全屏应用和系统安全输入场景尚待验证。系统内存压力的具体原因未确认。Linux 仍可使用手动连接，局域网自动发现的能力因平台而异。

## 自动测试和截图

- 已从公开快照重新构建 macOS 候选版界面、共享核心和中文资源。
- macOS 最终修订通过连接流程、共享核心生命周期、本地 IPC、客户端重试、身份校验、自动恢复和父进程退出 7 组相关回归测试。
- Windows 与 Linux 的普通构建测试来自两个最终恢复补丁之前的同一主体代码。Windows 实机使用兼容的控制端构建完成上述键鼠检查。
- README 截图由此源码的 Qt 界面生成，使用示例设备和独立配置。屏幕排列图展示兼容的整台电脑排列。

## 在本机运行测试

常规源码测试：

```sh
cmake -S . -B build-tests -DBUILD_TESTS=ON -DSKIP_BUILD_TESTS=ON -DBUILD_INSTALLER=OFF -DUPDATE_TRANSLATIONS=OFF
cmake --build build-tests --config Release --parallel 2
ctest --test-dir build-tests/src/unittests -C Release --output-on-failure
```

离线界面和连接流程测试：

```sh
cmake -S . -B build-lab -DDESKFLOW_LAB_BUILD=ON -DDESKFLOW_UI_REVIEW_BUILD=ON -DBUILD_TESTS=OFF -DBUILD_INSTALLER=OFF -DUPDATE_TRANSLATIONS=OFF
cmake --build build-lab --config Release --parallel 2
ctest --test-dir build-lab -C Release --output-on-failure
```

The final recovery changes were tested on macOS with a Windows controller. Simulated core suspension, abrupt GUI exit, and deliberate pause were exercised on the installed Mac build. Physical input was verified from Windows to Mac. The README uses offline application screenshots with demo devices.
