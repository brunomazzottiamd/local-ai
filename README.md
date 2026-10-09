# Quick and Dirty Local AI

A collection of Bash scripts that download, serve, and benchmark [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
on AMD Instinct GPUs using a containerized [vLLM](https://github.com/vllm-project/vllm) instance.
You can also spin up a paired development container with [OpenCode](https://opencode.ai) as an AI
coding assistant. See [ARCHITECTURE.md](ARCHITECTURE.md) for the project scope, goals, and design.

## Requirements

See [REQUIREMENTS.md](REQUIREMENTS.md) for a detailed list of software dependencies.

## Environment Variables

- `HF_TOKEN`: Hugging Face access token for authenticated model downloads (section 2).
- `VLLM_GPUS`: comma-separated GPU IDs for vLLM (section 3).
- `DEV_GPUS`: comma-separated GPU IDs for the development container (section 3).
- `VLLM_IMAGE`: vLLM container image, default `vllm/vllm-openai-rocm:latest` (section 4).
- `DEV_IMAGE`: development container image, default `rocm/pytorch:latest` (section 6).

## Installation and Usage

### 1. Get the Scripts

Execute this on the host:

```bash
git clone --depth=1 https://github.com/brunomazzottiamd/local-ai.git && \
cd local-ai && \
ls --format=single-column
```

### 2. Download the Model from Hugging Face

It's important to set your Hugging Face access token so your download isn't rate limited. It should
work without `HF_TOKEN`, but at a slower pace.

Execute this on the host:

```bash
HF_TOKEN=YOUR_HUGGING_FACE_ACCESS_TOKEN_HERE ./download_model.sh && \
ls --format=single-column ~/models/Qwen/Qwen3.8-27B
```

You can pass a different model directory to `download_model.sh` with `--model-dir` argument if you
want to save the model weights in a place other than your home. The directory holds this model only
(the default is `~/models/Qwen/Qwen3.8-27B`); pass the same `--model-dir` to `start_vllm.sh` (see
Example 4.2).

### (Optional) 3. Define the GPU Partition

We need to split the GPUs into two sets: one for the vLLM container and the other for the development
container. If you wish, you can do this with `DEV_GPUS` and `VLLM_GPUS` environment variables. They
are comma-separated device IDs, e.g. `0,2,3,7`. `DEV_GPUS` and `VLLM_GPUS` must not overlap. The
number of GPUs in `VLLM_GPUS` must be a power of two due to Tensor Parallelism (TP) constraints.

Defining `DEV_GPUS` and `VLLM_GPUS` is optional. If neither is defined, then we have an even split:
first half to development, second half to vLLM. On an 8-GPU node, it's `0,1,2,3` for development and
`4,5,6,7` for vLLM. If only `DEV_GPUS` is defined then `VLLM_GPUS` becomes the remaining GPUs. If
only `VLLM_GPUS` is defined then `DEV_GPUS` becomes the remaining GPUs. If both are defined, then
both sets are used as given. With an odd number of GPUs, vLLM gets the extra one. If the vLLM share
is not a power of two (e.g. 3 GPUs on a 6-GPU node), set `VLLM_GPUS` explicitly.

The start scripts (see sections 4 and 6) also look at the containers that already exist. Unless you
define the matching variable (`VLLM_GPUS` for vLLM, `DEV_GPUS` for the development container), an
existing container keeps the GPUs it was created with, and the GPUs of the other container are
reserved for it. For instance, `start_vllm.sh` restarts an existing vLLM container on its original
GPUs and gives vLLM no GPU used by the dev container. A stopped vLLM container is recreated when the
port, GPUs, network, model directory, or cache directory differ from what you request. `start_dev.sh`
never recreates the dev container, because it holds your work: it refuses to start a stopped one and
only warns about a running one.

Example 3.1 - TP2 for vLLM, other GPUs for development:

```bash
export VLLM_GPUS='6,7'
```

Example 3.2 - TP4 for vLLM, 1 GPU for yourself, leave remaining GPUs for your colleagues:

```bash
export VLLM_GPUS='0,1,2,3'
export DEV_GPUS=7
```

### 4. Start vLLM Server

Execute one of the following `start_vllm.sh` commands on the host.

Example 4.1 - default configuration:

- model loaded from home directory (same default directory of `download_model.sh`)
- vLLM container named `${USER}_vllm`, serving at port `8000`
- Docker network named `${USER}_llm_net`

```bash
./start_vllm.sh
```

Example 4.2 - load model from shared directory:

```bash
./start_vllm.sh --model-dir /opt/shared_models/Qwen/Qwen3.8-27B
# ^^^ this should work if you previously executed
#     ./download_model.sh --model-dir /opt/shared_models/Qwen/Qwen3.8-27B
```

Example 4.3 - picking another port because your colleague is already using port `8000` for their own
local AI:

```bash
./start_vllm.sh --port 8010
```

Example 4.4 - explicitly naming vLLM container and Docker network for sharing with your teammates:

```bash
./start_vllm.sh --vllm-container triton_kernels_team_vllm --network triton_kernels_team_llm_net
```

Only one vLLM container per Docker network: every vLLM container gets the network alias `vllm`.

**Important:** Write down the vLLM container name and Docker network reported by `start_vllm.sh` if
you changed them. Pass the container name to `bench_vllm.sh` (section 5), `start_dev.sh` and
`install_opencode.sh` (sections 6 and 7), and `stop_vllm.sh` (section 10), and the network name to
`start_dev.sh`. With the defaults, there is nothing to pass.

`start_vllm.sh` should report a summary like this:

```text
vLLM is up:
  container:    <${VLLM_CONTAINER_NAME}>.
  host URL:     <http://127.0.0.1:${VLLM_PORT}/v1>.
  network URL:  <http://vllm:${VLLM_PORT}/v1> (for containers on <${LLM_NETWORK}>).
  model:        ${MODEL_NAME}.
```

vLLM can be reached from the host at `http://127.0.0.1:${VLLM_PORT}/v1` API end-point (IPv4
loopback). It can be reached from the custom network at `http://vllm:${VLLM_PORT}/v1` API end-point.
`vllm` hostname is associated with the vLLM container so you don't need to deal with IP addresses.

### (Optional) 5. Benchmark vLLM Server

Execute this on the host:

```bash
./bench_vllm.sh
```

Results obtained on an 8-GPU MI355X system (with default `bench_vllm.sh` arguments):

| Metric                          |    TP1 |    TP2 |    TP4 |    TP8 |
|---------------------------------|-------:|-------:|-------:|-------:|
| Output token throughput (tok/s) | 277.54 | 361.35 | 428.56 | 498.52 |
| Input token throughput (tok/s)  | 256.22 | 333.61 | 395.69 | 460.25 |
| Total token throughput (tok/s)  | 533.76 | 694.96 | 824.24 | 958.78 |
| Median TTFT (ms)                | 263.79 | 242.91 | 212.69 | 209.30 |
| Median TPOT (ms)                |  14.18 |  10.84 |   9.16 |   7.80 |

If you used a container name other than the default one when calling `start_vllm.sh` then do this
when calling `bench_vllm.sh`:

```bash
./bench_vllm.sh --vllm-container my_custom_vllm_container_name
```

`bench_vllm.sh` accepts other arguments that control the benchmark. Run `./bench_vllm.sh --help`
to see them.

### 6. Start Your Development Container

This project ships `start_dev.sh`, a script that spins up a development container with the following
features:

- focus on kernel development for AMD Instinct GPUs
- runs in privileged mode, as `root` user
- PyTorch based with `rocm/pytorch:latest` image
- attached to the same Docker network of the vLLM container, so it can access vLLM chat completion
  API at `http://vllm:${VLLM_PORT}/v1`
- binds your host home directory to `/workspace/host_home` container directory
- files created under `/workspace/host_home` are owned by `root` on the host, because the
  container runs as `root`

Execute one of the following `start_dev.sh` commands on the host.

Example 6.1 - default configuration:

- development container named `${USER}_dev`
- attached to the same default Docker network as vLLM container, i.e. `${USER}_llm_net`

```bash
./start_dev.sh
```

Example 6.2 - explicitly naming development container and Docker network:

```bash
./start_dev.sh --dev-container my_custom_dev_container_name --network triton_kernels_team_llm_net
```

By default, the development container gets the GPUs that the vLLM container does not use. If the
development container already exists when you start vLLM, vLLM gets the GPUs the development
container does not use.

It's perfectly fine if you don't want to use `start_dev.sh` and its `stop_dev.sh` counterpart (see
section 9). You can spin up your own container as you wish. Just make sure to do the following:

- add `--network` option to your `docker run` command, with the network name reported by
  `start_vllm.sh` (see section 4)
- do not use the GPUs assigned to the vLLM container: vLLM reserves 95% of their VRAM

### 7. Install OpenCode in Your Development Container

`start_dev.sh` (see section 6) installs OpenCode in the development container by default. So, there
is nothing to do in this section if you rely on `start_dev.sh`. Pass `--no-opencode` to
`start_dev.sh` if you don't want OpenCode in your container. You can use other agent harness tools
if you wish since vLLM exposes an OpenAI-compatible API.

`install_opencode.sh` does the installation, and you can also run it yourself, e.g. to reinstall
OpenCode or to point it to vLLM again after restarting vLLM on another port. Another legitimate use
case is installing OpenCode in an arbitrary container. The development container must be running:
`install_opencode.sh` never starts a container. The development container must also have `curl` and
`tar` to download and uncompress OpenCode.

Example 7.1 - default configuration (development container `${USER}_dev`, vLLM container
`${USER}_vllm`):

```bash
./install_opencode.sh
```

Example 7.2 - explicitly naming development and vLLM containers, e.g. if you spun your own
development container:

```bash
./install_opencode.sh --dev-container my_custom_dev_container_name --vllm-container triton_kernels_team_vllm
```

### 8. Run OpenCode

Execute this on the host, to open a shell in your container (`${USER}_dev`, or the container name
printed by `start_dev.sh`):

```bash
docker exec --interactive --tty "${USER}_dev" bash
```

Execute this in your development container, that by now should have OpenCode installed:

```bash
opencode
```

`Qwen/Qwen3.8-27B Local vLLM` should be listed as the selected model. Give it a try with a simple
prompt like "Explain what a GPU kernel is like I'm 5 years old." You can also run OpenCode on the
shell:

```bash
opencode run "Explain what a GPU kernel is like I'm 5 years old."
```

### 9. Stop Your Development Container

Execute `stop_dev.sh` on the host to stop the development container. By default, it's stopped but
kept, so `start_dev.sh` brings it back with all your work.

Example 9.1 - default configuration:

```bash
./stop_dev.sh
```

Example 9.2 - to delete the development container and its contents (and its network, if no other
container uses it):

```bash
./stop_dev.sh --remove
```

Example 9.3 - specify a name for the container to be stopped:

```bash
./stop_dev.sh --dev-container my_precious_dev_container
```

### 10. Stop vLLM Server

Once you're done with local AI, be a good colleague and stop your vLLM container. Execute this on
the host to stop the vLLM server. This will free VRAM from `VLLM_GPUS` so they are available to your
colleagues.

Example 10.1 - default configuration:

```bash
./stop_vllm.sh
```

Example 10.2 - custom container name:

```bash
./stop_vllm.sh --vllm-container triton_kernels_team_vllm
```

By default, `stop_vllm.sh` removes the vLLM container, the vLLM cache directory (default
`~/vllm_cache`; without it, the next start compiles kernels again), and the Docker network if no
other container uses it. Skip any removal with `--keep-container`, `--keep-cache`, or
`--keep-network`.

## Contributing

Contributions are more than welcome, whether it be to fix bugs or to add new features that make
sense for the project. For more detailed instructions, please read the
[contributor's guide](CONTRIBUTING.md).
