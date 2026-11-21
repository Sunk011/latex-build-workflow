# LaTeX Build Workflow

Windows 上可复用的 LaTeX 编译配置：**编译前选择是否 Git commit → 完整编译 → 按版本归档 PDF → 清理过程文件**。

适合将同一套编译流程安装到论文、报告等已有 Git 仓库。仅分发脚本和配置，不包含论文正文、字体或个人路径。

## 功能

- VS Code LaTeX Workshop 编译按钮、`Ctrl+Alt+B` 和构建任务使用同一个入口。
- 有修改时弹出“提交后编译 / 直接编译 / 取消”；默认直接编译，无修改时不弹窗。
- 提交前可勾选文件、编辑说明；只提交所选文件当前的全部修改，保留其他文件的暂存状态。
- 正常触发 Git `pre-commit` 等原生 hooks；hook 拒绝提交时停止构建，不自动 push。
- 使用 `latexmk + XeLaTeX`，支持 BibTeX/Biber 以及 `glossaries`、`nomencl` 索引。
- PDF 保存到项目根目录 `pdf/`，同时提供固定预览文件和带时间、Git 版本的历史文件。
- 成功后清理过程文件，失败时保留日志和之前成功生成的 PDF。
- 安装器合并已有 VS Code 设置和任务，备份被修改的文件。

## 环境要求

当前版本面向 **Windows 10/11**，需要：

| 软件 | 用途 |
|---|---|
| PowerShell 7（`pwsh`） | 构建和安装脚本；Windows 自带 PowerShell 5.1 不适用 |
| Git | 版本号、修改检查、可选提交 |
| TeX Live | `latexmk`、`xelatex`、`bibtex`、`makeindex`、`makeglossaries`；使用 Biber 的项目还需 `biber` |
| VS Code + LaTeX Workshop | 编辑器编译与 PDF 预览；命令行使用时可不安装 VS Code |

可用 WinGet 安装前三项中的编辑器和命令行工具：

```powershell
winget install --id Microsoft.PowerShell --exact
winget install --id Git.Git --exact
winget install --id Microsoft.VisualStudioCode --exact
code --install-extension james-yu.latex-workshop
```

