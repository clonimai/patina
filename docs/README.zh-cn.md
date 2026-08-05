<div align="center">

# Patina

[English](../README.md) · 中文

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Patina CI](https://github.com/clonimai/patina/actions/workflows/patina.yml/badge.svg)](https://github.com/clonimai/patina/actions/workflows/patina.yml)

<img src="https://clonimai.github.io/patina/badge.svg" alt="Craftsmanship">

</div>

**Patina** 本意是铜绿，也用来描述器物在长期使用中形成的光泽——中文叫**包浆**。代码经过反复修改、review、重构，存活下来的每一行都带着人的痕迹。Patina 衡量的是这个痕迹在仓库中的占比。

评分含义由项目自己定义——`0.5` 是人机各半还是 AI 草稿人类润色，你自己定。CI 脚本就在仓库里，谁都可以改。Patina 不做校验：不信任你的人，你防不住；信任你的人，不需要防。

## How it works

每次 commit 附一个 `Craft: 0–1`，CI 用 `git blame` 追溯每行存活代码的来源，按行数加权平均，生成一个百分比。

评分公式：

$$R = \frac{\sum (S_k \times L_k)}{\sum L_k}$$

其中 $S_k$ 为 commit $k$ 的 Craft 评分，$L_k$ 为该 commit 引入且当前仍存活的代码行数。

核心思路是追踪**存量而非增量**。举例：A 加 100 行人类代码（1.0）→ B 加 100 行 AI 代码（0.0）→ C 删掉所有 AI 代码，加 10 行人类代码（1.0）。按提交次数平均 ≈ 0.67，但仓库此时 110 行全是人类代码，合理结果是 100%。Patina 按存活行加权——被删除的行在 `git blame` 中自然消失，权重同时从分子分母消去，结果始终反映仓库当前状态。

```
写 Craft（commit message 末尾） → CI blame 加权聚合 → badge 部署到 GitHub Pages
```

两个设计选择：分数以 **Git Trailer** 形式存放在 commit message 末尾，Git 原生支持解析（`--trailer`），不依赖额外基础设施。**不做逐文件评分**——每次提交一个 0–1 数值。

## Craft convention

Craft 评分是 commit message 末尾的一行 Git Trailer：

```
Fix the widget parsing edge case

Craft: 0.95
```

规则（Git trailer 的解析机制要求，缺一不识别）：

- 与正文之间至少隔一个空行。紧接在 subject 后、中间无空行，不识别。
- trailer token（`Craft:`）必须**顶格**——行首有空格或 tab 会导致整行不被解析为 trailer。
- trailer 块内不能有空行——空行会截断，之后的 trailer 全部失效。
- trailer 块之后不能再有内容——任何非 trailer 行都会截断整个块。
- 取值 0–1（`0`、`0.5`、`0.95`、`1`）。

用 `--trailer` 自动满足格式：

```bash
git commit -m "message" --trailer "Craft: 0.95"
```

## Quick start

四步接入：

**1. 复制 workflow 文件**到 `.github/workflows/patina.yml`：

```yaml
name: Patina

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: true

permissions:
  contents: write
  pages: write
  id-token: write

jobs:
  craft:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}

    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          fetch-depth: 0
          filter: blob:none

      - name: Main
        run: source main.sh

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v5
        with:
          path: .patina
          include-hidden-files: true

      - name: Deploy to GitHub Pages
        id: deploy
        uses: actions/deploy-pages@v5
```

**2. 下载 `main.sh` 和 `badge.svg` 到仓库根目录**：

```bash
curl -O https://raw.githubusercontent.com/clonimai/patina/main/main.sh \
     -O https://raw.githubusercontent.com/clonimai/patina/main/badge.svg
```

**3. 开启 GitHub Pages**——Settings → Pages → Source 选 *GitHub Actions*。**注意：该 workflow 会覆盖你仓库的 Pages 部署**。如果你已有 Pages 站点，需自行合并两个部署流程。

**4. 每次提交写 Craft 评分，然后把 badge 挂到 README：**

```markdown
![Craftsmanship](https://<你的用户名>.github.io/<你的仓库>/badge.svg)
```

## Badge

默认模板：

[![badge.svg](https://raw.githubusercontent.com/clonimai/patina/main/badge.svg)](badge.svg)

模板是纯 SVG，替换**首次出现**的 `100%` 为实际百分比。路径通过 `main.sh` 顶部的 `template` 变量指定，可自行修改颜色和文案。

只要有一个被 blame 追踪到的 commit 缺少 Craft，badge 就降级为 `—%`——全有或全无。

## 补分

忘记写 Craft、或者想给历史 commit 补评分，可以手动编辑缓存。

**原理**：`refs/patina` 是一个隐形 ref，指向一条只含 `cache` 文件的 commit 链。CI 每次运行会读取 cache 中已有的评分作为基线——commit 如果没有 Craft trailer，就回退到 cache 中的值。cache 格式：

```
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

```bash
git fetch origin +refs/patina:refs/patina
git worktree add --detach .patina refs/patina
# 编辑 .patina/cache
git -C .patina add cache
git -C .patina commit --allow-empty-message -m ""
git -C .patina push origin HEAD:refs/patina --force
git worktree remove .patina
```

不创建 worktree 也可以——直接 checkout、编辑、push、切回原分支。接入前的老 commit 同样通过补分处理，否则 badge 降级为 `—%`。

## Notes & limitations

- **Craft 格式敏感**：`Craft:` 必须顶格（行首无空格/tab）、与正文间有空行、块内无空行、块后无内容。不符合任一条件即不被识别。
- **CI 权限**：workflow 需要 `contents: write`、`pages: write`、`id-token: write`，并开启 Pages。**该 workflow 会覆盖你仓库的 Pages 部署**——如果已有 Pages 站点，需自行合并部署流程。
- **并发控制**：workflow 内置 `concurrency`，同一分支多次 push 自动串行、旧的取消，避免快速推送导致部署乱序。

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

**`main.sh`**——纯 Bash，零外部依赖，`source` 方式运行（变量跨函数传递，无中间文件）。

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

- 在 `.patina/` 内生成 `cache` 文件（加权聚合缓存，每次 CI 覆盖）
- 推送 `refs/patina` 到远程（`--force`，缓存链更新）
- 创建/销毁临时 worktree（`.patina`，原地操作，跑完清理）
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
