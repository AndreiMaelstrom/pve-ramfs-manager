#!/bin/bash

###################################################################################################################
# Name: pve-ramfs-manager.sh
# Description: Manages Proxmox VE data in RAM to reduce disk I/O operations.
#              Handles both pve-cluster and rrdcached data with configurable persistence.
# 
# Based on: pmxcfs-ram by Agustin Isasmendi
#           https://github.com/isasmendiagus/pmxcfs-ram
# 
# License: MIT License
# 
# Copyright (c) 2025 AndreiMaelstrom <andrei@maelstrom.ro>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
###################################################################################################################

###################################################################################################################
# CONFIGURATION
###################################################################################################################

# Log file
LOG_FILE="/var/log/pve-ramfs-manager.log"

# Lock file for instance protection
LOCK_FILE="/var/run/pve-ramfs-manager.lock"

# PVE Cluster Configuration
PVE_CLUSTER_ENABLED=true
PVE_CLUSTER_SERVICE="pve-cluster.service"
PVE_CLUSTER_DATA_PATH="/var/lib/pve-cluster"
PVE_CLUSTER_RAM_PATH="/dev/shm/pve-cluster-ram"
PVE_CLUSTER_PERSISTENT_PATH="/var/lib/pve-cluster-persistent"
PVE_CLUSTER_PERSIST_INTERVAL=3600  # seconds (0 = only on shutdown)

# RRDCached Configuration
RRDCACHED_ENABLED=true
RRDCACHED_SERVICE="rrdcached.service"
RRDCACHED_DATA_PATH="/var/lib/rrdcached/db"
RRDCACHED_RAM_PATH="/dev/shm/rrdcached-ram"
RRDCACHED_PERSISTENT_PATH="/var/lib/rrdcached-persistent"
RRDCACHED_PERSIST_INTERVAL=3600  # seconds (0 = only on shutdown)

###################################################################################################################
# GLOBAL VARIABLES
###################################################################################################################

# Track PIDs for background persistence jobs
declare -A PERSIST_PIDS
declare -A PERSIST_LOOP_PIDS

# Shutdown flag
SHUTTING_DOWN=false

# Detect if running under systemd unit context
RUNNING_UNDER_SYSTEMD=false
if [[ -n "${INVOCATION_ID:-}" ]] || [[ -n "${SYSTEMD_INVOCATION_ID:-}" ]]; then
    RUNNING_UNDER_SYSTEMD=true
fi

# Track services that must be started after systemd activation completes
declare -a DEFERRED_SERVICE_NAMES=()
declare -a DEFERRED_SERVICE_UNITS=()

###################################################################################################################
# LOCK MANAGEMENT
###################################################################################################################

acquire_lock() {
    # Create lock file directory if needed
    mkdir -p "$(dirname "$LOCK_FILE")"
    
    # Try to acquire lock using flock
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "ERROR: Another instance is already running (lock file: $LOCK_FILE)" >&2
        exit 1
    fi
    
    # Write PID to lock file
    echo $$ >&200
}

release_lock() {
    # Release the lock (flock is automatically released when fd is closed)
    # Only attempt if fd 200 is open
    if { true >&200; } 2>/dev/null; then
        exec 200>&-
    fi
    rm -f "$LOCK_FILE"
}

###################################################################################################################
# UTILITY FUNCTIONS
###################################################################################################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" | tee -a "$LOG_FILE" >&2
}

