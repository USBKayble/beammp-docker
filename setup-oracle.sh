#!/usr/bin/env bash
# setup-oracle.sh - guidance + safety guards for deploying the BeamMP bundle on
# an Oracle Cloud Infrastructure Always-Free VM. This script runs LOCALLY and
# creates/mutates NO cloud resources. It walks you through the deploy and flags
# the decisions that, if made wrong, lead to an unexpected bill.
#
#     curl -fsSL https://raw.githubusercontent.com/USBKayble/beammp-docker/main/setup-oracle.sh | bash
#
# Optional env overrides:
#   DASHBOARD=1   include the 8080/tcp dashboard ingress rule in the checklist
#   BRIDGE_IP     public IP/domain you'll put in the server command
#                 (default: 127.0.0.1 = both containers on one VM)
set -euo pipefail

GITHUB_REPO="USBKayble/beammp-docker"
BRIDGE_IP="${BRIDGE_IP:-127.0.0.1}"

print_sep() { printf '%s\n' '================================================================'; }

echo "=== Oracle Always-Free BeamMP deploy - pre-flight checklist ==="
echo "(run locally; nothing is created or billed. The 'ACTION' blocks are the"
echo "only things that need your decisions.)"
echo

print_sep
echo " 1. FREE-TIER SAFETY (do NOT get this wrong)"
echo "     Your OCI tenancy must be on the FREE billing model, NOT Pay-As-You-Go."
echo "     On Always-Free, exceeding the budget PAUSES instances - you are never"
echo "     billed. Upgrading to PAYG turns overage into an invoice. Verify by eye"
echo "     (Console -> Billing -> Overview -> 'How you pay'). It must read"
echo "     Always Free / Free. If it says Pay-As-You-Go / Universal Credits, STOP."
print_sep
echo

echo " 2. ARM (A1) SHAPE - keep the TOTAL under the monthly free ceiling"
echo "     Always-Free caps:  1500 OCPU-hours / 9000 GB-hours per month."
echo "     That equals a CONTINUOUS ceiling of 2 OCPU / 12 GB total across ALL"
echo "     instances. Two VMs count DOUBLE against this."
echo
echo "     RECOMMENDED (a single BeamMP bridge, leaves headroom):"
echo "        Shape:  VM.Standard.A1.Flex    OCPUs: 1    Memory: 8 GB"
echo "     The absolute max is 2 OCPU / 12 GB - but at 1/8 the twelve-month"
echo "     monthly budget never gets close to the wall. Image: Ubuntu 22.04 (aarch64)."
echo "     Boot volume ~47 GB (counts against the 200 GB free tier)."
echo
echo "     Public IP: keep the default EPHEMERAL. It survives reboots and stops;"
echo "     it is only released if you TERMINATE the instance. A reserved IP is a"
echo "     paid resource - avoid it here."
print_sep
echo

echo " 3. BUDGET TRIPWIRE (create BEFORE you create the VM)"
echo "     Console -> Billing -> Budgets -> Create budget."
echo "     Amount: \$1.00, scope = whole compartment, threshold 100%, email alert."
echo "     It should never fire; if it does, investigate before placing."
print_sep
echo

echo " 4. SECURITY LIST - add these INGRESS rules after the VM is running"
echo "     Console: Networking -> VCN -> your subnet -> Security List (or NSG)."
echo "     The default security list already allows ALL EGRESS - leave it."
echo "     Click 'Add Ingress Rule' once per line:"
echo
printf '  %-8s %-9s %-12s %s\n' "PORT" "PROTO" "SOURCE" "PURPOSE"
printf '  %-8s %-9s %-12s %s\n' "7000"  "TCP" "0.0.0.0/0" "frp control channel"
printf '  %-8s %-9s %-12s %s\n' "30814" "TCP" "0.0.0.0/0" "BeamMP game traffic"
printf '  %-8s %-9s %-12s %s\n' "30814" "UDP" "0.0.0.0/0" "BeamMP game traffic (required)"
if [ "${DASHBOARD:-0}" = "1" ]; then
  printf '  %-8s %-9s %-12s %s\n' "8080"  "TCP" "0.0.0.0/0" "control dashboard (set a password!)"
fi
echo
echo "     Leaving out 30814/UDP is the classic 'players connect then drop' miss."
echo "     7000 must be open on the VM because that is where frpc connects OUT"
echo "     to the bridge on the same host (BRIDGE_IP=${BRIDGE_IP})."
print_sep
echo

echo " 5. REGION / 'GLOBAL TRAFFIC'"
echo "     Oracle's DNS Traffic Steering (geolocation/failover policies) is NOT"
echo "     part of Always-Free. Enabling it requires a PAYG account and a"
echo "     per-policy monthly fee. With a single bridge it buys you nothing -"
echo "     do not turn it on. If you later add a second bridge region, do geo-"
echo "     lead via Cloudflare's free DNS instead of OCI."
print_sep
echo

echo " 6. DEPLOY (SSH into the running VM, then run two one-liners)"
echo "     First the bridge (prints a FRP_TOKEN):"
echo "       curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/setup-bridge.sh | bash"
echo "     Then the server (same VM, note bridge=127.0.0.1):"
echo "       curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/setup-server.sh \\"
echo "         | BEAMMP_AUTH_KEY='YOUR_KEY' \\"
echo "             BEAMMP_FRP_SERVER='${BRIDGE_IP}' \\"
echo "             BEAMMP_FRP_TOKEN='<from above>' bash"
echo "     Add 'BEAMMP_DASHBOARD=1  BEAMMP_DASHBOARD_PASSWORD=...' to enable the"
echo "     browser dashboard (plus the 8080 rule in step 4). Players join:"
echo "       ${BRIDGE_IP}:30814"
print_sep
echo
echo "=== done. The three real decisions are: (1) tenancy is Always-Free,"
echo "    (2) shape 1 OCPU / 8 GB, (3) skip Global Traffic."