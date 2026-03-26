# PyPTO-Lib 无 Ascend 环境本地模拟运行手册

本文档记录了一次基于实际排查的本地 bring-up 过程，目标是在 **没有 Ascend 真机 / CANN 运行环境** 的机器上，跑通 `models/pypto-lib/examples` 下的 `--sim` 示例。

文档不追求泛泛而谈，只沉淀这次实际探索里已经验证过、且对后续复用最有价值的信息：

- 最短可复现的环境准备步骤
- `beginner/` 与 `intermediate/` 示例的当前验证结果
- 实际遇到的跨仓问题、根因和最小修复点
- 下一次排查时应优先关注的断点

## 1. 适用范围

本文适用于以下场景：

- 本机没有 Ascend 真机，只想走 `a2a3sim`
- 希望运行 `models/pypto-lib/examples/beginner/*.py --sim`
- 希望运行 `models/pypto-lib/examples/intermediate/*.py --sim`
- 需要理解 `pypto`、`simpler`、`ptoas`、`pto-isa` 在本地模拟路径上如何串起来

本文不覆盖：

- 真机 `a2a3` / `a5` 路径
- CANN 安装与上板调试
- `models/pypto-lib/examples/models/` 下更大规模模型的系统性验证

## 2. 这次探索的结论

### 2.1 当前已经验证通过的示例

在本文记录的本地修复基础上，以下脚本都已经通过 `--sim` 运行：

- `models/pypto-lib/examples/beginner/hello_world.py`
- `models/pypto-lib/examples/beginner/matmul.py`
- `models/pypto-lib/examples/intermediate/gemm.py`
- `models/pypto-lib/examples/intermediate/layer_norm.py`
- `models/pypto-lib/examples/intermediate/rms_norm.py`
- `models/pypto-lib/examples/intermediate/rope.py`
- `models/pypto-lib/examples/intermediate/softmax.py`

### 2.2 当前最重要的经验

- `pypto-lib` 的 `--sim` 路径不是单仓自洽的，它依赖 `pypto + simpler + ptoas + pto-isa` 四层一起通
- `ptoas` 的 Python wheel 不能替代 `ptoas` CLI，可执行文件仍然要单独准备
- `hello_world` 和 `matmul` 的失败都不是“环境没装好”那么简单，而是暴露了两类真实的 sim 兼容问题
- `beginner/` 和 `intermediate/` 的 `--sim` 现在已经可以作为本地 smoke test 使用

## 3. 最短环境准备步骤

以下步骤已经在本仓工作区验证过。

### 3.1 Python 虚拟环境

```bash
cd /home/zwx/pto
python3 -m venv .venv-pto-sim
source .venv-pto-sim/bin/activate
python -m pip install --upgrade pip setuptools wheel
```

### 3.2 安装 `pypto`

```bash
cd /home/zwx/pto
python -m pip install -e frameworks/pypto
```

### 3.3 安装 CPU 版 `torch`

`sim` 路径需要 `torch` 来生成输入张量和 golden。

```bash
python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
```

### 3.4 准备 `ptoas` CLI

这次探索确认：

- `ptoas-0.17-cp312-...x86_64.whl` 可以装进虚拟环境
- 但它 **不会** 提供 `ptoas` 命令
- `pypto` 的 PTO backend 需要的是 **可执行文件** `ptoas`

因此，本地模拟路径应优先使用二进制压缩包：

- `ptoas-bin-x86_64.tar.gz`

解压后确保最终可执行文件路径为：

```bash
/home/zwx/pto/.tools/ptoas-bin/bin/ptoas
```

并验证：

```bash
chmod +x /home/zwx/pto/.tools/ptoas-bin/bin/ptoas
export PTOAS_ROOT=/home/zwx/pto/.tools/ptoas-bin/bin
$PTOAS_ROOT/ptoas --version
```

期望输出类似：

```text
ptoas 0.17
```

