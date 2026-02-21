#!/bin/bash
# Sweep bypass rates across all traces
# Results stored in results_sweep/ directory

BASEDIR="/home/kritin/Scratch/personal/CACHE/Champsim_density_rough"
TRACEDIR="/home/kritin/Scratch/personal/CACHE/ChampSim/dpc3_traces"
RESULTSDIR="$BASEDIR/results_sweep"
HEADER="$BASEDIR/inc/champsim.h"

mkdir -p "$RESULTSDIR"

RATES=(5 10 20 30 40 50)
TRACES=("602.gcc-s0.trace.xz" "459.GemsFDTD-s0.trace.gz" "bc-12.trace.gz")
TRACE_NAMES=("gcc" "gems" "bc12")

for rate in "${RATES[@]}"; do
    echo "============================================"
    echo "Setting BYPASS_RATE_PERCENT to $rate%"
    echo "============================================"
    
    # Update the bypass rate in champsim.h
    sed -i "s/^#define BYPASS_RATE_PERCENT .*/#define BYPASS_RATE_PERCENT $rate/" "$HEADER"
    
    # Clean and rebuild
    cd "$BASEDIR"
    rm -rf obj
    make -j$(nproc) 2>&1 | tail -1
    
    if [ $? -ne 0 ]; then
        echo "BUILD FAILED for rate=$rate"
        exit 1
    fi
    
    for i in "${!TRACES[@]}"; do
        trace="${TRACES[$i]}"
        name="${TRACE_NAMES[$i]}"
        outfile="$RESULTSDIR/bypass_${rate}pct_${name}.txt"
        
        echo "  Running $name at ${rate}% bypass..."
        ./bin/champsim 1000000 10000000 -traces "$TRACEDIR/$trace" > "$outfile" 2>&1
        
        # Extract key metrics
        ipc=$(grep "cumulative IPC" "$outfile" | tail -1 | awk '{print $5}')
        bypassed=$(grep "Write fills bypassed" "$outfile" | awk '{print $NF}')
        allocated=$(grep "Write fills allocated" "$outfile" | awk '{print $NF}')
        total_wf=$(grep "^Write fills:" "$outfile" | awk '{print $NF}')
        bypass_rate_actual=$(grep "Bypass rate:" "$outfile" | awk '{print $NF}')
        llc_inval=$(grep "LLC blocks invalidated" "$outfile" | awk '{print $NF}')
        
        echo "    IPC=$ipc  Write fills=$total_wf  Bypassed=$bypassed  Allocated=$allocated  Actual_rate=$bypass_rate_actual"
    done
done

echo ""
echo "============================================"
echo "ALL RUNS COMPLETE. Results in $RESULTSDIR/"
echo "============================================"
