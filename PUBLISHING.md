# 发布教程

这个目录已经是一个可以直接推上 GitHub 的插件仓库：`package.json` 里有 `dsh.bundle.patch`，`files` 白名单、`LICENSE`、`.gitignore`、`README.md`、`CHANGELOG.md` 都齐了。

下面按「先发 GitHub，再决定要不要发 npm」的顺序走。

---

## 0. 前置检查

```powershell
git --version     # 本机 2.56.0
node --version    # 本机 v26.13.0
npm --version     # 本机 11.20.0（发 npm 才需要）
```

`git config --global user.name` / `user.email` 必须已经设置过，否则提交会失败。

---

## 1. GitHub 仓库（已存在）

仓库已经在：<https://github.com/Lh1314-China/dsh-whale-eyes>。发布新版本直接推：

```powershell
cd dsh-whale-eyes

git add -A
git commit -m "feat: dsh-whale-eyes <version>"
git push origin main
git push origin v<version>
```

> `package.json` 里的 `repository` / `homepage` / `bugs` 已经按 `Lh1314-China` 填好。如果 GitHub 用户名不是这个，改这三处就行。

---

## 2. 在 DSH 里装上并验证

**方式 A：插件页**

侧边栏 → 插件 → 右上「添加插件」→ 填：

```
https://github.com/Lh1314-China/dsh-whale-eyes
```

**方式 B：命令行**

```powershell
dsh plugin --profile desktop add github:Lh1314-China/dsh-whale-eyes
```

安装器会先跑 `git ls-remote` 探一下仓库（默认超时 5 秒），连不上就直接失败，不会卡在下载环节。

**验证**：装完在「已安装插件」里能看到 `dsh-whale-eyes`，然后让模型调一次 `screen_sight`，能返回当前窗口摘要就算成功。

---

## 3. 发 npm（可选，但装起来最省事）

包名 `dsh-whale-eyes` 已在 npm 上发布。

```powershell
npm login            # 浏览器授权
npm publish          # 公开包，默认 public
```

发完以后，别人（和你自己换机器时）在「添加插件」里只填包名就行：

```
dsh-whale-eyes
```

不想公开就把 `publishConfig` 加上 `"access": "restricted"`，只有付费组织的私有包能这么发。

---

## 4. 打 tgz（离线分享 / 给朋友）

```powershell
npm pack
# 产出 dsh-whale-eyes-0.1.0.tgz
```

对方的 DSH 里填这个 tgz 的绝对路径即可安装。这个文件已经写进 `.gitignore`，不会被提交。

---

## 5. 以后升级版本的固定流程

```powershell
# 1) 改代码，确认语法
node --check index.js

# 2) 升版本号（同时打 tag）
npm version patch -m "chore: release %s"     # 或 minor / major

# 3) 补 CHANGELOG

# 4) 推代码和 tag
git push --follow-tags

# 5) 发新的 npm 版本（如果走 npm 渠道）
npm publish
```

在 DSH 里升级：插件页对 `dsh-whale-eyes` 点「更新」，或者先移除再添加。**替换已安装的插件通常需要重启 DSH** 才会加载新的 JS 模块，HMR 只会重组配置层，不会换掉已加载的模块代码。

---

## 6. 容易踩的坑

| 现象 | 原因 / 处理 |
|---|---|
| 安装报 `incompatible-version` | `engines.dsh` / `engines` 与运行版本不符。本包只声明了 `dsh.compatibility`（信息性），没有硬性 `engines.dsh` |
| 刚 `npm publish` 完装不上 | pnpm 的 `minimumReleaseAge` 会挡太新的版本，等一会儿或装指定版本 `dsh-whale-eyes@0.1.0` |
| GitHub 私有仓库装失败 | 需要本机的 git 凭据（凭据管理器里存过的才行，安装器会禁用交互式凭据提示） |
| 装完看不到 `screen_sight` | 确认 bundle 被选中（插件页里是启用状态），并检查 `include:whale-eyes` 这一行是否 active |
| 装完不起作用但也不报错 | 只在 Windows 生效（`os: ["win32"]`），macOS / Linux 上会跳过安装 |
| `runtime/port.txt` 被提交进仓库 | `.gitignore` 已经排除了，别用 `git add -f` 强行加 |

---

## 7. 发布前最后一遍清单
- [ ] `node --check index.js` 通过
- [ ] `package.json` 的 `version` 与 `CHANGELOG.md` 一致
- [ ] `files` 白名单里没有漏掉新增文件
- [ ] `README.md` 里的仓库地址、安装命令和实际一致
- [ ] 本地装一次、调用一次 `screen_sight` 成功
- [ ] `git status` 干净，`runtime/port.txt`、`captures/` 没进暂存区
- [ ] `npm run check` 通过（BOM + PowerShell 解析断言）

---

## 8. 回滚（link 安装 / tgz 安装都适用）

出问题时按「代码 → 进程 → 重启 → 验证」四步来，别先怀疑插件坏了：

```powershell
cd dsh-whale-eyes
git checkout v0.2.2          # 换成任意上一个 tag
```

1. **代码**：`git checkout <上一个 tag>`。link 安装时，profile 指的就是这个目录，改完即生效（要重启 DSH 才会重新加载 JS 模块）。
2. **旧的 daemon 会自愈**：文件回滚后 `sha256` 变了，插件下次调用会先把它 retire 掉再拉起新的。所以「看起来没变」时，**先看 `ping` 返回的 sha256**，别急着删插件。
3. **手工收尾**（可选）：`Stop-Process -Id <ping.pid>`；或如果装的是 tgz，`npm i <旧版 tgz>` 后重启。
4. **重启**：从桌面快捷方式/开始菜单正常启动，**不要经其他宿主或 AI 客户端拉进程**（会继承对方精简后的 PATH）。
5. **验证**：`screen_sight` 跑两遍 + `ping` 看 version/sha256 与本地文件一致。

**留的包**：仓库目录里保留 `dsh-whale-eyes-<version>.tgz`（gitignore，不进仓库），至少留最近两版。
