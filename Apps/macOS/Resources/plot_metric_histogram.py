#!/usr/bin/env python3
"""Render a large Instagram-style histogram of one HandTrack minute-bucket metric."""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

import numpy as np
import pandas as pd


METRICS = {
    "keystrokes": {
        "table": "keystroke_minute_buckets",
        "column": "key_count",
        "title": "Keys per minute",
        "subtitle": "External keyboard · every active minute since day one",
        "xlabel": "Keys in that minute",
        "color": "#FF6B35",
        "discrete": True,
    },
    "mouse_clicks": {
        "table": "mouse_click_minute_buckets",
        "column": "click_count",
        "title": "Clicks per minute",
        "subtitle": "External mouse · every active minute since day one",
        "xlabel": "Clicks in that minute",
        "color": "#4ECDC4",
        "discrete": True,
    },
    "mouse_travel": {
        "table": "mouse_travel_minute_buckets",
        "column": "travel_pixels",
        "title": "Pointer travel per minute",
        "subtitle": "External pointer · pixels moved each active minute",
        "xlabel": "Pixels in that minute",
        "color": "#7B68EE",
        "scale": 1000.0,
        "xlabel_scaled": "Thousand pixels in that minute",
        "discrete": False,
    },
    "scroll_bumps": {
        "table": "scroll_bump_minute_buckets",
        "column": "bump_count",
        "title": "Scroll bumps per minute",
        "subtitle": "External scroll · every active minute since day one",
        "xlabel": "Scroll bumps in that minute",
        "color": "#45B7D1",
        "discrete": True,
    },
    "builtin_keys": {
        "table": "builtin_keyboard_minute_buckets",
        "column": "key_count",
        "title": "MacBook keys per minute",
        "subtitle": "Built-in keyboard · every active minute since day one",
        "xlabel": "Keys in that minute",
        "color": "#F7B267",
        "discrete": True,
    },
    "builtin_trackpad_clicks": {
        "table": "builtin_trackpad_click_minute_buckets",
        "column": "click_count",
        "title": "Trackpad clicks per minute",
        "subtitle": "Built-in trackpad · every active minute since day one",
        "xlabel": "Clicks in that minute",
        "color": "#E07A5F",
        "discrete": True,
    },
    "builtin_trackpad_travel": {
        "table": "builtin_trackpad_travel_minute_buckets",
        "column": "travel_pixels",
        "title": "Trackpad travel per minute",
        "subtitle": "Built-in trackpad · pixels moved each active minute",
        "xlabel": "Pixels in that minute",
        "color": "#81B29A",
        "scale": 1000.0,
        "xlabel_scaled": "Thousand pixels in that minute",
        "discrete": False,
    },
    "builtin_trackpad_scroll": {
        "table": "builtin_trackpad_scroll_minute_buckets",
        "column": "scroll_pixels",
        "title": "Trackpad scroll per minute",
        "subtitle": "Built-in trackpad · scroll pixels each active minute",
        "xlabel": "Scroll pixels in that minute",
        "color": "#3D405B",
        "scale": 1000.0,
        "xlabel_scaled": "Thousand scroll pixels in that minute",
        "discrete": False,
    },
}


def load_values(db_path: Path, metric_key: str) -> pd.Series:
    meta = METRICS[metric_key]
    table = meta["table"]
    column = meta["column"]
    with sqlite3.connect(db_path) as conn:
        # Only minutes that actually recorded something.
        df = pd.read_sql_query(
            f"SELECT {column} AS value FROM {table} WHERE {column} > 0 ORDER BY minute_start ASC",
            conn,
        )
    if df.empty:
        return pd.Series(dtype=float)
    values = df["value"].astype(float)
    scale = float(meta.get("scale", 1.0))
    if scale != 1.0:
        values = values / scale
    return values


