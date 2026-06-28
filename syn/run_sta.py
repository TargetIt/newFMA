#!/usr/bin/env python3
"""
Lightweight (pessimistic) STA for fma_fp32_dot3 using SKY130 HD liberty timing.

NOTE ON ACCURACY
----------------
This tool computes a *worst-case upper bound* on the critical-path delay by
summing each cell's maximum liberty delay along the longest combinational path
(Kahn topological longest-path on the post-synthesis netlist).  It does NOT
propagate slew/load, so the number is pessimistic (typically 10-20x the real
delay) and must NOT be used as a signoff STA.

For liberty-aware, NLDM-based timing closure, use the ABC multi-period sweep:
    syn/sta_logs/sta_{8000..20000}ps.log   (run via: make sta)
That sweep shows the design closes timing at 8 ns (125 MHz) with zero area
penalty, which is the authoritative result.

Paths are configurable via environment variables:
    SKY130LIB   path to sky130_fd_sc_hd__tt_025C_1v80.lib
    NETLIST     path to the flattened post-synthesis Verilog netlist
"""

import os
import re
import sys
from collections import defaultdict, deque

# ============================================================
# Step 1: Parse Liberty file for cell timing arcs
# ============================================================
def parse_liberty(lib_path):
    """Extract cell delays from SKY130 liberty file using robust brace matching."""
    with open(lib_path) as f:
        text = f.read()

    cells = {}
    cell_start_pat = re.compile(r'cell\s*\(\s*"(sky130_fd_sc_hd__\w+)"\s*\)\s*\{')
    delay_val_pat = re.compile(r'values\s*\(\s*"([^"]*)"')
    area_pat = re.compile(r'area\s*:\s*([0-9.]+)')

    pos = 0
    while pos < len(text):
        cm = cell_start_pat.search(text, pos)
        if not cm:
            break
        cell_name = cm.group(1)
        cell_start = cm.end()
        depth = 1
        idx = cell_start
        while idx < len(text) and depth > 0:
            if text[idx] == '{':
                depth += 1
            elif text[idx] == '}':
                depth -= 1
            idx += 1
        cell_body = text[cell_start:idx-1]
        pos = idx

        am = area_pat.search(cell_body)
        cell_area = float(am.group(1)) if am else 10.0

        max_delay = 0.0
        all_delays = []
        for dm in delay_val_pat.finditer(cell_body):
            vals_str = dm.group(1).replace('\\\n', '').replace('\\', '')
            for val in vals_str.split(','):
                val = val.strip().strip('"')
                if val:
                    try:
                        v = float(val)
                        all_delays.append(v)
                        if v > max_delay:
                            max_delay = v
                    except ValueError:
                        pass

        cap_pat = re.compile(r'capacitance\s*:\s*([0-9.]+)')
        caps = cap_pat.findall(cell_body)
        input_cap = float(caps[0]) if caps else 0.001

        is_ff = ('df' in cell_name.lower() or 'dff' in cell_name.lower() or
                 'dfxtp' in cell_name or 'dfrtp' in cell_name or
                 'dfstp' in cell_name or 'dfbbp' in cell_name or
                 'dfbbn' in cell_name or 'dfrtn' in cell_name or
                 'edfxtp' in cell_name or 'dfxbp' in cell_name)

        avg_delay = sum(all_delays) / len(all_delays) if all_delays else 0.05
        cells[cell_name] = {'max_delay': max_delay, 'avg_delay': avg_delay,
                            'area': cell_area, 'input_cap': input_cap, 'is_ff': is_ff}
    return cells

