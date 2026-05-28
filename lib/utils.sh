# ==============================================================================
# KVM-Blacksmith: Systems Engineering Utility Helpers
# ==============================================================================

# Prints formatted info in bold blue text
log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

# Prints formatted warning in bold yellow text
log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1" >&2
}

# Prints formatted error in bold red text
log_err() {
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
}

# ==============================================================================
# Security validation: When sourcing external configuration files, it is vital
# to perform active input validation to prevent arbitrary command injection.
# The regex enforces:
# 1. Namespaced variables starting with 'FORGE_' and containing only caps/nums/underscores.
# 2. Strict wrapping of values in double quotes.
# 3. Rejection of backticks and dollar signs to disable command substitution/expansion.
# ==============================================================================
validate_forge_env_file() {
    local file="$1"
    local line=""
    if [ ! -f "$file" ]; then
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if ! [[ "$line" =~ ^FORGE_[A-Z0-9_]+=\"[^\`\$]*\"$ ]]; then
            return 1
        fi
    done < "$file"
}

# Expand path containing tilde (~) into absolute home path
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Check if yq is installed
check_yq() {
    if ! command -v yq &>/dev/null; then
        log_err "Required command 'yq' is missing. Please install it first."
        exit 1
    fi
}

# Check if gum is installed
check_gum() {
    if ! command -v gum &>/dev/null; then
        log_err "Required command 'gum' is missing. Please install it first."
        log_err "You can install it via:"
        log_err "  - Debian/Ubuntu: apt install gum"
        log_err "  - Fedora/RHEL:   dnf install gum"
        log_err "  - Homebrew:      brew install gum"
        exit 1
    fi
}
