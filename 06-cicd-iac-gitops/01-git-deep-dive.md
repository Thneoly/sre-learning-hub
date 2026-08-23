# 01 · Git 深入：对象模型、分支本质与救命操作

> 模块：06-cicd-iac-gitops ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点，是 CI/CD 与 GitOps 地基，面试高频）

## 学习目标

- 能解释 commit / tree / blob 三种对象的关系，并用 `git cat-file` 直接观察对象库
- 能解释 branch 只是指向 commit 的可变指针（一个 41 字节的文件），据此理解 HEAD、detached HEAD 与 fast-forward
- 能操作 merge 与 rebase 完成分支整合，并能按"黄金法则"判断该用哪个
- 能排查并解决合并冲突，包括 `--abort` 撤退与冲突标记解读
- 能用 stash 与 reflog 找回"看起来丢了"的提交，能配置 pre-commit hook 拦截坏提交

## 1. 对象模型：Git 是一个内容寻址数据库

Git 的底层不是"文件快照 + 增量"，而是**对象数据库**：所有内容（文件、目录结构、提交）都以 SHA-1 哈希为键存进 `.git/objects/`。理解这一点，后面所有命令都只是对这个数据库的查询和写入。

三种核心对象：

| 对象 | 存什么 | 类比 |
|---|---|---|
| blob | 文件**内容**（不含文件名） | 一块纯数据 |
| tree | 目录：文件名 → blob/其他 tree 的映射 | 目录 inode |
| commit | 一个 tree + 父提交 + 作者/信息 | 目录快照 + 指针 |

```
commit a1b2c3d
├── tree   ←── 根目录快照
│     ├── 100644 blob e4f5a6  "a.txt"
│     ├── 100644 blob f7a8b9  "b.txt"
│     └── 040000 tree 0c1d2e  "src/"
│                └── 100644 blob 3e4f5a  "src/main.go"
├── parent ←── 上一个 commit（初始提交没有）
└── author / committer / message
```

推论：

- 改一个字 → 生成新 blob → 生成新 tree → 生成新 commit，旧对象原地不动（所以历史不可改，改历史 = 造一条新链）
- 两个文件内容完全相同 → 共享同一个 blob（去重）
- commit hash 同时承担"内容校验"和"唯一标识"两个角色

## 2. branch 的本质：41 字节的文本文件

```bash
# [任意节点] Ubuntu 上需要先装 git
sudo apt-get update && sudo apt-get install -y git
```

```bash
# [任意节点] 建一个练习仓库，观察 .git 内部
mkdir -p ~/gitlab-demo && cd ~/gitlab-demo
git init -b main
git config user.name  "cka-student"
git config user.email "cka@example.com"

echo "hello" > a.txt
git add a.txt
git commit -m "first commit"

# branch 就是一个文件，内容是它指向的 commit hash
cat .git/refs/heads/main
# 输出形如：8e3c9f1d2a...（40 位 hash + 换行 = 41 字节）

# HEAD 又是指向"当前 branch"的指针
cat .git/HEAD
# 输出：ref: refs/heads/main

git rev-parse main HEAD   # 两者此刻相同
```

```
HEAD ──▶ main ──▶ commit-3 ──▶ commit-2 ──▶ commit-1
                        ▲
              feature ──┘   （另一个 41 字节文件，指向别的 commit）
```

- `git branch feature` = 写一个新 ref 文件，指向当前 commit，**零拷贝、瞬时完成**
- `git checkout/switch` = 改 HEAD 指向 + 把工作区换到对应快照
- detached HEAD：HEAD 直接指向某个 commit 而不是 branch。此时提交"挂在空中"，切走后容易被 GC 回收——要么建 branch 接住它，要么别在 detached 状态提交

## 3. merge vs rebase

两者都是"把两条分叉的线合起来"，区别是**谁被改写**：

```
合并前：                merge 后：               rebase 后：
  A---B---C  main         A---B---C---M  main      A---B---C---D'--E'  main
       \                       \             /
        D---E  feature          D---E------   （feature 的提交被"复印"到 main 顶端）
```

| 维度 | merge | rebase |
|---|---|---|
| 历史 | 保留真实分叉，多一个 merge commit | 线性，像没分过叉 |
| 改写对象 | 不改任何已有提交 | 重写当前分支的提交（新 hash） |
| 冲突 | 一次性解决 | 可能逐个提交重复解决 |
| 适用 | 公共分支（main/release） | 自己的私有特性分支 |