is_mounted() {
    if mountpoint -q "$1" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

is_service_running() {
    systemctl is-active --quiet "$1"
    return $?
}

queue_service_start() {
    local name=$1
    local service=$2
    DEFERRED_SERVICE_NAMES+=("$name")
    DEFERRED_SERVICE_UNITS+=("$service")
}

start_deferred_services() {
    local all_ok=true
    
    for i in "${!DEFERRED_SERVICE_NAMES[@]}"; do
        local name=${DEFERRED_SERVICE_NAMES[$i]}
        local service=${DEFERRED_SERVICE_UNITS[$i]}
        
        if ! ensure_service_started "$name" "$service"; then
            all_ok=false
        fi
    done
    
    # Reset arrays for future runs
    DEFERRED_SERVICE_NAMES=()
    DEFERRED_SERVICE_UNITS=()
    
    if [[ "$all_ok" == false ]]; then
        return 1
    fi
    
    return 0
}

wait_for_service_state() {
    local service=$1
    local desired_state=$2
    local timeout=${3:-10}
    local waited=0
    
    while (( waited < timeout )); do
        if [[ "$desired_state" == "active" ]]; then
            if is_service_running "$service"; then
                return 0
            fi
        else
            if ! is_service_running "$service"; then
                return 0
            fi
        fi
        sleep 1
        ((waited++))
    done
    
    return 1
}

ensure_service_stopped() {
    local name=$1
    local service=$2
    
    if is_service_running "$service"; then
        log "[$name] Stopping $service to prevent data races..."
        if ! systemctl stop "$service"; then
            log_error "[$name] Failed to stop $service"
            return 1
        fi
        
        if ! wait_for_service_state "$service" "inactive" 15; then
            log_error "[$name] $service is still running after stop attempt"
            return 1
        fi
    fi
    
    return 0
}

ensure_service_started() {
    local name=$1
    local service=$2
    
    if is_service_running "$service"; then
        return 0
    fi
    
    log "[$name] Starting $service..."
    if ! systemctl start "$service"; then
        log_error "[$name] Failed to start $service"
        return 1
    fi
    
    if ! wait_for_service_state "$service" "active" 15; then
        log_error "[$name] $service failed to reach active state"
        return 1
    fi
    
    return 0
}

###################################################################################################################
# MOUNT MANAGEMENT FUNCTIONS
###################################################################################################################

setup_mount() {
    local name=$1
    local data_path=$2
    local ram_path=$3
    local persistent_path=$4
    local service=$5
    
    log "[$name] Setting up RAM mount..."
    
    # Check if already mounted
    if is_mounted "$data_path"; then
        log_error "[$name] $data_path is already mounted"
        return 1
    fi
    
    if ! ensure_service_stopped "$name" "$service"; then
        return 1
    fi
    
    # Check for active file handles on data path
    if [[ -d "$data_path" ]] && command -v fuser &>/dev/null; then
        if fuser -s "$data_path" 2>/dev/null; then
            log_error "[$name] Files in $data_path are still in use by other processes"
            return 1
        fi
    fi
    
    # Check if RAM path already exists (indicates unclean shutdown)
    if [[ -d "$ram_path" ]]; then
        log "[$name] RAM path $ram_path exists from previous run, cleaning up..."
        rm -rf "$ram_path"
    fi
    
    # First-time setup: create persistent storage
    if [[ ! -d "$persistent_path" ]]; then
        log "[$name] First run - creating persistent storage"
        mkdir -p "$persistent_path" || {
            log_error "[$name] Failed to create persistent directory"
            return 1
        }
        
        # Copy existing data if present
        if [[ -d "$data_path" ]] && [[ "$(ls -A "$data_path" 2>/dev/null)" ]]; then
            log "[$name] Copying existing data to persistent storage"
            if ! rsync -a "$data_path"/ "$persistent_path"/; then
                log_error "[$name] Failed to copy existing data"
                return 1
            fi
        else
            log "[$name] No existing data found, starting fresh"
        fi
    fi
    
    # Create RAM directory
    log "[$name] Creating RAM directory"
    mkdir -p "$ram_path" || {
        log_error "[$name] Failed to create RAM directory"
        return 1
    }
    
    # Copy data from persistent storage to RAM
    if [[ "$(ls -A "$persistent_path" 2>/dev/null)" ]]; then
        log "[$name] Loading data from persistent storage to RAM"
        if ! rsync -a --delete "$persistent_path"/ "$ram_path"/; then
            log_error "[$name] Failed to copy data to RAM"
            rm -rf "$ram_path"
            return 1
        fi
    fi
    
    # Mount RAM directory over data directory
    log "[$name] Mounting RAM directory to $data_path"
    mount --bind "$ram_path" "$data_path" || {
        log_error "[$name] Failed to mount RAM directory"
        rm -rf "$ram_path"
        return 1
    }
    
    if [[ "$RUNNING_UNDER_SYSTEMD" == true ]]; then
        log "[$name] Deferring $service start until manager activation completes"
        queue_service_start "$name" "$service"
    else
        if ! ensure_service_started "$name" "$service"; then
            log_error "[$name] Failed to start $service after mounting; rolling back"
            teardown_mount "$name" "$data_path" "$ram_path"
            return 1
        fi
    fi
    
    log "[$name] RAM mount setup complete"
    return 0
}

teardown_mount() {
    local name=$1
    local data_path=$2
    local ram_path=$3
    
    log "[$name] Tearing down RAM mount..."
    
    # Unmount if mounted
    if is_mounted "$data_path"; then
        log "[$name] Unmounting $data_path"
        umount "$data_path" || {
            log_error "[$name] Failed to unmount $data_path"
            return 1
        }
    fi
    
    # Remove RAM directory
    if [[ -d "$ram_path" ]]; then
        log "[$name] Removing RAM directory"
        rm -rf "$ram_path"
    fi
    
    log "[$name] Teardown complete"
    return 0
}

###################################################################################################################
# PERSISTENCE FUNCTIONS
###################################################################################################################

persist_data() {
    local name=$1
    local ram_path=$2
    local persistent_path=$3
    local force=${4:-false}
    
    # Skip if shutting down (will be handled by shutdown routine) unless forced
    if [[ "$SHUTTING_DOWN" == true ]] && [[ "$force" != true ]]; then
        return 0
    fi
    
    if [[ ! -d "$ram_path" ]]; then
        log_error "[$name] RAM path $ram_path does not exist; skipping persistence"
        return 1
    fi
    
    log "[$name] Persisting data to disk..."
    
    # Create persistent directory if needed
    mkdir -p "$persistent_path"
    
    if [[ -z "$(ls -A "$ram_path" 2>/dev/null)" ]]; then
        if [[ -z "$(ls -A "$persistent_path" 2>/dev/null)" ]]; then
            log "[$name] RAM and persistent directories are empty, nothing to persist"
            return 0
        fi
        log_error "[$name] RAM directory is empty; refusing to run rsync --delete to protect persistent data"
        return 1
    fi
    
    # Use rsync for efficient incremental sync
    local rsync_output
    if ! rsync_output=$(rsync -av --delete "$ram_path"/ "$persistent_path"/ 2>&1); then
        log_error "[$name] Failed to persist data"
        echo "$rsync_output" >> "$LOG_FILE"
        return 1
    fi
    echo "$rsync_output" >> "$LOG_FILE"
    
    # Sync only the relevant filesystem
    sync -f "$persistent_path"
    
    log "[$name] Data persisted successfully"
    return 0
}

persistence_loop() {
    local name=$1
    local ram_path=$2
    local persistent_path=$3
    local interval=$4
    log "[$name] Starting persistence loop (interval: ${interval}s)"
    
    while true; do
        if [[ $interval -gt 0 ]]; then
            sleep "$interval" &
            local sleep_pid=$!
            PERSIST_PIDS["$name"]=$sleep_pid
            wait $sleep_pid 2>/dev/null
            
            if [[ "$SHUTTING_DOWN" == true ]]; then
                break
            fi
            
            if ! persist_data "$name" "$ram_path" "$persistent_path"; then
                log_error "[$name] Persistence loop encountered an error"
            fi
        else
            sleep 3600 &
            local sleep_pid=$!
            PERSIST_PIDS["$name"]=$sleep_pid
            wait $sleep_pid 2>/dev/null
        fi
    done
    
    unset PERSIST_PIDS["$name"]
    unset PERSIST_LOOP_PIDS["$name"]
}

###################################################################################################################
# MAIN FUNCTIONS
###################################################################################################################

start_service() {
    # Acquire lock to prevent multiple instances
    acquire_lock
    
    log "=========================================="
    log "Starting PVE RAMFS Manager"
    log "=========================================="
    
    local all_ok=true
    
    # Setup PVE Cluster
    if [[ "$PVE_CLUSTER_ENABLED" == true ]]; then
        if ! setup_mount "PVE-Cluster" "$PVE_CLUSTER_DATA_PATH" "$PVE_CLUSTER_RAM_PATH" \
                         "$PVE_CLUSTER_PERSISTENT_PATH" "$PVE_CLUSTER_SERVICE"; then
            all_ok=false
        else
            # Start persistence loop in background
            persistence_loop "PVE-Cluster" "$PVE_CLUSTER_RAM_PATH" "$PVE_CLUSTER_PERSISTENT_PATH" \
                           "$PVE_CLUSTER_PERSIST_INTERVAL" &
            PERSIST_LOOP_PIDS["PVE-Cluster"]=$!
        fi
    fi
    
    # Setup RRDCached
    if [[ "$RRDCACHED_ENABLED" == true ]]; then
        if ! setup_mount "RRDCached" "$RRDCACHED_DATA_PATH" "$RRDCACHED_RAM_PATH" \
                         "$RRDCACHED_PERSISTENT_PATH" "$RRDCACHED_SERVICE"; then
            all_ok=false
        else
            # Start persistence loop in background
            persistence_loop "RRDCached" "$RRDCACHED_RAM_PATH" "$RRDCACHED_PERSISTENT_PATH" \
                           "$RRDCACHED_PERSIST_INTERVAL" &
            PERSIST_LOOP_PIDS["RRDCached"]=$!
        fi
    fi
    
    if [[ "$all_ok" == false ]]; then
        log_error "Some mounts failed to setup"
        stop_service
        exit 1
    fi
    
    # Notify systemd that mounts and persistence loops are up
    systemd-notify --ready --status="Mounts ready; starting managed services"
    
    if ! start_deferred_services; then
        log_error "Failed to start managed services"
        stop_service
        exit 1
    fi
    
    systemd-notify --status="PVE RAMFS Manager is running"
    log "PVE RAMFS Manager started successfully"
    
    # Wait for persistence loops
    wait
}

stop_service() {
    log "=========================================="
    log "Stopping PVE RAMFS Manager"
    log "=========================================="
    
    SHUTTING_DOWN=true
    local shutdown_errors=false
    
    # Kill persistence loops
    for name in "${!PERSIST_PIDS[@]}"; do
        local pid=${PERSIST_PIDS[$name]}
        if kill -0 "$pid" 2>/dev/null; then
            log "[$name] Stopping persistence loop (PID: $pid)"
            kill "$pid" 2>/dev/null
        fi
    done
    
    # Ensure persistence loop processes themselves are stopped
    for name in "${!PERSIST_LOOP_PIDS[@]}"; do
        local loop_pid=${PERSIST_LOOP_PIDS[$name]}
        if kill -0 "$loop_pid" 2>/dev/null; then
            log "[$name] Waiting for persistence worker (PID: $loop_pid) to exit"
            kill "$loop_pid" 2>/dev/null
            wait "$loop_pid" 2>/dev/null
        fi
    done
    
    # Final persistence for PVE Cluster (force=true to bypass SHUTTING_DOWN check)
    if [[ "$PVE_CLUSTER_ENABLED" == true ]]; then
        if ! ensure_service_stopped "PVE-Cluster" "$PVE_CLUSTER_SERVICE"; then
            shutdown_errors=true
        fi
        
        if [[ -d "$PVE_CLUSTER_RAM_PATH" ]]; then
            if ! persist_data "PVE-Cluster" "$PVE_CLUSTER_RAM_PATH" "$PVE_CLUSTER_PERSISTENT_PATH" true; then
                shutdown_errors=true
            fi
            if ! teardown_mount "PVE-Cluster" "$PVE_CLUSTER_DATA_PATH" "$PVE_CLUSTER_RAM_PATH"; then
                shutdown_errors=true
            fi
        fi
    fi
    
    # Final persistence for RRDCached (force=true to bypass SHUTTING_DOWN check)
    if [[ "$RRDCACHED_ENABLED" == true ]]; then
        if ! ensure_service_stopped "RRDCached" "$RRDCACHED_SERVICE"; then
            shutdown_errors=true
        fi
        
        if [[ -d "$RRDCACHED_RAM_PATH" ]]; then
            if ! persist_data "RRDCached" "$RRDCACHED_RAM_PATH" "$RRDCACHED_PERSISTENT_PATH" true; then
                shutdown_errors=true
            fi
            if ! teardown_mount "RRDCached" "$RRDCACHED_DATA_PATH" "$RRDCACHED_RAM_PATH"; then
                shutdown_errors=true
            fi
        fi
    fi
    
    # Release lock
    release_lock
    
    if [[ "$shutdown_errors" == true ]]; then
        log_error "Shutdown completed with errors; manual verification recommended"
        exit 1
    fi
    
    log "PVE RAMFS Manager stopped"
    exit 0
}

###################################################################################################################
# SIGNAL HANDLERS
###################################################################################################################

trap stop_service SIGTERM SIGINT

###################################################################################################################
# MAIN
###################################################################################################################

case "${1:-start}" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
