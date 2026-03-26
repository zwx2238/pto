# 在当前机器上运行 `hello_world.py`

本文档只覆盖当前这台机器上的最短运行步骤。

目标脚本：

```bash
/home/zwx/pto/models/pypto-lib/examples/beginner/hello_world.py
```

运行模式：

```bash
--sim
```

## 1. 激活环境

```bash
cd /home/zwx/pto
source .venv-pto-sim/bin/activate
```

## 2. 设置环境变量

```bash
export SIMPLER_ROOT=/home/zwx/pto/frameworks/simpler
export PTOAS_ROOT=/home/zwx/pto/.tools/ptoas-bin/bin
export PTO_ISA_ROOT=/home/zwx/pto/upstream/pto-isa
```

## 3. 运行

```bash
cd /home/zwx/pto
python models/pypto-lib/examples/beginner/hello_world.py --sim
```

## 4. 成功标志

最后输出里应出现：

```text
Comparing y: shape=torch.Size([1024, 512]), dtype=torch.float32
y: PASS (524288/524288 elements matched)
```

## 5. 一条命令版

```bash
cd /home/zwx/pto && \
source .venv-pto-sim/bin/activate && \
export SIMPLER_ROOT=/home/zwx/pto/frameworks/simpler && \
export PTOAS_ROOT=/home/zwx/pto/.tools/ptoas-bin/bin && \
export PTO_ISA_ROOT=/home/zwx/pto/upstream/pto-isa && \
python models/pypto-lib/examples/beginner/hello_world.py --sim
```

## 6. 备注

这份文档依赖当前工作区已经具备以下状态：

- `frameworks/pypto` 已安装到 `.venv-pto-sim`
- CPU 版 `torch` 已安装到 `.venv-pto-sim`
- `ptoas` CLI 已解压到 `/home/zwx/pto/.tools/ptoas-bin/bin/ptoas`
- 当前工作区保留了本地 sim 兼容修复