**黄金法则**：已经 push 到共享分支的提交，永远不要 rebase——别人基于旧 hash 的工作会和你的新链分叉，产生地狱级冲突。团队惯例通常是"rebase 本地、merge 公共"：

```bash
# [任意节点] 模拟一次特性开发与整合
cd ~/gitlab-demo
git switch -c feature/login
echo "login page" > login.txt
git add . && git commit -m "feat: add login page"

git switch main
echo "readme" > README.md
git add . && git commit -m "docs: add readme"

# 方式一：merge（在 main 上执行）
git merge feature/login -m "merge: integrate login"

# 想要线性历史时，先回到分叉前重来一次
git reset --hard HEAD~1                 # 撤销刚才的 merge
git switch feature/login
git rebase main                          # 把 feature 的提交搬到 main 顶端
git switch main
git merge --ff-only feature/login        # 此刻是 fast-forward，不产生 merge commit
git log --oneline --graph --all
```

fast-forward：目标分支没有新提交时，merge 只是**移动指针**，不产生 merge commit。`--ff-only` 强制要求这种状态，否则报错——适合保护 main 的线性历史。

## 4. 冲突处理

```bash
# [任意节点] 人为制造一次冲突
cd ~/gitlab-demo
git switch -c feature/conflict
sed -i 's/hello/feature-version/' a.txt
git add . && git commit -m "change a.txt on feature"

git switch main
sed -i 's/hello/main-version/' a.txt
git add . && git commit -m "change a.txt on main"

git merge feature/conflict
# Auto-merging a.txt
# CONFLICT (content): Merge conflict in a.txt
# Automatic merge failed; fix conflicts and then commit the result.
```

打开 a.txt 会看到冲突标记：

```
# [文件 a.txt] 冲突标记示例
<<<<<<< HEAD
main-version
=======
feature-version
>>>>>>> feature/conflict
```

- `<<<<<<< HEAD` 到 `=======` 是**当前分支**的版本，`=======` 到 `>>>>>>>` 是**被合并分支**的版本
- 处理流程：手工编辑成想要的结果（把三行标记全删掉）→ `git add a.txt` → `git commit`
- 随时可以反悔：merge 场景 `git merge --abort`，rebase 场景 `git rebase --abort`，回到操作前
- rebase 过程中解决冲突后用 `git rebase --continue` 走下一个提交，`git rebase --skip` 跳过空提交

## 5. 救命操作：stash 与 reflog

### 5.1 stash：把没提交的工作"揣兜里"

典型场景：feature 写了一半，线上炸了要立刻切到 main 修 bug。

```bash
# [任意节点]
cd ~/gitlab-demo
git switch -c feature/wip
echo "half-done" > wip.txt                # 未跟踪文件
echo "half-done2" >> a.txt                # 已跟踪文件的改动

git stash push -u -m "login 半成品"       # -u 连未跟踪文件一起存
git status                                # 干净了
git switch main
# ...修 bug、提交、推送...
git switch feature/wip
git stash list
# stash@{0}: On feature/wip: login 半成品
git stash pop                             # 取回并删除栈顶；apply 则保留备份
```

注意：`stash pop` 后若与当前代码冲突，stash 不会被删除，解决冲突后需 `git stash drop` 手动清理。

### 5.2 reflog：HEAD 的移动日志，几乎所有"丢了的提交"都在这

```bash
# [任意节点] 先"手滑"丢掉提交
cd ~/gitlab-demo
git log --oneline | head -3
git reset --hard HEAD~2                   # 假装回退过头

git log --oneline                         # 刚才的两个提交不见了？

# reflog 记录了 HEAD 的每一次移动，包括 reset/rebase/merge 之前的位置
git reflog -5
# 9a8b7c6 (HEAD -> main) HEAD@{0}: reset: moving to HEAD~2
# 1f2e3d4 HEAD@{1}: commit: docs: add readme
# ...

git reset --hard HEAD@{1}                 # 回到 reset 之前的那次提交
git log --oneline                         # 提交回来了
```

- 只要对象还活着（被 reflog 引用），GC 就不会删它，默认保留 90 天
- rebase 改写历史后想整段退回：`git reflog` 找 rebase 开始前的位置，`git reset --hard <hash>`
- 连 reflog 都没有的"孤儿对象"：`git fsck --lost-found` 还能扫出 dangling commit
- 兜底心态：Git 中几乎没有真正"立刻丢失"的数据，慌的时候先 `git reflog`，别乱敲 reset

## 6. hooks：把规范变成强制

hooks 是 `.git/hooks/` 下的可执行脚本，按文件名触发。本地最常用 `pre-commit`（commit 前跑）：

