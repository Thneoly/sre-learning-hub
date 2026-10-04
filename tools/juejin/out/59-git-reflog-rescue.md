---
title_juejin: 'git reset --hard 之后先别哭：reflog 里存着你刚弄丢的那个分支'
title_zhihu: 'git reset --hard 之后先别哭：reflog 里存着你刚弄丢的那个分支'
description: 'Git对象不可变，丢的大多是指针：reflog记录HEAD每次移动，默认保留90天（不可达条目30天），三步救回reset弄丢的分支，fsck兜底孤儿提交，附gc危险区与救不回的诚实边界。'
category_id: "6809637769959178254"
tags: "后端,运维"
column_id: "7686472562230312970"
---

# git reset --hard 之后先别哭：reflog 里存着你刚弄丢的那个分支

> 周五 18:47，为了"清掉本地乱七八糟的改动"，一条 `git reset --hard HEAD~3` 敲下去，工位三秒后传来哀嚎：下午写的那两个提交没了。
>
> 同事开始翻编辑器的本地历史、翻回收站，甚至打算重写。我说先别哭——你丢的大概率不是代码，是一根 41 字节的指针。（典型案例，细节脱敏虚构）

## 一、底座：对象不可变，引用可丢

为什么救得回？因为 Git 的底层不是"文件快照加增量"，而是一个**内容寻址的对象数据库**：文件内容、目录结构、提交，全部以 SHA-1 哈希为键，存进 `.git/objects/`。

三种核心对象：

| 对象 | 存什么 | 类比 |
| --- | --- |
| blob | 文件内容（不含文件名） | 一块纯数据 |
| tree | 文件名到 blob/子 tree 的映射 | 目录 inode |
| commit | 一个 tree + 父提交 + 作者与信息 | 目录快照 + 指针 |

两条推论，直接决定今天的结论。

其一：改一个字，就生成新 blob、新 tree、新 commit，**旧对象原地不动**。所谓"改历史"，本质是造一条新链——老链一条不少，还躺在对象库里。

其二：branch 的本体只是一个 41 字节的文本文件，存的内容是"我指向哪个 commit"：

```bash
# 在任意本地仓库的根目录下执行
cat .git/refs/heads/main
# 输出形如：8e3c9f1d2a...（40 位 hash + 换行 = 41 字节）
```

把这两条放在一起，reset --hard、branch -D、rebase 这三个"刽子手"就露馅了：它们干的是同一件事——**挪指针，不删对象**。指针挪走，原来的 commit 还在 `.git/objects/` 里，没人引用，但也没人敢动：GC 只回收"不可达"对象，而谁可达，Git 另有一本账。

**你以为的删库，多半只是抽走了书签**——书还原封不动锁在对象库里，一页没少。

## 二、reflog：HEAD 的行车记录仪

对象还在，下一个问题是：hash 你不记得，`git log` 里也不显示，怎么找到它？那本账就是 reflog。

reflog 是 HEAD（以及各分支）的本地移动日志：每次 commit、reset、checkout、merge、rebase 之后 HEAD 落在哪，它都记一行。`git log` 展示的是"当前这条链的历史"，reflog 记录的是"这个仓库发生过什么"——被 reset 掉的提交在 log 里人间蒸发，在 reflog 里明明白白。

更关键的是它握着 GC 的生死簿：`git gc` 只回收不可达对象，而 reflog 把 HEAD 与各 ref 的历史位置**登记为可达根，默认保留 90 天**——准确说：从当前分支仍可达的条目 90 天，被 reset/rebase 抛弃的"不可达"条目默认只有 30 天（`gc.reflogExpireUnreachable`）。只要一条记录还在 reflog 里，它指向的对象就是"活着的"，GC 碰不得。

**log 记录历史，reflog 记录你干过什么**——前者属于分支，后者属于你。

但把 reflog 当万能存档，会栽三个跟头：

- 只在本机。reflog 是本地文件，不随 clone 走、不随 push 走——远端没有你的 reflog，你的也救不了同事【从业者判断】。
- CI 的浅克隆里没有。`--depth 1` 拉下来的仓库，对象库本身被裁剪过，reflog 无从谈起——别指望在 CI 的克隆里翻出上周的提交【从业者判断】。
- 有保质期。可达条目默认 90 天、不可达条目默认 30 天，过期后记录消失，对象失去靠山，进入 GC 的回收名单。

