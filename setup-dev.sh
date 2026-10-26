
#!/usr/bin/env bash
set -euo pipefail

# macOS Development Environment Setup
# Erlang 29.1.2 / Elixir 1.20.4-otp-29
# Node.js 24.21.0 / PostgreSQL 17.x

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: This script is intended for macOS."
  exit 1
fi

log() {
  printf '\n==> %s\n' "$1"
}

MISE_BIN="$HOME/.local/bin/mise"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
PG_DATA="$HOME/.local/share/postgres/17"
DB_NAME="$(id -un)"

# 1. Install mise
log "Installing/checking mise"

if [[ -x "$MISE_BIN" ]]; then
  echo "mise already installed."
elif command -v mise >/dev/null 2>&1; then
  MISE_BIN="$(command -v mise)"
else
  curl -fsSL https://mise.run | sh
fi

"$MISE_BIN" --version

# 2. Configure Zsh
log "Configuring Zsh"

touch "$ZSHRC"

# Avoid adding activation if already configured.
if ! grep -Eq 'mise activate zsh|mise\.zsh' "$ZSHRC"; then
  printf '\n# mise version manager\n' >> "$ZSHRC"
  printf 'eval "$(%s activate zsh)"\n' "$MISE_BIN" >> "$ZSHRC"
  echo "Added mise activation to $ZSHRC"
else
  echo "mise activation already present."
fi

# 3. Install exact language versions
log "Installing Erlang 29.1.2"
"$MISE_BIN" use --global erlang@29.1.2

log "Installing Elixir 1.20.4-otp-29"
"$MISE_BIN" use --global elixir@1.20.4-otp-29

log "Installing Node.js 24.21.0"
"$MISE_BIN" use --global node@24.21.0

# 4. Install PostgreSQL
log "Installing PostgreSQL 17.x"
"$MISE_BIN" use --global postgres@17

# 5. PostgreSQL initialization
log "Configuring PostgreSQL"

export PG_DATA DB_NAME

"$MISE_BIN" exec -- bash <<'POSTGRES_SETUP'
set -euo pipefail

# Use an already-running local server if available.
if pg_isready -q -h /tmp -p 5432; then
  echo "PostgreSQL is already running on port 5432."
else
  # Never overwrite an existing PostgreSQL cluster.
  if [[ ! -f "$PG_DATA/PG_VERSION" ]]; then
    if [[ -d "$PG_DATA" ]] &&
       [[ -n "$(ls -A "$PG_DATA")" ]]; then
      echo "Error: Data directory is not empty:"
      echo "$PG_DATA"
      exit 1
    fi

    mkdir -p "$PG_DATA"
    initdb -D "$PG_DATA"
  fi

  # Refuse to start a database from another major version.
  PG_MAJOR="$(cat "$PG_DATA/PG_VERSION")"
  if [[ "$PG_MAJOR" != "17" ]]; then
    echo "Error: Existing database uses PostgreSQL $PG_MAJOR."
    exit 1
  fi

  echo "Starting PostgreSQL..."
  if ! pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
    pg_ctl -D "$PG_DATA" \
      -l "$PG_DATA/server.log" \
      -o "-h localhost -k /tmp -p 5432" start
  fi
fi

# Check that the accessible server is PostgreSQL 17.
SERVER_MAJOR="$(
  psql -h /tmp -p 5432 -d postgres -Atqc \
    'SHOW server_version_num;' |
    awk '{print int($1 / 10000)}'
)"

if [[ "$SERVER_MAJOR" != "17" ]]; then
  echo "Error: Running server is not PostgreSQL 17."
  exit 1
fi

# Create a database matching the macOS username.
if ! psql -h /tmp -p 5432 -d postgres -Atqc \
  "SELECT 1 FROM pg_database WHERE datname = current_user" |
  grep -qx 1; then
  echo "Creating database: $DB_NAME"
  createdb -h /tmp -p 5432 "$DB_NAME"
else
  echo "User database already exists."
fi

echo "PostgreSQL is ready."
POSTGRES_SETUP

# 6. Verification
log "Verifying installation"

"$MISE_BIN" ls

"$MISE_BIN" exec -- bash <<'VERIFY'
set -e

echo
echo "Erlang:"
erl -noshell -eval \
  'io:format("~s~n", [erlang:system_info(system_version)]), halt().'

echo
echo "Elixir:"
elixir --version

echo
echo "Node.js:"
node --version

echo
echo "PostgreSQL:"
psql --version

echo
echo "Connected database:"
psql -h /tmp -d "$(id -un)" -Atqc \
  'SELECT current_database();'
VERIFY

log "Setup completed successfully!"

echo
echo "Open a new terminal or run:"
echo "  exec zsh"
echo
echo "Useful commands:"
echo "  mise ls"
echo "  mise doctor"
echo "  psql"
echo
echo "PostgreSQL data directory:"
echo "  $PG_DATA"
