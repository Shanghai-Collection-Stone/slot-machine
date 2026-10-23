#!/usr/bin/env python3
"""合成拉霸机音效（纯程序生成，无外部素材）。

    python3 tools/gen_sfx.py

输出到 assets/sfx/*.wav（44.1kHz / 16bit / 单声道），背景音乐为 assets/sfx/bgm.ogg（需要 ffmpeg，没有则输出 .wav）。
想换成自己的音效：用同名 .wav 或 .ogg 覆盖即可（同名 .ogg 优先于 .wav）。
依赖：numpy。

打击感的关键在 stop.wav：起始 2~3ms 的高频瞬态（"咔"）+ 金属撞击的非谐波模态（"锵"）
+ 快速下滑的低频正弦（"咚"），最后经过软削波压在一起，听感上是一记"实"的重击。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import wave

import numpy as np

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "sfx")
rng = np.random.default_rng(7)

# 滚轮转动循环里"咔嗒"声的频率（次/秒）。游戏里按 转速/此值 调整音调，让声音和画面同步。
SPIN_TICK_RATE = 16


# ---------------------------------------------------------------- 基础工具

def ns(dur: float) -> int:
    return int(round(dur * SR))


def tline(dur: float) -> np.ndarray:
    return np.arange(ns(dur)) / SR


def place(buf: np.ndarray, x: np.ndarray, at: float, gain: float = 1.0) -> np.ndarray:
    i = ns(at)
    j = min(len(buf), i + len(x))
    if j > i:
        buf[i:j] += x[: j - i] * gain
    return buf


def _freq(freq, n):
    return np.full(n, float(freq)) if np.ndim(freq) == 0 else np.asarray(freq, float)[:n]


def _phase(freq, dur):
    n = ns(dur)
    return np.cumsum(_freq(freq, n)) / SR  # 以"周期"为单位


def sine(freq, dur, phase=0.0):
    return np.sin(2 * np.pi * _phase(freq, dur) + phase)


def _polyblep(t, dt):
    y = np.zeros_like(t)
    m = t < dt
    x = t[m] / dt[m]
    y[m] = x + x - x * x - 1
    m = t > 1 - dt
    x = (t[m] - 1) / dt[m]
    y[m] = x * x + x + x + 1
    return y


def saw(freq, dur):
    """带 polyBLEP 抗混叠的锯齿波。"""
    n = ns(dur)
    f = _freq(freq, n)
    t = np.cumsum(f) / SR % 1.0
    return 2 * t - 1 - _polyblep(t, f / SR)


def tri(freq, dur):
    t = _phase(freq, dur) % 1.0
    return 2 * np.abs(2 * t - 1) - 1


def noise(dur):
    return rng.uniform(-1, 1, ns(dur))


def env_exp(dur, tau, attack=0.002):
    t = tline(dur)
    e = np.exp(-t / tau)
    if attack > 0:
        e *= np.clip(t / attack, 0, 1)
    return e


def env_adsr(dur, a, d, s, r):
    t = tline(dur)
    e = np.where(t < a, t / max(a, 1e-6), 1.0)
    e = np.where((t >= a) & (t < a + d), 1 - (1 - s) * (t - a) / max(d, 1e-6), e)
    e = np.where(t >= a + d, s, e)
    rel_start = dur - r
    return np.where(t > rel_start, e * np.clip((dur - t) / max(r, 1e-6), 0, 1), e)


def _coeffs(kind, f0, q):
    f0 = min(max(f0, 10.0), SR * 0.45)
    w0 = 2 * np.pi * f0 / SR
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / (2 * q)
    if kind == "lp":
        b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
    elif kind == "hp":
        b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
    else:  # band-pass, 0 dB peak
        b = (alpha, 0.0, -alpha)
    a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
    return b[0] / a0, b[1] / a0, b[2] / a0, a1 / a0, a2 / a0


def biquad(x, kind, f0, q=0.707, block=32):
    """RBJ 双二阶滤波。f0 可以是数组（时变截止频率，每 block 个采样更新一次）。"""
    xs = x.tolist()
    y = [0.0] * len(xs)
    varying = np.ndim(f0) > 0
    x1 = x2 = y1 = y2 = 0.0
    b0, b1, b2, a1, a2 = _coeffs(kind, float(f0 if not varying else f0[0]), q)
    for start in range(0, len(xs), block):
        if varying:
            b0, b1, b2, a1, a2 = _coeffs(kind, float(f0[min(start, len(f0) - 1)]), q)
        for i in range(start, min(start + block, len(xs))):
            xi = xs[i]
            yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, xi, y1, yi
            y[i] = yi
    return np.asarray(y)


def fft_filter(x, lo=0.0, hi=None):
    """循环（周期）带通，用于可无缝循环的声音。"""
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    gain = np.ones_like(f)
    if lo > 0:
        gain *= 1 / (1 + (lo / np.maximum(f, 1e-3)) ** 4)
    if hi:
        gain *= 1 / (1 + (f / hi) ** 4)
    return np.fft.irfft(spec * gain, len(x))


def softclip(x, drive=2.0):
    return np.tanh(x * drive) / np.tanh(drive)


def echo(x, taps=((0.085, 0.32), (0.16, 0.2), (0.27, 0.11), (0.39, 0.06)), tail=0.45):
    out = np.concatenate([x, np.zeros(ns(tail))])
    for d, g in taps:
        place(out, x, d, g)
    return out


def write(name, x, peak_db, fade=True):
    x = np.asarray(x, float)
    x = x - np.mean(x) if not fade else x
    if fade:
        k = min(len(x), ns(0.01))
        x[-k:] *= np.linspace(1, 0, k)
    x = x / (np.max(np.abs(x)) + 1e-9) * 10 ** (peak_db / 20)
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    path = os.path.join(OUT_DIR, f"{name}.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{name:10s} {len(x) / SR:5.2f}s  peak {peak_db:+.1f} dB")


# ---------------------------------------------------------------- 乐器

def bell(freq, dur, decay, brightness=1.2):
    t = tline(dur)
    mod = np.sin(2 * np.pi * freq * 3.5 * t) * brightness * np.exp(-t / (decay * 0.5))
    return np.sin(2 * np.pi * freq * t + mod) * env_exp(dur, decay, 0.002)


def brass(freqs, dur, attack=0.02, release=0.07, bright=1.0):
    t = tline(dur)
    x = np.zeros(len(t))
    vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.clip(t / 0.25, 0, 1)
    for f in freqs:
        for det in (-0.006, 0.0, 0.007):
            x += saw(f * (1 + det) * vib, dur)
    fc = 600 + 4200 * bright * np.clip(t / attack, 0, 1) * (0.55 + 0.45 * np.exp(-t / 0.2))
    x = biquad(x, "lp", fc, 1.2)
    return x * env_adsr(dur, attack, 0.12, 0.75, release) / (3 * len(freqs))


def timpani(freq=88, dur=0.7):
    t = tline(dur)
    f = freq * (1 + 0.35 * np.exp(-t / 0.02))
    body = sine(f, dur) * env_exp(dur, 0.2, 0.001)
    hit = biquad(noise(dur), "lp", 1200) * env_exp(dur, 0.012, 0)
    return body + hit * 0.5


def crash(dur=1.6):
    n = noise(dur)
    return (biquad(n, "hp", 4500) * 0.8 + biquad(n, "bp", 7500, 0.8) * 0.6) * env_exp(dur, dur * 0.3, 0.001)


# ---------------------------------------------------------------- 音效

def snd_press():
    """停止按钮：塑料"咔"。按下瞬间立即响，让操作有即时反馈。"""
    d = 0.08
    click = biquad(noise(d), "hp", 2500) * env_exp(d, 0.003, 0)
    tick = sine(1900, d) * env_exp(d, 0.010, 0.0005) * 0.5
    low = sine(230, d) * env_exp(d, 0.018, 0.001) * 0.6
    return click + tick + low


def snd_stop():
    """停轮重击："咔"（瞬态）+"锵"（金属）+"咚"（低频）。"""
    d = 0.55
    t = tline(d)
    nz = noise(d)
    transient = biquad(nz, "hp", 1800) * env_exp(d, 0.0025, 0)
    clank = np.zeros(len(t))
    for f, tau, a in [(690, 0.07, 1.0), (1130, 0.05, 0.7), (1870, 0.035, 0.5), (2650, 0.022, 0.35), (3720, 0.014, 0.25)]:
        clank += a * sine(f * (1 + 0.004 * rng.standard_normal()), d, rng.uniform(0, 6.28)) * env_exp(d, tau, 0.0005)
    grit = biquad(nz, "bp", 2400, 0.9) * env_exp(d, 0.03, 0)
    thump = sine(55 + 150 * np.exp(-t / 0.025), d) * env_exp(d, 0.11, 0.001)
    sub = sine(42, d) * env_exp(d, 0.2, 0.004) * 0.45
    x = 0.9 * transient + 0.3 * clank + 0.3 * grit + 1.0 * thump + sub
    return softclip(x, 2.2)


def snd_boom():
    """低频轰击：最后一列停下、中奖时叠加，让画面"砸"下去。"""
    d = 1.4
    t = tline(d)
    body = sine(32 + 95 * np.exp(-t / 0.09), d) * env_exp(d, 0.42, 0.002)
    crunch = biquad(noise(d), "lp", 900) * env_exp(d, 0.12, 0.001) * 0.9
    mid = tri(85 + 60 * np.exp(-t / 0.05), d) * env_exp(d, 0.09, 0.001) * 0.5
    return softclip(body * 1.2 + crunch + mid, 1.8)


def snd_lever():
    """开始：拉杆"咔嚓"两声 + 弹簧余震 + 上扬的呼啸。"""
    d = 0.7
    t = tline(d)
    x = np.zeros(len(t))

    def clack(at, bright, gain):
        dd = 0.12
        tt = tline(dd)
        c = biquad(noise(dd), "bp", 3200 * bright, 1.2) * env_exp(dd, 0.006, 0)
        for f, tau, a in [(1250, 0.03, 0.6), (2120, 0.022, 0.4), (3380, 0.012, 0.3)]:
            c += a * sine(f * bright, dd) * env_exp(dd, tau, 0.0003)
        c += sine(140 + 80 * np.exp(-tt / 0.02), dd) * env_exp(dd, 0.04, 0.001) * 0.8
        place(x, c, at, gain)

    clack(0.0, 1.0, 1.0)
    clack(0.05, 0.8, 0.8)
    spring = sine(180 + 8 * np.sin(2 * np.pi * 35 * t), d) * env_exp(d, 0.09, 0.002) * 0.25
    place(x, spring, 0.05)
    fc = 350 * (2800 / 350) ** np.clip((t - 0.05) / 0.45, 0, 1)
    whoosh = biquad(noise(d), "bp", fc, 1.4)
    wenv = np.clip((t - 0.05) / 0.2, 0, 1) * np.exp(-np.clip(t - 0.25, 0, None) / 0.12)
    x += whoosh * wenv * 0.9
    return softclip(x, 1.5)


def snd_spin_loop():
    """滚轮转动循环（正好 1 秒，可无缝循环）：电机嗡鸣 + 低频隆隆 + 每格一下的咔嗒。"""
    n = SR
    t = np.arange(n) / SR
    hum = sum(a * np.sin(2 * np.pi * f * t) for f, a in [(55, 1), (110, 0.6), (165, 0.35), (220, 0.2), (330, 0.1)])
    hum *= (1 + 0.25 * np.sin(2 * np.pi * SPIN_TICK_RATE * t)) * 0.35
    rumble = fft_filter(rng.standard_normal(n), 30, 180)
    rumble *= 0.35 / np.max(np.abs(rumble))
    ticks = np.zeros(n)
    k = ns(0.03)
    tt = np.arange(k) / SR
    for i in range(SPIN_TICK_RATE):
        tick = rng.uniform(-1, 1, k) * np.exp(-tt / 0.0025) * 0.6
        tick += np.sin(2 * np.pi * (950 + 40 * rng.standard_normal()) * tt) * np.exp(-tt / 0.008) * 0.5
        idx = ((2 * i + 1) * n // (2 * SPIN_TICK_RATE) + np.arange(k)) % n  # 错开循环接缝
        ticks[idx] += tick
    ticks = fft_filter(ticks, 500, 6000)
    ticks *= 0.55 / np.max(np.abs(ticks))
    return hum + rumble + ticks


def snd_reach():
    """听牌：上扬的"啾——"，带颤音，最后"叮"一声。"""
    d = 1.3
    t = tline(d)
    g = np.clip(t / 0.85, 0, 1)
    f = 330 * 4.0 ** (g**1.3)
    f = f * (1 + 0.012 * np.sin(2 * np.pi * 7 * t) * g)
    lead = 0.5 * saw(f, d) + 0.5 * saw(f * 1.007, d) + 0.5 * sine(f * 2, d)
    lead = biquad(lead, "lp", 1800 + 3200 * g, 0.9)
    trem = 0.75 + 0.25 * np.sin(2 * np.pi * 14 * t)
    env = np.clip(t / 0.04, 0, 1) * np.where(t < 0.9, 1.0, np.exp(-(t - 0.9) / 0.06))
    x = lead * trem * env
    place(x, bell(2637, 0.45, 0.14, 0.8) + 0.5 * bell(3951, 0.45, 0.1, 0.6), 0.88, 0.7)
    return echo(x)


def snd_win():
    """小奖：明亮的琶音 + 和弦余音 + 闪烁。"""
    d = 1.5
    x = np.zeros(ns(d))
    notes = [1046.5, 1318.5, 1568.0, 2093.0]
    for i, f in enumerate(notes):
        place(x, bell(f, 0.9, 0.3), i * 0.07, 0.8)
    for f in notes:
        place(x, bell(f, 1.1, 0.55, 0.7), 0.3, 0.32)
    for _ in range(14):
        place(x, bell(rng.uniform(3000, 6000), 0.15, 0.04, 0.3), rng.uniform(0.25, 1.1), 0.12)
    return echo(x)


def snd_win_big():
    """大奖：铜管"哒哒哒——哒——"号角 + 定音鼓 + 镲。"""
    d = 2.5
    x = np.zeros(ns(d))
    C = [523.25, 659.25, 783.99]
    F = [698.46, 880.0, 1046.5]
    G = [783.99, 987.77, 1174.66]
    Chi = [523.25, 659.25, 783.99, 1046.5]
    for at, chord, dur in [(0.0, C, 0.11), (0.14, C, 0.11), (0.28, C, 0.11), (0.42, F, 0.28), (0.74, G, 0.17), (0.95, Chi, 1.25)]:
        place(x, brass(chord, dur + 0.07), at)
        place(x, timpani(88 if chord is not G else 98), at, 0.5)
    place(x, crash(1.5), 0.95, 0.35)
    for i, f in enumerate([1046.5, 1318.5, 1568.0, 2093.0, 2637.0]):
        place(x, bell(f, 0.8, 0.3, 0.8), 0.95 + i * 0.05, 0.25)
    return echo(softclip(x * 1.4, 1.3), taps=((0.09, 0.22), (0.18, 0.12)), tail=0.3)


def snd_jackpot():
    """大奖（777）：轰击 + 两个八度的上行琶音 + 号角 + 长和弦。"""
    d = 3.8
    x = np.zeros(ns(d))
    place(x, snd_boom(), 0.0, 0.8)
    place(x, crash(1.2), 0.0, 0.35)
    arp = [523.25, 659.25, 783.99, 1046.5, 1318.5, 1568.0, 2093.0, 2637.0]
    for i, f in enumerate(arp):
        place(x, bell(f, 0.7, 0.25, 1.0), 0.1 + i * 0.055, 0.55)
    G = [587.33, 783.99, 987.77]
    for i in range(6):  # 定音鼓滚奏
        place(x, timpani(98, 0.4), 0.6 + i * 0.045, 0.25 + i * 0.06)
    place(x, brass(G, 0.13), 0.6)
    place(x, brass(G, 0.13), 0.74)
    final = [523.25, 659.25, 783.99, 1046.5, 1318.5]
    place(x, brass(final, 2.6, attack=0.03, release=0.9, bright=1.2), 0.9, 1.3)
    place(x, timpani(78, 1.0), 0.9, 0.9)
    place(x, crash(2.6), 0.9, 0.45)
    for i, f in enumerate([2093.0, 2637.0, 3136.0, 4186.0] * 3):
        place(x, bell(f, 0.6, 0.2, 0.8), 1.0 + i * 0.13, 0.18)
    return echo(softclip(x * 1.3, 1.4), taps=((0.1, 0.25), (0.21, 0.14), (0.33, 0.07)), tail=0.5)


def snd_coin():
    """金币"叮"，游戏里随机音调连发形成"哗啦啦"。"""
    d = 0.4
    t = tline(d)
    ring = (sine(2637, d) + 0.6 * sine(3951 * 1.002, d) + 0.3 * sine(5274, d)) * env_exp(d, 0.09, 0.0005)
    ring += biquad(noise(d), "hp", 5000) * np.exp(-t / 0.002) * 0.4
    x = ring.copy()
    place(x, ring[: ns(0.2)], 0.055, 0.35)
    return x


def snd_miss():
    """听牌没中："哇~哦~" 下行两音，泄气感。"""
    d = 0.85
    t = tline(d)
    f = np.where(t < 0.2, 330.0, 262.0 * (1 - 0.18 * np.clip((t - 0.45) / 0.35, 0, 1)))
    x = 0.7 * tri(f, d) + 0.3 * saw(f, d)
    x = biquad(x, "lp", 1100, 1.0)
    env = np.clip(t / 0.02, 0, 1) * (1 - 0.7 * np.exp(-(((t - 0.2) / 0.018) ** 2))) * np.clip((d - t) / 0.3, 0, 1)
    return x * env


# ---------------------------------------------------------------- BGM

BGM_BPM = 120
BGM_BARS = 16
# (和弦音 MIDI, 贝斯根音 MIDI)
CHORDS = {
    "C": ([60, 64, 67, 71], 36),
    "Am": ([57, 60, 64, 67], 45),
    "Dm": ([62, 65, 69, 72], 38),
    "G": ([55, 59, 62, 65], 43),
    "F": ([53, 57, 60, 64], 41),
    "Em": ([52, 55, 59, 62], 40),
    "Gsus": ([55, 60, 62, 65], 43),
}
PROGRESSION = ["C", "Am", "Dm", "G"] * 3 + ["F", "Em", "Dm", "Gsus"]
# 旋律（第 9~16 小节）：(小节, 拍, MIDI, 时值拍数)
MELODY = [
    (8, 0, 76, 0.5), (8, 0.5, 79, 0.5), (8, 1, 84, 1), (8, 2, 81, 0.5), (8, 2.5, 79, 1.5),
    (9, 0, 76, 0.5), (9, 0.5, 79, 0.5), (9, 1, 81, 1), (9, 2, 79, 0.5), (9, 2.5, 76, 1.5),
    (10, 0, 74, 0.5), (10, 0.5, 77, 0.5), (10, 1, 81, 1), (10, 2, 79, 0.5), (10, 2.5, 77, 0.5), (10, 3, 74, 1),
    (11, 0, 71, 0.5), (11, 0.5, 74, 0.5), (11, 1, 79, 1.5), (11, 3, 77, 0.5), (11, 3.5, 74, 0.5),
    (12, 0, 72, 0.5), (12, 0.5, 77, 0.5), (12, 1, 81, 1), (12, 2, 84, 1), (12, 3, 81, 1),
    (13, 0, 79, 1), (13, 1, 76, 0.5), (13, 1.5, 79, 0.5), (13, 2, 83, 1), (13, 3, 79, 1),
    (14, 0, 77, 0.5), (14, 0.5, 81, 0.5), (14, 1, 84, 1), (14, 2, 86, 1), (14, 3, 84, 0.5), (14, 3.5, 81, 0.5),
    (15, 0, 83, 1), (15, 1, 86, 1),
] + [(15, 2 + i * 0.25, n, 0.25) for i, n in enumerate([79, 81, 83, 84, 86, 88, 89, 91])]  # 上行琶音接回开头


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def ep_note(freq, dur, vel=1.0):
    """电钢琴：FM 音色 + 颤音。"""
    d = dur + 0.25
    t = tline(d)
    mod = np.sin(2 * np.pi * freq * t) * 1.6 * np.exp(-t / 0.3)
    x = np.sin(2 * np.pi * freq * t + mod) + 0.15 * np.sin(2 * np.pi * freq * 4 * t) * np.exp(-t / 0.04)
    env = np.clip(t / 0.004, 0, 1) * (0.45 + 0.55 * np.exp(-t / 0.35)) * np.clip((d - t) / 0.25, 0, 1)
    return x * env * (1 + 0.12 * np.sin(2 * np.pi * 5 * t)) * vel


_bass_cache: dict = {}


def bass_note(note, dur):
    key = (note, round(dur, 3))
    if key not in _bass_cache:
        f = midi(note)
        d = dur + 0.05
        t = tline(d)
        x = 0.6 * saw(f, d) + 0.6 * sine(f, d) + 0.25 * sine(f * 2, d)
        x = biquad(x, "lp", 250 + 1400 * np.exp(-t / 0.06), 1.0)
        env = np.clip(t / 0.005, 0, 1) * (0.6 + 0.4 * np.exp(-t / 0.15)) * np.clip((d - t) / 0.04, 0, 1)
        _bass_cache[key] = x * env
    return _bass_cache[key]


def drum_kick():
    d = 0.35
    t = tline(d)
    body = sine(48 + 110 * np.exp(-t / 0.03), d) * env_exp(d, 0.16, 0.001)
    return body + biquad(noise(d), "hp", 3000) * np.exp(-t / 0.002) * 0.3


def drum_clap():
    d = 0.3
    x = np.zeros(ns(d))
    for i, at in enumerate([0.0, 0.011, 0.022]):
        place(x, biquad(noise(0.02), "bp", 1500, 1.2) * env_exp(0.02, 0.006, 0), at, 1.0 - i * 0.15)
    place(x, biquad(noise(0.25), "bp", 1300, 0.9) * env_exp(0.25, 0.07, 0.001), 0.022, 0.8)
    return x


def drum_snare():
    d = 0.2
    return sine(190, d) * env_exp(d, 0.04) * 0.5 + biquad(noise(d), "bp", 2400, 0.7) * env_exp(d, 0.07, 0.001)


def drum_hat(open_=False):
    d = 0.3 if open_ else 0.06
    return biquad(noise(d), "hp", 7500) * env_exp(d, 0.14 if open_ else 0.02, 0.0005)


def snd_bgm():
    """背景音乐：120 BPM、16 小节、正好 32 秒，可无缝循环。
    四拍底鼓 + 反拍镲 + 走动贝斯 + 电钢琴切分和弦 + 后半段铃声旋律。"""
    spb = SR * 60 // BGM_BPM  # 每拍采样数
    total = spb * 4 * BGM_BARS
    tail = ns(2.0)
    drums = np.zeros(total + tail)
    bass = np.zeros(total + tail)
    keys = np.zeros(total + tail)
    bells = np.zeros(total + tail)

    def at(bar, beat):
        return (bar * 4 + beat) * spb / SR

    kick, clap, snare = drum_kick(), drum_clap(), drum_snare()
    hats = [drum_hat() for _ in range(4)]
    open_hat = drum_hat(True)

    for bar, name in enumerate(PROGRESSION):
        chord, root = CHORDS[name]
        next_root = CHORDS[PROGRESSION[(bar + 1) % BGM_BARS]][1]
        full = bar >= 4  # 前 4 小节轻一点，后面加拍手和十六分镲
        for beat in range(4):
            place(drums, kick, at(bar, beat), 0.9)
            place(drums, open_hat if beat == 3 and bar % 2 else hats[beat], at(bar, beat + 0.5), 0.32)
            if full:
                if beat in (1, 3):
                    place(drums, clap, at(bar, beat), 0.55)
                for q in (0.25, 0.75):
                    place(drums, hats[(beat + 1) % 4], at(bar, beat + q), 0.1)
        if bar == BGM_BARS - 1:  # 最后一小节军鼓加花，接回开头
            for i in range(8):
                place(drums, snare, at(bar, 2 + i * 0.25), 0.25 + i * 0.05)

        approach = next_root - 1 if next_root != root else root + 10
        for e, note, length in [(0, root, 1.4), (3, root + 12, 0.6), (4, root, 1.4), (6, root + 7, 0.7), (7, approach, 0.6)]:
            place(bass, bass_note(note, length * spb / 2 / SR), at(bar, e / 2), 0.55)

        hits = [(0, 1.4, 0.9), (1.5, 0.35, 0.65), (2.5, 1.3, 0.8)] + ([(3.5, 0.3, 0.55)] if bar % 2 else [])
        for beat, length, vel in hits:
            for n in chord:
                place(keys, ep_note(midi(n), length * spb / SR, vel), at(bar, beat), 0.16)

        if bar < 8:  # 前半段：高八度的稀疏琶音点缀
            for beat, idx in [(0.5, 1), (1.5, 2), (2.5, 3), (3.5, 2)]:
                place(bells, bell(midi(chord[idx] + 12), 0.6, 0.25, 0.6), at(bar, beat), 0.12)

    for bar, beat, note, length in MELODY:
        place(bells, bell(midi(note), length * spb / SR + 0.5, 0.35, 0.9), at(bar, beat), 0.32)

    bells = echo(bells, taps=((0.375, 0.35), (0.75, 0.18), (1.125, 0.08)), tail=0.0)[: total + tail]
    keys = echo(keys, taps=((0.375, 0.18), (0.75, 0.08)), tail=0.0)[: total + tail]
    x = softclip(drums * 0.9 + bass, 1.3) + keys + bells
    x[:tail] += x[total:]  # 尾音绕回开头，保证循环无缝
    return x[:total]


def write_ogg(name, x, peak_db):
    """BGM 体积较大：有 ffmpeg 时转成 OGG，否则保留 WAV。"""
    write(name, x, peak_db, fade=False)
    wav = os.path.join(OUT_DIR, f"{name}.wav")
    if shutil.which("ffmpeg"):
        ogg = os.path.join(OUT_DIR, f"{name}.ogg")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", wav, "-c:a", "libvorbis", "-q:a", "5", ogg], check=True)
        os.remove(wav)
        print(f"{name:10s} -> {name}.ogg")


SOUNDS = [
    # name, fn, peak dB, fade
    ("press", snd_press, -8.0, True),
    ("lever", snd_lever, -3.0, True),
    ("spin_loop", snd_spin_loop, -9.0, False),
    ("stop", snd_stop, -0.5, True),
    ("boom", snd_boom, -1.0, True),
    ("reach", snd_reach, -3.0, True),
    ("win", snd_win, -2.0, True),
    ("win_big", snd_win_big, -1.5, True),
    ("jackpot", snd_jackpot, -1.0, True),
    ("coin", snd_coin, -7.0, True),
    ("miss", snd_miss, -6.0, True),
]


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, fn, peak, fade in SOUNDS:
        write(name, fn(), peak, fade)
    write_ogg("bgm", snd_bgm(), -3.0)


if __name__ == "__main__":
    main()
