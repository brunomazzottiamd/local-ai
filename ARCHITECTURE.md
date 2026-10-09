# Project Architecture

## Scope

Running a capable LLM locally on a shared AMD Instinct GPU host takes many manual steps. This
small project turns them into a few Bash scripts that:

- Download a model from Hugging Face.
- Serve it with a containerized vLLM, behind an OpenAI-compatible API.
- Benchmark the server.
- Start a paired development container, with OpenCode wired to vLLM.

**Goals:**

- Everything containerized and nothing changed on the host. The host only requires basic
  command-line tools. The one exception is `bench_vllm.sh`: it downloads the `vllm-bench`
  client binary into the script directory (gitignored) and runs it on the host, because it is
  a pure HTTP client of the vLLM API.
- GPUs split cleanly between the vLLM container and the development container.
- Friendly to colleagues sharing the same machine.
- Focus on kernel development for AMD Instinct GPUs.

## Out of Scope

- GPUs other than AMD Instinct.
- Inference and serving engines other than vLLM.
- Shells other than Bash.
- Host changes: everything should be containerized. The only exception is the `vllm-bench`
  client that `bench_vllm.sh` downloads and runs on the host (see Goals).
- Multimodal Large Language Models (MLLMs) or Vision-Language Models (VLMs). The project is
  text-only; more specifically, coding-only.
- Supporting multiple models. **(This can change in the future.)**

## High-Level Diagram

```text
                 Hugging Face Hub
                        |
                        | download_model.sh
                        v
 Host  ------------- ~/models ---------------------------------------------
 |                      | (read-only mount)                               |
 |                      v                                                 |
 |   Docker network ${USER}_llm_net                                       |
 |   +----------------------------+        +---------------------------+  |
 |   | vLLM container             |  HTTP  | Dev container             |  |
 |   | ${USER}_vllm (alias vllm)  |<-------| ${USER}_dev               |  |
 |   | GPUs: VLLM_GPUS            |        | GPUs: DEV_GPUS            |  |
 |   | OpenAI API on :8000        |        | OpenCode, ~ bind-mounted  |  |
 |   +----------------------------+        +---------------------------+  |
 |                ^                                                       |
 |                | http://127.0.0.1:8000/v1                              |
 |          bench_vllm.sh                                                 |
 --------------------------------------------------------------------------
```

## Tech Stack

- Bash 4.3+
- Docker
- ROCm
- vLLM (`vllm/vllm-openai-rocm` image)
- PyTorch (`rocm/pytorch` image, development container)
- OpenCode
- Hugging Face Hub

Please check [REQUIREMENTS.md](REQUIREMENTS.md) for more details.

## Model Selection

We are currently using [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) for the following
reasons:

- It's a small model that fits on a single AMD Instinct GPU. You can use just one GPU for your local
  AI setup on a shared host, without bothering your colleagues. If more GPUs are available then it's
  possible to rely on Tensor Parallelism (TP) to increase inference performance. In other words,
  it's scalable according to GPU availability.
- It's a dense model with only 27B parameters, while Mixture of Experts (MoE) models of similar
  quality usually have many more parameters in total. Its weights are relatively small (52 GB).
  They are quicker to download and don't take up much storage space on a shared host. It's quick to
  migrate your local AI setup to another host if the need arises.

The project isn't tied forever to Qwen3.8-27B. Another similar model that's small, capable at
coding tasks, and performant on vLLM + AMD Instinct GPUs is eligible.
