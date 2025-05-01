#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# This part is supposed to run as root
chown -R autonomi:autonomi /data
echo "/data ownership updated to autonomi:autonomi."

echo "Switching to user autonomi and executing the rest of the script..."

# Use exec gosu to switch user, and run bash -c with a simple command
# The command it runs will be 'bash -s', which tells the *inner* bash
# to read its script from standard input.
# The following <<'EOF_INNER' then provides that script content.
exec gosu autonomi /bin/bash -s <<'EOF_INNER'
# --- Start of commands running as user autonomi (read from stdin) ---

echo "Now running as user $(whoami) (UID $(id -u): GID $(id -g))"

# 1. Check if required environment variables is set
echo "Checking for REWARDS_ADDRESS..."
if [ -z "$REWARDS_ADDRESS" ]; then
  echo "Error: REWARDS_ADDRESS environment variable is not set. Cannot proceed."
  exit 1 # Exit with a non-zero status to indicate failure
fi
echo "REWARDS_ADDRESS is set: $REWARDS_ADDRESS"

echo "Checking for HOST_IP_ADDRESS..."
if [ -z "$HOST_IP_ADDRESS" ]; then
  echo "Error: HOST_IP_ADDRESS environment variable is not set. Cannot proceed."
  exit 1 # Exit with a non-zero status to indicate failure
fi
echo "HOST_IP_ADDRESS is set: $HOST_IP_ADDRESS"

export ANVIL_IP_ADDR="$HOST_IP_ADDRESS"

cleanup() {
    exit 0
}

trap cleanup SIGTERM SIGINT

DATA_DIR="/data/.local/share/autonomi"
CSV_FILE="$DATA_DIR/evm_testnet_data.csv"
rm -f "$CSV_FILE"
rm -rf "$DATA_DIR/bootstrap_cache"

EXPORT_DIR="$DATA_DIR/export"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
BOOTSTRAP_TXT="$EXPORT_DIR/bootstrap.txt"

# 2. Start 'evm-testnet' process in the background
echo "Starting evm-testnet in the background..."
# Assuming 'evm-testnet' is in the PATH, otherwise provide the full path
evm-testnet &
EVM_PID=$! # Capture the Process ID of the background job

echo "evm-testnet started with PID $EVM_PID"

# 3. Wait for a evm-testnet csv file to exist
WAIT_TIMEOUT_SEC=30    # Maximum time to wait in seconds
WAIT_INTERVAL_MSEC=200 # How often to check (in milliseconds)

# Convert timeout to milliseconds for integer arithmetic
WAIT_TIMEOUT_MSEC=$((WAIT_TIMEOUT_SEC * 1000))
ELAPSED_TIME_MSEC=0

echo "Waiting for file '$CSV_FILE' to appear (timeout: ${WAIT_TIMEOUT_SEC}s)..."

# Calculate sleep duration in seconds for the 'sleep' command
# Use bc for floating point division if needed, or pre-calculate if interval is simple
# For 200ms, this is just 0.2 seconds
SLEEP_DURATION_SEC="0.${WAIT_INTERVAL_MSEC}" # Simple string for sleep command if interval is < 1 sec

while [ ! -f "$CSV_FILE" ] && [ "$ELAPSED_TIME_MSEC" -lt "$WAIT_TIMEOUT_MSEC" ]; do
  echo "File not found yet. Waiting ${SLEEP_DURATION_SEC}s..."
  # Use the sleep command which handles fractional seconds
  sleep "$SLEEP_DURATION_SEC"
  ELAPSED_TIME_MSEC=$((ELAPSED_TIME_MSEC + WAIT_INTERVAL_MSEC))
done

# Check if the file was found or if we timed out
if [ ! -f "$CSV_FILE" ]; then
  echo "Error: Timeout waiting for file '$CSV_FILE'. Aborting startup."
  exit 1 # Exit with failure status
fi

echo "File '$CSV_FILE' found! Proceeding..."

