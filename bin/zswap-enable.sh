#!/usr/bin/env bash

# --- 1. Path Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="$(dirname "$SCRIPT_DIR")/.env"

# --- 2. Environment Loader ---
if [ -f "$ENV_PATH" ]; then
    set -a
    source "$ENV_PATH"
    set +a
else
    echo -e "\033[31m[ERROR]\033[0m .env file not found at: $ENV_PATH"
    exit 1
fi

# --- 3. Formatting Function ---
echow(){
    echo -e "\033[1m[HOST-OPT]\033[0m ${1}"
}

# --- 4. Kernel & Zswap Optimization ---
apply_kernel_optimizations() {
    echow "Configuring Kernel for Ryzen 7900X + Redis + Zswap..."
    
    # Enable Zswap & Compression
    echo 1 > /sys/module/zswap/parameters/enabled
    echo "${ZSWAP_MAX_PERCENT:-38}" > /sys/module/zswap/parameters/max_pool_percent
    echo zstd > /sys/module/zswap/parameters/compressor 2>/dev/null
    
    if [ -d "/sys/module/z3fold" ]; then
        echo z3fold > /sys/module/zswap/parameters/zpool 2>/dev/null
    fi

    # --- Redis & DB Specific Kernel Fixes ---
    # Fixes: "Memory overcommit must be enabled"
    sysctl -w vm.overcommit_memory=1
    
    # Fixes: "TCP backlog setting... cannot be enforced"
    sysctl -w net.core.somaxconn=1024
    
    # Optimization: High-performance memory mapping for MariaDB/Redis
    sysctl -w vm.max_map_count=262144

    # Performance: Low swappiness for Zswap + NVMe
    sysctl -w vm.swappiness=10

    echow "Kernel parameters applied successfully."
}

# --- 5. NVMe Swapfile Logic ---
apply_swapfile() {
    if [ -n "${HOST_SWAP_SIZE}" ]; then
        if [ ! -f /swapfile ]; then
            echow "Creating ${HOST_SWAP_SIZE} swapfile on NVMe..."
            fallocate -l "${HOST_SWAP_SIZE}" /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
        else
            echow "Swapfile active. Ensuring swapon."
            swapon /swapfile 2>/dev/null
        fi
    fi
}

# --- 6. Main Execution ---
main() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "\033[31m[ERROR]\033[0m Must be run with sudo."
       exit 1
    fi

    echow "--- Starting Host Optimization ---"
    apply_kernel_optimizations
    apply_swapfile
    
    echo "------------------------------------------------"
    echow "VERIFYING SETTINGS:"
    echo -n "Zswap Active:      " && cat /sys/module/zswap/parameters/enabled
    echo -n "Overcommit Mem:    " && sysctl -n vm.overcommit_memory
    echo -n "TCP Backlog (Max): " && sysctl -n net.core.somaxconn
    echo -n "Global Swappiness: " && sysctl -n vm.swappiness
    echo -n "Compressor:        " && cat /sys/module/zswap/parameters/compressor
    echo "------------------------------------------------"
    echow "SUCCESS: Ryzen 7900X is tuned. Now run 'docker compose up -d'"
}

main