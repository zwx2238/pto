export PTOAS_ROOT=/home/zwx/pypto_test/pto/.tools/ptoas-bin/bin
export SIMPLER_ROOT=/home/zwx/pypto_test/pto/frameworks/simpler
export PTO_ISA_ROOT=/home/zwx/pypto_test/pto/upstream/pto-isa
export PYTHONPATH=/home/zwx/pypto_test/pto/models/pypto-lib/python:${PYTHONPATH:-}

export CC="$CONDA_PREFIX/bin/aarch64-conda-linux-gnu-gcc"
export CXX="$CONDA_PREFIX/bin/aarch64-conda-linux-gnu-g++"
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export TEST_DEVICE_ID=2
hash -r
.tools/ptoas-bin/bin/ptoas --version
#python models/pypto-lib/examples/beginner/hello_world.py --sim 2>&1| tee log.sim
python models/pypto-lib/examples/beginner/hello_world.py -d "${TEST_DEVICE_ID}" 2>&1| tee log.npu
python models/pypto-lib/examples/beginner/matmul.py -d "${TEST_DEVICE_ID}" 2>&1| tee log.npu
