# 多 Agent + Git Worktree 协作 SOP

本文定义 smart_frame 使用 Codex、Claude Code、Kimi Code CLI、Paseo 或其他 coding agent 并行工作的统一流程。工具可以不同，Git 隔离、任务契约、验收和交接格式必须相同。

## 1. 核心模型

`AGENTS.md` 是唯一权威项目规则。Kimi/Codex 可直接读取它；Claude Code 通过根目录 `CLAUDE.md` 导入它。客户端专用文件不得复制业务规则，避免多份规范漂移。

并行工作的隔离单位是：

```text
一个任务 = 一个任务简报 = 一个分支 = 一个 worktree = 一个可写 Agent
```

Agent 会话隔离不等于文件隔离。即使工具支持“子 Agent”，只要多个 Agent 会写文件，就必须分别绑定到不同 worktree。主工作区只用于协调、查看和最终集成，默认不在其中并行开发。

## 2. 角色与职责

| 角色 | 职责 | 禁止事项 |
|---|---|---|
| 用户 | 决定目标；批准 commit、push、合并、删除等 Git 变更 | — |
| 主协调者 | 确认基线、拆任务、分配文件 owner、创建 worktree、收集交接、归并前审查、全量验收 | 不把同一可写目录分给多个 Agent |
| 实现 Agent | 只在分配的 worktree 和文件边界内实现、测试、交接 | 不自行扩大范围、归并、commit 或 push |
| 审查 Agent | 只读检查 diff、测试与风险；给出可定位的问题 | 未获明确分配时不修改实现 |

任务存在先后依赖时不要强行并行。先并行只读调研/接口设计，待上游接口稳定后再启动下游实现。

## 3. 启动前检查

主协调者在仓库根目录执行：

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git worktree list
```

必须记录基线 commit。工作区已有改动属于用户：不得移动、覆盖或清理；若它们与任务文件重叠，先停下并让用户决定。未跟踪文件也按用户资产处理。

拆分任务时，每份简报至少写清：目标、基线 commit、允许修改的文件、禁止修改的文件、输入/输出接口、验收命令、交接格式、依赖与建议归并顺序。可复制本文末尾模板。

适合并行：不同模块、实现与只读审查、互不重叠的测试/文档。慎重并行：`apps/smart_frame/pubspec.yaml`、`apps/smart_frame/lib/main.dart`、协议定义、共享配置模型、同一测试文件；这些文件应指定唯一 owner。

## 4. 创建 worktree

推荐分支名：`agent/<任务号>-<简短主题>`；目录名由脚本把 `/` 转为 `-`。基线通常为 `main`，也可以是明确的 commit 或已稳定的上游分支。

```bash
./tool/agent_worktree.sh create agent/01-photo-cache main
./tool/agent_worktree.sh list
```

脚本默认把 worktree 放在仓库内的 `.agents/worktrees/` 下；该目录已被 Git 精确忽略，隐藏目录也不会进入常规项目搜索和 Flutter 源码扫描。这样所有 Agent 都能从项目根目录稳定定位工作区，同时不会忽略 `.agents/` 下未来可能需要版本控制的其他规则或技能。也可显式指定父目录：

```bash
WORKTREE_ROOT=/data/worktrees ./tool/agent_worktree.sh create agent/02-review main
```

等价的原生 Git 命令是：

```bash
git worktree add -b agent/01-photo-cache .agents/worktrees/agent-01-photo-cache main
```

创建分支/worktree 会改变 Git 状态，执行前应已得到用户对本次并行工作的授权。SOP 不自动 commit、push、merge 或删除。

## 5. 启动不同 Agent

所有 Agent 的工作目录都必须指向其 worktree，而不是主工作区。启动提示中直接粘贴任务简报，并明确“先读 AGENTS.md 与 docs/agent-workflow.md”。

```bash
# Codex（具体非交互参数按本机版本选择）
cd .agents/worktrees/agent-01-photo-cache && codex

# Claude Code
cd .agents/worktrees/agent-02-review && claude

