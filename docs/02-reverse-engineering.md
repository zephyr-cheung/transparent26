# 02 · 逆向笔记：SkyLight / WindowServer 的菜单栏

环境：`macOS 26 (Tahoe)`，Apple Silicon（arm64e），`csrutil status` = disabled，
只有 Command Line Tools（无 Xcode）。下文的绝对地址都来自**本机这个 build**，
换系统版本必须重新解析（地址会变，函数名不会）。

## 1. 静态分析的天花板

```sh
nm -n /tmp/SkyLight.macho | wc -l      # → 0（导出符号表为空）
```

WindowServer 的菜单栏代码几乎全在 **SkyLight**（`/System/Library/PrivateFrameworks/
SkyLight.framework/Versions/A/SkyLight`，约 5.2 MB）里；真正的渲染核心在
CoreAnimation / QuartzCore。`update_menu_bar_layers`、`resize_one_pill` 这些
都是**局部符号**，文件里不导出，所以：

- `nm` 拿不到 → 必须**运行时**在 lldb 里 `image lookup -rn MenuBar` 找；
- `__cstring` 里的层名字符串（`SLMenuBarBackdropLayer` 等）**静态没有 xref**，
  因为 chained fixups 在加载时才回填指针。所以「按字符串找引用」这条路死了，
  只能在运行时看真实调用。

Mach-O 布局（本机）：

| 段 | 地址 / 大小 |
| --- | --- |
| `__TEXT` vmaddr | `0x185c06000` |
| `__text` | 起 `0x185c08cac`，size `0x3f1fcc` |
| `__cstring` | 起 `0x18602b360`，size `0x32e86`，文件偏移 `4346720` |

有符号的入口（运行时解析到的，本机带 ASLR 偏移前）：

| 符号 | 地址 | 备注 |
| --- | --- | --- |
| `update_menu_bar_layers` | `0x185d00674` | 每次菜单栏重建的核心函数 |
| `resize_one_pill` | 调用点 `0x185d00d84` / `0x185d0130c` / `0x185d0141c` | **进入层树的入口** |
| `objc_msgSend$updateLayer:key:rendererWork:` | `0x1860a7a40` | CoreUI 画材质，调用点 `0x185c8e400` / `0x185cffb84` / `~0x185d0139c` |
| `objc_msgSend$setHidden:` | `0x1860a5780` | 重建时把 backdrop 设回可见就是它 |
| `_sl_dlopen` | `0x185ffe5f8` | `update_menu_bar_layers` 里 dlopen CoreUI |

## 2. `update_menu_bar_layers` 干了什么

从反汇编（`/tmp/sl.asm`，`update_menu_bar_layers` 的 body 在第 253560 行左右，
47 MB 的 symbolised disassembly）读出来的调用图：

1. `_sl_dlopen("CoreUI")`，然后拿符号：
   `getkCUIWidgetKey`、`getkCUIBackdropCompatibleKey`、`getkCUIScaleKey`、
   `getkCUIPresentationStateKey`、`getkCUIBezelTintColor`；
2. 组一个 `CUIDescriptor` 字典（widget = menu bar，presentation state = 当前
   外观，bezel tint = 壁纸取色）；
3. `objc_msgSend$updateLayer:key:rendererWork:` 把材质画进某个 layer；
4. 调 `resize_one_pill` 摆放 pill；
5. 还有 `SLSLogBreak`、`CGXWindowGetOwner`、
   `PKGManagedMenuSpaceWalkMenuBarCompanionWindows` 之类。

也就是说：**玻璃是 CoreUI 画出来的，但决定「哪一层可见」的是 SkyLight**。
我们要干的是后者，不用碰前者。

## 3. 怎么在运行时定位层

```sh
sudo tools/ws-symbols.sh    # image lookup -rn MenuBar / Backdrop / pill
sudo tools/ws-disasm.sh     # disassemble -n update_menu_bar_layers / resize_one_pill
```

两者都只 attach、不修改任何东西，输出 `/tmp/t26-ws-{symbols,disasm}.log`。

`resize_one_pill` 的签名（从反汇编推出来的形状）：

```
resize_one_pill(space, CALayer *pill, CGRect, ...)   // pill 在 x2
```

