#!/bin/bash
#  探测两把扇在 WMNB 100% 占空比下的真实最高转速，结束后还原出厂曲线
set -e
FR=/Users/anoxia-m/WorkBuddy/重写Ghelp/Build/fanread
RGBCTL=/usr/local/bin/rgbctl
WR=0x53564544
F0=0x00110024
F1=0x00110025
# 100% 占空比曲线：温度点 0/10/20/30/40/50/60/70℃ 全部 100% 占空比（0x64）
MAX_A1=0x1E140A00; MAX_A2=0x463C3228; MAX_A3=0x64646464; MAX_A4=0x64646464

echo "[base] 基线"
$FR F0Ac F0Mx F1Ac F1Mx

echo "[drive] fan0 → 100% 占空比 (WMNB)"
$RGBCTL wmnb $WR $F0 $MAX_A1 $MAX_A2 $MAX_A3 $MAX_A4
echo "  等待稳态 45s ..."
sleep 45
echo "[fan0] 实测"
$FR F0Ac F0Mx

echo "[drive] fan1 → 100% 占空比 (WMNB)"
$RGBCTL wmnb $WR $F1 $MAX_A1 $MAX_A2 $MAX_A3 $MAX_A4
sleep 45
echo "[fan1] 实测"
$FR F1Ac F1Mx

echo "[restore] fan0 出厂曲线"
$RGBCTL wmnb $WR $F0 0x4949463f 0x61534e4e 0x0f0a0601 0x5a1c1714
echo "[restore] fan1 出厂曲线"
$RGBCTL wmnb $WR $F1 0x4949463f 0x61534e4e 0x110e0b01 0x5b281f14
sleep 3
echo "[after] 还原后确认"
$FR F0Ac F0Mx F1Ac F1Mx
echo "[done]"
