# 04 · 为什么会卡，以及怎么把卡顿干掉

用户症状：修好之后整体「特别卡」，尤其**切窗口（焦点变化）**的时候。

## 卡顿的真正来源：ptrace 停进程，不是表达式慢

lldb 挂断点时停住的是**整个 WindowServer**（上百个线程：合成、渲染、
display link、事件分发）。每一次命中 = 停 → 跑 Python 回调 → 跑表达式 →
恢复，中间 CoreAnimation 的提交和 vsync 全部被推到后面。表达式快不快是次要的，
**暂停次数**才是主要成本。

实测一次菜单栏重建的断点命中数（来自 `/tmp/t26hook.log`）：

```
settle 那次：14 hits / 4 fix pass(es)   → 3.5 次/重建
fix    那次：22 hits / 6 fix pass(es)   → 3.7 次/重建
```

一次重建固定 1×`update_menu_bar_layers` + 3×`resize_one_pill`（每条 pill 一次，
两个显示器会更多）。焦点切换必然重建菜单栏（激活态、每个 App 的菜单都变），
所以切窗口时最卡。

## 测量记录

在 dummy（root 层是 `SLMenuBarOnScreenRootLayer`、挂 Backdrop+Text 两个子层）
上量的，同一套真代码路径：

| 做法 | 每次重建耗时 |
| --- | --- |
| 老的多次求值 walker（`_neutralize_tree`，逐层 eval） | **174 ms** |
| 单条大表达式（浅层：只 `setHidden`） | **10–11 ms** |
| 单条大表达式（deep：再加 4 个 setter） | **11–13 ms** |
| 真实 WindowServer 第一次 pass（lldb JIT 编译） | **256–268 ms** |
| 真实 WindowServer 之后每次 pass | **14–31 ms** |

`/tmp/t26hook.log` 里真实数据：

```
fix pass 1: neutralised 1 layer(s) under 0x600001b33080 in 256 ms
fix pass 2: neutralised 1 layer(s) under 0x600001bf3540 in 31 ms
fix pass 3: neutralised 1 layer(s) under 0x600001b33080 in 18 ms
```

第一刀特别慢是因为 lldb 要把表达式 JIT 编译进目标进程。

## 做过的优化

1. **把整个修复压成一条表达式**（`_fix_expr()`）：爬 root、扫两层、匹配名字、
   五个 setter、返回计数，全部一次 `EvaluateExpression` 完成。之前是每层一次
   eval，174 ms → 11 ms。
2. **`update_menu_bar_layers` 回调只立 flag**（`S.need_fix = True`）。它是按
   **显示器**调用的，如果在这里做手术，两个显示器就要做两遍。现在真正的 pass
   由下一次 `resize_one_pill` 触发，一次重建只做一次。
3. **删掉重复的爬升**：`_root_of` 已经折进 `_fix_expr` 了，但旧代码里 pill 回调
   还留着「爬 6 层 superlayer」的循环——每次命中白跑 6 次 eval，一重建就是 18 次
   多余的停进程。这是「还是特别卡」的直接原因之一，已删除。
4. **跳过已经藏好的层**：表达式里 `if (isHidden) m++; else {…}`，重复命中不再
   重复 set。
5. **命中上限不再停进程**：以前 `hits >= MAXHITS` 会 `return False` → 进程停在
   断点上直到脚本超时（桌面直接冻住）。现在改成打一行 `hit limit … reached —
   still fixing, logging muted` 然后继续干活；`fix`/`settle` 下 `MAXHITS` 直接
   拉到 1,000,000。
6. **日志收敛**：前 12 个 pass 每次都打，之后每 200 个打一次；`fix/settle` 不再
   挂 A/B/D/E 那些诊断断点（它们会命中全系统的 CALayer 属性 set）。
7. **最终解：`settle`**。修好之后 `breakpoint disable` + detach，之后
   **WindowServer 身上一个断点都没有**，零开销。这才是「不卡」的根本原因——
   不是把每次暂停变快，而是让暂停次数变成 0。

## 每个 pill 都修（settle 期间）

早期为了省停顿时只在**重建的第一次 pill** 上修（`need_fix` 门闩），结果第二块
显示器常常抓不到，或者被 WindowServer 在第一个 pill 之后重画回来。现在的策略是：

- `settle` 期间**每一次** `resize_one_pill` 都跑那条修复表达式（一次重建 3 次，
  每次 10–30 ms）——反正只是在「修好到撒手」这几秒里；
- 一旦「WindowServer 报告过的每块屏的 root 都至少被修过两次」，立刻
  `breakpoint disable` + detach，回到 0 停顿；
- `T26_SETTLE_MAX`（默认 60s）是兜底：等不到就带一行 WARNING 撒手，而不是
  永远挂着断点把机器拖卡。

## `settle` 为什么能撒手

WindowServer 每次重建都会把 backdrop 的 `hidden` 设回 `NO`，但**不会**恢复
`opacity` / `contents` / `filters` / `backgroundFilters`。深度中和之后这一层
既没有内容也没有滤镜、还是全透明，就算被设成可见也画不出玻璃。所以断点全禁用
之后菜单栏仍然是透明的（用户实测：「现在一切正常 现在不卡」）。

## 如果哪天 `settle` 撒手后玻璃回来了

说明这个系统版本的 WindowServer 连 `contents` 都会重画。那就退回 `fix`（常挂
断点，每次重建 ~10–30 ms），或者更进一步：用一次性诊断找出「谁把 backdrop 设回
`hidden:NO`」的调用点（`objc_msgSend$setHidden:` 的返回地址），直接在内存里把那
条指令改掉——一次性补丁，之后零开销，重启即恢复。
