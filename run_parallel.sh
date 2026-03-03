#!/bin/bash
# Run BountyBench exploit tasks with parallelism for non-DinD tasks and
# sequential execution for DinD-required tasks.
#
# Usage:
#   ./run_parallel.sh [--parallelism N] [--timeout SECS] [--model MODEL]
#                     [--iterations N] [--tasks "repo1 b1,repo2 b2,..."]
#                     [--env-file PATH] [--tar-path PATH] [--results-dir PATH]
#
# Defaults: 4 parallel workers, 900s timeout, mock model, 2 iterations,
# all 40 paper bounties.
#
# Results layout (native + wrapper logs) is grouped under:
#   <results-dir>/run_<timestamp>/
# with per-task native workflow logs in:
#   <results-dir>/run_<timestamp>/native_logs/<repo>_<bounty>/

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="bountybench-backend"
TAR_PATH="$SCRIPT_DIR/bountyagent.tar"
ENV_FILE="$SCRIPT_DIR/.env"
RESULTS_DIR="$SCRIPT_DIR/results_parallel"

# Defaults
PARALLELISM=4
TASK_TIMEOUT=900
MODEL=""
ITERATIONS=2
USE_MOCK="--use_mock_model"
CUSTOM_TASKS=""

# DinD-required tasks (service stacks / container-internal mounts)
DIND_TASKS="InvokeAI LibreChat fastapi gradio gpt_academic mlflow pytorch-lightning agentscope composio django gunicorn lunary bentoml scikit-learn"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallelism) PARALLELISM="$2"; shift 2 ;;
    --timeout) TASK_TIMEOUT="$2"; shift 2 ;;
    --model) MODEL="$2"; USE_MOCK=""; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --tasks) CUSTOM_TASKS="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --tar-path) TAR_PATH="$2"; shift 2 ;;
    --results-dir) RESULTS_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if ! [[ "$PARALLELISM" =~ ^[0-9]+$ ]] || [ "$PARALLELISM" -lt 1 ]; then
  echo "Invalid --parallelism value: $PARALLELISM"
  exit 1
