# BountyBench Setup Notes (amd64)

## Quick Start

```bash
# 1. Clone this fork
git clone https://github.com/jamesatkindo/bountybench-fork-2-27-2026.git bountybench
cd bountybench

# 2. Switch bountytasks to the fixed branch
cd bountytasks
git remote set-url origin https://github.com/jamesatkindo/bountytasks-fork-2-27-2026.git
git fetch origin
git checkout fix-dependency-drift
cd ..

# 3. Build Docker images
docker build -t cybench/bountyagent:latest -f Dockerfile .
docker save cybench/bountyagent:latest -o bountyagent.tar
docker build -f Dockerfile.backend -t bountybench-backend .

# 4. Create .env
cat > .env <<'EOF'
ANTHROPIC_API_KEY=<your-key>
OPENAI_API_KEY=sk-dummy-not-used-only-for-tokenizer
EOF

# 5. Create Docker volume
docker volume create dind-data

# 6. Run a task
# Non-Docker tasks (fast):
docker run --rm --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --env-file .env \
  --entrypoint bash \
  bountybench-backend \
  -c "python -m workflows.runner --workflow-type exploit_workflow \
      --task_dir bountytasks/kedro --bounty_number 0 \
      --model anthropic/claude-haiku-4-5-20251001 \
      --phase_iterations 30 --max_input_tokens 8192 --max_output_tokens 4096"

# Docker-service tasks (need DinD):
docker run --rm --privileged \
  -v dind-data:/var/lib/docker \
  -v $(pwd)/bountyagent.tar:/app/bountyagent.tar:ro \
  --env-file .env \
  bountybench-backend \
  bash -c "python -m workflows.runner --workflow-type exploit_workflow \
      --task_dir bountytasks/LibreChat --bounty_number 0 \
      --model anthropic/claude-haiku-4-5-20251001 \
      --phase_iterations 30 --max_input_tokens 8192 --max_output_tokens 4096"
```

## Why Two Docker Run Modes?

**Host socket** (`-v /var/run/docker.sock`): Fast, uses host Docker directly. Works for tasks that don't mount files via docker-compose.

**DinD** (`-v dind-data:/var/lib/docker`): Slower but required for tasks whose docker-compose.yml mounts files using container paths (e.g. LibreChat mounts `/app/bountytasks/LibreChat/.env`). These paths only exist inside the bountybench-backend container.

### Tasks requiring DinD
InvokeAI, LibreChat, fastapi, gradio, gpt_academic, mlflow, pytorch-lightning, agentscope, composio, django, gunicorn, lunary, bentoml

### Tasks OK with host socket
astropy, curl, gluon-cv, kedro, langchain, parse-url, scikit-learn, setuptools, undici, vllm, yaml, zipp

## Batch Runs

Use `run_parallel.sh` for running multiple tasks:

```bash
# All 40 tasks with mock model, 4 parallel:
./run_parallel.sh --parallelism 4

# Specific tasks with Haiku:
./run_parallel.sh --parallelism 3 \
  --model anthropic/claude-haiku-4-5-20251001 \
  --iterations 30 \
  --tasks "kedro 0,setuptools 0,zipp 0,astropy 0"
```

Note: DinD tasks cannot share the `dind-data` volume in parallel (boltdb lock). The parallel script uses host socket for non-DinD tasks and runs DinD tasks sequentially.

## Known Issues

### cybench/bountyagent is arm64-only on Docker Hub
Must build locally on amd64. The `Dockerfile` in the repo root builds it. Save as `bountyagent.tar` and mount into DinD containers.

### OPENAI_API_KEY required even for Anthropic models
The tokenizer in `resources/model_resource/model_utils.py` always creates an OpenAI provider. A dummy value works — the actual tokenization uses tiktoken which doesn't need a real key.

### InvokeAI/0 needs cached Docker layers
First DinD run builds a ~12GB image (PyTorch, diffusers, transformers) which takes 10+ minutes. Combined with app startup time, it exceeds the health check window. Subsequent runs use cached layers and work fine. InvokeAI/1 always works because the image is cached from bounty 0.

### What was fixed (dependency drift)
All fixes are in the `fix-dependency-drift` branch of the bountytasks fork:
- **gradio**: `huggingface_hub` 1.0 removed `HfFolder`. Fix: pin `<1.0`, Python 3.10
- **gpt_academic**: `pyautogen` new versions conflict with `protobuf==3.20`. Fix: pin `==0.2.35`
- **mlflow, pytorch-lightning**: `setuptools` removed `pkg_resources`. Fix: pin `<71`
- **pytorch-lightning**: `uvicorn` 0.36 removed `setup_event_loop`. Fix: pin `<0.36`

### Baseline Results (Haiku 4.5)
- 1/29 pass (fastapi/0 only) = 3.4% exploit success rate
- Paper reports 67.5% for Claude 3.7 Sonnet Thinking
- Main failure mode: model doesn't submit FinalSubmissionCommand within 30 iterations
