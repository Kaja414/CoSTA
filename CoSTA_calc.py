#!/usr/bin/env python3

"""
CoSTA_calc.py
Author: Kaja Reinhardt
Last Updated: 10/1/2026

Burst statistics, T in C and Practical Salinity for one CoSTA cycle
Called by CoSTA.sh:  python3 CoSTA_calc.py "<TS>"
Reads this cycle's rows from RAWFILE and appends the results to CALCFILE (header written by CoSTA.sh)
QC is done on the XIAO: T_run / EC_run = 1 or 2 passed, F failed (999999 = no data from the node)

Per burst, valid readings only (FAIL = invalid reading from the XIAO):
  N, mean, SD (N - 1), SEM = SD / sqrt(N)
  T: every voltage -> resistance -> C (Steinhart-Hart), then N, mean, SD, SEM in C
  EC: uncompensated, uS/cm
  SP = gsw.SP_from_C(EC_mean / 1000, T_mean, P_DBAR), only if T_run and EC_run are 1 or 2
       (uS/cm -> mS/cm for gsw, T = in-situ temperature of the same node)

Settings come from CoSTA.conf (path in COSTA_CONF, default /home/kaja/CoSTA/config/CoSTA.conf)
"""

import csv
import math
import os
import shlex
import statistics
import sys

import gsw

# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

CONF_PATH = os.environ.get("COSTA_CONF", "/home/kaja/CoSTA/config/CoSTA.conf")

conf = {}
for line in open(CONF_PATH):                     # NAME=value lines, quotes and comments removed
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        name, value = line.split("=", 1)
        conf[name.strip()] = " ".join(shlex.split(value, comments=True))

FAIL = float(conf["FAIL"])
N_T, N_EC = int(conf["T_SAMPLES"]), int(conf["EC_SAMPLES"])
VCC, R_BALANCE, R25 = (float(conf[k]) for k in ("VCC", "R_BALANCE", "R25"))
SH_A, SH_B, SH_C, SH_D = (float(conf[k]) for k in ("SH_A", "SH_B", "SH_C", "SH_D"))
P_DBAR = float(conf.get("P_DBAR", "0"))
TCAL = {k[5:]: [float(x) for x in v.split()] for k, v in conf.items() if k.startswith("TCAL_")}   # per-node T calibration from CoSTA.conf

RAWFILE = os.path.join(conf["DATA_DIR"], conf["RAWFILE"])
CALCFILE = os.path.join(conf["DATA_DIR"], conf["CALCFILE"])

# ------------------------------------------------------------
# Calculations
# ------------------------------------------------------------

def valid(fields):
    """Readings that are not the FAIL value."""
    return [float(x) for x in fields if float(x) != FAIL]

def volts_to_c(v, node):
    """Thermistor voltage -> T in C, with the node's TCAL_ values from CoSTA.conf if present, otherwise the defaults."""
    vcc, r_bal, a, b, c, d = TCAL.get(node, [VCC, R_BALANCE, SH_A, SH_B, SH_C, SH_D])
    r_ntc = r_bal * v / (vcc - v)                 # voltage divider -> thermistor resistance [Ohm]
    x = math.log(r_ntc / R25)
    return 1 / (a + b * x + c * x**2 + d * x**3) - 273.15   # K -> C

def stats(x):
    """N, mean, SD (N - 1), SEM. NaN if there are too few readings."""
    n = len(x)
    mean = statistics.mean(x) if n > 0 else math.nan
    sd = statistics.stdev(x) if n > 1 else math.nan
    return n, mean, sd, sd / math.sqrt(n) if n > 1 else math.nan


def fmt(x, decimals):
    return "NaN" if math.isnan(x) else f"{x:.{decimals}f}"

# ------------------------------------------------------------
# One cycle: raw rows of this TS -> calc rows
# ------------------------------------------------------------

ts = sys.argv[1]
with open(RAWFILE, newline="") as f:
    rows = [r for r in csv.reader(f) if r and r[0] == ts]
if not rows:
    print(f"No raw data for {ts}")
    sys.exit(1)

with open(CALCFILE, "a", newline="") as f:
    writer = csv.writer(f, lineterminator="\n")

    for r in rows:
        node, t_run, ec_run = r[1], r[2], r[3]
        t = stats([volts_to_c(v, node) for v in valid(r[4:4 + N_T]) if v < VCC])
        ec = stats(valid(r[4 + N_T:4 + N_T + N_EC]))

        sp = math.nan
        if t_run in ("1", "2") and ec_run in ("1", "2"):
            sp = float(gsw.SP_from_C(ec[1] / 1000, t[1], P_DBAR))

        writer.writerow([ts, node,
                         t_run, t[0], fmt(t[1], 4), fmt(t[2], 5), fmt(t[3], 5),
                         ec_run, ec[0], fmt(ec[1], 2), fmt(ec[2], 3), fmt(ec[3], 3),
                         fmt(sp, 4)])
        print(f"Node {node}: T run {t_run}, {fmt(t[1], 3)} C | "
              f"EC run {ec_run}, {fmt(ec[1], 1)} uS/cm | SP {fmt(sp, 4)}")