### 3.5 设置运行环境变量

```bash
export SIMPLER_ROOT=/home/zwx/pto/frameworks/simpler
export PTOAS_ROOT=/home/zwx/pto/.tools/ptoas-bin/bin
export PTO_ISA_ROOT=/home/zwx/pto/upstream/pto-isa
```

### 3.6 一条 smoke test

```bash
cd /home/zwx/pto
python models/pypto-lib/examples/beginner/hello_world.py --sim
```

## 4. 本地模拟链路如何串起来

本次探索确认的本地 `--sim` 主链如下：

```text
pypto-lib 示例脚本
  -> pypto.language / pypto.runtime.run()
  -> pypto codegen / pto backend
  -> ptoas CLI
  -> simpler CodeRunner
  -> simpler a2a3sim runtime
  -> pto-isa CPU_SIM headers / stubs
```

对应关键代码位置：

- `frameworks/pypto/python/pypto/runtime/runner.py`
- `frameworks/pypto/python/pypto/backend/pto_backend.py`
- `frameworks/simpler/examples/scripts/code_runner.py`
- `frameworks/simpler/python/kernel_compiler.py`
- `upstream/pto-isa/include/pto/pto-inst.hpp`

## 5. 实际排查中暴露出的关键问题

### 5.1 `hello_world.py --sim` 首次失败：输出全 0

表象：

- `simpler` 自带 `vector_example` 在 `a2a3sim` 下是 PASS
- `hello_world.py --sim` 则输出张量几乎全 0

实际根因：

- `pypto` 生成的 AIV kernel 主体被包在 `#if defined(__DAV_VEC__)` 条件里
- `simpler` 的 sim kernel 编译路径本来应该根据 `core_type` 自动追加 `-D__DAV_VEC__`
- 但 `frameworks/simpler/python/kernel_compiler.py` 的 sim 分支把 `core_type` 丢掉了

具体修复点：

- `compile_incore(..., core_type=...)` 调 `self._compile_incore_sim(...)` 时补传 `core_type`
- `_compile_incore_sim(...)` 内部调用 `self.gxx15.get_compile_flags(core_type=core_type)`

### 5.2 修完 AIV 宏后，sim 编译报 `set_mask_norm` / `set_vector_mask` 未定义

表象：

- AIV kernel 不再空跑
- 但 sim 编译失败，提示 `set_mask_norm` 和 `set_vector_mask` 找不到

实际根因：

- `pto-isa` 在 `__CPU_SIM` 下会 include `pto/common/cpu_stub.hpp`
- 但 `cpu_stub.hpp` 里没有给这两个接口提供 stub
- 而 `ptoas` 生成的 AIV 向量代码会直接调用它们

具体修复点：

- 在 `upstream/pto-isa/include/pto/common/cpu_stub.hpp` 中补充 no-op 版本：
  - `set_mask_norm()`
  - `set_vector_mask(uint64_t, uint64_t)`

说明：

- 对 `hello_world` 这类简单示例，这两个 stub 作为 no-op 足够
- 对依赖真实 mask 语义的更复杂 kernel，后续可能还需要更完整的 CPU sim 行为

### 5.3 `matmul.py --sim` 首次失败：CPU `TMATMUL` 静态断言拒绝当前布局

表象：

- `matmul.py --sim` 编译失败
- 报错来自 `upstream/pto-isa/include/pto/cpu/TMatmul.hpp`
- 错误信息为 `static assertion failed: Non-conforming matrix fractal`

实际根因：

- `ptoas` 生成的 matmul kernel 使用了如下布局组合：
  - `Left`: `BLayout::RowMajor`, `SLayout::RowMajor`
  - `Right`: `BLayout::RowMajor`, `SLayout::ColMajor`
  - `Acc`: `BLayout::ColMajor`, `SLayout::RowMajor`