fi
if ! [[ "$TASK_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TASK_TIMEOUT" -lt 1 ]; then
  echo "Invalid --timeout value: $TASK_TIMEOUT"
  exit 1
fi
if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
  echo "Invalid --iterations value: $ITERATIONS"
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

if docker info > /dev/null 2>&1; then
  DOCKER_CMD=(docker)
elif sudo -n docker info > /dev/null 2>&1; then
  DOCKER_CMD=(sudo -n docker)
else
  echo "Docker daemon is not reachable via 'docker' or 'sudo -n docker'."
  exit 1
fi

# Build model args
MODEL_ARGS="$USE_MOCK"
if [ -n "$MODEL" ]; then
  MODEL_ARGS="--model $MODEL --max_input_tokens 8192 --max_output_tokens 4096"
fi

# All 40 paper bounties
DEFAULT_TASKS="InvokeAI 0,InvokeAI 1,LibreChat 0,LibreChat 1,LibreChat 2,LibreChat 3,LibreChat 4,agentscope 0,astropy 0,bentoml 0,bentoml 1,composio 0,curl 0,django 0,fastapi 0,gluon-cv 0,gpt_academic 0,gradio 0,gradio 1,gradio 2,gunicorn 0,kedro 0,langchain 0,langchain 1,lunary 0,lunary 1,lunary 2,mlflow 0,mlflow 1,mlflow 2,mlflow 3,parse-url 0,pytorch-lightning 0,pytorch-lightning 1,scikit-learn 0,setuptools 0,undici 0,vllm 0,yaml 0,zipp 0"
TASK_LIST="${CUSTOM_TASKS:-$DEFAULT_TASKS}"

RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$RESULTS_DIR/$RUN_ID"
LOG_DIR="$RUN_DIR/task_stdout"
NATIVE_LOGS_DIR="$RUN_DIR/native_logs"
RESULTS_FILE="$RUN_DIR/results.log"

mkdir -p "$RESULTS_DIR" "$RUN_DIR" "$LOG_DIR" "$NATIVE_LOGS_DIR"

IFS=',' read -ra TASKS <<< "$TASK_LIST"
TOTAL=${#TASKS[@]}

is_dind_task() {
  local repo="$1"
  for dr in $DIND_TASKS; do
    [ "$repo" = "$dr" ] && return 0
  done
  return 1
}

NON_DIND_TASKS=()
DIND_TASKS_QUEUE=()
for task in "${TASKS[@]}"; do
  task_trimmed="$(echo "$task" | xargs)"
  repo="$(echo "$task_trimmed" | cut -d' ' -f1)"
  if is_dind_task "$repo"; then
    DIND_TASKS_QUEUE+=("$task_trimmed")
  else
    NON_DIND_TASKS+=("$task_trimmed")
  fi
done

echo "=== Parallel Run ($PARALLELISM workers) — $(date) ===" | tee "$RESULTS_FILE"
echo "Docker command: ${DOCKER_CMD[*]}" | tee -a "$RESULTS_FILE"
echo "Model: ${MODEL:-mock} | Iterations: $ITERATIONS | Timeout: ${TASK_TIMEOUT}s" | tee -a "$RESULTS_FILE"
echo "Tasks: $TOTAL | Non-DinD: ${#NON_DIND_TASKS[@]} | DinD (sequential): ${#DIND_TASKS_QUEUE[@]}" | tee -a "$RESULTS_FILE"
echo "Run dir: $RUN_DIR" | tee -a "$RESULTS_FILE"
echo "Native logs dir: $NATIVE_LOGS_DIR" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

latest_json_log() {
  local logs_root="$1"
  find "$logs_root" -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2-
}

workflow_success_from_logs() {
  local logs_root="$1"
  local json_file
  json_file="$(latest_json_log "$logs_root")"

  if [ -z "$json_file" ] || [ ! -f "$json_file" ]; then
    echo "unknown"
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    local success
    success="$(jq -r '.workflow_metadata.workflow_summary.success // empty' "$json_file" 2>/dev/null || true)"
    if [ "$success" = "true" ] || [ "$success" = "false" ]; then
      echo "$success"
      return
    fi
  fi

  if grep -q '"success"[[:space:]]*:[[:space:]]*true' "$json_file"; then
    echo "true"
  elif grep -q '"success"[[:space:]]*:[[:space:]]*false' "$json_file"; then
    echo "false"
  else
    echo "unknown"
  fi
}

normalize_repo_state() {
  local repo="$1"
  local module_git_dir="$SCRIPT_DIR/.git/modules/bountytasks/modules/$repo/codebase"

  sudo -n chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR/bountytasks/$repo" >/dev/null 2>&1 || true
  if [ -d "$module_git_dir" ]; then
    sudo -n chown -R "$(id -u):$(id -g)" "$module_git_dir" >/dev/null 2>&1 || true
    sudo -n find "$module_git_dir" -type f -name 'index.lock' -delete >/dev/null 2>&1 || true
  fi
  sudo -n find "$SCRIPT_DIR/bountytasks/$repo" -type f -name 'index.lock' -delete >/dev/null 2>&1 || true
}

run_task() {
  local idx="$1"
  local repo="$2"
  local bounty="$3"
  local force_dind="$4"
  local container_name="bb-par-${repo}-${bounty}-$$"
  local logfile="$LOG_DIR/${repo}_${bounty}.log"
  local task_slug="${repo}_${bounty}"
  local task_native_dir="$NATIVE_LOGS_DIR/$task_slug"
  local task_logs_dir="$task_native_dir/logs"
  local task_full_logs_dir="$task_native_dir/full_logs"
  local task_meta_file="$task_native_dir/meta.txt"
  local start_ts
  local end_ts
  local elapsed
  local exit_code
  local status
  local workflow_success
  local workflow_json
  local run_cmd
  local workflow_cmd
  local task_dir_arg

  mkdir -p "$task_logs_dir" "$task_full_logs_dir"

  if [ "$force_dind" = "true" ]; then
    task_dir_arg="bountytasks/$repo"
  else
    # Non-DinD uses host docker socket; nested volume paths must be host-absolute.
    task_dir_arg="$SCRIPT_DIR/bountytasks/$repo"
  fi

  workflow_cmd="python -m workflows.runner \
    --workflow-type exploit_workflow \
    --task_dir $task_dir_arg \
    --bounty_number $bounty \
    $MODEL_ARGS \
    --phase_iterations $ITERATIONS \
    --logging_level WARNING"
  run_cmd="$workflow_cmd"

  start_ts=$(date +%s)

  if [ "$force_dind" = "true" ]; then
    if [ ! -f "$TAR_PATH" ]; then
      echo "Missing bountyagent tar for DinD task $repo/$bounty: $TAR_PATH" > "$logfile"
      exit_code=1
    else
      timeout "$TASK_TIMEOUT" "${DOCKER_CMD[@]}" run --rm \
        --name "$container_name" \
        --privileged \
        -v dind-data:/var/lib/docker \
        -v "$TAR_PATH:/app/bountyagent.tar:ro" \
        -v "$task_logs_dir:/app/logs" \
        -v "$task_full_logs_dir:/app/full_logs" \
        --env-file "$ENV_FILE" \
        "$IMAGE" \
        bash -c "$workflow_cmd" > "$logfile" 2>&1
      exit_code=$?
    fi
  else
    normalize_repo_state "$repo"
    run_cmd="git config --global --add safe.directory '*' >/dev/null 2>&1; $workflow_cmd"
    timeout "$TASK_TIMEOUT" "${DOCKER_CMD[@]}" run --rm \
      --name "$container_name" \
      --privileged \
      -v "$SCRIPT_DIR:$SCRIPT_DIR" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -w "$SCRIPT_DIR" \
      -v "$task_logs_dir:$SCRIPT_DIR/logs" \
      -v "$task_full_logs_dir:$SCRIPT_DIR/full_logs" \
      --env-file "$ENV_FILE" \
      --entrypoint bash \
      "$IMAGE" \
      -c "$run_cmd" > "$logfile" 2>&1
    exit_code=$?
  fi

  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  if [ "$force_dind" != "true" ]; then
    # Non-DinD host-socket runs execute as root in the outer container.
    # Normalize ownership back to invoking user to keep git operations writable.
    sudo -n chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR/bountytasks/$repo" >/dev/null 2>&1 || true
  fi

  "${DOCKER_CMD[@]}" rm -f "$container_name" > /dev/null 2>&1 || true

  workflow_success="unknown"
  if [ "$exit_code" -eq 0 ]; then
    workflow_success="$(workflow_success_from_logs "$task_logs_dir")"
  fi

  if [ "$workflow_success" = "true" ]; then
    status="PASS"
  elif [ "$exit_code" -eq 0 ]; then
    status="OK"
  elif [ "$exit_code" -eq 124 ]; then
    status="TIMEOUT"
  else
    status="BROKEN"
  fi

  workflow_json="$(latest_json_log "$task_logs_dir")"
  {
    echo "task=$repo/$bounty"
    echo "status=$status"
    echo "exit_code=$exit_code"
    echo "elapsed_seconds=$elapsed"
    echo "workflow_success=$workflow_success"
    echo "stdout_log=$logfile"
    echo "workflow_json=${workflow_json:-none}"
  } > "$task_meta_file"

  printf "[%d/%d] %-25s %s (%ds)\n" "$idx" "$TOTAL" "$repo/$bounty" "$status" "$elapsed" | tee -a "$RESULTS_FILE"
}

run_non_dind_parallel() {
  local running=0
  local pids=()
  local idx=0
  local repo bounty

  for task in "${NON_DIND_TASKS[@]}"; do
    repo="$(echo "$task" | cut -d' ' -f1)"
    bounty="$(echo "$task" | cut -d' ' -f2)"
    idx=$((idx + 1))

    run_task "$idx" "$repo" "$bounty" "false" &
    pids+=("$!")
    running=$((running + 1))

    if [ "$running" -ge "$PARALLELISM" ]; then
      wait -n 2>/dev/null || wait "${pids[0]}"
      new_pids=()
      for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          new_pids+=("$pid")
        fi
      done
      pids=("${new_pids[@]}")
      running="${#pids[@]}"
    fi
  done

  wait
}

run_dind_sequential() {
  local idx="${#NON_DIND_TASKS[@]}"
  local repo bounty

  for task in "${DIND_TASKS_QUEUE[@]}"; do
    repo="$(echo "$task" | cut -d' ' -f1)"
    bounty="$(echo "$task" | cut -d' ' -f2)"
    idx=$((idx + 1))
    run_task "$idx" "$repo" "$bounty" "true"
  done
}

run_non_dind_parallel
run_dind_sequential

echo "" | tee -a "$RESULTS_FILE"
echo "=== SUMMARY ===" | tee -a "$RESULTS_FILE"
ok="$(grep -c " OK\\| PASS" "$RESULTS_FILE" || true)"
broken="$(grep -c " BROKEN\\| TIMEOUT" "$RESULTS_FILE" || true)"
pass="$(grep -c " PASS" "$RESULTS_FILE" || true)"
echo "Total: $TOTAL | OK: $ok | Broken: $broken | Pass: $pass" | tee -a "$RESULTS_FILE"
echo "Finished at $(date)" | tee -a "$RESULTS_FILE"
echo "Results: $RESULTS_FILE" | tee -a "$RESULTS_FILE"
echo "Run directory: $RUN_DIR" | tee -a "$RESULTS_FILE"
