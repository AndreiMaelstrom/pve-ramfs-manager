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

# Shutdown flag
SHUTTING_DOWN=false

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
    
    # Check if service is running
    if is_service_running "$service"; then
        log_error "[$name] $service is already running"
        return 1
    fi
    
    # Check if RAM path already exists
    if [[ -d "$ram_path" ]]; then
        log_error "[$name] RAM path $ram_path already exists"
        return 1
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
            cp -a "$data_path"/* "$persistent_path" || {
                log_error "[$name] Failed to copy existing data"
                return 1
            }
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
        cp -a "$persistent_path"/* "$ram_path" || {
            log_error "[$name] Failed to copy data to RAM"
            rm -rf "$ram_path"
            return 1
        }
    fi
    
    # Set proper permissions for RRDCached
    if [[ "$name" == "RRDCached" ]]; then
        chown -R rrdcached:rrdcached "$ram_path" 2>/dev/null || true
    fi
    
    # Mount RAM directory over data directory
    log "[$name] Mounting RAM directory to $data_path"
    mount --bind "$ram_path" "$data_path" || {
        log_error "[$name] Failed to mount RAM directory"
        rm -rf "$ram_path"
        return 1
    }
    
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
    local service=$4
    
    # Skip if shutting down (will be handled by shutdown routine)
    if [[ "$SHUTTING_DOWN" == true ]]; then
        return 0
    fi
    
    log "[$name] Persisting data to disk..."
    
    # Flush RRDCached cache if applicable
    if [[ "$name" == "RRDCached" ]] && is_service_running "$service"; then
        rrdcached-flush 2>/dev/null || true
    fi
    
    # Create persistent directory if needed
    mkdir -p "$persistent_path"
    
    # Clear old data
    rm -rf "${persistent_path:?}"/* 2>/dev/null
    
    # Copy data from RAM to disk
    if ! cp -a "$ram_path"/* "$persistent_path" 2>/dev/null; then
        log_error "[$name] Failed to persist data"
        return 1
    fi
    
    # Force sync to disk
    sync
    
    log "[$name] Data persisted successfully"
    return 0
}

persistence_loop() {
    local name=$1
    local ram_path=$2
    local persistent_path=$3
    local service=$4
    local interval=$5
    
    log "[$name] Starting persistence loop (interval: ${interval}s)"
    
    while true; do
        if [[ $interval -gt 0 ]]; then
            sleep "$interval" &
            local sleep_pid=$!
            PERSIST_PIDS["$name"]=$sleep_pid
            wait $sleep_pid 2>/dev/null
            
            # Check if we're shutting down
            if [[ "$SHUTTING_DOWN" == true ]]; then
                break
            fi
            
            persist_data "$name" "$ram_path" "$persistent_path" "$service"
        else
            # If interval is 0, just wait indefinitely
            sleep 3600 &
            local sleep_pid=$!
            PERSIST_PIDS["$name"]=$sleep_pid
            wait $sleep_pid 2>/dev/null
        fi
    done
}

###################################################################################################################
# MAIN FUNCTIONS
###################################################################################################################

start_service() {
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
                           "$PVE_CLUSTER_SERVICE" "$PVE_CLUSTER_PERSIST_INTERVAL" &
            PERSIST_PIDS["PVE-Cluster"]=$!
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
                           "$RRDCACHED_SERVICE" "$RRDCACHED_PERSIST_INTERVAL" &
            PERSIST_PIDS["RRDCached"]=$!
        fi
    fi
    
    if [[ "$all_ok" == false ]]; then
        log_error "Some mounts failed to setup"
        stop_service
        exit 1
    fi
    
    # Notify systemd that we're ready
    systemd-notify --ready --status="PVE RAMFS Manager is running"
    log "PVE RAMFS Manager started successfully"
    
    # Wait for persistence loops
    wait
}

stop_service() {
    log "=========================================="
    log "Stopping PVE RAMFS Manager"
    log "=========================================="
    
    SHUTTING_DOWN=true
    
    # Kill persistence loops
    for name in "${!PERSIST_PIDS[@]}"; do
        local pid=${PERSIST_PIDS[$name]}
        if kill -0 $pid 2>/dev/null; then
            log "[$name] Stopping persistence loop (PID: $pid)"
            kill $pid 2>/dev/null
            wait $pid 2>/dev/null
        fi
    done
    
    # Final persistence for PVE Cluster
    if [[ "$PVE_CLUSTER_ENABLED" == true ]] && [[ -d "$PVE_CLUSTER_RAM_PATH" ]]; then
        persist_data "PVE-Cluster" "$PVE_CLUSTER_RAM_PATH" "$PVE_CLUSTER_PERSISTENT_PATH" "$PVE_CLUSTER_SERVICE"
        teardown_mount "PVE-Cluster" "$PVE_CLUSTER_DATA_PATH" "$PVE_CLUSTER_RAM_PATH"
    fi
    
    # Final persistence for RRDCached
    if [[ "$RRDCACHED_ENABLED" == true ]] && [[ -d "$RRDCACHED_RAM_PATH" ]]; then
        persist_data "RRDCached" "$RRDCACHED_RAM_PATH" "$RRDCACHED_PERSISTENT_PATH" "$RRDCACHED_SERVICE"
        teardown_mount "RRDCached" "$RRDCACHED_DATA_PATH" "$RRDCACHED_RAM_PATH"
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