def prepare_plot_data(values: pd.Series, meta: dict) -> dict:
    """Shared prep: p99 cutoff, discrete integer counts, stats on full series."""
    xlabel = meta.get("xlabel_scaled") if meta.get("scale") else meta["xlabel"]
    if values.empty:
        return {
            "empty": True,
            "plotted": values,
            "bin_edges": None,
            "tick_values": None,
            "bar_x": None,
            "bar_h": None,
            "xlim": (0.0, 1.0),
            "n": 0,
            "mean": 0.0,
            "median": 0.0,
            "p90": 0.0,
            "xlabel": xlabel or meta["xlabel"],
            "discrete": bool(meta.get("discrete", False)),
        }

    hi = float(np.nanpercentile(values, 99.0)) if len(values) >= 20 else float(values.max())
    hi = max(hi, 1.0)
    discrete = bool(meta.get("discrete", False))
    plotted = values[values <= hi]
    bar_x = None
    bar_h = None

    if discrete and not plotted.empty:
        # Explicit per-integer counts → equal-width flush bars.
        ints = plotted.round().astype(int)
        lo_int = int(max(1, ints.min()))
        hi_int = int(ints.max())
        counts = ints.value_counts().sort_index()
        bar_x = list(range(lo_int, hi_int + 1))
        bar_h = [int(counts.get(x, 0)) for x in bar_x]
        bin_edges = np.arange(lo_int - 0.5, hi_int + 1.5, 1.0)
        tick_values = bar_x
        xlim = (lo_int - 0.5, hi_int + 0.5)
    else:
        bins = min(56, max(16, int(np.sqrt(len(plotted)) * 1.8)))
        lo = float(plotted.min()) if not plotted.empty else 0.0
        bin_edges = np.linspace(lo, hi, bins + 1)
        centers = (bin_edges[:-1] + bin_edges[1:]) / 2.0
        if len(centers) <= 40:
            tick_values = [float(c) for c in centers]
        else:
            step = max(1, len(centers) // 20)
            tick_values = [float(c) for c in centers[::step]]
        xlim = (lo, hi)

    return {
        "empty": False,
        "plotted": plotted,
        "bin_edges": bin_edges,
        "tick_values": tick_values,
        "bar_x": bar_x,
        "bar_h": bar_h,
        "xlim": xlim,
        "n": int(len(values)),
        "mean": float(values.mean()),
        "median": float(values.median()),
        "p90": float(values.quantile(0.90)),
        "xlabel": xlabel or meta["xlabel"],
        "discrete": discrete,
    }


def render_seaborn(values: pd.Series, metric_key: str, out_path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import seaborn as sns
    from matplotlib.ticker import FixedLocator, FuncFormatter

    meta = METRICS[metric_key]
    prep = prepare_plot_data(values, meta)
    sns.set_theme(style="white", font="Avenir Next")

    # Wide poster that fills macOS window space.
    fig = plt.figure(figsize=(18.0, 11.0), dpi=160, facecolor="#0F1115")
    ax = fig.add_axes([0.055, 0.12, 0.915, 0.70])
    ax.set_facecolor("#161A22")

    if prep["empty"]:
        ax.text(
            0.5,
            0.5,
            "No data yet for this metric",
            ha="center",
            va="center",
            color="#9AA3B2",
            fontsize=22,
            transform=ax.transAxes,
        )
    elif prep["discrete"] and prep["bar_x"] is not None:
        ax.bar(
            prep["bar_x"],
            prep["bar_h"],
            width=1.0,
            align="center",
            color=meta["color"],
            edgecolor=meta["color"],
            linewidth=0.0,
            alpha=0.92,
        )
        ax.set_xlim(*prep["xlim"])
        ticks = prep["tick_values"] or []
        ax.xaxis.set_major_locator(FixedLocator(ticks))
        ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(round(v))}"))
        # Wide figure: keep every integer label readable without forced 90° spin.
        if len(ticks) > 45:
            ax.tick_params(axis="x", labelsize=8, rotation=90)
        elif len(ticks) > 32:
            ax.tick_params(axis="x", labelsize=9, rotation=45)
        else:
            ax.tick_params(axis="x", labelsize=11, rotation=0)
    else:
        sns.histplot(
            prep["plotted"],
            bins=prep["bin_edges"],
            ax=ax,
            color=meta["color"],
            edgecolor="#0F1115",
            linewidth=0.6,
            alpha=0.92,
        )
        ax.set_xlim(*prep["xlim"])
        ticks = prep["tick_values"] or []
        if ticks:
            ax.xaxis.set_major_locator(FixedLocator(ticks))
            ax.xaxis.set_major_formatter(
                FuncFormatter(lambda v, _: f"{v:.1f}".rstrip("0").rstrip("."))
            )
            ax.tick_params(axis="x", labelsize=11)

    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(colors="#C5CCD8", labelsize=12)
    ax.yaxis.label.set_color("#C5CCD8")
    ax.xaxis.label.set_color("#C5CCD8")
    ax.set_ylabel("Number of minutes", fontsize=14, labelpad=10)
    ax.set_xlabel(prep["xlabel"], fontsize=14, labelpad=12)
    ax.grid(axis="y", color="#2A3140", linewidth=0.8)

    fig.text(
        0.055,
        0.935,
        meta["title"],
        color="white",
        fontsize=32,
        fontweight="700",
        fontname="Avenir Next",
    )
    fig.text(
        0.055,
        0.895,
        meta["subtitle"],
        color="#9AA3B2",
        fontsize=14,
        fontname="Avenir Next",
    )

    stats = (
        f"{prep['n']:,} minutes   ·   mean {prep['mean']:,.1f}   ·   "
        f"median {prep['median']:,.1f}   ·   p90 {prep['p90']:,.1f}"
    )
    fig.text(0.055, 0.045, stats, color="#9AA3B2", fontsize=13, fontname="Avenir Next")
    fig.text(
        0.055,
        0.018,
        "HandTrack · all-time minute buckets · through p99",
        color="#667084",
        fontsize=11,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.22)
    plt.close(fig)


def render_plotly(values: pd.Series, metric_key: str, out_path: Path) -> None:
    import plotly.graph_objects as go

    meta = METRICS[metric_key]
    prep = prepare_plot_data(values, meta)

    if prep["empty"]:
        fig = go.Figure()
        fig.add_annotation(
            text="No data yet for this metric",
            xref="paper",
            yref="paper",
            x=0.5,
            y=0.5,
            showarrow=False,
            font=dict(size=22, color="#9AA3B2"),
        )
    elif prep["discrete"] and prep["bar_x"] is not None:
        fig = go.Figure(
            data=[
                go.Bar(
                    x=prep["bar_x"],
                    y=prep["bar_h"],
                    marker=dict(color=meta["color"], line=dict(width=0)),
                    opacity=0.92,
                    name="Minutes",
                    hovertemplate="%{x}<br>%{y} minutes<extra></extra>",
                )
            ]
        )
        fig.update_xaxes(
            range=list(prep["xlim"]),
            tickmode="array",
            tickvals=prep["tick_values"],
            ticktext=[str(t) for t in (prep["tick_values"] or [])],
        )
        fig.update_layout(bargap=0.0, bargroupgap=0.0)
    else:
        hist_kwargs = dict(
            x=prep["plotted"],
            marker=dict(color=meta["color"], line=dict(color="#0F1115", width=0.5)),
            opacity=0.92,
            name="Minutes",
            hovertemplate="%{x}<br>%{y} minutes<extra></extra>",
            nbinsx=max(16, len(prep["bin_edges"]) - 1) if prep["bin_edges"] is not None else 40,
        )
        fig = go.Figure(data=[go.Histogram(**hist_kwargs)])
        fig.update_xaxes(range=list(prep["xlim"]))
        if prep["tick_values"]:
            fig.update_xaxes(
                tickmode="array",
                tickvals=prep["tick_values"],
                ticktext=[
                    f"{t:.1f}".rstrip("0").rstrip(".") for t in prep["tick_values"]
                ],
            )

    stats = (
        f"{prep['n']:,} minutes   ·   mean {prep['mean']:,.1f}   ·   "
        f"median {prep['median']:,.1f}   ·   p90 {prep['p90']:,.1f}"
    )
    fig.update_layout(
        title=dict(
            text=f"<b>{meta['title']}</b><br><span style='font-size:14px;color:#9AA3B2'>"
            f"{meta['subtitle']}</span>",
            x=0.02,
            xanchor="left",
            font=dict(size=28, color="white", family="Avenir Next, Helvetica, sans-serif"),
        ),
        paper_bgcolor="#0F1115",
        plot_bgcolor="#161A22",
        font=dict(color="#C5CCD8", family="Avenir Next, Helvetica, sans-serif"),
        margin=dict(l=64, r=28, t=90, b=90),
        bargap=0.0 if prep.get("discrete") else 0.05,
        xaxis=dict(
            title=prep["xlabel"],
            gridcolor="#2A3140",
            zeroline=False,
            tickfont=dict(size=11),
        ),
        yaxis=dict(
            title="Number of minutes",
            gridcolor="#2A3140",
            zeroline=False,
        ),
        annotations=[
            dict(
                text=f"{stats}<br><span style='color:#667084'>HandTrack · all-time · through p99 · Plotly</span>",
                xref="paper",
                yref="paper",
                x=0.0,
                y=-0.16,
                showarrow=False,
                align="left",
                font=dict(size=13, color="#9AA3B2"),
            )
        ],
        height=820,
        width=1400,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Inline plotly.js so WKWebView works offline.
    fig.write_html(
        str(out_path),
        include_plotlyjs=True,
        full_html=True,
        config={"displayModeBar": True, "responsive": True},
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--metric", required=True, choices=sorted(METRICS.keys()))
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument(
        "--engine",
        choices=("seaborn", "plotly"),
        default="seaborn",
        help="seaborn → PNG poster; plotly → interactive HTML",
    )
    args = parser.parse_args()

    if not args.db.is_file():
        print(f"Database not found: {args.db}", file=sys.stderr)
        return 2

    values = load_values(args.db, args.metric)
    if args.engine == "plotly":
        try:
            render_plotly(values, args.metric, args.out)
        except ImportError as exc:
            print(
                "Plotly is not installed. Run: python3 -m pip install plotly",
                file=sys.stderr,
            )
            print(str(exc), file=sys.stderr)
            return 3
    else:
        render_seaborn(values, args.metric, args.out)
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
