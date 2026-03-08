#!/bin/bash
set -euo pipefail

# FDB Docker entrypoint for persistent single-node deployments.
#
# Starts fdbserver and configures the database on first boot only.
# On subsequent boots, skips configure so existing data is preserved.
#
# Data persists as long as the fdb_data Docker volume is not removed.
# Use "docker compose down" (not "docker compose down -v") to preserve data.

FDB_CLUSTER_FILE=${FDB_CLUSTER_FILE:-/etc/foundationdb/fdb.cluster}
FDB_PORT=${FDB_PORT:-4500}
FDB_PROCESS_CLASS=${FDB_PROCESS_CLASS:-stateless}

# Write cluster file
mkdir -p "$(dirname "$FDB_CLUSTER_FILE")"
if [[ "${FDB_NETWORKING_MODE:-container}" == "container" ]]; then
    public_ip=$(hostname -i | awk '{print $1}')
elif [[ "$FDB_NETWORKING_MODE" == "host" ]]; then
    public_ip=127.0.0.1
else
    echo "Unknown FDB_NETWORKING_MODE: $FDB_NETWORKING_MODE" >&2
    exit 1
fi

echo "docker:docker@$public_ip:$FDB_PORT" > "$FDB_CLUSTER_FILE"
echo "Starting FDB server on $public_ip:$FDB_PORT"

# Start fdbserver in the background
fdbserver \
    --listen-address "0.0.0.0:$FDB_PORT" \
    --public-address "$public_ip:$FDB_PORT" \
    --datadir /var/fdb/data \
    --logdir /var/fdb/logs \
    --locality-zoneid="$(hostname)" \
    --locality-machineid="$(hostname)" \
    --class "$FDB_PROCESS_CLASS" &

fdb_pid=$!
echo "fdbserver pid: $fdb_pid"

# Wait for fdbserver to accept connections
echo "Waiting for fdbserver to be ready..."
for i in $(seq 1 30); do
    if fdbcli -C "$FDB_CLUSTER_FILE" --exec "status minimal" 2>&1 | grep -qE "available|unavailable"; then
        break
    fi
    sleep 1
done

# Configure on first boot only
db_status=$(fdbcli -C "$FDB_CLUSTER_FILE" --exec "status minimal" 2>&1 || true)

if echo "$db_status" | grep -q "The database is available"; then
    echo "Database already configured — skipping initialization"
else
    echo "Initializing database with single ssd configuration..."
    fdbcli -C "$FDB_CLUSTER_FILE" --exec "configure new single ssd"
    echo "Database initialized"
fi

wait $fdb_pid
