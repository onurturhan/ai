#!/usr/bin/env bash

# source Usage (Important) : setup-ai.sh

# 🚀 AI Multi-CLI tmux Workspace Bootstrap (Hardened)

set -euo pipefail
IFS=$'\n\t'

############################################
# ⚙️ Configuration
############################################
SESSION="ai"
WORKDIR="$(pwd)"
BASHRC="$HOME/.bashrc"
TMUX_CONF="$HOME/.tmux.conf"
NPM_GLOBAL="$HOME/.npm-global"
ENV_FILE="$HOME/.ai_env"
LOG_FILE="$HOME/ai-setup.log"
AI_CONF_DIR="$WORKDIR/.ai"

############################################
# 📝 Logging
############################################
exec > >(tee -a "$LOG_FILE") 2>&1
echo "🚀 Starting AI workspace setup..."

############################################
# 1️⃣ Ensure Node & npm exist (auto-install)
############################################

install_node() {
    echo "📦 Installing Node.js & npm..."

    if command -v apt >/dev/null 2>&1; then
        # Debian / Ubuntu
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt install -y nodejs

    elif command -v dnf >/dev/null 2>&1; then
        # Fedora / RHEL 8+
        curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
        sudo dnf install -y nodejs

    elif command -v zypper >/dev/null 2>&1; then
        # openSUSE / SLES
        sudo zypper refresh
        sudo zypper install -y nodejs npm

    elif command -v pacman >/dev/null 2>&1; then
        # Arch
        sudo pacman -Sy --noconfirm nodejs npm

    elif command -v brew >/dev/null 2>&1; then
        # macOS
        brew install node

    else
        echo "❌ Unsupported distro. Please install Node.js manually."
        return 1 2>/dev/null || exit 1
    fi
}

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    install_node
fi

# Final verification
command -v node >/dev/null 2>&1 || { echo "❌ Node.js installation failed."; return 1 2>/dev/null || exit 1; }
command -v npm  >/dev/null 2>&1 || { echo "❌ npm installation failed."; return 1 2>/dev/null || exit 1; }

echo "✅ Node.js & npm ready"

############################################
# 2️⃣ Setup npm global prefix (idempotent)
############################################
mkdir -p "$NPM_GLOBAL"

CURRENT_PREFIX="$(npm config get prefix)"
if [ "$CURRENT_PREFIX" != "$NPM_GLOBAL" ]; then
    echo "🔧 Configuring npm global prefix..."
    npm config set prefix "$NPM_GLOBAL"
fi

if ! grep -q 'npm-global/bin' "$BASHRC" 2>/dev/null; then
    echo "export PATH=\"$NPM_GLOBAL/bin:\$PATH\"" >> "$BASHRC"
    echo "✅ PATH update added to .bashrc"
fi

export PATH="$NPM_GLOBAL/bin:$PATH"

############################################
# 3️⃣ Install AI CLI tools if missing
############################################
install_if_missing () {
    PKG="$1"
    if ! npm list -g --depth=0 2>/dev/null | grep -q "$PKG@"; then
        echo "📦 Installing $PKG ..."
        npm install -g "$PKG" --force >/dev/null 2>&1
    else
        echo "✅ $PKG already installed"
    fi
}

TOOLS=(
  "@google/gemini-cli"
  "@openai/codex"
  "@anthropic-ai/claude-code"
)

for tool in "${TOOLS[@]}"; do
    install_if_missing "$tool"
done

############################################
# 4️⃣ Verify CLI binaries
############################################
command -v claude >/dev/null 2>&1 || { echo "❌ claude CLI missing"; return 1 2>/dev/null || exit 1; }
command -v gemini >/dev/null 2>&1 || { echo "❌ gemini CLI missing"; return 1 2>/dev/null || exit 1; }
command -v codex  >/dev/null 2>&1 || { echo "❌ codex CLI missing";  return 1 2>/dev/null || exit 1; }

echo "✅ All AI CLIs verified"

############################################
# 5️⃣ Persist API keys securely
############################################
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

persist_key () {
    VAR_NAME="$1"
    VALUE="${2:-}"

    if [ -n "$VALUE" ]; then
        if ! grep -q "export $VAR_NAME=" "$ENV_FILE" 2>/dev/null; then
            echo "export $VAR_NAME=\"$VALUE\"" >> "$ENV_FILE"
            echo "🔐 $VAR_NAME saved securely to $ENV_FILE"
        fi
        export "$VAR_NAME=$VALUE"
    fi
}

