# Issue #215+ 分类分析与架构级修复方案

> 日期:2026-07-18
> 基线:mcpp **0.0.96**(HEAD `42198fb`,`MCPP_VERSION = "0.0.96"` @ `fingerprint.cppm:21`)
> 范围:GitHub issue #215 及其后全部 OPEN 项(#224/#225/#226/#227/#228/#229/#230/#232/#233/#234/#235),外加"`mcpp run` 构建过但运行前很慢"、"nasm 冷环境失败"、"mcpp.toml 相关"三条用户重点;并入 **R6**(index 仓测试模块包所需的默认命名空间重定向)与两条 workspace ergonomics 补充(root `[indices]` 一次声明全员可用、`mcpp run` 选择成员)。
> 所有 file:line 锚点均在 0.0.96 源码上核实(五路并行 explorer 交叉验证)。
> 上游语境:本批 issue 绝大多数来自 mcpplibs 把 **ffmpeg-m / opencv-m 以"全源码直编"形态**收录时的踩坑(参见 [2026-07-17-asm-sources-and-general-build-capabilities-design.md](2026-07-17-asm-sources-and-general-build-capabilities-design.md) 的下一波),是 0.0.95 声明式清单能力落地后暴露的第二层缺口。

---

## 0. 结论先行

**先纠正一个直觉**:用户提示"mcpp.toml 相关的问题可能是一类"——实测**不是一类**。它们分裂成两个不同根因:命令行**装配语义**(#226/#234,把 flag 当不透明串)与解析器**语法表达力**(#227/#228,parser 缺 array-of-tables / glob 缺花括号)。而 `mcpp run` 慢(#225)与 nasm(#232)各自独立成类。#230 **已在 0.0.96 修复**(根因是 scanner 崩溃,非 nasm/子进程,详见 §7)。

按**根因所在子系统**归并,收敛为 **6 个可独立成 PR 的簇 + 2 个独立项**:

| 簇 | issue | 根因一句话 | 触及子系统 | 量级 | 建议 PR |
|---|---|---|---|---|---|
| **A** flag 装配模型 | #226 #234 | flag 是不透明 `vector<string>`:include 重写只认 `-I`、含空格值不转义 | scanner/flags/ninja_backend | 中 | **PR-1** |
| **B** 清单语法表达力 | #227 #228 | 自研 TOML parser 全局拒 `[[table]]`;glob 匹配器无 `{a,b}` | libs/toml + scanner glob | 中 | **PR-2** |
| **C** 构建图节点身份与输入完备 | #233 #235 | 对象路径按"父目录名+文件名"折叠必撞;扫描产出的 `.dep` 被丢弃、编译边根本无 depfile | plan/ninja_backend/dyndep | 中 | **PR-3** |
| **D** 条件源集统一求值 | #229(=#218 复发) | cfg 条件 sources 只在 root/version-dep 求值,path/git dep 漏;feature sources 已统一而 cfg 没有 | prepare 条件求值漏斗 | 小-中 | **PR-4** |
| **E** 源发现范围 + run/build 缓存复用 | #225(#228 glob 顺带) | glob 永远从 root 全树遍历、只排 `.mcpp`;`mcpp run` 每次重扫、build 缓存不存源清单/产物路径 | scanner/execute | 中 | **PR-5** |
| **F** 外部工具供给统一门 | #232(#230 已修) | nasm 走 bespoke 弱机制(无索引刷新前置、失败降级为 warning、guard 吞真错),未接入工具链那条同步供给门 | prepare/xlings/fetcher | 中 | **PR-6** |
| **G** workspace 配置与测试基建 | #224 + **R6** + 2 补充 | 继承只传 `version` 丢 `path`/根锚点;相对 `[indices]` 按成员目录解析;默认命名空间**结构上不可重定向**;`mcpp run` 无成员选择 | project/manifest/prepare/cli | 中 | **PR-7** |
| 不做 | #215 | 上游 Clang 落地 P2996 后才加一行,现无从动手 | cppfly | 微 | **不做** |

**版本建议**:A/B/C/D/E 是 ffmpeg-m/opencv-m 全源码直编的硬阻塞,建议合成一个版本里程碑(**0.0.97**)分 5 个 PR 顺序合入;F 可并行;#224 独立;#230 只需在 windows CI 用 0.0.96 pin 复验后关闭;#215 挂 upstream。

**贯穿全文的一条架构主线**:mcpp 目前多处把"结构化意图"过早压平成字符串/单点特判,再在下游试图恢复——A(flag 边界丢失)、C(对象名折叠丢路径)、D(条件求值散在多个调用点)、E(glob 前缀信息被丢弃后靠遍历补)、F(工具供给不复用统一门)都是同一病理的不同切面。每个簇的"架构方案"都指向**把意图保留到唯一的收敛点**,而非再加一处特判。

---

## 1. 分类方法与"一类"的判据

判定"能否放进一个 PR"的标准不是"issue 表面相似",而是**三个必须同时成立**:

1. **同根因子系统**——改动落在同一组文件/同一个抽象层,一个 reviewer 能一次性把握;
2. **同回归面**——共享同一批测试夹具与验证路径(避免一个 PR 拆两拨 e2e);
3. **无语义耦合冲突**——两处改动不互相改写对方的中间表示(否则应先做基础层)。

据此,用户直觉里的"mcpp.toml 一类"被拆开:#226/#234 落在**命令行装配**(scanner→ninja_backend 的 flag 流),#227/#228 落在**解析层**(libs/toml + glob 匹配器)——两层之间只有数据流经过、无共享逻辑,强行同 PR 会让 diff 横跨"parser 改造 + 命令装配改造"两个不相干高风险区。反过来,#233/#235 表面一个是"路径撞名"一个是"改 .inc 不重编",却**同根**:都在 `ninja_backend.cppm` 的构建边生成、都因"扫描已拿到的信息没并进 ninja 依赖边"而坏——故合一簇。

---

## 2. 簇 A:flag 装配模型(#226 + #234)—— PR-1

### 2.1 现象
- **#226**:`[build].cflags/cxxflags` 里相对 `-Ihdr` 会被绝对化(命令行可见),但 `-iquotehdr` / `-isystem` / `-idirafter` **不重写**,按 ninja 构建目录解析 → 头文件静默找不到。
- **#234**:`defines = ["T=long long"]` 未加引号拼进命令行,g++ 把 `long` 当独立输入文件 → `linker input file not found`。

### 2.2 根因(核实)
flag 在整条管线里是**不透明预拼字符串**,没有任何 `Flag{kind,value}` 结构:
- 数据模型:`GlobFlags`(`types.cppm:125-131`)、`BuildConfig.cflags/cxxflags/ldflags`(`types.cppm:137-156`)、`SourceUnit.packageC*flags`(`graph.cppm:15-29`)全是 `vector<string>`;全局 flag 更早在 `flags.cppm:312-331` 就压平成单个 `std::string` blob。
- **有损融合点**:`apply_glob_flags`(`scanner.cppm:571-586`)把 define 拼成 `"-D"+d`——`-DT=long long` 在此刻成为**一个含内部空格的 vector 元素**,参数边界意图就此丢失。
- **include 重写只认 `-I`**:`absolutize_include_flags`(`scanner.cppm:338-350`)用字面 `f.starts_with("-I")`(342)+ 硬编码 `substr(2)`(343)+ 硬编码 `"-I"` 重建(347)。`-iquote/-isystem/-idirafter` 首字母是小写 `-i`、且有 joined/separated 两种拼写,根本不进这个判断。注意 `-I` 本已被 `Dialect::includePrefix`(`dialect.cppm:27,74`)抽象,这里却绕过 dialect 硬编码。
- **发射端零转义**:`join_flags`(`ninja_backend.cppm:99-106`)就是 `out += ' '; out += flag;`。现有 `escape_ninja_path`/`escape_flag_path`(`ninja_backend.cppm:60-88`、`flags.cppm:80-90`)只做 ninja **语法**转义且只用于**路径**,不解决 shell 参数边界。

一句话:**边界与角色信息在 `scanner.cppm:571-586` 被抹掉,到 `ninja_backend.cppm:99` 想转义也已无从分辨** `-DT=long long`(一个参数须整体加引号)与 `-isystem /a/b`(两个 vector 元素、本就是两参数)。

### 2.3 架构方案(非临时)
**引入结构化参数中间表示,把"边界 + 角色"保留到发射点。**

- 定义 `struct Arg { enum Kind { Plain, IncludeDir, Define, Separated } kind; std::string spelling; std::string value; };` 作为 per-glob/per-unit flag 的**规范内部形式**(替换裸 `vector<string>` 的语义,发射时才铺开成命令行 token)。
- **规范化 pass**(唯一收敛点,放在 `apply_glob_flags`/scanner 附加处):
  - include 族——识别 `{-I, -iquote, -isystem, -idirafter, -iprefix, -L}` 全家族(joined 与 separated 两拼写),路径部分统一相对项目根绝对化,拼写走 `Dialect` 而非硬编码。把 `flags.cppm:161-165` 那条**另一路** includeDirs 绝对化也并进来,消除两套逻辑。
  - define——`value` 原样保留(含空格),不在此处拼 `-D`+串。
- **发射 pass**(`join_flags` + `flags.cppm:312-331` blob 装配两个 choke point):按 `Arg.kind` 生成 token,含空格/特殊字符的 `value` 施加 **shell 引号 + ninja `$` 转义**双层(叠在现有 `escape_*` 之上)。
- **一致性单测**:枚举 `-I/-iquote/-isystem/-idirafter` × 相对/绝对 × cflags/cxxflags/asmflags 三通道,断言绝对化;define 值含空格断言命令行单参数完整。

> 落地边界:本 PR **只碰 flag 流**(scanner 附加 → CompileUnit → ninja 变量),不动 sources/依赖解析。`Arg` 可先以最小形态落地(保留"是否 include 族 + 是否需整体引用"两个 bit),不必一步到位做全类型系统——关键是**边界不再在中途丢失**。

### 2.4 与 0.0.95 的历史呼应
asm 设计文档 §1.6 已把 #226 记为 G8b("相对 `-I` 对 `.cppm` 不生效,先加复现再修,随 flags PR 顺手"),此 PR 即其正式兑现,并把范围从"补一个漏"升级为"根治不透明串"。

---

## 3. 簇 B:清单语法表达力(#227 + #228)—— PR-2

### 3.1 现象
- **#227**:`[[build.flags]]` 标准 TOML 数组表被拒(`array-of-tables not supported`),长条目(NASM 8 个 `-I` + `-Pconfig.asm`,单行 300+ 字符)只能挤一行。
- **#228**:glob 不支持 `{a,b}`,`libavcodec/{aac,bsf,hevc,opus,vvc}/**` 触发 matched-no-source 警告,只能写 5 条重复条目。

### 3.2 根因(核实)
- #227 的拒绝在**词法/解析库层、全局**:`libs/toml.cppm:474-476` 见 `[` 直接 `return unexpected("array-of-tables not supported")`,注释("mcpp doesn't use them")说明是刻意未实现。mcpp.toml 走这个 parser(`toml.cppm:7` import),故 `[[build.flags]]` 在 tokenize 期就死,`toml.cppm:692` 的消费分支根本到不了。xpkg/Lua 路径反而原生支持有序数组表(`xpkg.cppm:864-919`)——两条 ingest 表达力不对等。
- #228:全仓唯一 glob 匹配器 `path_matches_glob`(`scanner.cppm:103-163`)的递归 `match`(126-161)只支持 `**`/`*`/字面量,`{` 当普通字符,故 brace glob 永不命中。

### 3.3 架构方案(非临时)
两处都是**"closed syntax, open vocabulary"下的纯语法补齐,零新语义**(符合 schema 准入规则):

- **#227**:教 `libs/toml.cppm` 的解析主循环(460-499,`[` 分支 471)把 `[[table]]` 累积成一个数组 `Value`;再扩 `toml.cppm:692-730` 让 `build.flags` **同时接受**内联表数组与数组表两形式(声明顺序=应用顺序语义不变)。这是补一个**通用 TOML 能力**,顺带让未来任何配置段都能用数组表。
- **#228**:在 `expand_glob` **入口处**把 `{a,b}` 脱糖成多个 glob(而非改 `match` 递归)——理由:脱糖与簇 E 的"前缀收窄遍历"天然复合(先脱糖再对每个分支取前缀),且不污染热路径匹配器。备选:flags 条目的 `glob` 键接受数组(更小、解析层),二者可都做。

> 落地边界:纯 parser + glob 入口,**不碰**命令装配与构建图。可与 PR-1 并行(无文件重叠除 glob 入口,而 PR-1 不碰 glob)。

---

## 4. 簇 C:构建图节点身份与输入完备(#233 + #235)—— PR-3

### 4.1 现象
- **#233**:`a/src/util.cpp` 与 `b/src/util.cpp` 都折叠成 `obj/repro_src/util.cpp.ddi` → `ninja: multiple rules generate`。是 OpenCV/LLVM 式 `modules/<mod>/src/*.cpp` 标准布局的直接杀手(opencv-m 现被迫生成 457 个转发 stub)。
- **#235**:模块 purview 内 `#include "vals.inc"` 改动后 `mcpp build` 判 up-to-date(0.01s),产物 stale。ffmpeg-m(978 函数)/opencv-m(~2000 名字)的 `gen_exports/*.inc` 导出面全走这个模式。

### 4.2 根因(核实)
- #233:对象路径唯一赋值点 `plan.cppm:450-462`。折叠逻辑 `455`:`parentDir = u.path.parent_path().filename()` ——只取**直接父目录名**,丢掉相对路径其余部分;`456-459` 拼成 `obj/<pkg>_<parentDir>/<fname>`。`basenameCount`(430-433)只检测 basename 撞名,而它的"解法"(父目录名前缀)**本身不唯一**、且无最终唯一性断言。`.ddi` 路径(`ninja_backend.cppm:620`)从 `cu.object.parent_path()` 派生,故连带撞。
- #235:**信息本已产出却被丢弃**。P1689 扫描命令带 `-M -MM -MF $out.dep`(`ninja_backend.cppm:531`)确实生成了含全部文本 include(purview + GMF + 普通头)的 depfile,但:① `cxx_scan` 规则**没有 `depfile=`/`deps=gcc`**(对比 nasm 规则 `:463-468` 是有的),`$out.dep` 生成即弃;② 计划期扫描 `p1689.cppm:350-365` 同样带 `-MF {dep}` 却只解析 `.ddi`,`.dep` 从不读;③ 更根本——`cxx_module`/`cxx_object` 编译规则在**非 MSVC 下根本没有任何 depfile**(`ninja_backend.cppm:402-435`,只有 `msvcDeps` 分支加 `deps=msvc`)。即**扫描的 `.dep` 是唯一曾捕获过 include 的地方,而它被丢在地上**;到达 ninja 的模块依赖边只有 `逻辑名→BMI`。

### 4.3 架构方案(非临时)
- **#233:对象路径镜像源相对路径。** 唯一改点 `plan.cppm:450-462`:把前缀从 `parent_path().filename()` 改为**源文件相对(包/项目根)完整路径**(sanitize 分隔符),即 `obj/<target>/a/src/util.cpp.o`;`.ddi/.dd/compile_target` 全部从 `cu.object` 派生故自动跟随。**追加一条 post-loop 断言**:所有 `cu.object` 互异(把"撞名"从运行期 ninja 错误提前成 mcpp 层可诊断错误)。基名撞名启发式(430-433)可退役。
- **#235:给编译边加真正的 depfile 追踪。** 首选**方案 2**(而非只捞扫描 `.dep`):给 `cxx_module`/`cxx_object` 加 `-MD -MF $out.d` + `depfile = $out.d` + `deps = gcc`(镜像 nasm 规则 `:463-468`)。这在**编译期**捕获所有头/purview/GMF include,**一次性根治整类 stale**——不止 #235 的 purview,还包括至今非 MSVC 下**普通头文件改动也不重编**的潜伏 bug(本次探查的额外发现)。若要更省(不重复编译期扫描),备选方案 1:让 `mcpp dyndep` 收集器(`dyndep.cppm:314-340`)读每个 `.ddi` 旁的 `.dep`、把文件列表作为额外 implicit input 并进 dyndep 边——但这只覆盖模块 TU,不如方案 2 普适。

> 落地边界:两改都在 `plan.cppm` + `ninja_backend.cppm` 构建图生成,同组文件同 reviewer。回归夹具:#233 用双 `src/util.cpp`,#235 用 purview `#include .inc` 改值后断言重编;顺带加"改普通头触发重编"用例锁住方案 2 的额外收益。

---

## 5. 簇 D:条件源集统一求值(#229,= #218 复发)—— PR-4

### 5.1 现象
`[target.'cfg(...)'.build].sources`(0.0.95 #223 引入)在包**自身 build** 时正常,但该包**作为 path 依赖被消费**时不展开 → undefined reference。与 0.0.94 修的 #218("feature sources 在 `mcpp test` 下不编译")**同类**:条件源集只在主构建路径求值,次级路径缺失。

### 5.2 根因(核实)—— 这是一个"漏斗未统一"的架构缺陷
- 存储:`ConditionalConfig`(`types.cppm:252-268`,含 `sources`)、`Manifest.conditionalConfigs`(`types.cppm:367`);parser(`toml.cppm:827-862`、`xpkg.cppm:930-986`)只**存**不并入 base。
- 求值/合并漏斗:`merge_conditional_build`(`prepare.cppm:345-362`)对命中谓词把 `cc.sources` APPEND 进 `buildConfig.sources`(358)与 `modules.sources`(359,scanner 实际走这个)。
- **关键不对称**:该漏斗只在 **root**(`prepare.cppm:792`)与 **version/registry dep**(`prepare.cppm:1714`,#223 加)被调用;**path/git dep 走另一条分支**(`prepare.cppm:2447-2459` 裸 `manifest::load` → 直接 `makePackageRoot`),**从不调用** `merge_conditional_build` → path dep 的 cfg sources 存了却永不并入 → scanner 看不到 → undefined reference。**这就是 #229**。
- 对照 feature sources:`apply` lambda(`prepare.cppm:2564-2668`)的 drop+add,#218 后 ADD 被移出 `!includeDevDeps` 门,且 `apply` **已对每个包**在每种模式调用(root `2689` + 每个 dep `2710`)——feature 维度**已统一**,cfg 维度**没有**。

### 5.3 架构方案(非临时)—— 建立"每包有效源集"唯一漏斗
把 cfg 源求值折进 feature sources 那个**已经存在的 per-package 循环**(`prepare.cppm:2669-2711`),使**每个包(packages[0..n])在每种模式(build/test/workspace)走同一段"解析有效源集 = base + cfg + feature、按已解析 target 求值"**——正是 #218 统一 feature sources 的同款做法。具体:
1. 在 per-package 循环内、modgraph 扫描前,对 `pkg.manifest` 调用 `merge_conditional_build`(此处 manifest 已可原地改,且在 feature 激活后、扫描前的正确时点);
2. **退役**现有两个散点调用(root `792` 的 sources/flags 半、version-dep `1714`)以免双重合并;
3. **保留** root-only 的条件*依赖*合并(`800-802`,必须在依赖解析前),这是合法的 root 专属。

> 这条修复的价值不止 #229:它把"条件源集必须在所有构建路径统一求值"从**惯例**(#218 靠 code review 记住"add 要在所有模式做")升级成**结构不变量**(只有一个漏斗,想漏都难)。任何未来新增的条件源维度自动被覆盖。
> 落地边界:纯 `prepare.cppm` 漏斗重排,回归夹具用 #229 的 `cfg(linux) sources` path dep + `mcpp test` 双路径(呼应记忆里"诊断 feature 必须 build/test 双路径对比")。

---

## 6. 簇 E:源发现范围 + run/build 缓存复用(#225)—— PR-5

### 6.1 现象
`mcpp run --version` 每次 real≈9.5s(其中 build 只 0.03s),strace 见 ~143 万次文件操作,几乎全在无关子模块(`compat/node` 37 万、`compat/bun` 13 万路径引用)。同一二进制直接跑 0.00s,`mcpp build` 缓存命中 0.04s。即**延迟全在 run 的解析/发现路径**。

### 6.2 根因(核实)—— 三个叠加缺陷
1. **无界遍历**:`expand_glob`(`scanner.cppm:233-287`)**永远从 `root` 起** `recursive_directory_iterator`(251-252),glob 只在**遍历后**逐文件 `path_matches_glob`(276)做词法过滤。`src/**/*` 仍访问整棵树。**从不从 glob 的固定前缀 `src/` 起走。**
2. **排除面太窄**:df985df 只加了 `.mcpp` 剪枝(`scanner.cppm:261-264`);**无** `.git`/git 子模块/`target`/vendored 树排除;且仍 `follow_directory_symlink`(252),只有 canonical 环检测。
3. **run 每次重扫、缓存复用不了**:`mcpp run` → `build_run_target`(`execute.cppm:387-431`)**无条件** `prepare_build(false)`(391),不像 `cmd_build` 有 `try_fast_build` 快路径(`cmd_build.cppm:81-90`)。原因:run 事后要用 `ctx->plan.linkUnits` 定位二进制(397-410),而 plan 只是 `prepare_build` 的产物。而 `target/.build_cache`(`BuildCacheEntry`,`execute.cppm:34-41`)**只存**够重跑 ninja 的字段,**不存解析后的源清单、不存二进制目标路径**——run 无可复用。
   - 附带:`try_fast_build` 自己还有**第二份**硬编码到 `src/` 的独立遍历做新鲜度检查(`execute.cppm:317-328`),非 glob 感知。

### 6.3 架构方案(非临时)
唯一 choke point 是 `expand_glob`/`expand_dir_glob`,所有源发现都过它:
1. **前缀收窄遍历**:从 glob 提取首个通配前的字面前缀(`src/`),`recursive_directory_iterator` 从 `root/prefix` 起,而非 `root`。单点改,全体调用者受益。与簇 B 的 `{a,b}` 脱糖复合(脱糖后每分支各取前缀)。
2. **边界排除**:在 `.mcpp` 剪枝旁,对 `.git`、`target`、`.gitmodules` 登记的子模块路径 `disable_recursion_pending()`;子模块边界默认排除除非显式声明为 member/package。
3. **共享解析缓存,让 run 跳过重扫**:扩 `.build_cache` schema 持久化**解析后的二进制目标输出路径**(+ 已有 runtime env),以既有 fingerprint(`prepare.cppm:2936`)为有效性键;给 `build_run_target` 加与 `cmd_build` 平行的快路径:缓存有效则直接定位并启动 exe,不 `prepare_build`。顺手把 `try_fast_build` 那第二份 `src/` 硬编码遍历统一到前缀收窄的 `expand_glob`。

> 落地边界:`scanner.cppm`(遍历)+ `execute.cppm`(缓存 schema/快路径)。回归夹具:含大无关目录/子模块的工程,断言 `mcpp run` 与缓存 `mcpp build` 耗时同量级(#225 明确要求)。这是"运行前很慢"的正解——**不是**加个跳过开关,而是让发现有界 + 让 run 复用 build 已解析的结果。

---

## 7. 簇 F:外部工具供给统一门(#232;#230 已修)—— PR-6

### 7.1 #232 现象
含 `.asm` 的包冷环境构建:`error: NASM sources present but no usable nasm ...` **先于** `Bootstrap nasm into mcpp sandbox (one-time)` 打出(~0.25s 后),构建已判死;两轮独立 run 时序一致;PATH 有 nasm 则不受影响。

### 7.2 #232 根因(核实)—— nasm 是一条**未接入统一供给门的弱机制**
- nasm 消费边 `prepare.cppm:3019-3032`:
  ```
  auto cfgNasm = get_cfg();               // 默认 requireBootstrap=true
  if (cfgNasm) nasmBin = xlings::ensure_nasm(...);   // ← guard
  if (!nasmBin) return unexpected("...no usable nasm...");
  ```
- `ensure_nasm`(`xlings.cppm:1276-1295`)链:PATH(`which`+版本)→ sandbox(`find_sandbox_nasm`)→ 打印 "Bootstrap"(1287)→ `install_with_progress`(1289,**同步** join `xlings.cppm:993`)→ 再 `find_sandbox_nasm`。**它技术上是同步的**,但两个架构缺陷制造了报错先行:
  1. **guard 吞真错**:冷环境 `get_cfg()` 的 `check_base_init` 失败(`prepare.cppm:636-644`)返回 error-expected,`if(cfgNasm)` 为假 → `ensure_nasm` **根本没被调**(故无 "Bootstrap" 行)→ 直接抛 "no nasm";而 `get_cfg()` 的**真实 bootstrap 错误被丢弃**。
  2. **无索引刷新前置**:`ensure_nasm` 装前不刷新 xlings 包索引(对比 fetcher 路径 `package_fetcher.cppm:745-746` 会 `ensure_official_package_index_fresh`),冷环境 `xim:nasm` 尚不在索引 → 装失败 → **仅 warning**(1290-1293)→ `find_sandbox_nasm` 返 nullopt → 抛错。失败根因再次被降级丢弃。

对照**正确范式**——工具链自动装是**同步 provision-before-edge 门**:`Fetcher::resolve_xpkg_path(target, autoInstall=true, &progress)`(`prepare.cppm:851/958-959/1080`,impl `package_fetcher.cppm:644-762`),它**先刷索引**(745-746)→ 阻塞 `install`(753)→ **校验 payload 落地**(758-762)→ 有 XLINGS_HOME 传播兜底(764-779);失败是**硬错**不是 warning。

### 7.3 #232 架构方案(非临时)—— nasm 走同一道门
把 `prepare.cppm:3019-3032` 的 bespoke `ensure_nasm` + `if(cfgNasm)` guard **替换为工具链同款** `resolve_xpkg_path("xim:nasm", autoInstall=true, ...)`(或抽一个 `ensure_tool(pkg)` 共享 helper,工具链与 nasm 都调),使 nasm 继承:索引刷新前置、失败硬错、payload 校验、copy-from-global 兜底。并**修 guard**:不再静默丢 `get_cfg()` 的 bootstrap 错、config 加载失败时不跳过供给。`xlings::ensure_nasm` + `install_with_progress` 可退役/吸收。

> 更广的收益:任何未来"惰性供给的构建期工具"(未来的 protoc/bison/flex 之类)都应走这道门——**工具供给不该有第二套弱机制**。这与记忆里 mingw-cross/msvc 供给都收敛到 registry/fetcher 的方向一致。

### 7.4 #230:**已在 0.0.96 修复**(不入本 PR)
探查推翻了 issue 的初步怀疑(非 #220 nasm / #222 build.mcpp 子进程)。真相:windows "exit 127" 实为 `0xC0000409`(`__fastfail`,git-bash 报成裸 127),源自 module scanner 未捕获的 `std::system_error`——glob 遍历经 `.mcpp` 符号链接逃逸进 index checkout,对 CJK 文件名做窄串转换时抛异常。**正是 `df985df`("prune .mcpp from glob walks; never throw on unnarrowable names (#230)")修的**——commit 消息直接引用 #230。修复在 `scanner.cppm`(~110-124 narrow guard + 261-264 剪枝)+ `main.cpp:7-18`(last-resort catch,返 70 不 fastfail)。**行动**:mcpp-index windows CI 用 0.0.96 pin 复验后关闭 #230,无需代码。
> 附带硬化(可选、低优):`build_program.cppm:499` 的 `build.mcpp.bin` **缺 `exe_suffix`**(nasm/其他工具都用 `platform::exe_suffix`),windows 上是潜伏隐患;`prepare.cppm:2395-2415` 的 git clone 是仅存的裸命令名 spawn(无 `which` 前置)。二者可随 F 顺手,但非 #232/#230 的成因。

---

## 8. 簇 G:workspace 配置与测试基建(#224 + R6 + 2 补充)—— PR-7

这四项**同根因子系统**(workspace 配置继承 + `[indices]` 命名空间路由),且**同一受益方**:让 index 仓能用一条 `mcpp test --workspace` 声明式地验证所有包(含模块包),删掉一整套 shell 伪造补丁。故合一簇一 PR。

### 8.1 病理总纲:workspace 的"根锚点"与"命名空间路由"都不完整
mcpp workspace 有 members 枚举与逐成员构建,但两个横切能力有洞:
1. **继承的相对配置无根锚点**——继承下来的 `path`/`[indices]` 相对值按**消费成员目录**而非 **workspace 根**求值;
2. **命名空间路由无"默认"入口**——`[indices]` 只能重定向**有名字**的命名空间,默认命名空间(`namespace = ""`)在两处被**硬编码短路**到 builtin index,`m->indices` 根本不被查。

这两个洞叠加,逼出 index 仓的 shell 补丁(R6)与逐成员重复声明(#224)。

### 8.2 #224:继承只传 version + 相对路径按成员目录重基("根添加一次不 ok")
- **根因**:
  - 复现 1(path dep 走 `workspace.dependencies`):`merge_workspace_deps`(`project.cppm:52-75`)只把 `spec.version` 从 workspace 抄给成员、**丢弃 `path`**,于是本地 path 依赖被当 index/semver 解析报 "isn't cloned locally yet"。
  - 复现 2(root `[indices]` 重基):workspace 索引**仅当成员自己没声明时**才继承(`prepare.cppm:577-579`、`600-602`,`if (m->indices.empty())`),且相对 `path` 值(如 `mcpp`)按**成员目录**解析成 `<root>/<member>/mcpp` 而非 `<root>/mcpp`;嵌套成员深度还改变含义(须 `../mcpp`、`../../mcpp`)。**这正是用户说的"根添加一次就 ok 不成立"**——每个成员被迫重复声明各自相对路径。
- **架构方向**:解析后的 workspace 配置**保留 workspace 根目录**为锚点;所有**继承而来**的相对路径(`[indices]`、path dep)一律相对**根**求值(而非消费成员);`merge_workspace_deps` 传播 `path` 时连带记录"相对根"来源。

### 8.3 R6:默认命名空间无法重定向(核心新增)—— 补一个语法空洞
- **背景**:index 仓本身是个 workspace,每个包配测试工程,用 `[indices] compat = { path = "../../.." }` 把 `compat` 命名空间指向本仓 checkout,PR 合并前即可 `mcpp test --workspace` 真实验证描述符。**但** imgui/ffmpeg/opencv 三个公开**模块包走默认命名空间**(描述符 `namespace = ""`,用户写 `[dependencies] opencv = "0.0.2"` 不带前缀),而 `[indices]` **没有语法能把"裸的默认命名空间"指到本地路径**。
- **现状替代品(要删的补丁)**:三个 ~100 行 `tests/smoke_*_module.sh`——建临时 `MCPP_HOME` → 把本仓 checkout 整个拷贝覆盖到默认 index 的落盘位置(`registry/data/mcpplibs`)→ 造临时消费工程 `mcpp build && mcpp run`;CI 还得为它们各开一个专属 job。**能用但丑**:三份近似复制的 shell(违背 index 仓 "zero-shell 自举" 立仓哲学,cf. [记忆:workspace-test-and-zero-shell-index])、易碎的 MCPP_HOME 重播/缓存链接/nasm 沙箱索引刷新细节、CI job 数随模块包线性增长。这个空洞在 imgui 时代就被 index 仓注释标记"待架构重构解决"。
- **根因(核实)—— 默认命名空间被两处硬编码短路,`[indices]` 从不被查**:
  - `usesBuiltinIndex`(`prepare.cppm:1134-1145`):default-ns dep 在 `1140` `if (ns == kDefaultNamespace) return true;` **直接短路**,`m->indices.find(ns)`(1142)对默认命名空间永不执行;
  - `findIndexForNs`(`prepare.cppm:1297-1310`):`1300` `if (ns.empty() || ns == kDefaultNamespace) return nullptr;`(nullptr = builtin)**又一处短路**,同样在查 `m->indices` 之前。
  - 即:默认命名空间→builtin index 是**结构写死**的,`[indices]` 只对有名字的命名空间生效。`[indices]` 解析(`toml.cppm:924` 起)本就迭代任意键,空引号键 `"" = {...}` TOML 可表达——**缺的不是解析,是路由未查表**。
- **架构方案(非临时)**:让默认命名空间可被 `[indices]` 重定向。定一个**规范拼写**映射到 `kDefaultNamespace`(建议保留 token `default = { path = ... }`,比空引号键 `""` 更可读、更不易误写;二者可都接受);两处短路(`1140`、`1300`)改为**先查** `m->indices` 是否有默认命名空间的重定向条目,有则用之、无则回落 builtin。这是**把"默认命名空间不可寻址"这个语法空洞补上**,不是给用户加功能——补完后三个模块包各建一个和 `opencv5` 一样的普通测试工程(只多一行 `default = { path = "../../.." }`)加入 workspace members:**三个 smoke shell 删除、三个专属 CI job 删除、模块包验证并入 `mcpp test --workspace` 一条命令**,以后每加模块包只加一个成员目录。

### 8.4 补充:`mcpp run` 不支持选择 workspace 成员
- **根因(核实)**:`cmd_run`(`cmd_build.cppm:99-107`)只读一个位置参数(二进制目标名)+ passthrough,**不解析 `--package`、不做 workspace fan-out**;对比 `cmd_build`(读 `--package` `cmd_build.cppm:47`)、`cmd_test`(读 `--package` `:121` + `workspace_fanout_members`)。`resolve_member_dir`(`project.cppm:87-106`)这条 build/test 已共享的成员选择规则,run 完全没接。
- **架构方案**:`cmd_run` 接入与 build/test **同一** `--package` 解析 + `resolve_member_dir`,`build_run_target` 增加 `package_filter` 形参、在成员目录 scope 内解析并启动该成员的二进制。语义与 `mcpp build -p <m>` / `mcpp test -p <m>` 对齐(run 天然单成员,不需要 `--workspace` fan-out)。

### 8.5 PR-7 边界与顺序
- 触及 `project.cppm`(继承/根锚点)、`prepare.cppm`(两处命名空间短路 + 索引继承重基)、`manifest/toml.cppm`(`default` 键规范化)、`cli/cmd_build.cppm`(run 成员选择)。与 A–F **无文件重叠**(F 也碰 prepare 但在 nasm 供给段 3019-3032,与此处 577/1134/1297 不冲突),可完全并行。
- 回归夹具:虚拟 + rooted workspace、不同深度成员、root `[indices]` 相对路径一次声明全员可用、`default = {path}` 重定向默认命名空间命中本地包、`mcpp run -p <member>`。**收尾验证**:在 mcpp-index 侧把一个模块包改成 workspace member 测试工程、删对应 smoke shell + CI job,`mcpp test --workspace` 全绿——这是 R6 真正落地的判据。

## 9-pre. #215:cppfly Clang 反射行 —— 不做
上游 Clang(非 bloomberg fork)落地 P2996 后才谈得上给 `cppfly.cppm` 的 `kReflectionRules` 加一行(且版本号 + 旗标拼写须实机 `-fsyntax-only` 特性宏核实,不得臆测)。截至 2026-07 上游无。**标记为不做**:不排期、不占里程碑;真要提前,只能走"把 clang-p2996 fork 打包成 `llvm-p2996@x` 进生态"的独立打包路径,与本批 issue 无关。

---

## 9. PR 批次与版本建议

```
0.0.97 里程碑(ffmpeg-m / opencv-m 全源码直编解锁):
  PR-1  簇A flag 装配模型(#226 #234)      ─┐ 可并行(文件不重叠)
  PR-2  簇B 清单语法(#227 #228)           ─┘
  PR-3  簇C 构建图身份+depfile(#233 #235)  ← 独立,建议先合(#233 阻塞大库直编)
  PR-4  簇D 条件源集统一漏斗(#229)         ← 依赖清晰,独立
  PR-5  簇E 源发现范围+run缓存(#225)       ← 含 #228 glob 入口,若与 PR-2 都改 expand_glob 需约定先后
并行/独立:
  PR-6  簇F 工具供给统一门(#232)
  PR-7  簇G workspace 配置与测试基建(#224 + R6 + run成员选择)  ← 解锁 index 仓删 smoke shell
复验即关:
  #230  windows CI 0.0.96 pin 复验(已由 df985df 修)
不做:
  #215  upstream P2996 未落地,无从动手
```

**PR-7 的生态收尾**:合入后到 mcpp-index 侧把 imgui/ffmpeg/opencv 三个模块包各改成 workspace member 测试工程(`default = {path=...}` 一行)、删三份 `smoke_*_module.sh` + 三个专属 CI job,`mcpp test --workspace` 全绿即验收。这是 R6 从"mcpp 补语法"到"index 仓删补丁"的闭环。

**合并顺序注意**:
- PR-2(#228 glob 脱糖)与 PR-5(expand_glob 前缀收窄)**都改 `expand_glob` 入口**——建议 **PR-5 先**(把遍历改造做扎实),PR-2 的脱糖叠在其上;或合成一个"scanner glob 引擎"PR。这是唯一的文件级耦合。
- PR-1 的 `Arg` 规范化落在 scanner 附加处,PR-4 的条件源漏斗落在 prepare per-package 循环,PR-3 落在 plan/ninja_backend——三者**无重叠**,可乱序。
- **可选精简**:若 reviewer 偏好"按 `[build].flags` 特性端到端",可把 PR-1 + #227 合成一个"[build].flags 管线 PR"(parse 数组表 → normalize include/边界 → escape),把 #228 glob 归 PR-5。本文默认按子系统切,更利于隔离回归。

## 10. 待用户 review 的决策点
1. **版本策略**:A–E 五 PR 是否统一挂 0.0.97 一次发布(vs 分批发)?
2. **PR-1 粒度**:`Arg` 结构化中间表示做到多细(最小两 bit vs 完整类型)?本文建议最小可用、以"边界不丢"为准。
3. **PR-2/PR-5 合并**:`expand_glob` 改造是拆两 PR(先遍历后脱糖)还是合成一个"scanner glob 引擎"PR?
4. **簇 C depfile 方案**:方案 2(编译边加 `-MD`,根治整类 stale,含额外收益)vs 方案 1(只捞扫描 `.dep`,改动更小但仅覆盖模块 TU)?本文推荐方案 2。
5. **#227 归属**:独立 PR-2,还是并入"[build].flags 管线"随 PR-1?
6. **R6 默认命名空间重定向拼写**:保留 token `default = { path = ... }`(推荐,可读)、空引号键 `"" = { path = ... }`,还是两者都接受?
7. **PR-7 范围**:#224 + R6 + `run -p member` 三者同 PR(同子系统、无重叠,推荐),还是把 `run -p member` 拆成独立小 PR 先行?