```bash
# [文件 .git/hooks/pre-commit] —— 创建后必须 chmod +x 才生效
#!/usr/bin/env bash
set -eu

# 1) 拦截大于 5MB 的文件
while IFS= read -r f; do
  size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$size" -gt 5242880 ]; then
    echo "拒绝提交：$f 超过 5MB，请改用制品库或 Git LFS" >&2
    exit 1
  fi
done < <(git diff --cached --name-only)

# 2) 拦截调试残留
if git diff --cached -U0 | grep -nE '^\+.*(console\.log\(|XXX-FIXME)'; then
  echo "拒绝提交：发现调试残留（console.log / XXX-FIXME）" >&2
  exit 1
fi
exit 0
```

```bash
# [任意节点] 验证 hook 生效
chmod +x ~/gitlab-demo/.git/hooks/pre-commit
cd ~/gitlab-demo
echo "console.log(1)" >> a.txt
git add a.txt
git commit -m "test hook"
# 拒绝提交：发现调试残留（console.log / XXX-FIXME）
git checkout -- a.txt                    # 还原，别把演示残留带进历史
```

两点工程认知：

- 本地 hook 不随仓库分发（`.git` 目录不进版本库），团队统一靠 husky/pre-commit 框架把 hook 文件放进仓库再安装
- **服务端 hook**（bare 仓库的 `pre-receive`）才是真正的红线：GitLab 的 push rules、protected branch 本质就是这套机制，客户端 hook 只是体验优化

## 7. tag 与版本

| 类型 | 命令 | 内容 | 用途 |
|---|---|---|---|
| annotated | `git tag -a v1.2.0 -m "release 1.2.0"` | 完整对象（含打标签人、时间、可签名） | 正式发布 |
| lightweight | `git tag v0.1.0` | 只是指向 commit 的 ref，无独立对象 | 本地临时书签 |

版本号遵循 SemVer `主.次.修订`：不兼容改动 +主、新增功能 +次、修 bug +修订。CI 里常以 tag 触发发布流水线（见下一章 `rules: if $CI_COMMIT_TAG`）。

```bash
# [任意节点]
cd ~/gitlab-demo
git tag -a v0.1.0 -m "first release"
git tag -l -n1                           # 列表带说明
git show v0.1.0 --stat | head -5
git push origin v0.1.0                   # tag 默认不随 push 走，要显式推
git describe --tags                      # v0.1.0-3-g9a8b7c6：距 tag 3 个提交
```

## 8. .gitignore 规范

规则语法（逐条从上往下匹配，后面的规则可以覆盖前面的）：

```gitignore
# [文件 .gitignore] 仓库根目录
# 注释以 # 开头
*.log                     # 所有 .log
node_modules/             # 目录（带斜杠，任意层级）
/build                    # 只忽略根目录的 build（开头斜杠 = 锚定）
config/local.yml          # 精确路径
*.tmp
!keep.tmp                 # 例外：这个文件要跟踪
```

三条高频纪律：

1. **只 ignore 不该进库的**：编译产物、依赖目录、本地配置、IDE 元数据（`.idea/`、`.vscode/`）、`.env`、`*.tfstate`（见第 6 章）
2. **已被跟踪的文件不受 .gitignore 影响**：先 `git rm --cached <file>` 再补规则
3. 排查用 `git check-ignore -v path/to/file`，它会告诉你命中了哪条规则

```bash
# [任意节点]
cd ~/gitlab-demo
printf '*.log\n.env\n' > .gitignore
git add .gitignore && git commit -m "chore: add gitignore"
touch debug.log .env
git status --short                        # 两者都不出现
git check-ignore -v .env                  # .gitignore:2:.env
```

## 实战演练：把对象库翻个底朝天

在任意 Ubuntu 节点完成（全部只影响 `~/gitlab-demo` 目录，可反复重来）。

```bash
# [任意节点] 步骤 1：观察一个提交的内部结构
cd ~/gitlab-demo
git cat-file -t HEAD            # commit
git cat-file -p HEAD            # 看 tree/parent/author
# tree 3f5a7c...
# author cka-student <cka@example.com> ...

git cat-file -p HEAD^{tree}     # 根 tree：每行 mode type hash 文件名
# 100644 blob 3e4f5a...  a.txt
# 100644 blob ...       README.md
# ...

# 直接用内容算 hash，验证"内容寻址"
echo "hello" | git hash-object --stdin
# ce013625030ba8dba906f756967f9e9ca394464a —— 和库里 a.txt 首版的 blob hash 一致
```