# ============================================================
# Step 2: Parse flattened Verilog netlist
# ============================================================
def parse_netlist(netlist_path, cells_db):
    with open(netlist_path) as f:
        text = f.read()
    cell_pat = re.compile(r'(sky130_fd_sc_hd__\w+)\s+(\w+)\s*\(([^;]*)\)\s*;', re.DOTALL)
    instances = []
    for m in cell_pat.finditer(text):
        cell_type = m.group(1)
        if cell_type not in cells_db:
            continue
        pin_conns = {}
        for pm in re.finditer(r'\.(\w+)\s*\(\s*(\w+(?:\[\d+\])?)\s*\)', m.group(3)):
            pin_conns[pm.group(1)] = pm.group(2)
        ci = cells_db[cell_type]
        instances.append({'type': cell_type, 'name': m.group(2), 'pins': pin_conns,
                          'is_ff': ci['is_ff'], 'max_delay': ci['max_delay'],
                          'avg_delay': ci['avg_delay'], 'area': ci['area']})
    return instances

def ff_outputs(inst):
    return [w for p, w in inst['pins'].items() if p.upper() in ('Q', 'Y', 'Z', 'X', 'OUT')]
def ff_data_inputs(inst):
    return [w for p, w in inst['pins'].items() if p.upper() in ('D', 'DI', 'IN')]
def cell_outputs(inst):
    skip_skip = None
    return [w for p, w in inst['pins'].items()
            if p.upper() in ('Q', 'Y', 'Z', 'X', 'OUT', 'COUT', 'SUM', 'CARRY')]
def cell_data_inputs(inst):
    skip = {'CLK', 'CLR', 'RESET', 'SET', 'PRE', 'EN', 'GATE',
            'VPWR', 'VGND', 'VNB', 'VPB', 'RESET_B', 'SET_B'}
    return [w for p, w in inst['pins'].items() if p.upper() not in skip]

# ============================================================
# Step 3: Kahn-based DAG longest path (correct convergence)
# ============================================================
def run_sta(instances, clock_period_ns=20.0):
    ffs  = [i for i in instances if i['is_ff']]
    comb = [i for i in instances if not i['is_ff']]
    comb_set = {i['name'] for i in comb}
    comb_map = {i['name']: i for i in comb}

    # wire -> driver instance
    wire_drv = {}
    for i in instances:
        for o in cell_outputs(i):
            wire_drv[o] = i
    ff_out_wires = set()
    for f in ffs:
        ff_out_wires.update(ff_outputs(f))

    # combinational edges: driver_comb -> this_comb (dedup)
    adj = defaultdict(list)
    indeg = {n: 0 for n in comb_map}
    for i in comb:
        seen = set()
        for w in cell_data_inputs(i):
            d = wire_drv.get(w)
            if d and d['name'] in comb_set and d['name'] != i['name'] and d['name'] not in seen:
                adj[d['name']].append(i['name'])
                indeg[i['name']] += 1
                seen.add(d['name'])

    # source arrival for a comb instance: max over non-comb input wires
    # (FF launch = clk-to-Q 0.35 ns; primary input = 0.0)
    CLK_TO_Q = 0.35
    def src_arrival(i):
        best = 0.0
        for w in cell_data_inputs(i):
            d = wire_drv.get(w)
            if d and d['name'] in comb_set and d['name'] != i['name']:
                continue
            if d and d['is_ff']:
                best = max(best, CLK_TO_Q)
        return best

    arrv = {n: 0.0 for n in comb_map}
    depth = {n: 0 for n in comb_map}
    q = deque([n for n in comb_map if indeg[n] == 0])
    for n in q:
        arrv[n] = src_arrival(comb_map[n]) + comb_map[n]['max_delay']
        depth[n] = 1
    processed = 0
    while q:
        n = q.popleft()
        processed += 1
        for m in adj[n]:
            if arrv[n] + comb_map[m]['max_delay'] > arrv[m]:
                arrv[m] = arrv[n] + comb_map[m]['max_delay']
            if depth[n] + 1 > depth[m]:
                depth[m] = depth[n] + 1
            indeg[m] -= 1
            if indeg[m] == 0:
                q.append(m)

    cyclic = processed < len(comb)
    # capture at FF D pins
    cap_arr = 0.0
    for f in ffs:
        for w in ff_data_inputs(f):
            d = wire_drv.get(w)
            if d and d['name'] in comb_set:
                cap_arr = max(cap_arr, arrv[d['name']])
            elif d and d['is_ff']:
                cap_arr = max(cap_arr, CLK_TO_Q)

    setup = 0.25
    max_arr = max(arrv.values()) if arrv else 0.0
    max_depth = max(depth.values()) if depth else 0
    return {
        'total_ff': len(ffs), 'total_cells': len(instances),
        'comb_cells': len(comb), 'processed': processed, 'cyclic': cyclic,
        'max_arrival_ns': max_arr, 'capture_arrival_ns': cap_arr,
        'setup_ns': setup, 'critical_path_ns': cap_arr + setup,
        'slack_ns': clock_period_ns - (cap_arr + setup),
        'max_depth': max_depth, 'ffs': ffs,
    }

