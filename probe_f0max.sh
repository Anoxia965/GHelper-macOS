#!/bin/bash
set -e
FR=/Users/anoxia-m/WorkBuddy/重写Ghelp/Build/fanread
RGBCTL=/usr/local/bin/rgbctl
WR=0x53564544
F0=0x00110024
MAX_A1=0x1E140A00; MAX_A2=0x463C3228; MAX_A3=0x64646464; MAX_A4=0x64646464
echo "[base] 基线 fan0"
$FR F0Ac F0Mx
echo "[drive] fan0 → 100% 占空比 (WMNB)，等 75s 稳态"
$RGBCTL wmnb $WR $F0 $MAX_A1 $MAX_A2 $MAX_A3 $MAX_A4
sleep 75
echo "[fan0] 实测（应为满速稳态）"
$FR F0Ac F0Mx
echo "[restore] fan0 出厂曲线"
$RGBCTL wmnb $WR $F0 0x4949463f 0x61534e4e 0x0f0a0601 0x5a1c1714
sleep 5
echo "[after] 还原后"
$FR F0Ac F0Mx
echo "[done]"
