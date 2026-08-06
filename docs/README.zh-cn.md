<div align="center">

# Patina

[English](../README.md) · 中文

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Patina CI](https://github.com/clonimai/patina/actions/workflows/patina.yml/badge.svg)](https://github.com/clonimai/patina/actions/workflows/patina.yml)

<img src="https://clonimai.github.io/patina/badge.svg" alt="Craftsmanship">

</div>

**Patina** 本意是铜绿，引申为器物（古玩、手工艺品等）在长期使用中，表面形成的光泽，可以翻译成**包浆**。代码经过反复修改、review、重构，留存下来的每一行都会有独特的"质感"。Patina 衡量的是这些痕迹在仓库中的当前占比。

评分含义由项目自己定义——`0.5` 是人机各半还是 AI 草稿人类润色... Patina 不做校验：完全可以随意篡改，但对于不信任你的人，你仍然无法说服。

## How it works

每次 commit 附一个 `Craft: 0–1`，CI 用 `git blame` 追溯每行存活代码的来源，按行数加权平均，生成一个百分比。

计算公式：

$$R = \frac{\sum (S_k \times L_k)}{\sum L_k}$$

$S_k$ 为 commit $k$ 的 Craft 评分, $L_k$ 为该 commit 引入且当前仍存在的代码行数。

核心思路是追踪**存量而非增量**——分数衡量的是此刻仓库里代码的质量，而不是写这些代码时付出的努力。

举例：A 加 100 行人类代码 (1.0) → B 加 100 行 AI 代码 (0.0) → C 删所有 AI 代码、补 10 行人类代码 (1.0)。把三个 commit 的评分按修改行数加权平均，约为 0.68。然而现在这 110 行全部来自人类，也算是 100%。前者算的是"怎么做的"（努力），后者看的是"留下的结果"（质量），Patina 取后者。匠心本质是质量，打磨只是手段。

```
Craft 评分附在每次 commit 上 → CI blame 加权聚合 → badge 部署到 GitHub Pages
```

分数以 **Git Trailer** 形式存放在 commit message 末尾，Git 原生支持解析。trailer 是 commit message 末尾、以 key 开头的一行：

```
Fix the widget parsing edge case

Craft: 0.95
```

提交时用 `--trailer` 方便附加：

```bash
git commit -m "message" --trailer "Craft: 0.95"
```

> [!NOTE]
> 如果要手写，注意 Git 的 trailer 解析要求：`Craft:` 必须顶格（行首无空格/tab）、与正文间有空行、块内无空行、块后无内容。

## Quick start

**1. 把本仓库的 workflow 配置复制到你自己的仓库**  
`.github/workflows/patina.yml` 放你自己仓库 `.github/workflows/` 目录下，也可以改名：

```yaml
name: Patina

on:
  push:
    branches: [main]  # push 到主分支每次触发
  workflow_dispatch:  # 也支持手动触发

# 连续多次触发时，自动取消正在运行的旧工作
concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: true

permissions:
  contents: write  # 推送缓存到 refs/patina
  pages: write   # 部署到 Github Pages
  id-token: write

jobs:
  craft:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}

    steps:
      # 拉取远程仓库并 checkout
      - name: Checkout
        uses: actions/checkout@v7
        with:
          fetch-depth: 0  # 全量历史
          filter: blob:none # blobless 轻量拉取

      # 在你的仓库根目录中，运行脚本 main.sh
      - name: Main
        run: source main.sh

      # 把 .patina 中内容打包上传到工件存储区
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v5
        with:
          path: .patina
          # 包括 . 开头的隐藏文件和文件夹
          include-hidden-files: true

      # 把上传后的内容自动部署到 github pages
      - name: Deploy to GitHub Pages
        id: deploy
        uses: actions/deploy-pages@v5
```

**2. 把 `main.sh` 和 `badge.svg` 放到你仓库中喜欢的位置**  
注意更新相对路径引用：patina.yml 中 run `source main.sh`，`main.sh` 开头 `template=badge.svg`。
默认主脚本和模板 SVG 在仓库根目录，可自行修改位置但要同步改 `run:` 和 `template`。badge 模板可以换成你自己的 SVG，但注意脚本唯一做的事情是替换**第一次出现**的 `100%` 为实际百分比。

**3. 开启 GitHub Pages**——Settings → Pages → Source 选 *GitHub Actions*。

> [!NOTE]
> workflow 会覆盖你仓库的 Pages 部署（已有站点需自行合并流程），需要 `contents: write`、`pages: write`、`id-token: write` 权限；连续触发时自动取消正在运行的旧工作，避免部署乱序。

**4. 每次提交写 Craft 评分，然后把 badge 挂到 README：**

```markdown
![Craftsmanship](https://<你的用户名>.github.io/<你的仓库>/badge.svg)
```

## Badge

默认模板：

[![badge.svg](https://raw.githubusercontent.com/clonimai/patina/main/badge.svg)](badge.svg)

模板为纯 SVG，替换**首次出现**的 `100%` 为实际百分比。路径通过 `main.sh` 顶部的 `template` 变量指定，可自行修改颜色和文案。

只要有一个被 blame 追踪到的 commit 缺少 Craft，badge 就降级为 `—%`——全有或全无。

## 补分

忘记写 Craft、或者想给历史 commit 补评分，可以手动编辑缓存。

**原理**：`refs/patina` 是一个隐形 ref，指向一条只含 `cache` 文件的 commit 链。CI 每次运行会读取 cache 中已有的评分作为基线——commit 如果没有 Craft trailer，就回退到 cache 中的值。cache 格式：

```txt
<head> <count> <sum_lines> <weights> <final>    # 元信息行
<hash> <lines> <score>                          # 数据行（score 空缺即待补）
```

补分就是在数据行末尾填上缺失的 score：

```diff
  # 数据行
- a1b2c3d4... 120
+ a1b2c3d4... 120 0.95
```

**推荐用 worktree**，不干扰当前工作区：

> [!NOTE]
> 修改前最好先拉取一遍。CI 每次运行都会 force push `refs/patina`，本地缓存可能已过期，需要基于最新版本编辑，必要时处理冲突。

```bash
git fetch origin +refs/patina:refs/patina      # 拉取隐形 ref（远端可能已被 CI force push 过）
git worktree add --detach .patina refs/patina  # 把缓存链检出到独立工作树 .patina/，不碰当前分支
# 编辑 .patina/cache —— 在数据行末尾填上缺失的 score
git -C .patina add cache                        # 暂存 cache
git -C .patina commit -m "backfill craft"       # 提交，message 随意写
git -C .patina push origin HEAD:refs/patina --force # 推回远端 refs/patina（force 确保覆盖）
git worktree remove .patina                     # 移除临时工作树
```

worktree 把缓存链检出一个独立的临时目录，和当前工作区互不干扰：在 `.patina/` 里改 `cache`，主分支上的代码和未提交的改动都不受影响。改完提交、force push 回 `refs/patina`（远端该 ref 可能已被 CI 更新，force 确保覆盖），最后移除 worktree。

`git -C .patina xxx` 等价于先 `cd .patina` 再执行 `git xxx`，两种写法任选：

```bash
cd .patina
git add cache
git commit -m "backfill craft"
git push origin HEAD:refs/patina --force
cd .. && git worktree remove .patina
```

不创建 worktree 也可以——直接 checkout、编辑、push、切回原分支，代价是短暂占用当前工作区。

接入前的老 commit 同样通过补分处理，否则 badge 降级为 `—%`。

## FAQ

**分数能刷吗？** 能。这是声明，不是裁判。

**为什么缺一个 Commit 的评分，badge 就显示 `—%`？** Patina 不做没有根据的猜测——没有评分就是不知道，不硬凑一个数字。

**和 Not By AI 徽章有什么区别？** 静态徽章只做声明。Patina 量化（0–100%）、融入 workflow、每次 push 自动更新。

**会拖慢 CI 吗？** 全量 `git blame` 随仓库规模增长。增量计算 + blobless clone 已优化。

## Architecture

三个文件：

```
patina.yml          # CI 编排（Checkout → Main → Upload → Deploy）
main.sh             # 核心逻辑，由 workflow 的 source main.sh 直接执行
badge.svg           # SVG 模板，替换首次出现的 100%，路径可自定义
```

**`main.sh`**——纯 Bash，无重型外部依赖，`source` 运行。

期望输入（运行前由 workflow 准备）：

| 输入 | 说明 |
|---|---|
| 当前仓库 | `actions/checkout`（`fetch-depth: 0` + `filter: blob:none`） |
| `badge.svg` | 任意路径（`main.sh` 顶部 `template` 变量指定），替换首次出现的 `100%` |
| 远程 `refs/patina` | 隐形 ref，存放缓存链（首次运行自动创建） |
| `git config user.name/email` | workflow 未设置，脚本内自配 `github-actions[bot]` |

理想输出：

```
.patina/
└── badge.svg        # 渲染后的 SVG（100% → 实际百分比）
```

副作用：

- 会临时挂载 `.patina/` 作为 worktree，并读写其中的 `cache` 文件。cache 内容推送到远程后，worktree（连同 cache）会自动移除，`.patina/` 目录里最终只剩 `badge.svg`
- 推送 `refs/patina` 到远程（`--force`，缓存链更新）
- 部署 `.patina/` 到 GitHub Pages（覆盖站点内容）

## 版本

- **v1** — 全量 `git blame` 加权算分 + badge 生成 + GitHub Pages 部署。
- **v2** — `refs/patina` 隐形 ref 缓存链（seed / 三遍校验 / cache push 闭环），增量 blame awk 化管道，对象预热，增量与全量一致性验证。
- **v3** — `--text` 统一二进制 blame、批量 `--batch-check` cache 校验、CI amend 策略、12 case 测试框架。
- **HEAD** — C 风格引号路径支持、预热阶梯 + 兜底 refetch、日志体系重构、SIGPIPE 修复。

## 待办

- Git hooks——`commit-msg` 检测 Craft trailer；两个 commit 间计算平均 Craft。
- 补分自动化——worktree 手动补分的命令行封装（当前可手动操作，见上方补分节）。

MIT © clonimai
