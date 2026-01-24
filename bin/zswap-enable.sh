#!/usr/bin/env bash

# 1. Source the .env file from the current working directory
if [ -f .env ]; then
    source .env
else
    echo -e "\033[31m[ERROR]\033[0m .env file not found. Please run this from the project root (ols-docker-env/)."
    exit 1
fi

# Formatting function
echow(){
    echo -e "\033[1m[HOST-OPT]\033[0m ${1}"
}

apply_zswap() {
    # Check if Zswap variables exist in your .env
    if [ -n "${ZSWAP_MAX_PERCENT}" ]; then
        echow "Configuring Zswap with Ryzen 7900X compression..."
        
        # Set the max pool size (percentage of your 4GB RAM)
        echo "${ZSWAP_MAX_PERCENT}" > /sys/module/zswap/parameters/max_pool_percent
        
        # Ensure the Zswap module is enabled
        echo 1 > /sys/module/zswap/parameters/enabled
        
        # Use z3fold for better compression ratio if available (standard in modern kernels)
        if [ -d "/sys/module/z3fold" ]; then
            echo z3fold > /sys/module/zswap/parameters/zpool 2>/dev/null
        fi
        
        echow "Zswap pool set to ${ZSWAP_MAX_PERCENT}%."
    else
        echow "ZSWAP_MAX_PERCENT not found in .env. Skipping Zswap config."
    fi
}

apply_swapfile() {
    if [ -n "${HOST_SWAP_SIZE}" ]; then
        if [ ! -f /swapfile ]; then
            echow "Creating ${HOST_SWAP_SIZE} swapfile on NVMe..."
            
            # Using fallocate for instant allocation on NVMe
            fallocate -l "${HOST_SWAP_SIZE}" /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            
            # Ensure it persists after a reboot
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
                echow "Swapfile added to /etc/fstab for persistence."
            fi
        else
            echow "Swapfile check: Already active."
            # Ensure it is actually on (in case it was turned off manually)
            swapon /swapfile 2>/dev/null
        fi
    else
        echow "HOST_SWAP_SIZE not found in .env. Skipping swapfile creation."
    fi
}

main() {
    # Ensure script is run as root (required to touch /sys/ and /etc/fstab)
    if [[ $EUID -ne 0 ]]; then
       echo -e "\033[31m[ERROR]\033[0m This script must be run as root. Use: sudo ./bin/zswap-enable"
       exit 1
    fi

    echow "Starting Host Optimization..."
    apply_zswap
    apply_swapfile
    echow "SUCCESS: Your Ryzen host is now optimized for the LiteSpeed stack."
}

main