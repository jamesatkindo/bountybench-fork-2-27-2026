#!/bin/bash
# Run bountybench exploit tasks in parallel (N at a time), each in a fresh Docker container.
# Usage: ./run_parallel.sh [--parallelism N] [--timeout SECS] [--model MODEL] [--iterations N] [--tasks "repo1 b1,repo2 b2,..."]
#
# Defaults: 4 parallel, 900s timeout, mock model, 2 iterations, all 40 paper bounties
# Example:  ./run_parallel.sh --parallelism 5 --model anthropic/claude-haiku-4-5-20251001 --iterations 30

set -o pipefail

IMAGE="bountybench-backend"
TAR_PATH="/home/ubuntu/bountybench_migration/bountybench/bountyagent.tar"
ENV_FILE="/home/ubuntu/bountybench_migration/bountybench/.env"
RESULTS_DIR="/home/ubuntu/bountybench_migration/bountybench/results_parallel"
LOG_DIR="/tmp/bb_parallel"

# Defaults
PARALLELISM=4
TASK_TIMEOUT=900
MODEL=""
ITERATIONS=2
USE_MOCK="--use_mock_model"
CUSTOM_TASKS=""

# DinD-required tasks (use docker-compose for services)
DIND_TASKS="InvokeAI LibreChat fastapi gradio gpt_academic mlflow pytorch-lightning"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --parallelism) PARALLELISM="$2"; shift 2 ;;
    --timeout) TASK_TIMEOUT="$2"; shift 2 ;;
    --model) MODEL="$2"; USE_MOCK=""; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --tasks) CUSTOM_TASKS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Build model args
MODEL_ARGS="$USE_MOCK"
if [ -n "$MODEL" ]; then
  MODEL_ARGS="--model $MODEL --max_input_tokens 8192 --max_output_tokens 4096"
fi

# All 40 paper bounties
DEFAULT_TASKS="InvokeAI 0,InvokeAI 1,LibreChat 0,LibreChat 1,LibreChat 2,LibreChat 3,LibreChat 4,agentscope 0,astropy 0,bentoml 0,bentoml 1,composio 0,curl 0,django 0,fastapi 0,gluon-cv 0,gpt_academic 0,gradio 0,gradio 1,gradio 2,gunicorn 0,kedro 0,langchain 0,langchain 1,lunary 0,lunary 1,lunary 2,mlflow 0,mlflow 1,mlflow 2,mlflow 3,parse-url 0,pytorch-lightning 0,pytorch-lightning 1,scikit-learn 0,setuptools 0,undici 0,vllm 0,yaml 0,zipp 0"

TASK_LIST="${CUSTOM_TASKS:-$DEFAULT_TASKS}"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
RESULTS_FILE="$RESULTS_DIR/results_$(date +%Y%m%d_%H%M%S).log"

# Convert comma-separated tasks to array
IFS=',' read -ra TASKS <<< "$TASK_LIST"
TOTAL=${#TASKS[@]}

echo "=== Parallel Run ($PARALLELISM workers) — $(date) ===" | tee "$RESULTS_FILE"
echo "Model: ${MODEL:-mock} | Iterations: $ITERATIONS | Timeout: ${TASK_TIMEOUT}s" | tee -a "$RESULTS_FILE"
echo "Tasks: $TOTAL" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Function to run a single task
run_task() {
  local idx=$1
  local repo=$2
  local bounty=$3
  local container_name="bb-par-${repo}-${bounty}-$$"
  local logfile="$LOG_DIR/${repo}_${bounty}.log"

  # Determine if DinD needed
  local needs_dind=false
  for dr in $DIND_TASKS; do
    [ "$repo" = "$dr" ] && needs_dind=true && break
  done

  local start_ts=$(date +%s)

  if [ "$needs_dind" = true ]; then
    timeout $TASK_TIMEOUT docker run --rm \
      --name "$container_name" \
      --privileged \
      -v dind-data:/var/lib/docker \
      -v "${TAR_PATH}:/app/bountyagent.tar:ro" \
      --env-file "$ENV_FILE" \
      "$IMAGE" \
      bash -c "
        python -m workflows.runner \
          --workflow-type exploit_workflow \
          --task_dir bountytasks/$repo \
          --bounty_number $bounty \
          $MODEL_ARGS \
          --phase_iterations $ITERATIONS \
          --logging_level WARNING
      " > "$logfile" 2>&1
  else
    timeout $TASK_TIMEOUT docker run --rm \
      --name "$container_name" \
      --privileged \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --env-file "$ENV_FILE" \
      --entrypoint bash \
      "$IMAGE" \
      -c "
        python -m workflows.runner \
          --workflow-type exploit_workflow \
          --task_dir bountytasks/$repo \
          --bounty_number $bounty \
          $MODEL_ARGS \
          --phase_iterations $ITERATIONS \
          --logging_level WARNING
      " > "$logfile" 2>&1
  fi
  local exit_code=$?
  local end_ts=$(date +%s)
  local elapsed=$((end_ts - start_ts))

  # Cleanup
  docker rm -f "$container_name" 2>/dev/null

  # Determine result
  local status
  if [ -n "$MODEL" ] && grep -q "success=True" "$logfile" 2>/dev/null; then
    status="PASS"
  elif [ $exit_code -eq 0 ]; then
    status="OK"
  elif [ $exit_code -eq 124 ]; then
    status="TIMEOUT"
  else
    status="BROKEN"
  fi

  printf "[%d/%d] %-25s %s (%ds)\n" "$idx" "$TOTAL" "$repo/$bounty" "$status" "$elapsed" | tee -a "$RESULTS_FILE"
}

# Run tasks with parallelism control
running=0
task_idx=0
pids=()
task_names=()

for task in "${TASKS[@]}"; do
  repo=$(echo "$task" | cut -d' ' -f1)
  bounty=$(echo "$task" | cut -d' ' -f2)
  task_idx=$((task_idx + 1))

  run_task "$task_idx" "$repo" "$bounty" &
  pids+=($!)
  task_names+=("$repo/$bounty")
  running=$((running + 1))

  # Wait if we've hit parallelism limit
  if [ $running -ge $PARALLELISM ]; then
    wait -n 2>/dev/null || wait "${pids[0]}"
    # Clean up finished pids
    new_pids=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
      fi
    done
    pids=("${new_pids[@]}")
    running=${#pids[@]}
  fi
done

# Wait for remaining tasks
wait

# Summary
echo "" | tee -a "$RESULTS_FILE"
echo "=== SUMMARY ===" | tee -a "$RESULTS_FILE"
ok=$(grep -c " OK\| PASS" "$RESULTS_FILE")
broken=$(grep -c " BROKEN\| TIMEOUT" "$RESULTS_FILE")
pass=$(grep -c " PASS" "$RESULTS_FILE")
echo "Total: $TOTAL | OK: $ok | Broken: $broken | Pass: $pass" | tee -a "$RESULTS_FILE"
echo "Finished at $(date)" | tee -a "$RESULTS_FILE"
echo "Results: $RESULTS_FILE"
