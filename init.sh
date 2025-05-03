#!/bin/bash
# Entrypoint script: Configures antnode, sets permissions, then executes /run.sh as 'autonomi' user.

# Exit immediately if a command fails.
set -e

# --- Config ---
# Controls antnode source. Set via Env Var. Examples: "LATEST", "BUNDLED". Comparison is case-insensitive.
ANTNODE_SOURCE="${ANTNODE_SOURCE:-BUNDLED}"
UPGRADE_TRIGGER_VALUE="LATEST" # Value of ANTNODE_SOURCE that triggers an upgrade.

# --- Antnode Setup ---
# Compare case-insensitively by converting both sides to lowercase (Bash 4.0+)
if [[ "${ANTNODE_SOURCE,,}" == "${UPGRADE_TRIGGER_VALUE,,}" ]]; then
  echo "Attempting to download and install latest antnode (case-insensitive match)..." >&2
  if antctl upgrade; then
    echo "'antctl upgrade' completed." >&2
    # Verify download before moving, as 'antctl upgrade' might succeed without producing the file.
    if [[ -f "/var/antctl/downloads/antnode" ]]; then
      echo "Moving downloaded antnode to /usr/local/bin/..." >&2
      rm -f /usr/local/bin/antnode
      mv /var/antctl/downloads/antnode /usr/local/bin/antnode
      chmod 0755 /usr/local/bin/antnode
      echo "Antnode binary updated." >&2
    else
      echo "Error: 'antctl upgrade' ran but '/var/antctl/downloads/antnode' not found." >&2
      exit 1
    fi
  else
    echo "Error: 'antctl upgrade' failed." >&2
    exit 1
  fi
else
  # Assuming any other value means using whatever 'antnode' is pre-installed or in PATH.
  echo "Using bundled antnode." >&2
fi

# --- Verification & Permissions ---
echo "Verifying antnode version:" >&2
if antnode --version >&2; then
  echo "Antnode check successful." >&2
else
  echo "Error: 'antnode --version' failed. Cannot proceed." >&2
  exit 1
fi

echo "Updating /data ownership..." >&2
chown -R autonomi:autonomi /data
echo "/data ownership set to autonomi:autonomi." >&2

# --- Execution ---
echo "Switching to user autonomi:autonomi and executing /run.sh..." >&2
# Replace current shell process with the target script.
exec gosu autonomi:autonomi /run.sh