TeX Live 请按 [官方安装说明](https://tug.org/texlive/windows.html) 安装并加入 PATH。安装软件后重新打开终端，检查：

```powershell
pwsh --version
git --version
latexmk -v
xelatex --version
```

无需 GitHub CLI 即可使用本配置。

## 1. 拉取配置仓库

将工具仓库放在目标论文仓库之外，例如：

```powershell
git clone https://github.com/Sunk011/latex-build-workflow.git D:/tools/latex-build-workflow
```

已配置 SSH 的用户也可以使用：

```powershell
git clone git@github.com:Sunk011/latex-build-workflow.git D:/tools/latex-build-workflow
```

## 2. 安装到其他 LaTeX 仓库

假设已有项目 `D:/project/my-paper`，主文件为 `main.tex`：

```powershell
pwsh -NoProfile -File D:/tools/latex-build-workflow/install.ps1 -TargetPath D:/project/my-paper -MainFile main.tex -PdfPrefix 我的论文
```

`TargetPath` 必须是已有 Git 仓库的根目录。如果目标尚未初始化 Git，先执行：

```powershell
git -C D:/project/my-paper init
```

安装西北工业大学 `yanputhesis` 模板时，例如：

```powershell
pwsh -NoProfile -File D:/tools/latex-build-workflow/install.ps1 -TargetPath D:/project/my-thesis -MainFile yanputhesis-sample.tex -PdfPrefix 毕业论文 -ShellEscape
```

`-ShellEscape` 用于确实需要外部命令的可信模板。默认关闭。

安装完成后的结构：

```text
my-paper/
├── main.tex
├── latex-build.json                 # 本项目主文件和命名配置
├── .vscode/
│   ├── settings.json                # 合并编译设置
│   ├── tasks.json                   # 添加构建与清理任务
│   └── extensions.json              # 推荐 LaTeX Workshop
├── .latex-workflow/                 # 独立、可随项目提交的运行脚本
│   ├── build.ps1
│   ├── latex-common.ps1
│   ├── hooks/before-build.ps1
│   ├── latexmkrc
│   ├── VERSION
│   └── LICENSE
├── pdf/                            # 成功后生成，Git 忽略
└── .build/                         # 临时文件及安装备份，Git 忽略
```

运行所需文件均复制到目标项目，之后编译不依赖 `D:/tools/latex-build-workflow` 的位置。可以将 `.latex-workflow/`、`latex-build.json`、`.vscode/` 和 `.gitignore` 随目标项目正常提交。

已有 `.vscode` 的其他设置、任务和扩展推荐会被保留；JSONC 注释会在合并写回时去除，原文件先备份。若存在其他默认构建任务，安装器保留它，此时请使用 LaTeX Workshop 编译按钮或选择下述任务。

## 3. 日常编译

在 VS Code 打开目标项目根目录，打开主 `.tex` 文件：

- 点击 LaTeX Workshop 的编译按钮或按 `Ctrl+Alt+B`。
- `Ctrl+Shift+B` 运行默认构建任务。
- “终端 → 运行任务”中提供询问提交、跳过提交、仅清理三个 `LaTeX Workflow:` 任务。

保存时自动编译默认关闭，避免每次保存都出现提交窗口。主文件由 `latex-build.json` 指定，编译入口不会随当前编辑的章节文件变化。章节文件可用 `% !TEX root = ../main.tex` 帮助 LaTeX Workshop 识别预览主文件。

命令行运行（在目标项目根目录）：

```powershell
# 询问是否提交；Windows 弹窗需要 -STA
pwsh -NoProfile -STA -File ./.latex-workflow/build.ps1

# 直接编译，适合无需交互的环境
pwsh -NoProfile -File ./.latex-workflow/build.ps1 -CommitMode Skip

# 清理过程文件，保留 PDF 与发布的 SyncTeX
pwsh -NoProfile -File ./.latex-workflow/build.ps1 -CleanOnly

# 本次只保留 PDF，不保留源码/PDF 跳转文件
pwsh -NoProfile -File ./.latex-workflow/build.ps1 -CommitMode Skip -NoSyncTeX
```

## 项目配置

编辑目标项目根目录的 `latex-build.json`：

```json
{
  "rootFile": "main.tex",
  "pdfPrefix": "我的论文",
  "shellEscape": false,
  "keepSynctex": true
}
```

| 字段 | 含义 |
|---|---|
| `rootFile` | 相对于 Git 根目录的主 `.tex` 文件。建议放在根目录；所有编译命令从仓库根目录执行，`\input` 和图片等相对路径也据此编写 |
| `pdfPrefix` | 历史 PDF 的名称前缀，允许中文，不允许路径分隔符等非法文件名字符 |
| `shellEscape` | 是否允许 TeX 调用外部命令，仅为需要它的可信模板开启 |
| `keepSynctex` | 是否保留最新 PDF 的 `.synctex.gz`，用于双向跳转 |

当前只提供 XeLaTeX 流程。编译规则位于 `.latex-workflow/latexmkrc`，采用 `-norc` 显式加载，**项目原有 `.latexmkrc` 不会被覆盖，也不会自动合并或加载**。项目特有规则需加入这份工作流配置。缺少字体或宏包时，仍需安装模板要求的依赖。

## PDF 命名与清理

例如主文件为 `main.tex`、前缀为“我的论文”：

```text
pdf/main.pdf                                    # 最新成功版本，用于预览
pdf/main.synctex.gz                             # 最新版本的双向跳转数据
pdf/我的论文_20261121_153000_a1b2c3d.pdf           # 已提交的工作树
pdf/我的论文_20261121_153500_a1b2c3d_dirty.pdf     # 包含未提交修改
```

- 时间使用电脑本地时间。尚无首个 Git 提交时，版本标记为 `unborn`。
- 存在未提交修改，或构建期间 HEAD 改变时，使用 `_dirty` 标记；未提交内容不能仅凭 Git 短号还原。
- 同名追加序号，历史文件不覆盖、不自动淘汰。
- 成功后删除 `.build/latex/`；每次是完整构建，不依赖前次缓存。
- 失败后保留 `.build/latex/build.log` 与 TeX 日志，固定预览 PDF 不会被失败结果替换。
- 根目录中当前主文件对应的已知中间文件也会清理，但 Git 已跟踪的文件、其他资源和原来的根目录 PDF 保留。
- `.build/build.lock` 是空的并发控制文件，进程退出即释放锁，不必手工删除。
- 历史 PDF 不附带 SyncTeX；双向跳转使用固定的最新版本。

## Git 提交机制

“编译前 hook”是 `.latex-workflow/hooks/before-build.ps1`，由构建脚本调用；它不是 Git 原生事件，因此无需修改 `.git/hooks` 或 `core.hooksPath`。

选择“提交后编译”时，使用临时 Git 索引提交勾选文件，然后更新这些文件在实际索引中的状态。所选文件的**全部当前修改**都会提交，包含未暂存内容；未勾选文件的暂存内容保持不变。中文文件名、删除和重命名均有测试覆盖。

真正执行 `git commit` 时，仓库已有的原生 hooks 正常执行；提交失败就停止。此流程不执行 `push`。首次提交前请确认 Git 用户身份已配置。

## 更新、备份与卸载

更新工具仓库后，对目标项目重新运行安装器：

```powershell
git -C D:/tools/latex-build-workflow pull --ff-only
pwsh -NoProfile -File D:/tools/latex-build-workflow/install.ps1 -TargetPath D:/project/my-paper -Force
```

未传 `MainFile`、`PdfPrefix`、`ShellEscape` 时保留已有项目配置。`-Force` 允许替换内容不同的运行脚本；若未指定，会在写入前停止，避免覆盖定制脚本。即便使用 `-Force`，已有文件也先备份到 `.build/latex-workflow-backups/<时间_随机号>/`，可按原相对路径恢复。

更新会替换工作流专属的 `latexmkrc`；修改过它时，请先保留定制内容，更新后按需合并。备份目录不会被编译清理任务删除。

卸载时，删除 `.latex-workflow/` 和 `latex-build.json`，在 `.vscode` 中移除工作流对应的设置及带 `Managed by latex-build-workflow` 标记的任务，或恢复安装前备份；按需移除 `.gitignore` 中标记的配置块。历史 PDF 可自行保留。

## 验证

在本工具仓库根目录执行：

```powershell
pwsh -NoProfile -File ./tests/test-workflow.ps1
```

测试使用临时 Git 仓库，检查安装合并和备份、配置更新、中文文件名、选择性提交、原生 hook 拒绝、重复编译、失败时保留旧 PDF、成功后的清理。不会在真实论文仓库中创建提交。

## 常见问题

- **找不到 `pwsh` / `latexmk`**：重新打开终端和 VS Code，检查 PATH；Windows PowerShell 5.1 不能替代 PowerShell 7。
- **编译成功但预览打不开**：打开配置中的主文件后再执行查看 PDF，确认输出在项目根目录的 `pdf/`；多根工作区建议为论文单独打开一个窗口。
- **看不到提交窗口**：无修改时不会弹窗；命令行交互模式必须加 `-STA`，也可用 `-CommitMode Skip`。
- **旧 PDF 被占用**：关闭锁定文件的阅读器后重试；推荐 LaTeX Workshop 内置预览。
- **提交失败**：查看命令输出，检查 Git 用户信息、签名设置或现有 hooks；脚本不会绕过它们。

## 许可

[MIT](LICENSE)。配置最初用于西北工业大学 LaTeX 论文项目，现提取为独立工作流；本仓库不分发该论文模板。