- CPU sim 侧 `TMatmul.hpp` 的 `CheckMadValid()` 对 `Left` 的布局要求过严，强制要求 `!TileLeft::isRowMajor`
- 但同一套 CPU offset 计算代码已经支持多种布局组合，说明这个静态断言比实现本身更窄

具体修复点：

- 放宽 `upstream/pto-isa/include/pto/cpu/TMatmul.hpp` 里 `TileLeft` 的静态断言
- 保留 `TileLeft::Loc == TileType::Left` 和 `TileLeft::SFractal == SLayout::RowMajor`
- 不再强制 `!TileLeft::isRowMajor`

### 5.4 示例脚本里的报错文案会误导

`hello_world.py`、`matmul.py` 等示例包含如下逻辑：

- 如果 traceback 中包含字符串 `"code_runner"`，就打印
  - `Result: COMPILE OK — device run skipped (code_runner not found).`

这会误判真实运行错误。

因为：

- 真正的执行路径本来就会经过 `frameworks/simpler/examples/scripts/code_runner.py`
- 只要 traceback 里出现 `code_runner.py`，示例脚本就可能错误地把它解释成“找不到 code_runner”

这次探索里就出现过这种误导：

- 实际上运行已经发生了
- 真正错误是 kernel 编译失败或输出 mismatch
- 但顶层示例文案却打印成了“device run skipped”

这点目前只作为文档提醒，尚未在示例脚本里统一修正文案。

## 6. 已验证通过的批量结果

在本次修复后的环境中，以下命令全部 PASS：

### 6.1 `beginner/`

```bash
python models/pypto-lib/examples/beginner/hello_world.py --sim
python models/pypto-lib/examples/beginner/matmul.py --sim
```

### 6.2 `intermediate/`

```bash
python models/pypto-lib/examples/intermediate/gemm.py --sim
python models/pypto-lib/examples/intermediate/layer_norm.py --sim
python models/pypto-lib/examples/intermediate/rms_norm.py --sim
python models/pypto-lib/examples/intermediate/rope.py --sim
python models/pypto-lib/examples/intermediate/softmax.py --sim
```

批量结果汇总：

- PASS: 7
- FAIL: 0
- TIMEOUT: 0

## 7. 当前建议的 smoke-test 顺序

如果后续有人在新机器上做 bring-up，建议按这个顺序验证：

1. `hello_world.py --sim`
2. `matmul.py --sim`
3. `softmax.py --sim`
4. `layer_norm.py --sim`
5. 其余 `intermediate/` 示例

理由：

- `hello_world` 能最快验证 AIV 基础路径
- `matmul` 能覆盖 AIC / `TMATMUL` 路径
- `softmax` / `layer_norm` 能覆盖更复杂的张量组合与 reduce 路径

## 8. 当前仍需保留的本地补丁点

这次实际跑通依赖以下本地修改：

- `frameworks/simpler/python/kernel_compiler.py`
- `upstream/pto-isa/include/pto/common/cpu_stub.hpp`
- `upstream/pto-isa/include/pto/cpu/TMatmul.hpp`

如果后续切换分支、重置子模块或重新拉 superproject 指针，需要优先检查这三处是否仍然存在。

## 9. 下次继续探索时的建议

如果后续继续扩大 `--sim` 覆盖面，建议按这个顺序推进：

1. 先批量跑 `models/pypto-lib/examples/models/` 中较小样例
2. 再检查哪些失败点属于 `pto-isa` CPU sim 缺失 stub
3. 哪些失败点属于 `pypto` codegen 生成了 CPU sim 当前不接受的布局/指令组合
4. 最后再决定这些兼容性应该修在 `pypto`、`simpler` 还是 `pto-isa`

这次探索的经验是：

- 不要先怀疑环境
- 先用 `simpler` 自带 `vector_example` 证明 sim runtime 本身是健康的
- 再把问题缩到生成物和 CPU sim 兼容层