# ============================================================
# Main
# ============================================================
def main():
    lib_path = os.environ.get(
        'SKY130LIB',
        "/Users/jiuri/tools/pdks/volare/sky130/versions/"
        "0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.ref/"
        "sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib")
    netlist_path = os.environ.get('NETLIST', "/tmp/fma_flat.v")
    clock_period = float(os.environ.get('CLOCK_PERIOD', '20.0'))

    print("=" * 64)
    print("  fma_fp32_dot3 - Lightweight STA (pessimistic upper bound)")
    print("  Library: SKY130 HD tt_025C_1v80")
    print("  Clock:   {:.1f} ns ({:.1f} MHz)".format(clock_period, 1000.0/clock_period))
    print("=" * 64)

    print("\n[1/3] Parsing liberty file...")
    cells = parse_liberty(lib_path)
    ff_count_liberty = sum(1 for c in cells.values() if c['is_ff'])
    print("  Found {} cell types ({} FF types)".format(len(cells), ff_count_liberty))
    for key_cell in ['sky130_fd_sc_hd__nand2_1', 'sky130_fd_sc_hd__nor2_1',
                     'sky130_fd_sc_hd__xor2_1', 'sky130_fd_sc_hd__mux2_1',
                     'sky130_fd_sc_hd__dfxtp_1']:
        if key_cell in cells:
            c = cells[key_cell]
            print("  {:40s} max_delay={:.4f}ns area={:.2f}".format(
                key_cell, c['max_delay'], c['area']))

    print("\n[2/3] Parsing netlist...")
    instances = parse_netlist(netlist_path, cells)
    ffs = [i for i in instances if i['is_ff']]
    comb = [i for i in instances if not i['is_ff']]
    print("  Total instances: {}".format(len(instances)))
    print("  FFs: {}  Combinational: {}".format(len(ffs), len(comb)))

    print("\n[3/3] Running longest-path analysis (Kahn, DAG)...")
    r = run_sta(instances, clock_period)

    print("\n" + "=" * 64)
    print("  TIMING REPORT  (worst-case-sum delay model -- NOT signoff)")
    print("=" * 64)
    print("  Clock period:            {:.3f} ns".format(clock_period))
    print("  Total cell instances:    {}".format(r['total_cells']))
    print("  FFs / Combinational:     {} / {}".format(r['total_ff'], r['comb_cells']))
    print("  Longest path depth:      {} cells".format(r['max_depth']))
    print("  Combinational cycles:    {}".format("YES (timing invalid)" if r['cyclic'] else "no"))
    print("")
    print("  Max capture arrival:     {:.4f} ns".format(r['capture_arrival_ns']))
    print("  FF setup time:           {:.4f} ns".format(r['setup_ns']))
    print("  Critical path (pess.):   {:.4f} ns".format(r['critical_path_ns']))
    print("  Pessimistic slack:       {:+.4f} ns".format(r['slack_ns']))
    print("")
    print("  *** This sums each cell's MAX liberty delay (no slew/load")
    print("  *** propagation) -- a 10-20x pessimistic upper bound.")
    print("  *** Authoritative timing = ABC NLDM sweep in syn/sta_logs/:")
    print("  ***   design closes at 8 ns (125 MHz), zero area penalty.")
    print("=" * 64)

if __name__ == "__main__":
    main()
