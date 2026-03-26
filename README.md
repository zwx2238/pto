# PTO Superproject

当前仓库作为 PTO-Project 的聚合入口，使用 `git submodule` 固定跨仓联调版本，便于：

- 一次拉齐相关仓，降低环境准备成本
- 在小时级迭代中固定可复现的跨仓组合
- 按职责快速定位代码边界和技术负责人

按当前提供的远端地址，可直接落地为 7 个子模块；将本仓库作为 superproject 后，整体即为 8 仓协同入口。

## 目录结构

```text
docs/
  pypto_top_level_documents
frameworks/
  pypto
  simpler
  distributed-runtime
upstream/
  PTOAS
  pto-isa
models/
  pypto-lib
```

## 仓库清单

| 分类 | 路径 | 仓库 | 技术负责人 | 远端地址 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 文档 | `docs/pypto_top_level_documents` | `pypto_top_level_design_documents` | `@LIAO HENG` | `https://github.com/hengliao1972/pypto_top_level_design_documents.git` | 顶层设计文档 |
| 框架 | `frameworks/pypto` | `pypto` | `@LIAO HENG` `@冯思远` | `https://github.com/hw-native-sys/pypto.git` | 前端 / IR |
| 框架 | `frameworks/simpler` | `simpler` | `@汪超` `@陈鹏` `@张芷萁` | `https://github.com/hw-native-sys/simpler.git` | 底层 / Runtime，采用迁移后的规范地址 |
| 框架 | `frameworks/distributed-runtime` | `pypto_runtime_distributed` | `@LIAO HENG` `@周哲` | `https://github.com/hengliao1972/pypto_runtime_distributed.git` | 通信、分布式 |
| 上游依赖 | `upstream/PTOAS` | `PTOAS` | `@周若愚` `@石伟` `@孙文博` | `https://github.com/zhangstevenunity/PTOAS.git` | 汇编器相关 |
| 上游依赖 | `upstream/pto-isa` | `pto-isa` | `@周若愚` `@石伟` | `https://github.com/PTO-ISA/pto-isa.git` | 指令集相关 |
| 模型成果 | `models/pypto-lib` | `pypto-lib` | `@林嘉树` `@张中` `@尹杰` | `https://github.com/hw-native-sys/pypto-lib.git` | 当前 GitCode 主干 PTO v2 成果 |

## 本地模拟运行

如果本机没有 Ascend 真机，但希望跑通 `models/pypto-lib/examples` 下的 `--sim` 示例，可参考：

- [`docs/pypto_lib_sim_runbook.md`](docs/pypto_lib_sim_runbook.md)

该文档基于实际探索整理，包含：

- 本地 Python / `ptoas` / `simpler` / `pto-isa` 的最短准备步骤
- `beginner/` 与 `intermediate/` 示例当前已验证通过的范围
- 本次实际排查中发现的跨仓 sim 兼容问题与修复点

## 初始化

如果是第一次拉取本聚合仓：

```bash
git clone --recurse-submodules <superproject-url>
```

如果已经拉下本仓库，再补齐子模块：

```bash
git submodule update --init --recursive
```

说明：

- `.gitmodules` 已为所有子模块指定 `branch = main`
- `frameworks/pypto` 自身含有嵌套子模块，因此初始化时建议始终带 `--recursive`

## 常用命令

查看当前锁定版本：

```bash
git submodule status --recursive
```

将所有子模块更新到各自跟踪分支的最新提交：

```bash
git submodule update --remote --recursive
```

拉取子模块远端最新内容后，提交 superproject 中更新过的指针：

```bash
git add .gitmodules docs frameworks upstream models
git commit -m "chore: update PTO submodules"
```

## 后续扩展

如果后面补齐第 8 个外部仓，按同样模式添加即可：

```bash
git submodule add -b main <repo-url> <category/path>
git add .gitmodules <category/path>
git commit -m "chore: add new PTO submodule"
```
