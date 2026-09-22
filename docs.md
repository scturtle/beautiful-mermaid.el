# beautiful-mermaid.el — 单文件 Emacs Lisp 移植方案

> 目标:把 [beautiful-mermaid](https://github.com/lukilabs/beautiful-mermaid) 的
> ASCII/Unicode 渲染器移植成**单个 `.el` 文件**,支持 `graph` 流程图、
> Unicode 框线、纯文本(终端)输出,无主题、无颜色。
> 本包布局:`beautiful-mermaid.el`(实现,约 1900 行,零依赖,Emacs 26.1+)、
> `beautiful-mermaid-test.el`(55 个 E2E 测试)、本设计文档。

---

## 1. 范围决策:保留什么,裁剪什么

原 TS 版渲染管线支持 6 种图、15 套主题、ANSI 颜色、子图、样式指令……
单文件 Elisp 版按"最小可用但质量不降级"原则取舍:

| 能力 | 决策 | 理由 |
|---|---|---|
| `graph`/`flowchart` TD/TB/LR/BT/RL | ✅ 保留 | 核心需求 |
| 全部 12 种节点形状 | ✅ 保留 | 全部都是"盒子 + 特殊角字符",只差一张查找表,成本极低 |
| 边样式 solid/dotted/thick、开线 `---` | ✅ 保留 | 只是换线字符(`─│` / `.:` / `═║`) |
| 边标签、`-- 文字 -->`、双向箭头、链式、`A & B --> C & D`、自环、回边 | ✅ 保留 | 解析器 + A* 天然支持 |
| **边捆绑**(fan-in/fan-out 合并走线) | ✅ 保留(分析后决定) | 平行结构太常见,不捆绑会从侧面绕路、箭头侧入,质量明显下降;逻辑其实只有 ~150 行 |
| 多行标签(`<br>`) | ✅ 保留 | 解析时替换为 `\n`,绘制时按行居中 |
| CJK 对齐 | ✅ **修正**(优于 TS) | TS 用 UTF-16 `length` 量宽,CJK 标签错位;Elisp 用 `string-width` 按显示列计算并绘制 |
| `stateDiagram`/`sequence`/`class`/`er`/`xychart` | ❌ 报错 | 各需独立布局器(列布局/UML 分区/坐标轴),超出最小范围 |
| subgraph、`classDef`/`style`/`linkStyle` | ❌ 静默忽略 | 子图需要整套包围盒逻辑;样式在纯文本下无意义。这些行被"解析并忽略"而不是报错,共享源码仍可渲染 |
| ANSI 颜色 / role canvas / 主题 | ❌ 裁剪 | 终端纯文本输出 |
| SVG 渲染、ELK 布局引擎 | ❌ 不涉及 | 另一条独立管线,依赖 ELK.js |

---

## 2. 原 TS 版架构 → Elisp 映射

ASCII 渲染管线(TS 源码 ~3000 行,分散在 `src/parser.ts` + `src/ascii/` 15 个文件):

```
parseMermaid          正则行解析 → MermaidGraph
convertToAsciiGraph   → AsciiGraph(无子图时退化为直接映射)
createMapping         网格布局:根节点放置 → 逐层放子节点
                      → 列宽/行高 → 边捆绑分析 → A* 路由 → 标签定位
                      → 网格坐标→字符坐标
drawGraph             分层绘制:盒子 → 线 → 角 → 箭头 → 盒起点 → 标签
canvasToString        行主序拼接(BT 方向再整体垂直翻转)
```

单文件化的函数映射(`bm--` 为内部前缀):

| TS 模块 | Elisp 函数 | 说明 |
|---|---|---|
| `parser.ts` | `bm--parse` + `bm--parse-edge-line` + `bm--consume-node(-group)` | 逐行正则;形状模式按"最长定界符优先"排序尝试 |
| `converter.ts` | (内联) | 无子图/样式时就是直通映射 |
| `grid.ts` | `bm--layout`, `bm--reserve`, `bm--set-col-width`, `bm--grid->drawing` | 布局编排 |
| `pathfinder.ts` | `bm--astar`, `bm--heap-create`, `bm--merge-path` | 二叉堆闭包 + 拐角惩罚启发式 |
| `edge-routing.ts` | `bm--determine-path`, `bm--start-and-end-dirs`, `bm--determine-label-line` | 起止方向选择表完整移植 |
| `edge-bundling.ts` | `bm--analyze-bundles`, `bm--process-bundles` | 仅 TD 方向生效(与 TS 一致) |
| `shapes/*` | `bm--shape-frame`, `bm--shape-grid-dims` | 只需角字符表 + 3 个特例尺寸 |
| `draw.ts` | `bm--draw-graph` + 8 个分层绘制函数 | 层序与 TS 完全一致 |
| `canvas.ts` | `bm--canvas-put`, `bm--canvas-to-string`, `bm--flip-canvas` | 哈希画布 + 合并语义 |

**数据结构选择**:

- **节点/边/图**:`cl-defstruct` 向量结构体(快、可 `setf` 原地改)。
- **网格占用 / 列宽 / 行高 / 画布**:全是哈希表 —— 键 `(x . y)`(cons,`equal` 测试)
  或整数索引,天然支持稀疏、负坐标无关(布局只产生非负坐标)。
  TS 的列主序 `canvas[x][y]` 二维数组被彻底替换,**canvas 大小不再需要预先确定**,
  也不需要 `increaseSize`/`mergeCanvases` 的搬运逻辑。
- **节点插入顺序**:哈希表不保证迭代顺序,所以 `graph-nodes` 单独维护有序列表
  (根节点检测与文档顺序相关)。

---

## 3. 关键算法(与 TS 语义逐条对齐)

### 3.1 网格布局:3×3 块模型

- 每个节点在**逻辑网格**上占一个 3×3 块:列 `[边框, 内容, 边框]`,
  行同理。块与块之间由"填充列/行"(`bm-padding-x/y`,默认 5)隔开。
- **根节点** = 文档顺序中首次出现且此前未作为任何边终点的节点;放在第 0 层,
  位置指针每次 +4(3 格块 + 1 格间距)。
- 子节点逐层放置:`childLevel = parent ± 4`,同层用 `hppl` 哈希表记录
  "该层下一个空位";**多轮扫描**直到所有节点落位(容忍任意声明顺序)。
- 冲突时按垂直于主流方向 +4 平移重试(`bm--reserve`)。
- 列宽/行高取同列所有节点的最大值——所以**同一列的盒子会拉伸到等宽**,
  这是 TS 输出的显著特征(`simpleTD` 中 Start/Process/End 同宽)。
- 3 个形状有特例尺寸(TS `getDimensions` 的差异):`subroutine`/`stadium`
  边框列宽为 2(容纳 `╠╣` / `( )` 角),`cylinder` 边框行高为 2(容纳圆弧顶底)。

### 3.2 网格坐标 → 字符坐标

```
drawing(x,y) = Σ colWidth[0..x-1] + ⌊colWidth[x]/2⌋    (行同理)
```

即"单元格中心"。节点盒子左上角 = 其 3×3 块左上格的中心;块内 8 个方向常量
(`bm--up = (1 . 0)` 等,块内偏移而非单位向量)用于选取**附件点**——
恰好落在盒子边框的中点。两张关键表:

- `bm--start-and-end-dirs`:按 from/to 相对方向(8 向)× 图方向(TD/LR)
  给出"首选/备选"起止附件方向,A* 各跑一次取短者。
- 边线绘制时首尾各让 1 格(`offset 1, -1`),于是:
  盒起点字符(`┬┴├┤`)画在源盒子边框上、箭头画在目标边框外 1 格、
  拐角画在中间弯点——三层字符互不覆盖,这正是 TS 分层绘制的意义。

### 3.3 A* 寻路

- 4 向移动(**单位向量**,与块内方向常量是两套东西——这是移植时最容易踩的坑),
  目标格即使被占用也可进入(它就是目标块的边框格)。
- 启发式 = 曼哈顿距离 + 1(双轴非零时),**偏好直线**。
- 优先队列:closure 捕获的可增长向量二叉堆(`bm--heap-create` 返回 push/pop 闭包对)。
- `bm--merge-path` 折叠共线中间点,减少绘制段数。
- 双路径(首选+备选)都失败时退化为两点直连,保证箭头总有落点。

### 3.4 交叉线合并(junction merging)

两条边交叉在同一格:先画的 `─` 与后画的 `│` 合成 `┼`。TS 用 10×9 的查表;
Elisp 版改成**位掩码并集**——每个框线字符代表一组连接方向
(`左=1 上=2 右=4 下=8`,如 `┌`=下|右=12),合并 = `logior` 后反查。
数学上可证明与 TS 的 90 项查表在所有可达输入上等价,代码只有 ~20 行。
另外附加一条 TS 没有的小改进:`═`×`║`(两条粗线交叉)合并为 `╬`。

### 3.5 边捆绑(平行链路)

`analyzeEdgeBundles` 仅在 **TD** 方向生效(LR 下拐角自然合并,与 TS 一致):

- **fan-in**(多源同汇,如 `B --> D & C --> D`):汇合点放在目标块上方 1 格,
  各源 → 汇合点单独 A*,汇合点 → 目标共享一段 + 单个箭头。
- **fan-out**(同源多汇,如 `A --> B & C`):分裂点放在源块下方 1 格。
- 成束条件:≥2 条边、同线型、无标签、非自环(无子图时 TS 的子图检查恒真)。
- 汇合/分裂点按"实际连接方向集合"选字符(`┼┬┴├┤`…),逐方向分析后查表。
- 绘制分层:每条边画自己的段;共享段、汇合字符、fan-in 箭头只在
  **束的首边**(等于首次在边序中遇到)画一次。

### 3.6 BT 方向 = TD 布局 + 整幅翻转

`RL` 按 TS 处理为 LR;`BT` 先按 TD 走完整管线,最后把画布按行翻转并
重映射有向字符(`↑↔↓`、`┌↔└`、`┐↔┘`、`┬↔┴`、`╔↔╚`、`↖↔↙` 等)。

### 3.7 CJK 宽字符(对 TS 的修正)

- **量宽**:`string-width`(显示列)而非 codepoint 数 → 盒子按显示宽度开。
- **绘制**:逐字符推进 `string-width` 步;宽字符把覆盖到的画布单元标记为
  `bm--wide-marker`,序列化时**跳过**这些单元——宽字形在终端天然占两列,
  输出字符串中相邻排布即可连续显示,右边框精确对齐:
  ```
  ┌──────┐     ┌──────────┐
  │ 开始 ├────→│ 处理过程 │
  └──────┘     └──────────┘
  ```

---

## 4. 字符集策略:`safe` / `full` 双档案

约束(来自 `unicode.txt`,受限字体覆盖表):绘图字符尽量只用表内 166 个码点。
表内可用:单线框全套、双线框全套(`╔╗╚╝═║╠╣╦╩╬`)、细箭头
`←↑→↓↖↗↘↙`、实心三角 `▲▼◀▶`、`◊◌╱╲▷`;表外:`╭╮╰╯ ┄┆ ━┃ ►◄ ◤◥◣◢ ◇◯◎ ╟╢ ⌜⌝⌞⌟`。

`bm-char-profile` 两个取值:

| 元素 | `safe`(默认) | `full`(TS 原版) |
|---|---|---|
| rounded / cylinder 角 | `╔╗╚╝` + `═║` 边 | `╭╮╰╯` + `─│` 边 |
| dotted 线 | `. :` | `┄ ┆` |
| thick 线 | `═ ║`,拐角 `╔╗╚╝` | `━ ┃`,拐角 `┌┐└┘` |
| diamond / circle / doublecircle 标记 | `◊` / `◌` / `◌` | `◇` / `◯` / `◎` |
| hexagon 角 | `╱╲╲╱` | `⌜⌝⌞⌟` |
| subroutine 角 | `╠╣` | `╟╢` |
| **箭头(两档案一致)** | `→←↑↓` + `↖↗↘↙`(默认);`bm-arrow-style='triangle` 时 `▲▼◀▶` | 同左 |

要点:

- **箭头不进 `full` 档案**——TS 的 `►◄`(U+25BA/4)与 `◤◥◣◢` 不在字体表内,
  一律以 `→←↑↓`/`↖↗↘↙`(或表内三角)替代。
- `safe` 输出恒等于 `full` 输出的**纯字符替换**(几何完全一致),
  这让两档案可以共用全部布局/绘制代码,只有 4 张查找表不同。
- `full` 档案的定位是**回归测试基线**:对 TS 输出做箭头归一化
  (`►→→` 等 8 项)后,可做逐字节比对。

---

## 5. Elisp 移植特有的问题(踩坑记录)

1. **正则方言反转**:Emacs 里 `\\(` 是分组、`(` 是字面量,与 JS 相反;
   `\|` 是或、`|` 是字面量;`\\`` `\\'` 是串首/串尾锚。
2. **非贪婪**:`\\{1,\\}?` **不是**非贪婪(会退化为贪婪匹配,导致
   `A[Start] --> B[Process]` 的标签吞到最后的 `]`);必须用 `*?`。
   验证行为后所有形状模式改用 `\\(.*?\\)`。
3. **char literal**:框线字符直接 `?┌` 读入;`?\(` `?\\` 注意转义。
4. **结构体缺槽**:`cl-defstruct` 的 accessor 用了不存在的槽位只在运行时爆
   `(setf bm--edge-xxx)` —— 移植时先定全结构再写逻辑。
5. **块内方向 ≠ 移动向量**:`Up=(1 . 0)` 是 3×3 块内偏移(附件点寻址),
   A* 必须用独立单位向量表。混用会得到"只能往右下走"的寻路 → 死循环。
6. **哈希表无序**:凡依赖文档顺序(节点顺序、边顺序、束内首边)都另配列表。
7. **性能**:小图(< 20 节点)毫秒级;`bm--grid->drawing` 是 O(列数) 的前缀和,
   图大时可加缓存;A* 用真堆而不是线性扫描。16 节点图含 Emacs 启动共 66ms。

---

## 6. 与 TS 的有意偏差(除字符替换外)

| 行为 | TS | Elisp 版 | 理由 |
|---|---|---|---|
| `**bold**` 等标记 | 转成字面 `<b>bold</b>` | **剥离**格式标签 | `<b>` 在终端是噪音 |
| CJK 标签 | 按 codepoint 计宽,错位 | 按 `string-width`,对齐 | 见 §3.7 |
| `graph LR; A --> B` | 报错(header 必须独占一行) | **接受**(分号后当边行解析) | README 示例即此写法 |
| 空标签 `A[]` | 不匹配,退化为裸节点 | 匹配为空标签 | 宽容 |
| 双向捆绑边起点箭头 | 不绘制 | 不绘制(一致) | 忠实移植 |

---

## 7. 验证方法与结果

**黄金对拍**:17 个用例覆盖——链式、全部 12 形状、3 种线型+开线、
标签(竖排/横排)、平行 fan-in/out、自环、纯环、回边、菱形分支回流、
双向箭头、多行标签、粗线拐弯、`flowchart` 关键字、`A & B --> C & D`、
文本内嵌标签。流程:

```
TS 渲染器(src/ascii,tsx 直跑) → golden 输出
  → 归一化(仅 8 个箭头字符替换,§4)
  ↔ Elisp 渲染(bm-char-profile='full,emacs --batch)
  → diff 逐字节比对
```

**结果：17/17 完全一致**（含所有边捆绑用例）。
另：`safe` 档案 17/17 无错渲染；`batch-byte-compile` 零警告。

**独立测试套件 `beautiful-mermaid-test.el`**（55 个 ERT 测试，四组，全部端到端，自包含可单独运行）：

```
emacs -Q --batch -l beautiful-mermaid-test.el -f ert-run-tests-batch-and-exit
```

每个测试都从公开 API（`beautiful-mermaid-render`、交互命令或 org 集成）驱动，只对最终输出断言，不触碰任何内部函数——重构内部实现只要输出不变，测试就不受影响。

| 组 | 内容 |
|---|---|
| A. Rendering（19）| TD/LR 箭头方向、每行等显示宽（含 CJK）、**BT ≡ TD+垂直翻转**不变式（翻转表硬编码在测试里，独立于实现）、RL≡LR、12 形状双档案渲染、边样式字符、边标签（管道/内嵌）、自环、环、双向、多行标签、**fan-in/fan-out 捆绑**（共享箭头计数、标签阻止捆绑）、CJK 连续性与边框贴合、padding 配置生效、**safe 档案禁字符扫描**（24 个表外码点零出现）、full 档案 TS 字符、triangle 箭头风格 |
| B. Goldens（28）| **全部 27 个 TS 对拍用例**逐个字节级回归锁（rstrip 归一后逐字节相等，full 档案）：12 形状（all-shapes、shapes-lr）、回边、三风格双向+标签、链、环、自环、捆绑（diamond、diamonds2、parallel、thick-bundle、dotted-bundle）、**标签阻止捆绑**（label-vs-bundle）、flowchart 关键字、节点组、多行标签、**LR 边标签**、**跨级边**、**多根不连通子图**、**孤立节点**、**深树碰撞平移**、四线型、内嵌标签、粗线分支、**BT 方向**、**RL 方向** + CJK（safe 档案，宽字符吸收与边框对齐） |
| C. API（3）| 返回纯字符串无尾换行、region/buffer 交互命令写入 `*mermaid-ascii*` |
| D. Org（5）| **overlay 切换**（建立/恢复、display 内容与等宽面）、`C-u` 全部块批量切换、块外报错、**列表内缩进对齐**、org-babel 执行（钩子函数 + 完整 `org-babel-execute-src-block` 往返） |

测试文件通过 `eval-and-compile` + `require` 自动加载同目录实现，编译期零警告，可在任意 cwd 运行。

## 8. 使用

```elisp
(beautiful-mermaid-render "graph TD\n  A[Start] --> B{Choice}")   ;; => string
```

交互：选中 mermaid 源码 → `M-x beautiful-mermaid-render-region`
（或整缓冲 `beautiful-mermaid-render-buffer`），结果弹出到 `*mermaid-ascii*`。

### Org 集成（切换显示）

```elisp
;; 建议键位（C-c C-x M-m 在 org 9.x 未被占用）
(define-key org-mode-map (kbd "C-c C-x M-m") #'beautiful-mermaid-org-toggle)
```

光标在 `#+begin_src mermaid` 块内按 `C-c C-x M-m`：源码被 overlay 盖住，
显示渲染后的 ASCII 图（等宽字体）；再按一次恢复源码。`C-u` 前缀作用
于缓冲区内**全部** mermaid 块（全部渲染/全部恢复）。鼠标点击图也可切换。
列表/引用内缩进的块会自动把图缩进到相同列，与周围文本对齐。
块在渲染状态下被编辑不会自动刷新，再按两次即可。

```org
- 一个流程图：
  #+begin_src mermaid
    graph LR
      A[开始] --> B{判断}
      B -->|yes| C[结束]
  #+end_src
```

Org-babel 同步支持：`C-c C-c` 在 mermaid 块上执行，把渲染结果插入
`#+RESULTS:`；加 `:results raw` 头则直接作为 org 文本插入。注意
`org-babel-execute:mermaid` 与 MELPA 的 `ob-mermaid` 包（SVG 方案）
同名，后加载者生效。

```elisp
(setq bm-char-profile 'safe)       ;; safe(默认,受限字体) | full
(setq bm-arrow-style 'triangle)    ;; →←↑↓ | ▲▼◀▶
(setq bm-padding-x 5 bm-padding-y 5 bm-box-padding 1)
```

## 9. 若要继续扩展

按依赖顺序:子图(`subgraph` → 包围盒 + 偏移 + 穿边路由,grid.ts 里
~150 行逻辑)→ stateDiagram(复用 flowchart 管线 + 伪状态形状)→
RL 真支持(水平翻转)→ ANSI 颜色(role canvas + `ansi.ts`)→
sequence/class/er(各自独立布局器,与 flowchart 管线无关)。