## 三、三步救回：找 SHA → 固定住 → 验证

全程可以在一个练习仓库里复现，两分钟搭好，怎么折腾都不心疼：

```bash
# 搭一个可反复重来的练习仓库，任意目录均可
mkdir -p ~/gitlab-demo && cd ~/gitlab-demo
git init -b main
git config user.name  "cka-student"
git config user.email "cka@example.com"
echo "hello" > a.txt && git add a.txt && git commit -m "first commit"
echo "readme" > README.md && git add . && git commit -m "docs: add readme"
echo "more" >> a.txt && git add . && git commit -m "feat: more"
```

### 第一步：reflog 找 SHA

制造一起手滑：

```bash
cd ~/gitlab-demo
git log --oneline | head -3
git reset --hard HEAD~2        # 假装回退过头
git log --oneline              # 刚才的两个提交不见了
```

此刻最重要的是管住手：不要再敲任何 reset。先看行车记录仪：

```bash
git reflog -5
# 9a8b7c6 (HEAD -> main) HEAD@{0}: reset: moving to HEAD~2
# 1f2e3d4 HEAD@{1}: commit: feat: more
# ...
```

`HEAD@{0}` 是现在，`HEAD@{1}` 就是 reset 之前的位置——`1f2e3d4`，这就是要找的 SHA。

### 第二步：固定住

两种姿势：

```bash
# 姿势 A（推荐）：建分支接住，不动当前工作区
git branch rescue 1f2e3d4      # hash 换成你 reflog 里看到的那个

# 姿势 B：直接把 main 拉回 reset 之前
git reset --hard HEAD@{1}
```

推荐 A 的理由写在对象模型里：建 branch 只是写一个新的 41 字节 ref 文件，**零拷贝、瞬时完成**，不碰工作区也不碰 main。刚手滑过一次的人，不该立刻再碰 reset——救回的东西先钉死，再从容决定怎么合。

### 第三步：验证

```bash
git log --oneline --graph --all   # rescue 指向的那条链回来了
git log --oneline rescue          # 只看救回的链
```

rebase 翻车同理：改写历史后想整段退回，`git reflog` 找到 rebase 开始前的位置，`git reset --hard <hash>`。

**救回的顺序是先找到、再固定、后验证**；固定用 branch 而不是再一次 reset，是**给第二次手滑留余地**。

## 四、真正的危险区：什么时候哭是对的

诚实边界必须讲：Git 里真正的数据丢失只有两类——**对象被物理清除，或者内容从未进入对象库**。对着这两类，reflog 无能为力。

**gc 的剪刀。** `git gc` 默认自动触发，只回收不可达对象，reflog 保它最多 90 天（不可达条目 30 天）。而 `git gc --prune=now --aggressive` 是明抢：立刻清除不可达对象，一天都不等。不过"不可达"的判定包含 reflog——还没过期的 reflog 条目仍算可达根，所以彻底的明抢要先 `git reflog expire --expire=now --all` 清空保质期再 gc；这两条一起跑，reflog 记录和对象一起没，照样白板。仓库文件损坏同理，属于物理删除这一类。

**从未提交过的东西。** `reset --hard` 清掉的不只是提交，还有工作区里未提交的改动——没 add 过的内容，对象库里根本不存在；add 过但没 commit 的，blob 虽已入库，却没有任何引用与记录指向它，同样无从找起。对这两类，reflog 都无从谈起，编辑器的本地历史这时候是最后一线【从业者判断】。

**detached HEAD 里的提交。** HEAD 直接指向某个 commit 而非分支时，提交"挂在空中"，切走后容易被 GC 回收——要么先建分支接住，要么别在 detached 状态提交。

**跨机器的失联提交。** rebase、amend 改写历史等于造新链，旧链上的提交全部失联。本机 reflog 还在时能整段退回；但旧链条目属于"不可达"，默认 30 天过期——你在新链上继续开发过了保质期，或者改写发生在另一台机器上，旧链就只剩那台机器的 reflog 记得，你这台够不着——reflog 只在本机，这是它最硬的边界。

**reflog 救得了手滑，救不了物理删除和从未提交**——分清这两类，才知道哭得有没有道理。