```bash
# [任意节点] 步骤 2：验证 branch 是指针
git rev-parse main > /tmp/main-hash
git switch -c tmp-branch
cat .git/refs/heads/tmp-branch && cat /tmp/main-hash   # 完全相同
git branch -D tmp-branch
```

```bash
# [任意节点] 步骤 3：完整走一遍 merge 冲突 → 解决 → stash → reflog
# （按第 4、5 节命令依次执行）
# 验证方法：
git log --oneline --graph --all            # 能看到 merge 节点或线性历史
git stash list                             # 空
git fsck --full 2>&1 | head -3             # 无 error 行
```

预期结果：三条命令都能输出与上文一致的结构，仓库无损坏。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `git push` 被拒 non-fast-forward | 远端有你没有的提交 | 先 `git pull --rebase` 再 push，别用 `--force`（共享分支） |
| detached HEAD 下提交后切 branch 不见了 | 提交没被任何 ref 引用 | `git reflog` 找到 hash，`git branch rescue <hash>` 接住 |
| rebase 后同事那边一团糟 | rebase 了已推送的公共提交 | 沟通后让对方 `git rebase --onto` 或 reset 到共同祖先；今后只 rebase 私有分支 |
| .gitignore 加了规则但文件还在仓库里 | 文件已被跟踪 | `git rm --cached <file>` 并提交 |
| stash pop 冲突后 stash 消失了？ | 冲突时 pop 不会删 stash | 解决冲突后 `git stash drop` 手动清理 |
| Windows 换行导致整文件 diff | CRLF/LF 混用 | `git config core.autocrlf input`（Linux 侧）+ 仓库加 `.gitattributes` 写 `* text=auto` |

## 自测

<details><summary>1. 为什么改一个已推送 commit 的 message 也会导致它的 hash 变化？同事拉代码会发生什么？</summary>

commit 对象的内容包含 tree、parent、author/committer、时间戳和 message，SHA-1 是对整段内容算的——改任何一项都是新对象、新 hash。而且原提交的所有子孙提交因为 parent 链变了也要全部重写。同事本地还留着旧链，你这边是新链，两边再交互就会分叉冲突，只能靠 rebase/reset 对齐。这就是"公共分支禁止 rebase/force push"的根因。
</details>

<details><summary>2. fast-forward 与三方合并的触发条件分别是什么？--ff-only 在什么团队规范下有用？</summary>

目标分支自分叉后没有新提交时，merge 只需把 branch 指针移到源分支顶端（fast-forward）；两边都有新提交时，Git 找到共同祖先做三方合并（ancestor/ours/theirs），生成 merge commit。`--ff-only` 要求"必须能 fast-forward 否则失败"，用于保护 main 线性历史：想合入必须先 rebase 整理好再回来。
</details>

<details><summary>3. git stash 存的东西在哪里？pop 之后 stash 条目为什么有时还在？</summary>

stash 本质是 refs/stash 指向的一串 commit（工作区与暂存区各一个，带合并结构），存在对象库里。`pop` = `apply` + `drop`，但 apply 产生冲突时 Git 不会自动 drop（防止你还没解决完就丢数据），所以要手工 `git stash drop`。
</details>

<details><summary>4. 如果 protected branch 禁止 force push，但一次 rebase 后确实需要覆盖远端，正确的做法是什么？</summary>

不要想办法绕过保护。正确姿势：把改写后的提交推到一个新分支开 MR/PR，让远端 main 通过一次正常 merge 收敛；或者在管理面临时解除保护并广播（团队协作场景）。本地已经错乱时，先 `git fetch` 后以远端为准 reset，再重新整理。核心是"远端公共历史视为不可变"。
</details>

<details><summary>5. 为什么说"Git 几乎不会真正丢数据"？从对象库与 GC 角度解释 reflog 的作用。</summary>

reset/rebase/branch -D 只是把 ref 指到别处，原 commit 对象仍在 `.git/objects`。GC（`git gc`，默认自动触发）只回收"不可达"对象，而 reflog 把 HEAD 与各 ref 的历史位置都登记为可达根，默认保留 90 天。所以 `git reflog` → `git reset --hard <hash>` 能救回绝大多数"手滑"；真正危险的是 `git gc --prune=now --aggressive` 或仓库损坏这类物理删除。
</details>

## 延伸阅读

- Pro Git Book（中文版）第 10 章"Git 内部原理"：<https://git-scm.com/book/zh/v2/>
- Git 官方文档 `git-reflog` / `git-stash` / `githooks`：<https://git-scm.com/docs>
- SemVer 规范：<https://semver.org/lang/zh-CN/>
