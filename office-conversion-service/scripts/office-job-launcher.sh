#!/bin/zsh
set -euo pipefail

cpu_seconds=""
memory_bytes=""
sandbox_executable=""
profile=""

while (( $# > 0 )); do
  case "$1" in
    --cpu-seconds) cpu_seconds="$2"; shift 2 ;;
    --memory-bytes) memory_bytes="$2"; shift 2 ;;
    --sandbox-executable) sandbox_executable="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --) shift; break ;;
    *) print -u2 "unknown launcher option: $1"; exit 64 ;;
  esac
done

if [[ -z "$cpu_seconds" || -z "$memory_bytes" || -z "$sandbox_executable" || -z "$profile" || $# -eq 0 ]]; then
  print -u2 'resource launcher configuration is incomplete'
  exit 64
fi
if [[ "$cpu_seconds" != <-> || "$memory_bytes" != <-> || "$cpu_seconds" -le 0 || "$memory_bytes" -le 0 ]]; then
  print -u2 'resource limits must be positive integers'
  exit 64
fi

# The Java process enforces the wall clock timeout as well. These limits keep
# runaway LibreOffice children bounded before the wall clock guard fires.
if ! ulimit -t "$cpu_seconds" 2>/dev/null; then
  print -u2 'the host cannot apply the CPU resource limit'
  exit 64
fi
# macOS does not support setting a useful virtual-memory rlimit for this
# process on every supported host. Enforce the independent memory contract by
# supervising the sandbox process and its descendants instead. The sampling
# interval is 100ms, so the documented bound permits one interval of RSS
# growth as the enforcement overshoot. The process timeout and CPU rlimit
# remain hard bounds.
memory_kib=$(( memory_bytes / 1024 ))
if (( memory_kib < 262144 )); then
  print -u2 'configured process memory limit is below 256 MiB'
  exit 64
fi

descendant_pids() {
  local root="$1"
  local snapshot
  snapshot="$(ps -axo pid=,ppid=,rss= 2>/dev/null)" || return 1
  [[ -n "$snapshot" ]] || return 1
  print -r -- "$snapshot" | awk -v root="$root" '
    function descendant(pid, current, hops) {
      current = pid
      for (hops = 0; hops < 10000; hops++) {
        if (current == root) return 1
        if (!(current in parent)) return 0
        if (parent[current] == current) return 0
        current = parent[current]
      }
      return 0
    }
    { parent[$1] = $2; rss[$1] = $3 }
    END {
      for (pid in rss) if (descendant(pid)) print pid
    }
  '
}

tree_rss_kib() {
  local root="$1"
  local snapshot
  snapshot="$(ps -axo pid=,ppid=,rss= 2>/dev/null)" || return 1
  [[ -n "$snapshot" ]] || return 1
  print -r -- "$snapshot" | awk -v root="$root" '
    function descendant(pid, current, hops) {
      current = pid
      for (hops = 0; hops < 10000; hops++) {
        if (current == root) return 1
        if (!(current in parent)) return 0
        if (parent[current] == current) return 0
        current = parent[current]
      }
      return 0
    }
    { parent[$1] = $2; rss[$1] = $3 }
    END {
      if (!(root in rss)) { print "MISSING"; exit 2 }
      total = 0
      for (pid in rss) if (descendant(pid)) total += rss[pid]
      print total + 0
    }
  '
}

terminate_tree() {
  local root="$1"
  local captured
  captured="$(descendant_pids "$root" 2>/dev/null || true)"
  local pid
  for pid in ${(f)captured}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.2
  # Keep the original PID set: children can reparent after the root receives
  # TERM and would disappear from a fresh ancestry walk before KILL.
  for pid in ${(f)captured}; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

"$sandbox_executable" -f "$profile" -- "$@" &
child_pid=$!
memory_exceeded=0
while kill -0 "$child_pid" 2>/dev/null; do
  rss_kib="$(tree_rss_kib "$child_pid" 2>/dev/null || true)"
  if [[ "$rss_kib" != <-> ]]; then
    if ! kill -0 "$child_pid" 2>/dev/null; then
      break
    fi
    terminate_tree "$child_pid"
    print -u2 'the host cannot inspect the conversion process memory bound'
    exit 64
  fi
  if (( rss_kib > memory_kib )); then
    memory_exceeded=1
    terminate_tree "$child_pid"
    break
  fi
  sleep 0.1
done

wait "$child_pid" 2>/dev/null || child_status=$?
child_status="${child_status:-0}"
if (( memory_exceeded )); then
  print -u2 'the conversion process exceeded its memory resource limit'
  exit 137
fi
exit "$child_status"
