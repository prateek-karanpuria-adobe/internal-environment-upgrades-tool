#!/bin/zsh

# Print colored info section for project processing
print_info() {
    local msg="$1"
    local use_log="${2:-false}"
    if [ "$use_log" = true ]; then
        printf "${MAGENTA}==================================================================${RESET}\n"
        log INFO "$msg"
        printf "${MAGENTA}==================================================================${RESET}\n"
    else
        printf "\n${CYAN}==================================================================${RESET}\n"
        printf " %s " "$msg"
        printf "\n${CYAN}==================================================================${RESET}\n"
    fi
}

# Logging with colors
log() {
    local level=$1; shift
    local msg="$*"
    case "$level" in
        INFO)  color=$'\033[38;5;214m'; icon="ℹ️ " ;;
        OK)    color="\033[32m"; icon="✅" ;;
        WARN)  color="\033[33m"; icon="⚠️ " ;;
        ERROR) color="\033[31m"; icon="❌ " ;;
        *)     color=""; icon=" " ;;
    esac
    reset="\033[0m"
    printf "%b %s %s%b\n" "$color" "$icon" "$msg" "$reset"
}

# Spinner utility for background processes
spinner() {
    local pid=$1 spin='|/-\\' i=0
    command -v tput >/dev/null && tput civis
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r%s" "${spin:$i:1}"
        sleep 0.1
    done
    command -v tput >/dev/null && tput cnorm
    printf "\r"
}
