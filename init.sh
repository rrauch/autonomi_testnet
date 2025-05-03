#!/bin/bash
set -e

if [[ "$EDITOR" == "$TARGET_VALUE" ]]; then
  echo "downloading latest antnode binary" >&2
  antctl upgrade
  rm -f /usr/local/bin/antnode
  mv /var/antctl/downloads/antnode /usr/local/bin/
  chmod 0755 /usr/local/bin/antnode
else
  echo "using bundled version of antnode binary" >&2
fi
echo "Antnode version:" >&2
antnode --version >&2

chown -R autonomi:autonomi /data
echo "/data ownership updated to autonomi:autonomi." >&2

echo "Switching to user autonomi and executing the rest of the script..." >&2
exec gosu autonomi:autonomi /run.sh