`x2` 指向的层是 `SLMenuBarPill_*` 之一（或者它的父容器），从它往上爬 6 层就到
root。实测爬升次数 ≤ 6，且 root 的 `superlayer` 为 nil。

层树是用纯 ObjC 反射 dump 出来的（`libexec/t26/ws_hook.py` 里的 `_walk`）：
`-[CALayer sublayers]`、`-name`、`-isHidden`、`-filters`、
`-backgroundFilters`、`-compositingFilter`、`-className`。

## 4. 菜单栏层名清单

全部是**普通的 `CALayer`**（SkyLight 里没有 `SLMenuBar*Layer` 这个 ObjC 类，
名字只是 `setName:` 的字符串）——所以能在 ObjC 层操作它们：

```
SLMenuBarOnScreenRootLayer        SLMenuBarBackdropLayer
SLMenuBarEnhancementLayer         SLMenuBarAXBackstopLayer
SLMenuBarFSBackstopLayer          SLMenuBarSelectionPillContainer
SLMenuBarPill_1  SLMenuBarPill_2  SLMenuBarPill_StatusItem
SLMenuBarTextGroupLayer           SLMenuBarTextLayer
SLMenuBarAppleLogoLayer           SLMenuBarShadowLayer
```

这些名字在 `__cstring`（`0x18602b360` + 偏移）里能找到，但如 §1 所说静态没有
xref，所以只能运行时观察。

## 5. lldb 批量脚本的坑（踩过的）

- 批量模式下正确的导入方式：`script import resolve`，然后
  `script resolve.dump(lldb.debugger, '<addrs>')`；
- **用命名断点**（`-N t26pill`），不要用数字 id——lldb 会把一个名字拆成多个
  地址，编号会漂；
- `-n` 后面要么给完整名字，要么给不带签名的名字（`update_menu_bar_layers`），
  不能给带参数表的签名；
- 自动继续是 `breakpoint modify -G true`（不是 `-a`，`-a` 是"之后追加命令"）；
- 对 **void** 方法做 `(void)[obj setX]` 强制转换会让 lldb 假报
  `unknown error`（调用其实成功了）；用 `(int)[obj setX]` 或 `(id)` 包一层；
- Python 回调里返回 `False` **不会**停住进程（因为 `-G true` 会自动继续），
  要真停只能 `process interrupt` 或 `breakpoint disable`；
- Python 模块文件名**不能带横线**（`ws_hook.py`，不是 `ws-hook.py`）；
- **不要在 Python timer 线程里 detach**：那里 `lldb.debugger` 是 `None`。
  detach 交给 shell（FIFO `/tmp/t26-ctl`）做；
- `SBDebugger` 没有 `GetNumBreakpoints()`，要
  `GetSelectedTarget().GetNumBreakpoints()`；
- **表达式 JIT 的两个坑**（`EvaluateExpression` 里才这样）：
  - 取 `double` 返回值（如 `[(id)p opacity]`）拿到的是垃圾（`5.26e-315`），
    必须用 `(float)` 取；
  - `[(id)p contents] == 0` 这种「指针和字面量 0 比较」会被编错
    （`err=False val=None`），要写成
    `(unsigned long long)[(id)p contents] != 0`；
  - 换句话说：`setHidden:` / `setOpacity:0.0` 这些 **void 调用**是可靠的，
    读回值不可靠——所以「写」用一条表达式做完，验证另说。

## 6. 复现路径（换机 / 换版本）

1. `sudo tools/ws-symbols.sh` 确认 `update_menu_bar_layers`、`resize_one_pill`
   还在，记下新地址；
2. `sudo t26 tree` 看层树，确认 backdrop 层名字是否仍含
   `MenuBarBackdrop`，以及它是不是 root 的兄弟；
3. 名字变了就 `sudo t26 tree` 后设置
   `T26_PATTERN=<新名字>` 再跑 `settle`；
4. 如果 backdrop 不再是兄弟而变成父节点（文字在它里面），那 `setHidden:YES`
   会连文字一起藏掉——这种情况改用「只清 contents/filters、不设 hidden」，
   即 `T26_DEEP=0` + 只 `setContents:nil` 的组合，需要再验证。