parse_csv_file() {
  local file="$1"
  
  # Check if file exists
  if [ ! -f "$file" ]; then
    echo ">>> Error: File $file does not exist." >&2
    return 1
  fi
  
  # Read the first line of the file
  local line
  line=$(head -n 1 "$file")
  
  # Split the line by comma into an array
  IFS=',' read -r -a parts <<< "$line"
  
  # Check if we have exactly 4 parts
  if [ ${#parts[@]} -ne 4 ]; then
    echo ">>> Error: Expected 4 comma-separated values in $file, found ${#parts[@]}." >&2
    return 1
  fi
  
  # Return values by setting variables in the parent scope
  # Bash doesn't have a direct way to return multiple values,
  # but we can set variables in the calling scope
  RPC_URL="${parts[0]}"
  PAYMENT_TOKEN_ADDRESS="${parts[1]}"
  DATA_PAYMENTS_ADDRESS="${parts[2]}"
  SECRET_KEY="${parts[3]}"
  
  # Return success
  return 0
}

parse_csv_file "$CSV_FILE"

escape_sed_chars() {
  echo "$1" | sed 's/[.[\*^$|]/\\&/g'
}
ESCAPED_RPC_URL=$(escape_sed_chars "$RPC_URL")

LOCAL_RPC_URL="http://localhost:$ANVIL_PORT/"
#sed -i "s|$ESCAPED_RPC_URL|$LOCAL_RPC_URL|g" "$CSV_FILE"

echo ">>> Executing antctl local run..."
antctl local run --clean --rewards-address "$REWARDS_ADDRESS" --node-port "$NODE_PORT" --rpc-port "$RPC_PORT"
sleep 1

echo ""	
echo "------------------------------------------------------"
echo "evm testnet details"
echo ""
echo "> RPC_URL: $RPC_URL"
echo "> PAYMENT_TOKEN_ADDRESS: $PAYMENT_TOKEN_ADDRESS"
echo "> DATA_PAYMENTS_ADDRESS: $DATA_PAYMENTS_ADDRESS"
echo "> SECRET_KEY: $SECRET_KEY"
echo ""
echo "------------------------------------------------------"
echo ""
echo "node details"
echo ""

NODES=$(jq '.nodes' "$DATA_DIR/local_node_registry.json")
echo "$NODES" | jq -c '.[]' | while read -r node; do
    # Extract peer_id and node_port for the current node
    peer_id=$(echo "$node" | jq -r '.peer_id')
    node_port=$(echo "$node" | jq -r '.node_port')

    echo "$node_port   $peer_id"
done

echo ""
echo "------------------------------------------------------"
echo ""

jq --arg host_ip "$HOST_IP_ADDRESS" -r \
   '.nodes[].listen_addr[] | select((split("/") | .[2]) == $host_ip)' \
   "$DATA_DIR/local_node_registry.json" >> "$BOOTSTRAP_TXT"

darkhttpd "$EXPORT_DIR" --port "$BOOTSTRAP_PORT" --daemon --no-listing > /dev/null 2>&1

BOOTSTRAP_URL="http://$HOST_IP_ADDRESS:$BOOTSTRAP_PORT/bootstrap.txt"
echo "Bootstrap URL: $BOOTSTRAP_URL"

echo ""
echo "------------------------------------------------------"
echo ""


# Function to URL encode a string according to RFC 3986
urlencode() {
    # Check if argument is provided
    if [ -z "$1" ]; then
        echo "Error: No input provided to urlencode" >&2
        return 1
    fi
    
    local string="$1"
    local length="${#string}"
    local i=0
    local encoded=""
    local c
    
    while [ "$i" -lt "$length" ]; do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) 
                # These are the "unreserved" characters that don't need encoding
                encoded+="$c"
                ;;
            *)
                # All other characters need percent-encoding
                # Using printf to get the ASCII value and convert to hex
                LC_CTYPE=C printf -v encoded_char '%%%02X' "'$c"
                encoded+="$encoded_char"
                ;;
        esac
        i=$((i + 1))
    done
    
    echo "$encoded"
}


echo "autonomi:config:local?rpc_url=$( urlencode "$RPC_URL" )&payment_token_addr=$PAYMENT_TOKEN_ADDRESS&data_payments_addr=$DATA_PAYMENTS_ADDRESS&bootstrap_url=$( urlencode "$BOOTSTRAP_URL" )"


echo ""
echo "------------------------------------------------------"
echo ""


# 5. Run 'status_check' command in a loop until it fails
STATUS_CHECK_SLEEP_SECONDS=2 # How long to sleep between status_check executions
STATUS_COMMAND="antctl local status --fail" # The command to run repeatedly

echo ">>> Nodes started, observing status: $STATUS_COMMAND"

while true; do
  # Sleep first
  sleep "$STATUS_CHECK_SLEEP_SECONDS"

  # Execute the command, suppress all output (&>/dev/null)
  # If the command fails (exit status != 0), the 'if' condition is false
  if $STATUS_COMMAND &>/dev/null; then
    # Command succeeded (exit status 0) - do nothing, loop continues
    : # This is the null command, does nothing
  else
    # Command failed (non-zero exit status)
    EXIT_STATUS=$? # Capture the exit status
    echo ">>> Command '$STATUS_COMMAND' failed with exit status $EXIT_STATUS. Exiting." >&2 # Output failure to stderr
    exit $EXIT_STATUS # Exit the script with the command's failure status
  fi
done

# This part is only reached if the 'while true' loop is somehow broken without the command failing.
echo ">>> Loop unexpectedly terminated." # Should not be reached
exit 1 # Indicate an unexpected exit
# --- End of commands running as user autonomi ---
EOF_INNER

