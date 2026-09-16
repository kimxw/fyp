#!/bin/bash
# Pre-flight setup for energy measurement sweeps
# Run this once before each sweep session (sudo required for some steps)

set -e

echo "=== fernandez-cpu-followup: Pre-flight ==="

if ! command -v cpupower &> /dev/null; then
  echo "[1/5] Installing cpupower..."
  sudo apt install -y linux-tools-common "linux-tools-$(uname -r)"
else
  echo "[1/5] cpupower already installed."
fi

echo "[1/5] Setting CPU governor to 'performance'..."
sudo cpupower frequency-set -g performance > /dev/null

CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
if [ "$CURRENT_GOV" = "performance" ]; then
  echo "      Confirmed: governor is 'performance'."
else
  echo "      WARNING: governor reads '$CURRENT_GOV', not 'performance'. Check manually."
fi

echo "[2/5] Stopping/disabling unattended-upgrades..."
sudo systemctl stop unattended-upgrades 2>/dev/null || true
sudo systemctl disable unattended-upgrades 2>/dev/null || true

echo "[3/5] Turning off Wi-Fi..."
nmcli radio wifi off 2>/dev/null || echo "      (nmcli not available or already off — check manually)"

echo "[4/5] Turning off display (screen will go blank — this is expected)..."
xset dpms force off 2>/dev/null || echo "      (xset not available — skipping, not critical)"

echo "[5/5] Checking RAPL is readable..."
if [ -r /sys/class/powercap/intel-rapl:0/energy_uj ]; then
  echo "      OK — package-0 energy_uj is readable."
else
  echo "      ERROR — cannot read package-0 energy_uj. Sweep will fail. Check permissions/sudo."
fi

echo ""
echo "=== Pre-flight complete. Ready to run a sweep ==="
echo "(Remember: nmcli radio wifi on   -- to re-enable Wi-Fi afterward if needed)"
