#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
source_dir="$project_dir/Sources"

check_fixed() {
    local id=$1
    local label=$2
    local pattern=$3
    shift 3
    if /usr/bin/grep -Fq -- "$pattern" "$@"; then
        printf '%s\t%s\t%s\n' "$id" "FOUND" "$label"
    else
        printf '%s\t%s\t%s\n' "$id" "MISSING" "$label"
    fi
}

print -r -- "guardian technical spike doctor (static, read-only)"
printf 'ID\tSTATUS\tCHECK\n'

check_fixed T01 "UserPromptSubmit hook installer" \
    'events["UserPromptSubmit"]' \
    "$source_dir/TokenPetCore/RoutingPreflight.swift"
check_fixed T01 "top-level task safety gate" \
    'CodexThreadSelectionReader.isTopLevelUserTask' \
    "$source_dir/TokenPetCLI/main.swift"
check_fixed T02 "task replay accepts model override" \
    'model: model' \
    "$source_dir/TokenPetCore/CodexDesktopIPC.swift"
check_fixed T02 "task replay accepts effort override" \
    'reasoningEffort: reasoningEffort' \
    "$source_dir/TokenPetCore/CodexDesktopIPC.swift"
check_fixed T03 "active turn interrupt entrypoint" \
    'public static func interrupt(' \
    "$source_dir/TokenPetCore/CodexDesktopIPC.swift"
check_fixed T04 "multi-agent audit implementation" \
    'public enum MultiAgentAuditPolicy' \
    "$source_dir/TokenPetCore/MultiAgentAudit.swift"
check_fixed T04 "subagent lifecycle Hook ledger" \
    'public struct SubagentHookObservation' \
    "$source_dir/TokenPetCore/SubagentHookLedger.swift"
check_fixed T04 "execution waste implementation" \
    'public struct ExecutionWasteObservation' \
    "$source_dir/TokenPetCore/ExecutionWaste.swift"
check_fixed T05 "preflight can launch a model classifier without an app consent gate (BLOCKER)" \
    'classifyPreflight(' \
    "$source_dir/TokenPetCLI/main.swift"

if /usr/bin/grep -Rq --include='*.swift' -E \
    'AGENTS\.md.*(fingerprint|hash)|(?:fingerprint|hash).*AGENTS\.md' \
    "$source_dir"; then
    printf 'T06\tFOUND\tAGENTS.md configuration fingerprint\n'
else
    printf 'T06\tMISSING\tAGENTS.md configuration fingerprint\n'
fi

if /usr/bin/grep -Rq --include='*.swift' -E \
    '(skill|agent|hook).*(version|fingerprint).*(routing|outcome)|routing.*outcome.*(skill|agent|hook)' \
    "$source_dir"; then
    printf 'T07\tFOUND\tworkflow fingerprint linked to routing outcome\n'
else
    printf 'T07\tMISSING\tworkflow fingerprint linked to routing outcome\n'
fi

printf 'NOTE\tS1_ONLY\tFOUND proves source presence only; it does not prove build or runtime behavior\n'

if [[ ${1:-} == "--local-runtime" ]]; then
    codex_home_path=${CODEX_HOME:-$HOME/.codex}
    hooks_path="$codex_home_path/hooks.json"
    ipc_path="$codex_home_path/ipc/ipc.sock"
    installed_helper="$project_dir/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli"
    app_lock_path="$HOME/Library/Application Support/TokenPet/app.lock"

    print
    print -r -- "local runtime metadata (read-only, no task or model call)"
    printf 'ID\tSTATUS\tCHECK\n'

    if [[ -f $hooks_path ]]; then
        printf 'R00\tFOUND\tCodex hooks file\n'
        if /usr/bin/grep -Fq -- '--user-prompt-submit-hook' "$hooks_path"; then
            printf 'R00\tFOUND\tGuardian UserPromptSubmit marker\n'
        else
            printf 'R00\tMISSING\tGuardian UserPromptSubmit marker\n'
        fi
        if /usr/bin/grep -Fq -- '--subagent-lifecycle-hook' "$hooks_path"; then
            printf 'R00\tFOUND\tGuardian subagent lifecycle markers\n'
        else
            printf 'R00\tMISSING\tGuardian subagent lifecycle markers\n'
        fi
        if command -v jq >/dev/null 2>&1 && jq -e --arg helper "$installed_helper" \
            '[.. | objects | .command? // empty | select(type == "string") | contains($helper)] | any' \
            "$hooks_path" >/dev/null; then
            printf 'R00\tFOUND\tHook points to current installed Guardian helper\n'
        else
            printf 'R00\tMISSING\tHook target could not be verified as current installed Guardian helper\n'
        fi
    else
        printf 'R00\tMISSING\tCodex hooks file\n'
        printf 'R00\tMISSING\tGuardian UserPromptSubmit marker\n'
        printf 'R00\tMISSING\tHook target could not be verified as current installed Guardian helper\n'
    fi

    if [[ -S $ipc_path ]]; then
        printf 'R00\tFOUND\tCodex Desktop IPC socket\n'
    else
        printf 'R00\tMISSING\tCodex Desktop IPC socket\n'
    fi

    if [[ -x $installed_helper ]]; then
        printf 'R00\tFOUND\tinstalled Guardian CLI helper\n'
    else
        printf 'R00\tMISSING\tinstalled Guardian CLI helper\n'
    fi

    if [[ -f $app_lock_path ]] && /usr/sbin/lsof "$app_lock_path" 2>/dev/null | /usr/bin/grep -q 'CodexSess'; then
        printf 'R00\tFOUND\tGuardian owns the app lock\n'
    else
        printf 'R00\tMISSING\tGuardian app-lock owner\n'
    fi

    printf 'NOTE\tMETADATA_ONLY\tNo configuration body, prompt, task, or model call was emitted\n'
fi