# Kimi Code CLI
cd .agents/worktrees/agent-03-tests && kimi
```

若使用 Paseo，流程仍相同：先创建 worktree，再创建 Agent，并把 Agent 的 `cwd` 设为返回的 `worktreePath`。provider/model 必须从本机可用 provider 列表和编排偏好中选择，不在仓库 SOP 中硬编码。

若某客户端内建子 Agent 但不能为每个写任务指定独立 worktree，仅允许它们做只读探索/审查；写任务改用独立顶层会话。

## 6. Agent 执行规则

每个实现 Agent：

1. 读取 `AGENTS.md`、本 SOP 和任务相关文档，确认当前目录、分支及基线。
2. 检查 `git status --short`；发现未知改动立即报告，不得清理。
3. 只修改简报授权的文件。需要越界时先报告原因和建议，不自行扩展。
4. 小步实现并运行与风险相称的定向测试；代码任务最终必须执行项目硬性要求的 analyze 和全量 test。
5. 不执行 commit、push、merge、rebase、cherry-pick、worktree remove 或 branch delete，除非用户对该动作明确授权。
6. 按第 8 节格式交接，并保持 worktree 可供主协调者检查。

Flutter 验证统一使用无代理环境：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter analyze
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
```

多个 worktree 可并行测试，但首次依赖下载、Flutter SDK 缓存写入或高负载构建可能争用资源。出现 SDK/cache 锁时降低并发，不能用删除缓存或杀死其他 Agent 的方式“解锁”。

## 7. 主协调者验收与归并

收到交接后，主协调者依次检查：

```bash
git -C <worktree> status --short
git -C <worktree> diff --check
git -C <worktree> diff --stat
git -C <worktree> diff
```

先核对是否越界，再核对实现与测试。测试通过不替代 diff 审查。多个任务的推荐归并顺序是：共享接口/配置 → 实现 → UI/调用方 → 测试补充 → 文档。

因为本项目要求 Git 写操作逐次获批，主协调者应先向用户汇报待归并内容和风险；获得明确确认后，才可按 [commit-convention.md](commit-convention.md) commit，并根据用户指定方式 merge/cherry-pick。若尚未获准 commit，可用 `git diff --binary` 导出补丁供审查，但不要把补丁写入其他 Agent 的工作目录。

所有变更汇总到集成分支后，必须重新运行 `flutter analyze` 和全量 `flutter test`。各 worktree 单独通过不代表组合后通过。

冲突处理原则：保留双方意图，回到权威代码/协议/规格判断；禁止用 `ours/theirs`、覆盖复制或硬重置跳过理解。共享文件的冲突由该文件 owner 或主协调者解决。

## 8. 标准交接格式

```markdown
状态：DONE | BLOCKED | PARTIAL
任务/分支：<task> / <branch>
worktree：<absolute-path>
基线：<commit>

改动：
- <file>: <what/why>

验证：
- `<command>` → <result>

接口/行为变化：
- <none or details>

风险与未完成：
- <none or details>

建议归并顺序：
- <before/after which task>
```

`BLOCKED` 必须写明已尝试的办法和继续所需条件；`PARTIAL` 必须区分可保留成果与不可用草稿。

## 9. 收尾

只有在变更已安全归并、集成验证通过且用户确认后，才归档 worktree。先做只读确认：

```bash
git worktree list
git -C <worktree> status --short
git branch --merged
```

随后按用户批准的具体目标执行 `git worktree remove <path>`；是否删除分支另行确认。禁止批量清理或用 `--force` 掩盖未提交改动。

## 10. 任务简报模板

```markdown
# Task <id>: <title>

- 目标：
- 基线 commit：
- 分支：`agent/<id>-<topic>`
- worktree：由主协调者填写绝对路径
- owner：
- 依赖：无 | Task <id>
- 建议归并顺序：

允许修改：
- `path/**`

禁止修改：
- `path/file`

输入/现有接口：
- ...

输出/验收接口：
- ...

验证：
- `<targeted command>`
- `flutter analyze`
- `flutter test`

执行约束：
- 先读 `AGENTS.md` 与 `docs/agent-workflow.md`
- 不 commit/push/merge，不清理未知改动
- 按标准交接格式返回
```

## 11. 故障处理

- 分支已存在：用 `git worktree list` 查它是否已绑定；不要自动复用未知目录或强制新建。
- 目标目录已存在：视为潜在用户数据，换名字或请用户处理，不删除。
- Agent 跑错目录：立即停止写入，报告已改文件；不要自行搬运或回滚。
- 两个任务重叠：暂停后启动的任务，由主协调者重新划分 owner/接口。
- Agent 失联：保留 worktree，通过 `git status`/`git diff` 恢复现场；不要因会话失联删除目录。
- 验证失败：交接状态不得写 DONE；记录完整命令、首个关键错误和是否与本任务相关。
