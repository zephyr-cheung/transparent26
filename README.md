# transparent26

macOS 26 (Tahoe) 的菜单栏**全透明**：去掉 Liquid Glass 背板，文字、图标、时钟、
状态项、pill、苹果 logo、阴影全部保留。

做法是在 WindowServer 内部做手术（lldb 断点 + 一条表达式），**不往进程里加载
任何代码**，所以 AMFI 的 platform-binary 限制拦不到；**不写任何磁盘状态**，
注销 / 重启即完全恢复。

```sh
cd ~/Desktop/Projects/transparent26

sudo tools/ws-layer.sh settle -s 40   # 或 make settle   ← 修好之后放开 WindowServer
tools/ws-layer.sh --status            # 看日志
```

`settle` 会挂上断点做几个 pass（这几秒会卡一下，正常），把菜单栏的 backdrop 层
中和掉，然后**把断点全部禁用并 detach**——之后 WindowServer 身上没有任何调试器，
跑满速，菜单栏依然是透明的。已在本机真实 WindowServer 上验证：玻璃消失、图标与
文字完整、切窗口不卡。

要求：**SIP 关闭**（`csrutil status` = disabled）+ 你自己执行 `sudo`。

## 文档

| 文件 | 内容 |
| --- | --- |
| [docs/01-how-it-works.md](docs/01-how-it-works.md) | 机制：层树结构、入口 `resize_one_pill`、为什么要「深度」中和、撤销方式 |
| [docs/02-reverse-engineering.md](docs/02-reverse-engineering.md) | 逆向笔记：SkyLight 地址、Mach-O 布局、函数调用图、lldb 批量脚本的坑 |
| [docs/03-dead-ends.md](docs/03-dead-ends.md) | 死路：alpha override、dylib 注入、`SLSTransactionSpaceRebuildMenuBar`、setName 漏斗、CoreUI renderer |
| [docs/04-performance.md](docs/04-performance.md) | 为什么卡（ptrace 停进程）、测量数据、优化过程、`settle` 为什么能撒手 |

## 命令

```sh
sudo tools/ws-layer.sh settle -s 40   # 推荐：中和一次后放开
sudo tools/ws-layer.sh fix -s 600     # 兜底：一直挂着断点，每次重建补一刀
sudo tools/ws-layer.sh tree -s 25     # 只 dump 活的菜单栏层树，不修改
sudo tools/ws-layer.sh probe          # 诊断：层命名管线
sudo tools/ws-layer.sh hunt           # 诊断：玻璃相关 render setter
sudo tools/ws-layer.sh theme          # 诊断：CoreUI 材质渲染
tools/ws-layer.sh --status            # 日志尾巴
```

环境变量：`T26_PATTERN`（层名子串，默认 `MenuBarBackdrop`）、`T26_MAXFIX`、
`T26_DEEP`（默认 1）、`T26_SETTLE_MIN`（默认 4）、`T26_SETTLE_MAX`（默认 60）、
`T26_MAXHITS`、`T26_LOG`、`T26_PID`。

### 不要 Ctrl-C

挂上 lldb 时 WindowServer 是被 ptrace 停住的，**SIGINT 会让 batch lldb 直接 kill
目标**，而目标是 WindowServer。要中止只能另开终端：

```sh
sudo sh -c 'echo "process interrupt" > /tmp/t26-ctl'
sudo sh -c 'echo "process detach"    > /tmp/t26-ctl'
```

### 撤销

注销或重启。磁盘上只多 `/tmp/t26hook.log` 之类的日志。

## 目录

```
Tweak/ws_hook.py        lldb Python 回调（断点逻辑、层树遍历、单表达式修复）
tools/ws-layer.sh       控制器：attach / 设断点 / 等 done / detach
tools/ws-symbols.sh     运行时符号探查（只读，输出 /tmp/t26-ws-symbols.log）
tools/ws-disasm.sh      update_menu_bar_layers 等函数的符号化反汇编
Sources/transparent26/  legacy 客户端工具（见下）
docs/                   逆向笔记
```

## legacy：客户端工具

```sh
make app
./bin/transparent26                     # 菜单栏 app（滑杆 + 预设）
./bin/transparent26 --alpha 0.0         # 一次性，淡出整条 bar
./bin/transparent26 --restore
./bin/transparent26 --status
```

走的是 SkyLight 的 `SLSSetMenuBarSystemOverrideAlpha(cid, display, alpha, flags,
animate)`（`display 0` = 所有显示器，override 是 connection 作用域，进程退出即
失效）。它会把**整条**菜单栏（背板 + 文字 + 图标）一起淡出，所以不是最终方案，
只适合临时淡出。原因见 [docs/03](docs/03-dead-ends.md)。

## 环境

macOS 26 / Apple Silicon（arm64e），Command Line Tools 即可，不需要 Xcode。
