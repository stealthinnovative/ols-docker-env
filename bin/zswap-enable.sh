#!/usr/bin/env bash

# 1. Source the .env file
if [ -f .env ]; then
    source .env
else
    echo -e "\033[31m[ERROR]\033[0m .env file not found."
    exit 1
fi

echow(){
    echo -e "\033[1m[HOST-OPT]\033[0m ${1}"
}

# --- NEW: Sysctl Optimizations (Network & Redis) ---
apply_sysctl() {
    echow "Applying Kernel & Network optimizations (BBR, Redis backlog)..."
    
    cat <<EOF > /etc/sysctl.d/99-commerce-optimization.conf
# Allow Redis to handle massive commerce backlogs
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
vm.overcommit_memory = 1

# Performance & Latency
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF

    sysctl --system > /dev/null
    echow "Sysctl settings applied and persistent."
}

# --- NEW: Disable Transparent Huge Pages (Redis Speed) ---
apply_thp() {
    echow "Disabling Transparent Huge Pages for Redis stability..."
    # Disable immediately
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
    
    # Make persistent via a simple systemd service
    cat <<EOF > /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable disable-thp.service > /dev/null 2>&1
    echow "THP disabled and persistence service created."
}

apply_zswap() {
    if [ -n "${ZSWAP_MAX_PERCENT}" ]; then
        echow "Configuring Zswap..."
        echo "${ZSWAP_MAX_PERCENT}" > /sys/module/zswap/parameters/max_pool_percent
        echo 1 > /sys/module/zswap/parameters/enabled
        echow "Zswap pool set to ${ZSWAP_MAX_PERCENT}%."
    fi
}

apply_swapfile() {
    if [ -n "${HOST_SWAP_SIZE}" ]; then
        if [ ! -f /swapfile ]; then
            echow "Creating ${HOST_SWAP_SIZE} swapfile..."
            fallocate -l "${HOST_SWAP_SIZE}" /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    fi
}

main() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "\033[31m[ERROR]\033[0m Must be run as root."
       exit 1
    fi

    echow "Starting Host Optimization..."
    apply_sysctl
    apply_thp
    apply_zswap
    apply_swapfile
    echow "SUCCESS: Host is ready for OLS Docker or CyberPanel."
}

main