persist_key "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}"
persist_key "OPENAI_API_KEY" "${OPENAI_API_KEY:-}"

if ! grep -q '.ai_env' "$BASHRC" 2>/dev/null; then
    echo "[ -f \"$ENV_FILE\" ] && source \"$ENV_FILE\"" >> "$BASHRC"
    echo "✅ .ai_env loader added to .bashrc"
fi

# Source immediately for current shell (since you're using source script.sh)
source "$ENV_FILE"

############################################
# 6️⃣ Install tmux if missing (cross-platform)
############################################
if ! command -v tmux >/dev/null 2>&1; then
    echo "📦 Installing tmux..."

    if command -v apt >/dev/null 2>&1; then
        sudo apt update && sudo apt install -y tmux
    elif command -v brew >/dev/null 2>&1; then
        brew install tmux
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy tmux
    else
        echo "❌ Please install tmux manually."
        return 1 2>/dev/null || exit 1
    fi
fi

############################################
# 7️⃣ Configure tmux (idempotent)
############################################
touch "$TMUX_CONF"

add_tmux_line () {
    LINE="$1"
    if ! grep -Fxq "$LINE" "$TMUX_CONF" 2>/dev/null; then
        echo "$LINE" >> "$TMUX_CONF"
    fi
}

# Start maximized (full screen)
add_tmux_line 'setw -g aggressive-resize on'       # Panes automatically resize if terminal size changes
add_tmux_line 'set -g mouse on'                    # Enable mouse support
add_tmux_line 'set -g pane-border-status top'
add_tmux_line 'set -g pane-border-format "#{pane_index} #{pane_title}"'
add_tmux_line 'set -g status on'
add_tmux_line 'set -g status-interval 1'
add_tmux_line 'set -g display-time 2000'
add_tmux_line 'set -s escape-time 500'             # Recognize Alt/Meta keys reliably
add_tmux_line 'set-option -g default-terminal "screen-256color"'

tmux source-file "$TMUX_CONF" 2>/dev/null || true
echo "✅ tmux configured"

############################################
# 8️⃣ Persist useful alias
############################################
add_alias () {
    NAME="$1"
    VALUE="$2"
    if ! grep -q "alias $NAME=" "$BASHRC" 2>/dev/null; then
        echo "alias $NAME=\"$VALUE\"" >> "$BASHRC"
        echo "✅ Alias '$NAME' added"
    fi
}

add_alias "aia" "tmux attach -t $SESSION"

############################################
# 9️⃣ Handle existing session safely
############################################
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "⚠ Existing session found."

    read -rp "Kill and recreate it? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "🔥 Killing existing session..."
        tmux kill-session -t "$SESSION"
    else
        echo "❌ Aborting setup."
        return 0 2>/dev/null || exit 0
    fi
fi


############################################
# 🔟 Create fresh session (deterministic layout)
############################################
echo "🚀 Creating AI tmux workspace..."

tmux new-session -d -s "$SESSION" -n "AI-Workspace" -c "$WORKDIR"

tmux split-window -h -t "$SESSION:0"
tmux split-window -v -t "$SESSION:0.0"
tmux split-window -v -t "$SESSION:0.2"

tmux select-layout -t "$SESSION" tiled

tmux select-pane -t "$SESSION:0.0" -T "Claude"
tmux select-pane -t "$SESSION:0.1" -T "Gemini"
tmux select-pane -t "$SESSION:0.2" -T "Codex"
tmux select-pane -t "$SESSION:0.3" -T "Shell"

tmux send-keys -t "$SESSION:0.0" \
"clear && echo '=== Claude CLI ===' && echo 'Dir: $WORKDIR' && echo && claude --settings $AI_CONF_DIR/claude.json" C-m

tmux send-keys -t "$SESSION:0.1" \
"clear && echo '=== Gemini CLI ===' && echo 'Dir: $WORKDIR' && echo && gemini --output-format text" C-m

tmux send-keys -t "$SESSION:0.2" \
"clear && echo '=== Codex CLI ===' && echo 'Dir: $WORKDIR' && echo && codex --no-alt-screen" C-m

#tmux send-keys -t "$SESSION:0.3" "ai-cli" C-m

# Ctrl+b + number (prefix) jumps
tmux bind-key 1 select-pane -t 0
tmux bind-key 2 select-pane -t 1
tmux bind-key 3 select-pane -t 2
tmux bind-key 4 select-pane -t 3

############################################
# 🔗 Attach
############################################
echo "✅ AI Workspace Ready."

tmux attach -t "$SESSION"
