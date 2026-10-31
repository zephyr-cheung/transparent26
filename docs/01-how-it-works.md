# 01 · 它是怎么工作的

目标：让 macOS 26 (Tahoe) 的菜单栏**去掉 Liquid Glass 背板**，但文字、图标、
时钟、状态项、pill、苹果 logo、阴影全部保留。上一版用
`SLSSetMenuBarSystemOverrideAlpha(alpha=0)` 把整个 bar 一起淡出，菜单项直接
消失，所以那条路被否掉了（见 [03-dead-ends](03-dead-ends.md)）。

## 结论先行

菜单栏的玻璃是一层 **`CALayer`，名字里带 `MenuBarBackdrop`**，而且它是
文字层/图标层/阴影层/pill 层的**兄弟节点**，不是父亲。所以只要把这一层做掉，
玻璃消失，其它一切不动。

```
root                                   (SLMenuBarOnScreenRootLayer，无名字)
├─ SLMenuBarBackdropLayer              ← 玻璃本体（要干掉的就是它）
│    └─ SLMenuBarEnhancementLayer       cf=darkenBlendMode
├─ SLMenuBarAXBackstopLayer   hidden
├─ SLMenuBarFSBackstopLayer   hidden
├─ SLMenuBarSelectionPillContainer  hidden
│    ├─ SLMenuBarPill_1 / _2 / _StatusItem
│         └─ (unnamed) → CUIMenuBarSelectionLayer → Active
│              cf=plusL / brighten
└─ SLMenuBarTextGroupLayer
     ├─ SLMenuBarTextLayer
     ├─ SLMenuBarAppleLogoLayer
     └─ SLMenuBarShadowLayer    fl=(gaussianBlur) cf=vibrantLightSourceOver
```

这份 dump 是 `sudo t26 tree` 在真实 WindowServer 上跑出来
的，不是猜的。

## 为什么不能注入 dylib

WindowServer 是 platform binary，AMFI 会拒绝 map 任何非 Apple 的 image，
和 SIP 开关无关：

```
dlopen(...): code signature ... not valid for use in process:
mapping process is a platform binary, but mapped file is not
```

但**调试是允许的**：lldb 可以停住进程、读参数、跑表达式、调用真实函数。
所以整个方案是「断点 + 表达式手术」，一行代码也没有被 load 进去。

## 唯一的入口：`resize_one_pill`

`update_menu_bar_layers()` 每次重建菜单栏都会调用
`resize_one_pill(...)`，它的第二个参数（arm64 的 `x2`）就是一个活的
`CALayer`，位于真实菜单栏层树里。

流程（全在一条 lldb 表达式里完成，见下）：

1. 从 `x2` 往上爬最多 6 层 `superlayer`，拿到 bar 的 root；
2. 扫 root 的子层（以及再下一层），对 `[name containsString:@"MenuBarBackdrop"]`
   的层：
   - `setHidden:YES`
   - `setOpacity:0.0`
   - `setContents:nil`
   - `setFilters:nil`
   - `setBackgroundFilters:nil`
   - 以及**它的子层**（`SLMenuBarEnhancementLayer`，`cf=darkenBlendMode`）同样
     藏掉、清空——某些显示器上，父层空了之后仍然是这个子层在画那层玻璃
3. 返回 `新藏掉的层数 * 1000 + 本来就已经藏着的层数`。

名字不匹配的层（文字、logo、阴影、pill）一个字节都不碰。

## 为什么要「深度」中和

日志证据：每个 pass 都是 `already hidden: 0`，也就是 **WindowServer 每次重建
都会把 `hidden` 重新设回 `NO`**（同一个 layer 指针 `0x600001b33080` 被反复
藏）。只设 `hidden` 的话，一停断点玻璃就回来了。

但 `opacity=0` / `contents=nil` / `filters=nil` 它不会复位。所以：

- `hidden` 被复位也没关系，层已经没有内容、没有滤镜、完全透明，画不出东西；
- 于是修好之后可以**把断点全部 disable、让调试器退出**，WindowServer 全速跑，
  菜单栏依然是透明的。

这就是 `settle` 模式，也是目前验证过「不卡 + 一直透明」的用法。

注意一个坑（双屏踩到的）：`settle` 曾经在「4 个 pass + 3 秒」之后就撒手，结果
第二块屏的 bar 只被修过**一次**就没人管了，重建之后又变成磨砂。现在 `settle`
的退出条件是「**WindowServer 报告过的每一块显示器的 root 都至少被修过两次**」，
或者等满 `T26_SETTLE_MAX`（默认 60s）后带警告退出。改完之后双屏实测
`2/2 display(s) confirmed`，撒手后两块屏都稳定透明。

## 用法

```sh
make && sudo make install   # 只需一次

sudo t26 settle             # 修好就撒手（推荐）
sudo t26 fix -s 600         # 一直挂着断点（调试用，会掉帧）
sudo t26 tree               # 看一眼真实层树
t26 status                  # 上次跑了什么、成没成
```

`settle` 会先挂断点做几个 pass（这几秒会卡，正常），然后
`breakpoint disable`，脚本 detach 退出。之后零开销。

模式：

| 模式 | 作用 |
| --- | --- |
| `settle` | 中和 + 丢掉断点，之后无调试器（默认推荐） |
| `fix` | 常挂断点，每次重建补一刀（回退方案） |
| `tree` | 打印活的菜单栏层树，不改任何东西 |
| `probe` / `hunt` / `theme` | 纯诊断，详见 [02](02-reverse-engineering.md) |

CLI 是唯一入口：`-s/--seconds`、`--pattern`、`--shallow`、`--settle-min`、
`--settle-max`、`--pid`、`--log` 会被翻译成下面这些引擎环境变量（手工调引擎时
也可以直接设）。

环境变量：`T26_MODE` `T26_PATTERN`（默认 `MenuBarBackdrop`）`T26_MAXFIX`
（`fix` 下默认 0 = 不停）`T26_MAXHITS`（`fix/settle` 默认 1000000）
`T26_DEEP`（默认 1，可关掉深度中和）`T26_SETTLE_MIN`（默认 4s，最早撒手时间）
`T26_SETTLE_MAX`（默认 60s，等不到「每块屏都确认」就带警告撒手）
`T26_TREECAP` `T26_LOG` `T26_PID`。

## 撤销

不需要任何持久化清理：

- `settle` 之后想恢复：注销 / 重启（WindowServer 重启，一切复原）；
- 或者直接再跑一次 `sudo t26 fix -s 5` 后手动把层
  `setHidden:NO`……没必要，重启最干净。

磁盘上只多了 `/tmp/*.log`。

## 安全红线

挂上 lldb 的时候 WindowServer 是**被 ptrace 停住**的。**绝对不要 Ctrl-C 这个
脚本**：SIGINT 会让 batch lldb 直接 **kill 目标**，而目标是 WindowServer。
要中止只能另开一个终端：

```sh
sudo sh -c 'echo "process interrupt" > /tmp/t26-ctl'
sudo sh -c 'echo "process detach"    > /tmp/t26-ctl'
```
