# 03 · 死路与「为什么不是那样」

按时间顺序记录被否掉的方案，附证据，避免以后重走。

## 1. `SLSSetMenuBarSystemOverrideAlpha` —— 会连文字一起淡出

```
SLSSetMenuBarSystemOverrideAlpha(cid, display, alpha, flags, animate)
// display 0 = 所有显示器；override 是 connection 作用域，进程退出即失效
```

`--alpha 0` 之后不是"玻璃没了"，而是**整条 bar 消失**：文字、图标、菜单项一起
变透明。原因很直白——这个 API 设置的是整条菜单栏（backdrop + content）的合成
alpha，没有单独的 backdrop 通道。这就是用户第一轮说「我的图标菜单都没了」的
原因。

`Sources/transparent26` 里那套 Swift 代码保留了这条路线，只用来临时淡出调试，
**不是**最终方案。

## 2. 注入 dylib —— AMFI/平台二进制，跟 SIP 无关

`Tweak/t26menuhook.m` + `tools/ws-inject.sh`（已验证不可行，已从仓库删除）是
原始设想：swizzle `-[CALayer setName:]`，在服务进程里改层。结果：

```
dlopen(...): code signature ... not valid for use in process:
mapping process is a platform binary, but mapped file is not
```

即使 `csrutil status` 是 disabled、dylib 已 ad-hoc 签名、编译了 arm64 + arm64e
两个 slice，也一样被拒。AMFI 的 platform-binary 规则不看 SIP 开关。

顺带的坑：

- 只编 arm64 会被 dyld 以 `missing compatible architecture ... need 'arm64e'` 拒绝；
- 用 lldb 表达式在目标里**构造 block IMP** 会踩 arm64e ptrauth：
  `EXC_BAD_ACCESS ... 0x20000001916c7da0`；
- 造出来的 arm64e 测试可执行文件会被内核直接 `Killed: 9`。

结论：**不加载任何代码**，只做断点 + 表达式手术。

## 3. `SLSTransactionSpaceRebuildMenuBar` —— 不是"重建"，是编码器

名字很诱人，但它第一个参数是 `SLSTransaction`（它会往事务里写 opcode 字节）。
拿 `CGSConnectionID` 去调 → `SIGBUS`。真正的"重建菜单栏"是让前台 App 变化：
脚本里用 `open -a Finder`（不用 `osascript`，避免 Automation/TCC 弹窗）。

## 4. `-[CALayer setName:]` / `CA::Layer::setter(attr=0x17c)` —— macOS 26 不这么命名

最早的观察是：`-[CALayer setName:]` 会汇入
`CA::Layer::setter(attr = 0x17c, type = 3)`（attr 0x17c 就是 "name"）。
这个漏斗是真的，但**在 macOS 26 上，画菜单栏的时候层名字并不是这时候设的**：
在两个断点上都挂了 25 秒（含强制 rebuild），菜单栏相关命中为 0。名字在层创建时
就带上了，之后重建只是改属性/内容。

所以 `probe` / `hunt` 模式里的 A、B 断点只用于诊断，`fix`/`settle` 不再挂它们
（它们会命中**全系统**每一个 CALayer 属性 set，是最大噪声源）。

## 5. CoreUI theme renderer —— 25 秒 0 命中

`objc_msgSend$updateLayer:key:rendererWork:`（`theme` 模式）是"真正画玻璃"的
地方，理论上把它的 key 换掉最优雅。实测在真实 WindowServer 上 25 秒 0 命中，
放弃。

## 6. 用表达式扫堆 / 静态找字符串引用 —— 都不成立

- 表达式里遍历堆找 `CALayer` 实例：太慢（每次都停住进程），且会因为访问已释放
  对象直接把 WindowServer 打死；
- 静态找 `SLMenuBar*Layer` 字符串的引用：chained fixups 让静态 xref 为空；
- `nm -n SkyLight.macho` 0 个符号；`SLMenuBar*Layer` 名字也没有被静态引用。

## 7. 用 `-a` 做自动继续 / 用数字编号引用断点

- `breakpoint modify -a` 是"之后追加命令"，不是 auto-continue，正确的是 `-G true`；
- 数字编号会因为一个符号被拆成多个 location 而漂移，必须用 `-N` 命名。

## 8. 只设 `hidden` 就够了？—— 不够

`fix` 模式下每个 pass 都打印 `neutralised 1 layer(s) ... (already hidden: 0)`，
说明 WindowServer 每次重建都把 `hidden` 设回 `NO`。于是 `settle` 里追加了
`opacity=0 / contents=nil / filters=nil / backgroundFilters=nil`，它不会复位这些，
才能做到"撒手之后仍然透明"。详见 [01](01-how-it-works.md)。
