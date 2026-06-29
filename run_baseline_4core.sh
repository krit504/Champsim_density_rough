#!/bin/bash

BIN=/home/kritin/Scratch/personal/CACHE/ChampSim_STTRAM_variant3/ChampSim_STTRAM_4mb/bin/champsim
AT=/home/kritin/Scratch/personal/CACHE/dpc3traces
BN=/home/kritin/Scratch/personal/CACHE/ChampSim/dpc3_traces/bc-12.trace.gz
OUTDIR=/home/kritin/Scratch/personal/CACHE/ChampSim_STTRAM_variant3/ChampSim_STTRAM_4mb

labels[1]="v2+v2+v2+v2 (all attack)"
traces[1]="$AT/v2.trace.xz $AT/v2.trace.xz $AT/v2.trace.xz $AT/v2.trace.xz"
labels[2]="v3+v3+v3+v3 (all attack)"
traces[2]="$AT/v3.trace.xz $AT/v3.trace.xz $AT/v3.trace.xz $AT/v3.trace.xz"
labels[3]="v4+v4+v4+v4 (all attack)"
traces[3]="$AT/v4.trace.xz $AT/v4.trace.xz $AT/v4.trace.xz $AT/v4.trace.xz"
labels[4]="v4+v4+v4+bc12 (3 attack + 1 benign)"
traces[4]="$AT/v4.trace.xz $AT/v4.trace.xz $AT/v4.trace.xz $BN"

outfiles[1]="$OUTDIR/results_baseline_4core_v2all.txt"
outfiles[2]="$OUTDIR/results_baseline_4core_v3all.txt"
outfiles[3]="$OUTDIR/results_baseline_4core_v4all.txt"
outfiles[4]="$OUTDIR/results_baseline_4core_v4bc12.txt"

for i in 1 2 3 4; do
    echo "========================================" > ${outfiles[$i]}
    echo "4-CORE BASELINE (no bypass) | ${labels[$i]} | warmup=10M sim=250M" >> ${outfiles[$i]}
    echo "========================================" >> ${outfiles[$i]}
    echo "Started: $(date)" >> ${outfiles[$i]}

    echo "[$(date)] Starting run $i/4: ${labels[$i]}"
    $BIN -warmup_instructions 10000000 -simulation_instructions 250000000 \
        -traces ${traces[$i]} >> ${outfiles[$i]} 2>&1

    echo "Finished: $(date)" >> ${outfiles[$i]}
    echo "[$(date)] Done run $i/4"
done

echo "[$(date)] All baseline runs complete."