## 五、兜底：fsck 翻垃圾堆

如果连 reflog 都指望不上（条目过期，或者手滑发生在记不清的过去），还有最后一招，扫对象库里的孤儿：

```bash
git fsck --lost-found
# dangling commit 4be9a2f...
```

dangling commit 就是没有 ref 引用、但还躺在 `.git/objects/` 里的悬空提交。找回姿势与第三节相同，先验货，再接住：

```bash
git show --stat 4be9a2f     # 看看这个孤儿里装的是什么
git branch rescue2 4be9a2f  # 确认是你要的，再接住（hash 换成实际值）
```

**fsck 是兜底不是依赖**：它只负责把孤儿列出来，不告诉你哪个是你要的——一个个 show 是体力活，找到是运气，翻不到是常态【从业者判断】。它的正确位置在 runbook 的最后一行，而不是第一行。

## 六、预防清单：把后悔药换成安全绳

**危险操作前先打 tag 或 branch。** `git tag before-rebase` 或 `git branch backup-main`——零拷贝、瞬时完成，成本为零，事后删掉即可。它等于你亲手写下的永久 reflog。

**push 是异地备份。** push 过的提交，远端对象库里就还有一份；本地再怎么折腾，fetch 下来就能救，跨机器场景这是唯一的后悔药。注意 tag 默认不随 push 走，安全绳要显式推上去。

**半成品先 stash。** 未提交的工作区是 reflog 的盲区，切分支前 `git stash push -u -m "说明"`（`-u` 连未跟踪文件一起存），别让工作区裸奔。

**detached HEAD 里先建分支再提交**，或者干脆别在那里提交。

**慌的时候先 `git reflog`，别乱敲 reset**——第二次手滑往往比第一次更致命。

**安全绳的成本是零，事故的成本是一晚**——这买卖没有理由不做。

## 七、预答两个反方

"团队有保护分支和 push rules，用不着学这个。"那套防线拦的是"往远端推什么"——服务端 hook（bare 仓库的 pre-receive）才是真正的红线，而它长在远端。你本机的 `reset --hard` 不经过任何审核，本地仓库里没人拦你。reflog 是本机唯一的安全网。

"那把 reflog 期限调成永久、再关掉 gc 不就行了？"对象库会无限膨胀：长期不回收的仓库，`.git` 比工作区大出几倍，clone、gc 全都变慢。默认的 90/30 天保质期是后悔药与磁盘占用之间的折中；真有重要的东西，正解是 push 上远端，而不是把 `.git` 养成仓鼠笼【从业者判断】。

## 八、教训与 30 秒自检

| 要点 | 一句话 |
| --- | --- |
| 丢的本质 | 丢的多是指针不是对象，commit 还在 .git/objects |
| 救回三步 | reflog 找 SHA → branch 接住 → log 验证 |
| reflog 边界 | 只在本机、默认 90 天（不可达条目 30 天）、浅克隆里没有 |
| 真危险区 | gc --prune=now、未提交改动、跨机器失联 |
| 兜底 | git fsck --lost-found 扫 dangling commit |
| 预防 | 危险操作前打 tag/branch，push 当异地备份 |

三件现在就能做的事。第一件，开个练习仓库照第三节亲手弄丢一次再救回来——肌肉记忆比收藏夹有用。第二件，给自己立规矩：reset --hard、rebase 之前，先 `git tag backup`。第三件，看一眼你的 CI 是不是浅克隆，是的话记住：那里的克隆救不了任何东西。

## 写在最后

这篇最想留下的只有一个认知：**在 Git 里，"删掉"大多只是"挪走了指针"**。对象库的不可变设计意味着你的代码比想象中能苟活，但苟活有期限——reflog 的 90/30 天保质期，gc 一把剪刀，跨机器一张白纸。把"先 push、先打 tag"变成肌肉记忆，比背十条恢复命令都值钱。

全部命令与练习仓库整理自我维护的开源学习库——GitHub 搜 sre-learning-hub，Git 深入章节的练习环境全部操作只影响本地目录，可反复重来。你上一次靠 reflog 救回的是什么场景——reset 过头、rebase 翻车，还是 detached HEAD 里的孤儿提交？评论区对个暗号。
