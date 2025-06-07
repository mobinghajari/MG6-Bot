# MG6-Bot

This repository contains a MetaTrader 5 Expert Advisor tailored for **XAUUSD** on the one‑minute timeframe. The source code resides in `MQL5/Experts/SpikeChannelPB_EA_V4_M1_Gold/`.

## Features

- Spike → Channel → Pullback logic implemented as a simple state machine
- Risk management with daily and weekly profit/loss limits
- Automatic position closure when reward equals twice the initial risk
- Configurable EMA period, body strength filters, and SL buffer
- Optional debug output when `DEBUG_FULL` is defined

## Building

1. Open `SpikeChannelPB_EA_V4_M1_Gold.mq5` in MetaEditor.
2. Compile the file (`F7`).
3. Attach the compiled expert to an **XAUUSD,M1** chart in MetaTrader 5.

## Statistics

The EA writes a daily row to `stats.csv` (in the terminal's *Common* files directory) summarizing trade counts.
