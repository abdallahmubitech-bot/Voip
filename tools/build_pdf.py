#!/usr/bin/env python3
"""
Builds docs/ESP32_VoIP_Project_Guide.pdf — a guide for both non-technical
readers and the person who will extend this project.

Run:  python3 tools/build_pdf.py
Deps: reportlab (pip install reportlab)
"""
from __future__ import annotations

import datetime
import re
import os
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, CondPageBreak, Flowable, Frame, Image,
                                KeepTogether, NextPageTemplate, PageBreak,
                               PageTemplate, Paragraph, Spacer, Table,
                               TableStyle)

# ---------------------------------------------------------------------------
# Fonts (DejaVu: full arrow/greek glyph coverage)
# ---------------------------------------------------------------------------
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
pdfmetrics.registerFont(TTFont("Body", f"{FONT_DIR}/DejaVuSans.ttf"))
pdfmetrics.registerFont(TTFont("Body-Bold", f"{FONT_DIR}/DejaVuSans-Bold.ttf"))
pdfmetrics.registerFont(TTFont("Mono", f"{FONT_DIR}/DejaVuSansMono.ttf"))
pdfmetrics.registerFont(TTFont("Mono-Bold", f"{FONT_DIR}/DejaVuSansMono-Bold.ttf"))
pdfmetrics.registerFontFamily("Body", normal="Body", bold="Body-Bold",
                              italic="Body", boldItalic="Body-Bold")
pdfmetrics.registerFontFamily("Mono", normal="Mono", bold="Mono-Bold",
                              italic="Mono", boldItalic="Mono-Bold")

# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------
INK = colors.HexColor("#111827")
MUTED = colors.HexColor("#5B6472")
BRAND = colors.HexColor("#1F6FEB")
BRAND_DK = colors.HexColor("#0B3D91")
NAVY = colors.HexColor("#0E1420")
CARD = colors.HexColor("#F4F6FA")
LINE = colors.HexColor("#DCE1EA")
GREEN = colors.HexColor("#12874A")
AMBER = colors.HexColor("#9A6206")
RED = colors.HexColor("#B42318")
AMBER_BG = colors.HexColor("#FFF7E6")
GREEN_BG = colors.HexColor("#EAF7EF")
BLUE_BG = colors.HexColor("#EDF3FE")
RED_BG = colors.HexColor("#FDEDEC")

PAGE_W, PAGE_H = A4
MARGIN = 17 * mm
CONTENT_W = PAGE_W - 2 * MARGIN

ss = getSampleStyleSheet()


def st(name, **kw):
    base = dict(fontName="Body", fontSize=9.8, leading=14.6, textColor=INK,
                spaceAfter=6, alignment=TA_LEFT)
    base.update(kw)
    return ParagraphStyle(name, **base)


S = {
    "body": st("body"),
    "body_sm": st("body_sm", fontSize=8.8, leading=13, textColor=MUTED),
    "lead": st("lead", fontSize=11.2, leading=17.4, textColor=colors.HexColor("#243044")),
    "h1": st("h1", fontName="Body-Bold", fontSize=19, leading=23, textColor=NAVY,
             spaceAfter=2, spaceBefore=2),
    "h1_num": st("h1_num", fontName="Body-Bold", fontSize=9, leading=11, textColor=BRAND,
                 spaceBefore=14),
    "h2": st("h2", fontName="Body-Bold", fontSize=12.4, leading=16, textColor=NAVY,
             spaceBefore=10, spaceAfter=4),
    "h3": st("h3", fontName="Body-Bold", fontSize=10.2, leading=14, textColor=BRAND_DK,
             spaceBefore=6, spaceAfter=2),
    "bullet": st("bullet", leftIndent=12, bulletIndent=2, spaceAfter=3.5),
    "num": st("num", leftIndent=16, bulletIndent=2, spaceAfter=4),
    "code": st("code", fontName="Mono", fontSize=7.9, leading=11.4, textColor=colors.HexColor("#1B2432")),
    "th": st("th", fontName="Body-Bold", fontSize=8.6, leading=11.6, textColor=colors.white),
    "td": st("td", fontSize=8.5, leading=12.2),
    "td_mono": st("td_mono", fontName="Mono", fontSize=7.6, leading=11),
    "cover_title": st("cover_title", fontName="Body-Bold", fontSize=31, leading=36,
                      textColor=colors.white),
    "cover_sub": st("cover_sub", fontSize=13, leading=19, textColor=colors.HexColor("#C7D3E6")),
    "cover_note": st("cover_note", fontSize=9.6, leading=15,
                     textColor=colors.HexColor("#D6E0F0")),
    "cover_kicker": st("cover_kicker", fontName="Body-Bold", fontSize=9.2, leading=11,
                       textColor=colors.HexColor("#8FB4FF")),
    "callout": st("callout", fontSize=9.4, leading=14.2),
    "callout_title": st("callout_title", fontName="Body-Bold", fontSize=9.6, leading=12,
                        textColor=NAVY, spaceAfter=3),
    "toc_l1": st("toc_l1", fontName="Body-Bold", fontSize=10, leading=15),
    "toc_l2": st("toc_l2", fontSize=9, leading=13.6, textColor=MUTED, leftIndent=14),
    "caption": st("caption", fontSize=8.2, leading=11, textColor=MUTED,
                  alignment=TA_CENTER, spaceBefore=2),
}


def esc(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


_TAG_RE = re.compile(r"</?(?:b|i|u|br|font|super|sub)(?:\s[^<>]*)?/?>")


def safe_markup(text: str) -> str:
    """Escape XML specials but keep the small inline tag whitelist usable."""
    out, pos = [], 0
    for m in _TAG_RE.finditer(text):
        out.append(esc(text[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(esc(text[pos:]))
    return "".join(out)


# ---------------------------------------------------------------------------
# Small content helpers
# ---------------------------------------------------------------------------
def H1(number: str, title: str) -> list:
    return [
        Paragraph(f"SECTION {number}", S["h1_num"]),
        Paragraph(esc(title), S["h1"]),
        Spacer(1, 3),
        HRule(CONTENT_W, 1.6, BRAND),
        Spacer(1, 9),
    ]


def H2(text: str) -> Paragraph:
    return Paragraph(esc(text), S["h2"])


def H3(text: str) -> Paragraph:
    return Paragraph(esc(text), S["h3"])


def P(text: str, style: str = "body") -> Paragraph:
    return Paragraph(text, S[style])


def LEAD(text: str) -> Paragraph:
    return Paragraph(text, S["lead"])


def BULLETS(items: list, style: str = "bullet", bullet: str = "•") -> list:
    return [Paragraph(i, S[style], bulletText=bullet) for i in items]


def NUMBERED(items: list) -> list:
    out = []
    for i, item in enumerate(items, 1):
        out.append(Paragraph(item, S["num"], bulletText=f"{i}."))
    return out


def SP(h: float = 6) -> Spacer:
    return Spacer(1, h)


class HRule(Flowable):
    def __init__(self, width, thickness=1, color=LINE):
        super().__init__()
        self.width, self.thickness, self.color = width, thickness, color

    def wrap(self, *a):
        return (self.width, self.thickness)

    def draw(self):
        self.canv.setStrokeColor(self.color)
        self.canv.setLineWidth(self.thickness)
        self.canv.line(0, 0, self.width, 0)


def CALLOUT(title: str, body_lines: list, kind: str = "info") -> Table:
    """Coloured advisory box. kind: info | plain | warn | good"""
    bg, bar = {
        "info": (BLUE_BG, BRAND),
        "plain": (CARD, colors.HexColor("#98A2B3")),
        "warn": (AMBER_BG, AMBER),
        "good": (GREEN_BG, GREEN),
        "bad": (RED_BG, RED),
    }[kind]
    inner = []
    if title:
        inner.append(Paragraph(esc(title), S["callout_title"]))
    for line in body_lines:
        inner.append(Paragraph(line, S["callout"]))
    table = Table([[inner]], colWidths=[CONTENT_W])
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LINEBEFORE", (0, 0), (0, -1), 3, bar),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    return table


def CODE(text: str, width: float = CONTENT_W) -> Table:
    """Monospace panel, one table row per line, so a long block can break across pages."""
    def _line(line: str) -> str:
        if not line.strip():
            return "&nbsp;"
        # keep the monospace alignment Paragraph would otherwise collapse
        return esc(line).replace(" ", "&nbsp;")

    rows = [[Paragraph(_line(line), S["code"])]
            for line in text.strip("\n").split("\n")]
    t = Table(rows, colWidths=[width])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F6F8FB")),
        ("LINEBEFORE", (0, 0), (0, -1), 2.4, BRAND),
        ("LINEAFTER", (-1, 0), (-1, -1), 0.5, LINE),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 9),
        ("TOPPADDING", (0, 0), (-1, -1), 0),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, 0), 7),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 7),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    return t


def TABLE(headers: list, rows: list, widths: list, mono_cols: tuple = (),
          font_size: float = 8.5, mono_size: float = 7.6) -> Table:
    head = [Paragraph(safe_markup(h), S["th"]) for h in headers]
    body = []
    for r in rows:
        cells = []
        for i, cell in enumerate(r):
            style = S["td"] if i not in mono_cols else S["td_mono"]
            if i in mono_cols and mono_size != 7.6:
                style = ParagraphStyle(f"tm{i}", parent=S["td_mono"], fontSize=mono_size,
                                       leading=mono_size + 3.4)
            if font_size != 8.5 and i not in mono_cols:
                style = ParagraphStyle(f"tmp{i}", parent=style, fontSize=font_size,
                                       leading=font_size + 3.6)
            cells.append(Paragraph(safe_markup(str(cell)), style))
        body.append(cells)
    data = [head] + body
    t = Table(data, colWidths=widths, repeatRows=1)
    style = [
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, LINE),
        ("BOX", (0, 0), (-1, -1), 0.6, LINE),
    ]
    for i in range(1, len(data)):
        if i % 2 == 0:
            style.append(("BACKGROUND", (0, i), (-1, i), colors.HexColor("#F8FAFC")))
    t.setStyle(TableStyle(style))
    if len(rows) <= 6:          # never strand a single row on the next page
        return KeepTogether([t])
    return t


class Diagram(Flowable):
    """Vector diagram drawn with plain canvas calls."""

    def __init__(self, width: float, height: float, painter, caption: str | None = None):
        super().__init__()
        self.width, self.height = width, height
        self.painter = painter
        self.caption = caption

    def wrap(self, aw, ah):
        return (self.width, self.height + (12 if self.caption else 0))

    def draw(self):
        self.painter(self.canv, self.width, self.height)
        if self.caption:
            self.canv.setFont("Body", 8.2)
            self.canv.setFillColor(MUTED)
            self.canv.drawCentredString(self.width / 2, -9, self.caption)


# --- canvas drawing primitives ---------------------------------------------
def rbox(c, x, y, w, h, title, lines=(), fill=colors.white, stroke=LINE,
         title_color=INK, line_color=MUTED, radius=7, title_size=9.2,
         line_size=7.8):
    c.setFillColor(fill)
    c.setStrokeColor(stroke)
    c.setLineWidth(1)
    c.roundRect(x, y, w, h, radius, stroke=1, fill=1)
    c.setFillColor(title_color)
    c.setFont("Body-Bold", title_size)
    c.drawCentredString(x + w / 2, y + h - title_size - 7, title)
    c.setFont("Body", line_size)
    c.setFillColor(line_color)
    ty = y + h - title_size - 7 - line_size - 3
    for line in lines:
        c.drawCentredString(x + w / 2, ty, line)
        ty -= line_size + 1.8


def arrow(c, x1, y1, x2, y2, color=BRAND, width=1.2, dash=None, head=4.2):
    c.setStrokeColor(color)
    c.setFillColor(color)
    c.setLineWidth(width)
    if dash:
        c.setDash(dash, 2)
    c.line(x1, y1, x2, y2)
    c.setDash()
    import math
    ang = math.atan2(y2 - y1, x2 - x1)
    for sign in (0.42, -0.42):
        c.line(x2, y2,
               x2 - head * math.cos(ang + sign),
               y2 - head * math.sin(ang + sign))


def label(c, x, y, text, color=MUTED, size=7.4, center=True, font="Body"):
    c.setFont(font, size)
    c.setFillColor(color)
    if center:
        c.drawCentredString(x, y, text)
    else:
        c.drawString(x, y, text)


# ---------------------------------------------------------------------------
# Diagrams
# ---------------------------------------------------------------------------
def diagram_system(c, w, h):
    """Phone A  <->  ESP32  <->  Phone B"""
    bw, bh = w * 0.26, 66
    y = h - bh - 8
    rbox(c, 0, y, bw, bh, "PHONE A", ["Local VoIP app", "mic + speaker"],
         fill=colors.HexColor("#EAF1FE"), stroke=BRAND_DK, title_color=BRAND_DK)
    rbox(c, w / 2 - bw / 2, y, bw, bh, "ESP32 ROUTER",
         ["Wi-Fi access point", "the switchboard"],
         fill=NAVY, stroke=NAVY, title_color=colors.white, line_color=colors.HexColor("#B9C6DA"))
    rbox(c, w - bw, y, bw, bh, "PHONE B", ["Local VoIP app", "mic + speaker"],
         fill=colors.HexColor("#EAF1FE"), stroke=BRAND_DK, title_color=BRAND_DK)

    arrow(c, bw + 4, y + bh / 2, w / 2 - bw / 2 - 4, y + bh / 2, color=BRAND, width=1.5)
    arrow(c, w / 2 - bw / 2 - 4, y + bh / 2 - 9, bw + 4, y + bh / 2 - 9, color=BRAND, width=1.5)
    arrow(c, w - bw - 4, y + bh / 2, w / 2 + bw / 2 + 4, y + bh / 2, color=BRAND, width=1.5)
    arrow(c, w / 2 + bw / 2 + 4, y + bh / 2 - 9, w - bw - 4, y + bh / 2 - 9, color=BRAND, width=1.5)

    gap_l = (bw + (w / 2 - bw / 2)) / 2
    gap_r = ((w / 2 + bw / 2) + (w - bw)) / 2
    for gx in (gap_l, gap_r):
        label(c, gx, y + bh / 2 + 9, "Wi-Fi", color=BRAND_DK, size=7, font="Body-Bold")
        label(c, gx, y + bh / 2 - 15, "port 81", size=6.6)

    c.setFillColor(colors.HexColor("#F4F6FA"))
    c.roundRect(0, 0, w, 32, 6, stroke=0, fill=1)
    c.setFillColor(MUTED)
    c.setFont("Body", 8.2)
    c.drawCentredString(w / 2, 19, "One live WebSocket connection from each phone to the board — nothing else.")
    c.drawCentredString(w / 2, 7, "No internet. No SIM card. No cloud. No data plan.")


def diagram_pipeline(c, w, h):
    """Capture path on top, playback path underneath."""
    boxw, boxh = w * 0.175, 52
    gap = (w - 5 * boxw) / 4

    def row(y, items, color, fill, title):
        x = 0
        for i, (t, sub) in enumerate(items):
            rbox(c, x, y, boxw, boxh, t, sub, fill=fill, stroke=color,
                 title_size=7.6, line_size=6.8)
            if i < len(items) - 1:
                arrow(c, x + boxw + 1, y + boxh / 2, x + boxw + gap - 1, y + boxh / 2,
                      color=color, width=1.1)
            x += boxw + gap
        label(c, w / 2, y + boxh + 6, title, color=color, size=8, font="Body-Bold")

    top_y = h - boxh - 20
    row(top_y, [
        ("MICROPHONE", ["sound in"]),
        ("CHOP", ["40 ms slices"]),
        ("ADDRESS", ["+ 1 byte"]),
        ("WI-FI", ["to ESP32"]),
        ("ESP32", ["forwards it"]),
    ], BRAND, colors.HexColor("#EAF1FE"), "WHAT YOU SAY  (25 packets every second)")

    bot_y = 22
    row(bot_y, [
        ("SPEAKER", ["sound out"]),
        ("JITTER", ["small queue"]),
        ("STRIP", ["- 1 byte"]),
        ("WI-FI", ["from ESP32"]),
        ("ESP32", ["passes it on"]),
    ], GREEN, colors.HexColor("#EAF7EF"), "WHAT YOU HEAR  (played back in order, 40 ms at a time)")

    mid = (top_y + bot_y + boxh) / 2 + 4
    c.setStrokeColor(LINE)
    c.setLineWidth(0.8)
    c.setDash(2, 3)
    c.line(0, mid, w, mid)
    c.setDash()
    label(c, w / 2, mid - 10, "both directions run at the same time — that is what 'full duplex' means",
          size=7.2)


def diagram_packet(c, w, h):
    bar_h = 34
    y = h - bar_h - 12
    head_w = w * 0.13
    c.setFillColor(colors.HexColor("#F59E0B"))
    c.rect(0, y, head_w, bar_h, stroke=0, fill=1)
    c.setFillColor(colors.HexColor("#DCE7FB"))
    c.rect(head_w, y, w - head_w, bar_h, stroke=0, fill=1)
    c.setStrokeColor(colors.HexColor("#9DB6DE"))
    c.rect(head_w, y, w - head_w, bar_h, stroke=1, fill=0)
    c.setStrokeColor(colors.HexColor("#B7791F"))
    c.rect(0, y, head_w, bar_h, stroke=1, fill=0)

    c.setFillColor(colors.HexColor("#3B2A05"))
    c.setFont("Body-Bold", 8.6)
    c.drawCentredString(head_w / 2, y + bar_h / 2 - 3, "1 byte")
    c.setFillColor(colors.HexColor("#12305F"))
    c.setFont("Body-Bold", 8.6)
    c.drawCentredString(head_w + (w - head_w) / 2, y + bar_h / 2 + 6, "1280 bytes of voice")
    c.setFont("Body", 7.6)
    c.setFillColor(colors.HexColor("#3C5B8C"))
    c.drawCentredString(head_w + (w - head_w) / 2, y + bar_h / 2 - 6,
                        "16000 samples/sec × 0.040 sec × 2 bytes = exactly 40 ms of sound")

    label(c, head_w / 2, y + bar_h + 6, "WHO IT IS FOR", color=AMBER, size=7.6, font="Body-Bold")
    label(c, head_w + (w - head_w) / 2, y + bar_h + 6, "THE SOUND ITSELF",
          color=BRAND_DK, size=7.6, font="Body-Bold")

    label(c, w / 2, y - 14, "whole packet = 1281 bytes  ·  25 packets per second  ·  256 kbit/s per direction",
          color=MUTED, size=7.6)


def diagram_sequence(c, w, h):
    """Call setup, three visible participants."""
    xa, xr, xb = w * 0.13, w * 0.5, w * 0.87
    top = h - 16
    bottom = 18

    for x, name in ((xa, "PHONE A  (caller)"), (xr, "ESP32  (switchboard)"), (xb, "PHONE B  (callee)")):
        c.setFillColor(NAVY)
        c.roundRect(x - 52, top - 2, 104, 18, 4, stroke=0, fill=1)
        c.setFillColor(colors.white)
        c.setFont("Body-Bold", 7.4)
        c.drawCentredString(x, top + 4, name)

    c.setStrokeColor(colors.HexColor("#C3CBD9"))
    c.setLineWidth(0.9)
    for x in (xa, xr, xb):
        c.setDash(3, 3)
        c.line(x, top - 6, x, bottom + 26)
        c.setDash()

    msgs = [
        (xa, xr, 'register  "User_A"', BRAND),
        (xr, xa, 'registered  id = 1', GREEN),
        (xa, xr, 'make_call  to "User_B"', BRAND),
        (xr, xb, 'incoming_call  from User_A, id = 1', BRAND),
        (xr, xa, 'call_ringing', GREEN),
        (xb, xr, 'call_accept', BRAND),
        (xr, xa, 'call_answered  id = 2', GREEN),
    ]
    step = (top - 34 - (bottom + 70)) / (len(msgs) - 1)
    y = top - 34
    for i, (src, dst, text, color) in enumerate(msgs):
        arrow(c, src + (4 if dst > src else -4), y, dst - (4 if dst > src else -4), y,
              color=color, width=1.15)
        mid = (src + dst) / 2
        label(c, mid, y + 4.5, f"{i + 1}. {text}", color=colors.HexColor("#26364D"), size=7.2)
        y -= step

    y += step * 0.35
    band_h = 22
    c.setFillColor(colors.HexColor("#EAF7EF"))
    c.rect(0, y - band_h + 12, w, band_h, stroke=0, fill=1)
    arrow(c, xa + 4, y, xr - 4, y, color=GREEN, width=1.5)
    arrow(c, xr + 4, y, xb - 4, y, color=GREEN, width=1.5)
    arrow(c, xb - 4, y - 11, xr + 4, y - 11, color=GREEN, width=1.5)
    arrow(c, xr - 4, y - 11, xa + 4, y - 11, color=GREEN, width=1.5)
    label(c, xa + (xr - xa) / 2, y + 5, "8. voice packets", color=GREEN, size=7.2, font="Body-Bold")
    label(c, xr + (xb - xr) / 2, y + 5, "8. voice packets", color=GREEN, size=7.2, font="Body-Bold")
    label(c, w / 2, bottom + 12, "8. … until one side sends  end_call  (step 9)",
          color=GREEN, size=7.2, font="Body-Bold")


def diagram_busy(c, w, h):
    """The busy-line branch, drawn small."""
    bw, bh = w * 0.23, 46
    y = h - bh - 20
    rbox(c, 0, y, bw, bh, "PHONE A", ["was ringing"], fill=colors.HexColor("#EAF1FE"),
         stroke=BRAND_DK, title_color=BRAND_DK, title_size=8, line_size=7)
    rbox(c, w - bw, y, bw, bh, "PHONE C", ["already in a call"], fill=colors.HexColor("#FDEDEC"),
         stroke=RED, title_color=RED, title_size=8, line_size=7)
    rbox(c, w / 2 - bw / 2, y, bw, bh, "ESP32", ["checks the line"], fill=NAVY,
         stroke=NAVY, title_color=colors.white, line_color=colors.HexColor("#B9C6DA"),
         title_size=8, line_size=7)
    gl = (bw + (w / 2 - bw / 2)) / 2
    gr = ((w / 2 + bw / 2) + (w - bw)) / 2
    arrow(c, bw + 3, y + bh / 2 + 5, w / 2 - bw / 2 - 3, y + bh / 2 + 5, color=BRAND, width=1.2)
    label(c, gl, y + bh / 2 + 11, "make_call", color=BRAND_DK, size=7, font="Body-Bold")
    arrow(c, w / 2 - bw / 2 - 3, y + bh / 2 - 5, bw + 3, y + bh / 2 - 5, color=RED, width=1.2)
    label(c, gl, y + bh / 2 - 17, "line_busy", color=RED, size=7, font="Body-Bold")
    arrow(c, w / 2 + bw / 2 + 3, y + bh / 2, w - bw - 3, y + bh / 2, color=RED,
          width=1.2, dash=(3, 2))
    label(c, gr, y + bh / 2 + 11, "never rings", color=RED, size=6.8)
    label(c, gr, y + bh / 2 - 17, "no call is set up", size=6.8)

    c.setFillColor(colors.HexColor("#FDEDEC"))
    c.roundRect(0, 0, w, 30, 5, stroke=0, fill=1)
    c.setFillColor(RED)
    c.setFont("Body-Bold", 9.4)
    c.drawCentredString(w / 2, 17, '"Please wait, the user is on another call."')
    c.setFont("Body", 7.6)
    c.setFillColor(MUTED)
    c.drawCentredString(w / 2, 6, "the ring tone stops at once and this pop-up appears — nothing is left ringing")


# ---------------------------------------------------------------------------
# Page furniture
# ---------------------------------------------------------------------------
def cover_page(c, doc):
    c.saveState()
    c.setFillColor(NAVY)
    c.rect(0, 0, PAGE_W, PAGE_H, stroke=0, fill=1)
    # accents
    c.setFillColor(colors.HexColor("#12203A"))
    c.circle(PAGE_W * 0.86, PAGE_H * 0.78, 150, stroke=0, fill=1)
    c.setFillColor(colors.HexColor("#16284A"))
    c.circle(PAGE_W * 0.1, PAGE_H * 0.2, 120, stroke=0, fill=1)
    c.setFillColor(BRAND)
    c.rect(0, PAGE_H - 6, PAGE_W, 6, stroke=0, fill=1)
    c.restoreState()


def body_page(c, doc):
    c.saveState()
    c.setStrokeColor(LINE)
    c.setLineWidth(0.6)
    c.line(MARGIN, PAGE_H - MARGIN + 12, PAGE_W - MARGIN, PAGE_H - MARGIN + 12)
    c.setFont("Body", 7.6)
    c.setFillColor(MUTED)
    c.drawString(MARGIN, PAGE_H - MARGIN + 17, "Local Wi-Fi VoIP over ESP32  ·  Project Guide")
    c.drawRightString(PAGE_W - MARGIN, PAGE_H - MARGIN + 17,
                      datetime.date(2026, 11, 2).strftime("%d %B %Y"))
    c.line(MARGIN, MARGIN - 10, PAGE_W - MARGIN, MARGIN - 10)
    if getattr(doc, "_show_page_number", False):
        c.setFont("Body", 8)
        c.setFillColor(MUTED)
        c.drawCentredString(PAGE_W / 2, MARGIN - 22, str(doc.page))
    c.restoreState()


# ---------------------------------------------------------------------------
# Story
# ---------------------------------------------------------------------------
def cover_story() -> list:
    W = CONTENT_W
    return [
        Spacer(1, 120),
        Paragraph("PROJECT GUIDE  ·  VERSION 1.1.0", S["cover_kicker"]),
        Spacer(1, 10),
        Paragraph("Talking Over Thin Air", S["cover_title"]),
        Spacer(1, 6),
        Paragraph("How a Wi-Fi voice-call system built from an ESP32 and a Flutter app<br/>actually works — and how to take it further", S["cover_sub"]),
        Spacer(1, 26),
        Table(
            [[Paragraph(
                "Written for two readers at once: anyone who wants to understand the idea "
                "without touching a line of code, and the builder who will extend it. "
                "Plain-language explanations sit on the light pages; the dark "
                "<b>Builder's notes</b> boxes hold the technical detail that makes the "
                "next feature easier to add.", S["cover_note"])]],
            colWidths=[W * 0.62],
            style=TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#16233C")),
                ("TEXTCOLOR", (0, 0), (-1, -1), colors.HexColor("#D6E0F0")),
                ("LEFTPADDING", (0, 0), (-1, -1), 14),
                ("RIGHTPADDING", (0, 0), (-1, -1), 14),
                ("TOPPADDING", (0, 0), (-1, -1), 12),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 12),
                ("LINEBEFORE", (0, 0), (0, -1), 3, BRAND),
            ]),
        ),
        Spacer(1, 40),
        Table(
            [[Paragraph("<font color='#8FB4FF'>THE SYSTEM</font>", S["body_sm"]),
              Paragraph("<font color='#8FB4FF'>THE STACK</font>", S["body_sm"]),
              Paragraph("<font color='#8FB4FF'>THE ARTEFACTS</font>", S["body_sm"])],
             [Paragraph("<font color='#E6ECF6'>2 Android phones<br/>1 ESP32 board<br/>1 Wi-Fi network</font>", S["callout"]),
              Paragraph("<font color='#E6ECF6'>Flutter · Dart · BLoC<br/>WebSocket · raw PCM<br/>Arduino C++</font>", S["callout"]),
              Paragraph("<font color='#E6ECF6'>Signed Android APK<br/>Firmware .ino<br/>Source + tests</font>", S["callout"])]],
            colWidths=[W / 3.0] * 3,
            style=TableStyle([
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ]),
        ),
        Spacer(1, 60),
        Paragraph("<font color='#7E8CA6'>Prepared 2 November 2026  ·  com.example.esp32_voip  ·  build 1.1.0+2</font>",
                  S["body_sm"]),
        NextPageTemplate("body"),
        PageBreak(),
    ]


# Filled in by build() from a first pass, so the contents can never go stale.
PAGES: dict[str, str] = {}


def contents_story() -> list:
    rows = [
        ("0", "Read this first — the whole project in 60 seconds", PAGES.get("0", "")),
        ("1", "What this project is (and what it is not)", PAGES.get("1", "")),
        ("2", "The three pieces, and the switchboard idea", PAGES.get("2", "")),
        ("3", "What happens when you make a call", PAGES.get("3", "")),
        ("4", "How your voice actually travels", PAGES.get("4", "")),
        ("5", "Why the first calls sounded bad — and the fix", PAGES.get("5", "")),
        ("6", "The technology, and why each piece was chosen", PAGES.get("6", "")),
        ("7", "How the code is organised (and where to change things)", PAGES.get("7", "")),
        ("8", "When something goes wrong", PAGES.get("8", "")),
        ("9", "Scaling it up: a roadmap you can actually execute", PAGES.get("9", "")),
        ("10", "Glossary for non-technical readers", PAGES.get("10", "")),
        ("A", "Protocol reference (for the firmware developer)", PAGES.get("A", "")),
        ("B", "Build, flash, and what has been verified", PAGES.get("B", "")),
    ]
    data = [[Paragraph("<b>Contents</b>", S["h2"]), ""]]
    for num, title, page in rows:
        label_txt = f"<b>{num}</b>&nbsp;&nbsp;{esc(title)}" if num != "0" else f"<i>{esc(title)}</i>"
        data.append([Paragraph(label_txt, S["toc_l1"]),
                     Paragraph(f"<font color='#5B6472'>{page}</font>", S["toc_l1"])])
    t = Table(data, colWidths=[CONTENT_W * 0.88, CONTENT_W * 0.12])
    t.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "BOTTOM"),
        ("ALIGN", (1, 0), (1, -1), "RIGHT"),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, -1), 3.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5),
        ("LINEBELOW", (0, 1), (-1, -2), 0.3, LINE),
    ]))
    return [
        SP(6),
        t,
        SP(14),
        *H1("0", "Read this first — the whole project in 60 seconds"),
        LEAD("You have a working system where two Android phones, standing in the same room, "
             "can call each other by name and talk in both directions at once. There is no "
             "internet involved, no SIM card, no phone company, and no monthly bill. A small "
             "microcontroller — an ESP32, about the price of a coffee — creates its own Wi-Fi "
             "network and introduces the two phones to each other."),
        SP(4),
        H2("The five sentences that matter"),
        *NUMBERED([
            "The ESP32 turns itself into a Wi-Fi hotspot, so the phones do not need any other network.",
            "Each phone opens <b>one live connection</b> to the ESP32 and announces a name, for example <font face='Mono' size='8'>User_A</font>.",
            "Calling someone is just a short text message to the ESP32: <i>“connect me to User_B”</i>.",
            "The ESP32 checks that User_B is free. If they are already talking to someone, it answers <i>“line busy”</i> and the app says so on screen.",
            "Once both sides agree, each phone chops its microphone sound into tiny 40-millisecond packets, writes the other phone’s number on the front, and fires them across the Wi-Fi link 25 times a second. The ESP32 passes them along, and the other phone plays them out loud.",
        ]),
        SP(6),
        CALLOUT("How to read the rest of this guide",
                ["<b>If you are not technical:</b> sections 1, 2, 3, 4, 5 and 10 are written for you. "
                 "Skim the diagrams — they carry the argument. You can stop at section 8.",
                 "<b>If you are the builder:</b> every grey “Builder’s note” box is for you. "
                 "Section 7 maps every folder and file, section 9 is the roadmap for growing the "
                 "system, and the appendices hold the exact wire protocol and build commands."],
                kind="info"),
    ]


def section_one() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("1", "What this project is (and what it is not)"),
        LEAD("A pocket-sized telephone exchange. Anyone who joins the Wi-Fi network it creates "
             "can call anyone else on that network by name, and hold a normal two-way "
             "conversation — with nothing but a cheap board and a pair of phones."),
        SP(4),
        H2("Two parts, working together"),
        P("The system is deliberately split in two, because the two halves are changed by "
          "different people at different times:"),
        *BULLETS([
            "<b>The app</b> (Android, built with Flutter). It is the telephone: it takes a name, "
            "dials, rings, captures your voice, plays the other person’s voice, and shows what is "
            "happening on screen.",
            "<b>The router</b> (the ESP32 board). It is the switchboard: it remembers who is on the "
            "network, decides who may talk to whom, refuses calls to busy lines, and moves the "
            "voice packets between phones without ever listening to them.",
        ]),
        SP(2),
        CALLOUT("A useful way to picture it",
                ["A phone call needs two things that are easy to confuse: <b>a way to reach each "
                 "other</b> (the network) and <b>a way to understand each other</b> (the audio). "
                 "The ESP32 provides the first. The app provides the second. That is why the app "
                 "can be swapped for a different one, and the router swapped for a different "
                 "router, without the other side noticing."],
                kind="plain"),
        SP(6),
        H2("Why not simply use WhatsApp or a normal phone call?"),
        P("Because both of those depend on something this project deliberately does not need."),
        TABLE(
            ["", "WhatsApp / normal call", "This project"],
            [
                ["Needs the internet or mobile coverage", "Yes — always", "No. The ESP32 is the network"],
                ["Needs a SIM card or data plan", "Yes", "No"],
                ["Keeps working when the masts are down or there is no coverage", "No", "Yes — Wi-Fi range only"],
                ["Where the audio goes", "Through a company’s servers", "Never leaves the room / building"],
                ["Cost to run", "Data or airtime, every month", "Electricity for the board"],
                ["Who can use it", "Anyone with a phone number", "Anyone inside Wi-Fi range who joins"],
                ["Reach", "Anywhere on earth", "30–50 m indoors, more outdoors"],
                ["Group calls, video, voicemail", "Yes", "Not yet — see section 9"],
            ],
            [W * 0.30, W * 0.30, W * 0.40],
        ),
        SP(8),
        H2("Where this kind of system earns its keep"),
        *BULLETS([
            "<b>Estates, farms and construction sites</b> — gate house to supervisor, without "
            "paying for airtime for staff who only ever talk to each other.",
            "<b>Factories, warehouses, hospital wards</b> — hands-free intercom where people are "
            "moving around and coverage is patchy.",
            "<b>Schools and labs</b> — a teaching platform: students can see a real call being set "
            "up, packet by packet, and break it on purpose.",
            "<b>Events and security teams</b> — a private channel that keeps working when the "
            "local network is congested.",
            "<b>Anywhere the conversation itself is sensitive</b> — because the sound never travels "
            "beyond the building, there is nothing to intercept remotely.",
        ]),
        SP(4),
        CALLOUT("Being honest about the limits",
                ["One ESP32 comfortably handles <b>one call at a time</b> and keeps track of up to "
                 "8 handsets. Its Wi-Fi reaches about 30–50 m indoors. The link is protected by "
                 "the Wi-Fi password (WPA2), but the call audio itself is not separately encrypted "
                 "yet, and it cannot call ordinary phone numbers or emergency services.",
                 "None of these are dead ends — section 9 shows exactly how each one is lifted."],
                kind="warn"),
    ]


def section_two() -> list:
    return [
        CondPageBreak(330),
        *H1("2", "The three pieces, and the switchboard idea"),
        LEAD("Two phones and one small board. Everything else in this document is detail "
             "hanging off that picture."),
        SP(6),
        Diagram(CONTENT_W, 150, diagram_system,
                caption="Figure 1 — The whole system. The ESP32 is both the Wi-Fi network and the "
                        "switchboard inside it."),
        SP(10),
        H2("What each piece is responsible for"),
        TABLE(
            ["Piece", "In plain words", "In technical terms"],
            [
                ["Phone A / Phone B",
                 "The telephone. It knows your name, dials the other phone, turns your voice into "
                 "data, and turns the other person’s data back into sound.",
                 "Flutter app. Owns the UI, the call state machine (BLoC), the microphone and "
                 "speaker (flutter_sound), and the live connection to the board."],
                ["ESP32 board",
                 "The switchboard operator. It answers when a phone joins, remembers names, "
                 "refuses calls to busy lines, and passes packets between phones — without ever "
                 "opening them.",
                 "Espressif ESP32 running Arduino C++ with a WebSocket server on port 81, a "
                 "routing table of 1-byte device ids, and a call-ownership table."],
                ["The Wi-Fi network",
                 "The air between them. It is created by the board itself, so it exists wherever "
                 "the board is plugged in.",
                 "WPA2 SoftAP on 2.4 GHz; each handset gets an IP automatically and speaks "
                 "WebSocket (RFC 6455) over it."],
            ],
            [CONTENT_W * 0.15, CONTENT_W * 0.40, CONTENT_W * 0.45],
        ),
        SP(10),
        H2("The switchboard analogy, in full"),
        P("Picture a 1950s office. Every desk has a telephone with no dial, only a cord. When you "
          "want to speak to someone, you lift the handset and an operator answers. You say a name. "
          "The operator knows every extension in the building, knows which ones are already "
          "talking, and physically plugs a cable between the two sockets. From that moment the "
          "operator is not part of the conversation — the two desks are simply connected, and the "
          "operator can go back to their newspaper."),
        P("This project is that, with more modern parts:"),
        TABLE(
            ["In the office", "In this project"],
            [
                ["The operator", "The ESP32 board"],
                ["“Extension 12, please”", "“make_call, to User_B”"],
                ["The operator knows the extension list", "The routing table: name → 1-byte id"],
                ["“That line is engaged”", "“line_busy — please wait, the user is on another call”"],
                ["Plugging in the cable", "Bridging the two WebSocket connections"],
                ["“Hello? Can you hear me?”", "The first audio packets, 40 ms each"],
                ["Unplugging the cable at the end", "“end_call”, both sides stop streaming"],
            ],
            [CONTENT_W * 0.42, CONTENT_W * 0.58],
        ),
        SP(8),
        CALLOUT("The clever bit: seat numbers instead of names",
                ["Moving sound around is time-critical — 25 packets a second per phone, in both "
                 "directions. So the phones do not write a name on each audio packet (a name is "
                 "long and slow to read). Instead the ESP32 hands each phone a <b>seat number</b> "
                 "between 1 and 254, a single byte. It is written as the very first byte of every "
                 "audio packet, and the board simply reads that one byte and forwards the packet "
                 "to the right seat. Names are only used in the rare, slow messages: joining, "
                 "dialling, hanging up.",
                 "<b>Builder’s note:</b> that is why the packet is 1281 bytes rather than 1280 — "
                 "one byte of addressing, 1280 bytes of sound."],
                kind="info"),
    ]


def section_three() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("3", "What happens when you make a call"),
        LEAD("Nine short steps. Steps 1–2 happen once, when the phone joins the network. Steps 3–9 "
             "happen on every call, in well under a second."),
        SP(6),
        Diagram(CONTENT_W, 250, diagram_sequence,
                caption="Figure 2 — A successful call. The numbered arrows are the actual messages "
                        "sent; steps 8 and 9 are the conversation itself."),
        SP(10),
        H2("The same steps, narrated"),
        TABLE(
            ["#", "Message", "What it means in plain words"],
            [
                ["1", 'register "User_A"',
                 "You open the app and type a name. The phone tells the board: “I am User_A.”"],
                ["2", "registered id = 1",
                 "The board replies: “Noted. Your seat number is 1.” From now on, every audio packet "
                 "this phone sends starts with the number 1."],
                ["3", 'make_call to "User_B"',
                 "You press Call. The phone asks the board to connect you."],
                ["4", "incoming_call from User_A, id = 1",
                 "The board asks User_B’s phone to ring — and tells it that the caller’s seat is 1, "
                 "so it knows where to send the answer-audio."],
                ["5", "call_ringing",
                 "The board confirms it is ringing. Your phone plays the ringback tone."],
                ["6", "call_accept",
                 "User_B presses the green button. Their phone tells the board it is ready."],
                ["7", "call_answered id = 2",
                 "The board tells your phone: “User_B is on seat 2 and is ready.” Your phone now "
                 "knows both seat numbers, so audio can flow in both directions."],
                ["8", "voice packets",
                 "Both phones start sending 40 ms packets, 25 per second (section 4). Your phone "
                 "also opens the microphone and the speaker in voice-call mode."],
                ["9", "end_call",
                 "One side presses the red button. Both phones stop streaming, close the microphone, "
                 "and go back to the dial pad."],
            ],
            [W * 0.05, W * 0.30, W * 0.65],
        ),
        SP(10),
        H2("The busy line — the feature that makes it feel like a real phone"),
        P("A switchboard is only useful if it refuses impossible calls cleanly. If User_C is "
          "already talking and User_A dials them, the board answers immediately and the app "
          "reacts within the same second:"),
        SP(2),
        Diagram(CONTENT_W, 112, diagram_busy),
        SP(8),
        *NUMBERED([
            "The board sees that User_C is already bridged to someone, so it does <b>not</b> ring them.",
            "It replies to User_A with one sentence: "
            "<font face='Mono' size='8'>line_busy</font>.",
            "User_A’s app stops the ringback tone <b>at once</b> (no ghost ringing), throws away the "
            "half-finished call, and shows a pop-up with the board’s sentence.",
            "When you dismiss the pop-up you are back on the dial pad, free to try someone else.",
        ]),
        SP(6),
        CALLOUT("Builder’s note — why the ringback must stop in the state machine, not the screen",
                ["Screen-level code cannot be trusted with “stop the ringing”, because the screen "
                 "can be rebuilt, backgrounded or replaced at any moment. The instruction lives in "
                 "<font face='Mono' size='8'>CallBloc._handleLineBusy()</font>, which stops the tone "
                 "and then emits the <font face='Mono' size='8'>CallLineBusy</font> state. The screen "
                 "only renders that state. That is why the behaviour is testable without a "
                 "microphone or a phone at all."],
                kind="plain"),
        SP(6),
        H2("Ringing that gives up on its own"),
        *BULLETS([
            "<b>45 seconds</b> of ringing with no answer ends the attempt on both sides and shows "
            "“No answer”.",
            "If the callee’s phone disconnects mid-ring, the caller is told the call ended instead "
            "of listening to a ringback forever.",
            "If the caller cancels while it is ringing, the callee’s phone stops ringing immediately.",
        ]),
    ]


def section_four() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("4", "How your voice actually travels"),
        LEAD("Human speech is a continuous wave. A computer can only send numbers. The whole "
             "trick of a phone call is doing that conversion fast enough that nobody notices — "
             "in this design, 25 times per second, in both directions."),
        SP(6),
        Diagram(CONTENT_W, 190, diagram_pipeline,
                caption="Figure 3 — Two independent pipelines, running at the same time. That "
                        "simultaneity is what “full duplex” means."),
        SP(12),
        H2("One packet, byte by byte"),
        SP(2),
        Diagram(CONTENT_W, 80, diagram_packet),
        SP(12),
        H2("Why 40 milliseconds?"),
        TABLE(
            ["Choice", "Alternative", "Why this one won"],
            [
                ["40 ms per packet", "10 ms", "More packets means more Wi-Fi overhead and more chances "
                 "to lose one; the ESP32 also prefers bigger, rarer writes."],
                ["40 ms per packet", "100 ms", "Noticeable delay and a “walkie-talkie” feel. Sound "
                 "would arrive in lumps."],
                ["16 000 samples/sec", "8 000", "8 kHz sounds muffled and telephone-like; 16 kHz keeps "
                 "voices natural while staying small."],
                ["Raw PCM", "Opus / MP3", "Raw needs no decoding — the board can forward it without "
                 "understanding it, which keeps the ESP32 cheap and the delay low. Opus is the "
                 "obvious upgrade later (section 9)."],
            ],
            [W * 0.20, W * 0.16, W * 0.64],
        ),
        SP(8),
        H2("The queue that saves the conversation"),
        P("Packets do not arrive evenly. Wi-Fi retries, other devices, and the phone’s own "
          "scheduling mean they arrive in little bursts: three at once, then a gap, then two. If "
          "you played each packet the instant it arrived, the speaker would stutter and click."),
        P("So the app keeps a small <b>jitter buffer</b>: a short queue of packets. Playback only "
          "starts once four packets (about 160 ms) are queued, and from then on the app releases "
          "exactly one packet every 40 ms — a metronome. Bursts are absorbed by the queue; the ear "
          "hears smooth speech. If the queue ever runs dry (the network stalled), the app stops, "
          "waits for it to refill, and carries on rather than playing garbage."),
        SP(2),
        CALLOUT("The clever part is what happens when the queue gets too full",
                ["A queue that only grows turns into delay: you would eventually hear the other "
                 "person several seconds late. So the queue has a hard ceiling. When it fills up, "
                 "the <b>oldest</b> audio is thrown away, not the newest. Losing 40 ms of the past "
                 "is unnoticeable; losing the present is a dropped syllable."],
                kind="info"),
        SP(8),
        H2("The delay budget, end to end"),
        TABLE(
            ["Stage", "Typical delay", "Why"],
            [
                ["Microphone fills a block", "10–20 ms", "Hardware block size"],
                ["Chopping into a 40 ms packet", "up to 40 ms", "Must wait for 40 ms of sound to exist"],
                ["Wi-Fi, phone → board", "3–8 ms", "Same room, small packets"],
                ["Board forwards it", "under 1 ms", "It only reads the first byte"],
                ["Wi-Fi, board → phone", "3–8 ms", "Same as above"],
                ["Jitter buffer", "≈160 ms", "The deliberate cushion that keeps playback smooth"],
                ["Speaker plays it", "—", "Continuous"],
                ["<b>Total, mouth to ear</b>", "<b>≈ 200–250 ms</b>", "Comparable to a normal mobile call"],
            ],
            [W * 0.34, W * 0.18, W * 0.48],
        ),
        SP(8),
        CALLOUT("Builder’s note — the three numbers you will want to tune",
                ["They all live in one file, <font face='Mono' size='8'>lib/core/utils/constants.dart</font>, "
                 "and the firmware mirrors them: <b>sample rate</b> (16 000), <b>frame duration</b> "
                 "(40 ms) and <b>prefill frames</b> (4). Change the first two and the packet size "
                 "changes with them — 1280 bytes today — so the firmware must be re-flashed to match. "
                 "Change only the prefill and you trade a little delay for a lot of smoothness."],
                kind="plain"),
        SP(6),
        H2("Mute, and why it is not just a speaker icon"),
        P("Pressing Mute stops packets being created at all — the app discards the microphone data "
          "before it reaches the network. Nothing is sent, so there is nothing to un-mute on the "
          "far side, and the Wi-Fi airtime is freed for the other direction. This is why muting "
          "also visibly drops the “packets sent” counter on the call screen."),
    ]


def section_five() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("5", "Why the first calls sounded bad — and the fix"),
        LEAD("If you have ever held two phones next to each other on a call and heard a howl, you "
             "have met the single hardest problem in speakerphone design. It has a name, a cause, "
             "and a standard cure."),
        SP(4),
        H2("What the problem actually is"),
        P("Your phone has a microphone and a loudspeaker in the same plastic box, centimetres "
          "apart. In a hands-free call the speaker plays the other person’s voice into the room, "
          "and the microphone hears it — along with your own voice — and sends it back. The other "
          "person now hears themselves, slightly late. If it loops repeatedly at a high volume, it "
          "becomes the familiar rising howl."),
        P("A phone company solves this with dedicated hardware and decades of tuning. A VoIP app "
          "gets the same tools, but must switch them on itself. Three things were missing:"),
        TABLE(
            ["Missing piece", "What it sounded like", "What was fixed"],
            [
                ["Echo cancellation not engaged",
                 "Your own voice came back to you, or the other side complained about an echo. On "
                 "speaker, a ringing or howling tone.",
                 "The microphone is now opened as a <b>voice-communication</b> source with the "
                 "platform echo canceller switched on, and the phone is put into voice-call mode. "
                 "Android now actively subtracts what the speaker is playing from what the "
                 "microphone hears."],
                ["Output on the loudspeaker by default",
                 "Everything above, only much worse — the speaker is centimetres from the mic.",
                 "Calls now start on the <b>earpiece</b>, exactly like a normal phone call. The "
                 "loudspeaker is a button you press deliberately."],
                ["No noise suppression",
                 "A constant hiss or hum, fans and air-conditioning, room rumble.",
                 "Noise suppression and automatic gain are enabled on the same capture path."],
                ["Buffers too shallow",
                 "Clicks and crackles every few hundred milliseconds.",
                 "Bigger native buffers and a deeper jitter cushion (section 4)."],
            ],
            [W * 0.26, W * 0.32, W * 0.42],
        ),
        SP(10),
        H2("Earpiece or loudspeaker — now your choice"),
        P("The call screen has three buttons: <b>Mute</b>, <b>Speaker / Earpiece</b>, and the red "
          "hang-up button. The speaker button does the same thing the speaker button does in your "
          "normal phone app: it moves the sound between the small speaker you hold to your ear and "
          "the loud one that fills the room. On the loudspeaker, some echo is normal even on real "
          "phones — the echo canceller keeps it from turning into a howl."),
        SP(4),
        CALLOUT("A note for whoever runs the hardware",
                ["If a call howls even on the earpiece, the cause is usually physical: a "
                 "development board with a small speaker sitting next to its own microphone. Point "
                 "the speaker away from the microphone, lower the volume, or use a headset. No "
                 "software can fix a microphone that is louder than the echo canceller can "
                 "subtract."],
                kind="warn"),
    ]


def section_six() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("6", "The technology, and why each piece was chosen"),
        LEAD("Nine technologies. For each one: what it is in plain words, and the reason it is in "
             "this project rather than something else."),
        SP(6),
        TABLE(
            ["Technology", "What it is, in plain words", "Why it is here"],
            [
                ["Flutter / Dart",
                 "A toolkit for writing one app that runs on Android and iPhone, in a language "
                 "called Dart.",
                 "Fast to build, gives smooth custom screens, and has mature audio plugins. One "
                 "codebase can later serve iOS and even desktop."],
                ["Feature-first Clean Architecture",
                 "A way of arranging files so that the ‘registration’ feature and the ‘call’ "
                 "feature do not tangle, and the database/network details sit behind a wall.",
                 "You can replace the audio library or the socket library without touching the "
                 "screens, and you can test the call logic with no phone attached."],
                ["BLoC (state management)",
                 "A pattern where every screen state is an explicit, named thing — "
                 "<i>Ringing</i>, <i>Active</i>, <i>LineBusy</i>, <i>Ended</i> — and the screen "
                 "simply draws whatever the current state says.",
                 "A phone call is a set of states with strict rules. Named states make impossible "
                 "situations unrepresentable and make every transition testable."],
                ["WebSocket",
                 "A connection that stays open in both directions, so either side can send at any "
                 "moment — unlike a web page that asks and then waits.",
                 "A call needs the server to push (an incoming call, a hang-up) and needs to carry "
                 "audio continuously. It also reuses one connection for messages and audio."],
                ["JSON messages",
                 "Plain text in a widely understood shape, e.g. "
                 "<font face='Mono' size='7.5'>{\"type\":\"make_call\",\"to\":\"User_B\"}</font>.",
                 "Signalling is rare and needs to be readable while debugging on a serial monitor."],
                ["Raw PCM audio",
                 "Sound stored as a straight list of numbers — 16 000 numbers per second, per "
                 "channel, each 2 bytes.",
                 "No decoding means no work on the ESP32 and the lowest possible delay. It is also "
                 "the easiest format to inspect while learning."],
                ["flutter_sound",
                 "The plugin that reaches the phone’s microphone and speaker and streams raw audio "
                 "in and out.",
                 "It can hand you a live stream of microphone bytes and accept a live stream of "
                 "bytes to play — which is exactly the shape this design needs."],
                ["Kotlin + Android AudioManager",
                 "A few dozen lines of native Android code, reached through a small ‘channel’.",
                 "Choosing the earpiece or loudspeaker, and putting the phone into voice-call mode, "
                 "are operating-system decisions that no cross-platform plugin exposes well."],
                ["ESP32 + Arduino C++",
                 "A £5 microcontroller with Wi-Fi built in, programmed with the Arduino IDE.",
                 "It can create its own Wi-Fi network, hold 8 sockets open, and forward ~64 kB/s "
                 "without difficulty. Cheap enough to leave in every room."],
                ["arduinoWebSockets",
                 "An Arduino library that makes the ESP32 behave as a WebSocket server.",
                 "It speaks exactly the protocol the app already uses, in ~50 lines of setup."],
            ],
            [W * 0.19, W * 0.36, W * 0.45],
        ),
        SP(8),
        CALLOUT("Builder’s note — the dependency rule that keeps this scalable",
                ["Inside <font face='Mono' size='8'>lib/features/</font> there are three layers, and "
                 "the arrows only ever point one way: <b>presentation → domain ← data</b>. Screens "
                 "may not import the network or audio code; the audio and socket code may not "
                 "import a screen. The domain layer holds only plain Dart rules and interfaces. "
                 "Follow that, and swapping Opus in, or replacing the ESP32 with a server, stays a "
                 "one-layer change."],
                kind="plain"),
    ]


def section_seven() -> list:
    W = CONTENT_W
    tree = """lib/
├── main.dart                  app starts here; reads the server URL
├── app.dart                   wires the providers and the MaterialApp
├── app_shell.dart             decides which screen to show; owns the busy-line pop-up
├── core/                      shared, feature-agnostic machinery
│   ├── audio/
│   │   ├── ringtone_service.dart     ringback + incoming ringtone (separate player)
│   │   └── audio_route_service.dart  earpiece / loudspeaker / voice-call mode
│   ├── di/injector.dart              the one place objects are constructed
│   ├── errors/                       exceptions (data layer) ↔ failures (user messages)
│   ├── network/websocket_service.dart  connect, ping, auto-reconnect, split text/binary
│   └── utils/constants.dart          ALL the audio + network numbers live here
└── features/
    ├── auth_registration/       FEATURE 1 — claiming a username
    │   ├── data/                socket handshake, ack parsing
    │   ├── domain/              DeviceIdentity + RegisterDeviceUseCase
    │   └── presentation/        RegistrationController + the join screen
    └── voice_call/              FEATURE 2 — everything about a call
        ├── data/
        │   ├── datasources/     call_websocket_source, audio_hardware_source,
        │   │                    pcm_chunker, playback_jitter_buffer
        │   ├── models/          call_signal_model, audio_packet_model
        │   └── repositories/    call_repository_impl  (glues socket + audio together)
        ├── domain/              CallSignal, CallSession, CallRepository interface,
        │                        and 9 use cases (make, answer, mute, speaker…)
        └── presentation/        CallBloc (+ events + states) and the 3 screens

test/                          22 automated tests (no phone needed)
firmware/esp32_voip_router/    the ESP32 sketch
docs/protocol.md               the exact wire format
tools/build_pdf.py             generates this document"""
    return [
        CondPageBreak(330),
        *H1("7", "How the code is organised (and where to change things)"),
        LEAD("The codebase is arranged by what it does, not by what kind of file it is. If you want "
             "to change how a call behaves, you will almost always be in one of five files."),
        SP(6),
        CODE(tree),
        SP(10),
        H2("The shape of a feature"),
        P("Every feature answers the same three questions, in the same three folders:"),
        TABLE(
            ["Folder", "Answers the question", "Example from this project"],
            [
                ["presentation/", "What does the user see, and which intents can they express?",
                 "The dial pad; the press of a button becomes an event on the call controller."],
                ["domain/", "What are the rules, in plain Dart, with no framework?",
                 "“You cannot call yourself.” “A busy line ends in this state.”"],
                ["data/", "How does the outside world actually do it?",
                 "Send this JSON, chop the microphone into 1280-byte frames, play these bytes."],
            ],
            [W * 0.16, W * 0.34, W * 0.50],
        ),
        SP(10),
        H2("Where to go for the change you want to make"),
        TABLE(
            ["I want to…", "Open this", "Notes"],
            [
                ["Change the board’s address or port", "lib/core/utils/constants.dart",
                 "Or pass <font face='Mono' size='7.5'>--dart-define=VOIP_SERVER_URL=…</font> at "
                 "build time — nothing else needs to change."],
                ["Change packet size or sample rate",
                 "constants.dart <i>and</i> the firmware", "They must agree, or the sound will be "
                 "garbled. Re-flash the board."],
                ["Make the ringtone louder / different",
                 "lib/core/audio/ringtone_service.dart, assets/audio/*.wav",
                 "Any 16-bit mono WAV works; the service loops it."],
                ["Add a new signal, e.g. “hold”",
                 "call_signal_model.dart (parse) → call_event.dart → call_bloc.dart",
                 "The model already ignores unknown types safely, so old builds survive."],
                ["Change the busy-line wording or pop-up",
                 "call_bloc.dart (_handleLineBusy) and app_shell.dart",
                 "Wording comes from the board’s message; the pop-up is in app_shell."],
                ["Add a screen", "features/<feature>/presentation/screens/",
                 "Then add a case to the switch in app_shell.dart."],
                ["Touch the microphone or speaker",
                 "data/datasources/audio_hardware_source.dart",
                 "This is the only file that knows which audio library is used. Swapping "
                 "flutter_sound for something else ends here."],
                ["Add an Android-only capability",
                 "android/…/MainActivity.kt + a MethodChannel Dart wrapper",
                 "The pattern is already there for earpiece/loudspeaker — copy it."],
                ["Change the routing logic",
                 "firmware/…/esp32_voip_router.ino",
                 "Registration table, call table, and the one-byte forwarding loop."],
            ],
            [W * 0.22, W * 0.42, W * 0.36],
            mono_cols=(1,),
            mono_size=6.8,
        ),
        SP(8),
        CALLOUT("Builder’s note — the single object that holds a call together",
                ["<font face='Mono' size='8'>CallBloc</font> owns the whole life of a call: the "
                 "socket, the ring tones, the timeout timers and the audio pipeline. Every entry "
                 "point is an explicit event (<font face='Mono' size='8'>CallStarted</font>, "
                 "<font face='Mono' size='8'>CallSignalReceived</font>, "
                 "<font face='Mono' size='8'>CallHungUp</font>, "
                 "<font face='Mono' size='8'>CallLoudspeakerToggled</font>, …) and every outcome is "
                 "an explicit state. If you remember one file, remember this one: it is the map of "
                 "the system’s behaviour."],
                kind="plain"),
    ]


def section_eight() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("8", "When something goes wrong"),
        LEAD("A phone system is judged by how it fails, not by how it works when everything is "
             "fine. Each row below is already handled in the app — the right-hand column is what "
             "to check if you see it and suspect the hardware."),
        SP(6),
        TABLE(
            ["What you see", "What the app does about it", "If you suspect the hardware"],
            [
                ["“Could not reach the router” when joining",
                 "Stops, shows the reason, offers Retry.",
                 "Is the board powered and are you on its Wi-Fi network? Check the serial monitor "
                 "for the listening line."],
                ["Connection badge turns amber, then green",
                 "It is reconnecting on its own, backing off from 0.5 s to 8 s, and re-registers "
                 "the name when it succeeds.",
                 "Ordinary Wi-Fi flakiness. If it never recovers, the board has restarted."],
                ["Call ends with “the Wi-Fi link dropped”",
                 "Ends the call cleanly on both sides rather than leaving dead air.",
                 "Check distance, interference, and the board’s power supply."],
                ["“Please wait, the user is on another call”",
                 "Stops the ring tone at once, shows the pop-up.",
                 "Correct behaviour. The other handset really is in a call."],
                ["“That username is not online”",
                 "Ends the attempt immediately.",
                 "The other phone has not registered — check its connection badge, or its spelling."],
                ["“No answer”", "Gives up after 45 s and tells both sides.",
                 "Is the other handset’s screen on and the app in the foreground?"],
                ["Microphone blocked",
                 "Ends the call and explains that Settings permission is needed, rather than "
                 "silently sending silence.",
                 "Android Settings → Apps → Local VoIP → Permissions → Microphone."],
                ["Choppy or robotic voice",
                 "Drops stale audio to protect delay (never queues it).",
                 "Wi-Fi signal, other traffic on the network, or the board struggling — read the "
                 "<font face='Mono' size='7.5'>[stat]</font> line on the serial monitor."],
                ["Clicks and crackles",
                 "Prefills the jitter buffer deeper before playing.",
                 "Packet loss; move closer to the board or change the Wi-Fi channel."],
                ["A constant howl or whistle",
                 "Echo canceller plus earpiece routing reduces it.",
                 "Physical: speaker too close to microphone, or volume too high (section 5)."],
                ["Chipmunk or slow-motion voices",
                 "Nothing — it is a format mismatch, not a fault.",
                 "The ESP32’s audio interface is not running at 16 000 Hz mono 16-bit."],
            ],
            [W * 0.24, W * 0.38, W * 0.38],
        ),
    ]


def section_nine() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("9", "Growing the project: a realistic roadmap"),
        LEAD("Everything below is ordered by the ratio of value to work. Each entry says what it "
             "buys, what it touches, and how hard it is — so you can pick the next step instead of "
             "rewriting everything."),
        SP(6),
        H2("Stage 1 — make one-to-one calls dependable"),
        TABLE(
            ["Upgrade", "What it buys", "What it touches", "Effort"],
            [
                ["Loopback echo suppression in the firmware",
                 "Removes the last source of self-echo: never send a frame back to its sender "
                 "(except deliberate broadcast).",
                 "Two lines in the sketch’s forward loop.", "Very low"],
                ["Real ESP32 audio (I2S microphone + speaker)",
                 "Turns the demo into a physical intercom in a room.",
                 "A new audio driver in the sketch; nothing in the app changes because the format "
                 "already matches.",
                 "Medium"],
                ["DTMF keypad + ring cadence",
                 "Feels like a phone: dial tones, a two-second ring rhythm.",
                 "ringtone_service.dart plus one sound file.", "Low"],
                ["Call history and a contacts list",
                 "You stop retyping names.",
                 "A new feature folder; a local list is enough to start.", "Low"],
                ["Automatic reconnect mid-call",
                 "A brief Wi-Fi drop no longer kills the call.",
                 "CallBloc gains a “recovering” state; the socket layer already retries.",
                 "Medium"],
            ],
            [W * 0.23, W * 0.32, W * 0.31, W * 0.14],
        ),
        SP(8),
        H2("Stage 2 — better sound for the same network"),
        P("Raw audio is 256 kbit/s per direction. That is what limits how many calls one board "
          "can serve. Compressing it is the single biggest lever — the ESP32 has hardware for "
          "exactly this."),
        TABLE(
            ["Upgrade", "What it buys", "What it touches", "Effort"],
            [
                ["Opus or ADPCM compression",
                 "3–10× less bandwidth: 8–30 kbit/s instead of 256, and more calls per board.",
                 "The audio datasource (encode) and the sketch (decode or pass-through). The "
                 "packet model already carries opaque bytes, so the wire format barely changes.",
                 "Medium–high"],
                ["Adaptive jitter buffer",
                 "Smooth audio on a busy Wi-Fi network without adding delay on a quiet one.",
                 "playback_jitter_buffer.dart — it already has the queue and the ceiling.",
                 "Medium"],
                ["Comfort noise and packet-loss concealment",
                 "A dropped packet becomes a short fade instead of a click.",
                 "The decode step on the receiving side.", "Medium"],
            ],
            [W * 0.23, W * 0.32, W * 0.31, W * 0.14],
        ),
        SP(8),
        H2("Stage 3 — more phones, more rooms"),
        TABLE(
            ["Upgrade", "What it buys", "What it touches", "Effort"],
            [
                ["Many handsets, several simultaneous calls",
                 "Two or three conversations at once in a small office.",
                 "The sketch’s fixed-size call table and its socket loop. The app already "
                 "understands the concept of seat numbers, so it needs no change.",
                 "Medium"],
                ["Conference calls (mix of 3+)",
                 "Group conversation.",
                 "The board must decode, sum and re-encode — this is where Opus, not raw audio, "
                 "becomes mandatory.",
                 "High"],
                ["Several ESP32 boards over one Wi-Fi network",
                 "Coverage across a building; each board serves the rooms nearest to it.",
                 "Board-to-board discovery, or a small server. The app only needs a URL.",
                 "High"],
                ["Movement between boards mid-call",
                 "Walk through the building without dropping the call.",
                 "Session handover; essentially a roaming protocol.", "High"],
            ],
            [W * 0.23, W * 0.32, W * 0.31, W * 0.14],
        ),
        SP(8),
        H2("Stage 4 — security, before anyone else can use it"),
        P("The current design is deliberately open: anyone on the Wi-Fi network can claim any name. "
          "That is fine for a prototype and unacceptable for a product. Do these in order."),
        *NUMBERED([
            "<b>WPA2 on the access point</b> — already the default in the sketch’s "
            "<font face='Mono' size='8'>voip12345</font>; change the password in one line and on "
            "every phone.",
            "<b>Secret token in the register message</b> — a shared string the board checks before "
            "accepting a name. Small change in the sketch, small change in the app; stops casual "
            "name hijacking.",
            "<b>Transport encryption (WSS)</b> — the socket library supports TLS server mode. Costs "
            "a certificate on the board and a URL change from "
            "<font face='Mono' size='8'>ws://</font> to "
            "<font face='Mono' size='8'>wss://</font> in the app.",
            "<b>Per-device credentials</b> — a key per phone, so a lost phone can be revoked "
            "without disturbing the others.",
        ]),
        SP(8),
        H2("Stage 5 — platforms and products"),
        TABLE(
            ["Upgrade", "What it buys", "What it touches", "Effort"],
            [
                ["iOS build",
                 "iPhone users.",
                 "A Swift audio-route handler mirrors the Kotlin one "
                 "(<font face='Mono' size='7.5'>docs/ios-audio-route.md</font> explains the exact "
                 "code); plus a Mac for signing.",
                 "Low–medium"],
                ["Push notifications for missed calls",
                 "An incoming call reaches a phone whose app is closed.",
                 "Needs a small internet server; the ESP32 cannot send push messages.",
                 "High"],
                ["Desktop or tablet screens",
                 "A reception console showing who is on which call.",
                 "Flutter already targets these; mostly layout work.", "Low"],
                ["Record and log calls",
                 "Training, dispute resolution, compliance.",
                 "A WAV writer on the receiving pipeline; mind local consent laws.", "Low"],
            ],
            [W * 0.23, W * 0.32, W * 0.31, W * 0.14],
        ),
        SP(10),
        CALLOUT("The three things that will actually block you, in order",
                ["<b>1. Bandwidth.</b> One uncompressed call is 256 kbit/s each way. Six calls "
                 "would exhaust a small board’s Wi-Fi and its CPU long before its socket table "
                 "fills. Compression is the answer, not a faster board. "
                 "<b>2. Real audio hardware.</b> The sketch deliberately starts with a stub audio "
                 "path so the plumbing can be proven first; a real I2S microphone and amplifier is "
                 "the next physical step. <b>3. Security.</b> The moment the network is not a "
                 "closed prototype, an open registration is a liability. Do Stage 4 before Stage 5, "
                 "not after."],
                kind="warn"),
    ]


GLOSSARY = [
    ("AEC", "Acoustic Echo Cancellation — the algorithm that subtracts what the loudspeaker is "
            "playing from what the microphone hears, so the other side does not hear themselves."),
    ("Access point", "The device that creates a Wi-Fi network. Here the ESP32 is the access point, "
                     "which is why phones connect directly to it with no internet involved."),
    ("Bit rate", "How many bits of audio travel per second. 16 000 samples × 16 bits = "
                 "256 000 bit/s per direction, uncompressed."),
    ("BLoC", "A pattern that keeps the state of a screen as an explicit object. Comes from "
             "“Business Logic Component”."),
    ("Clean Architecture", "Organising code in layers so that rules do not depend on tools. "
                           "Practical effect: you can replace the audio library without touching "
                           "the screens."),
    ("Earpiece / Loudspeaker", "The small speaker you hold to your ear, and the loud one that fills "
                               "a room. The latter is the main cause of echo on a speakerphone."),
    ("Frame / packet", "One fixed slice of audio — here 40 ms of sound — with its own small "
                       "addressing header, sent as one message."),
    ("Full duplex", "Both directions at the same time, like a phone call. The opposite, half "
                    "duplex, is a walkie-talkie: one talks, the other listens."),
    ("Jitter", "The unevenness of packet arrival — some bunched up, some late. Not the same as "
               "delay: a jitter buffer trades a little delay for smoothness."),
    ("Latency", "Total delay from mouth to ear. Under about 250 ms feels natural; above 400 ms "
                "people start talking over each other."),
    ("PCM", "Pulse Code Modulation — sound stored as a plain sequence of amplitude numbers, with no "
            "compression. The WAV format and CDs use it."),
    ("Signalling", "The messages that set a call up and tear it down (call, ring, answer, hang up), "
                   "as opposed to the audio itself."),
    ("SoftAP", "Software access point — a device that behaves as a Wi-Fi router in software. This "
               "is what makes the ESP32 network self-contained."),
    ("WebSocket", "A connection that stays open in both directions. Ideal for anything where the "
                  "server must speak without being asked."),
    ("16 kHz / 16-bit / mono", "16 000 measurements per second, each stored in 2 bytes, one channel "
                               "— the format used for every audio frame in this project."),
]


def section_ten() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("10", "Plain-English glossary"),
        LEAD("The words you are likely to be asked about, in the order they will probably come up."),
        SP(6),
        TABLE(["Term", "Plain English"], [[t, d] for t, d in GLOSSARY], [W * 0.22, W * 0.78]),
    ]


def appendix_a() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("A", "Appendix: the protocol on the wire"),
        LEAD("Every message in the system, exactly as it appears. This is the page to hand to "
             "anyone writing a second client, or to keep beside you when editing the firmware."),
        SP(6),
        H2("Control messages — text frames, one JSON object each"),
        TABLE(
            ["Direction", "Message", "Meaning"],
            [
                ["App → board", '{"type":"register","from":"User_A"}',
                 "Claim a name. Must be the first message after connecting."],
                ["Board → app", '{"type":"registered","id":3,"name":"User_A"}',
                 "Accepted; the id is this handset’s seat number, the first byte of every audio "
                 "frame it sends."],
                ["App → board", '{"type":"make_call","from":"User_A","to":"User_B"}',
                 "Ask to be connected."],
                ["Board → callee", '{"type":"incoming_call","from":"User_A","id":1}',
                 "Ring; id is the caller’s seat number, so the answer audio has somewhere to go."],
                ["Board → caller", '{"type":"call_ringing"}',
                 "The callee’s phone is ringing — start the ringback tone."],
                ["App → board", '{"type":"call_accept"}',
                 "The callee is ready; the bridge may open."],
                ["Board → both", '{"type":"call_answered","id":2}',
                 "The call is connected; id is the far end’s seat number."],
                ["App → board", '{"type":"call_reject"}',
                 "Decline. The caller returns to the dial pad."],
                ["Board → caller", '{"type":"call_rejected"}',
                 "The callee declined."],
                ["App → board", '{"type":"end_call"}',
                 "Hang up. Valid from ringing or active."],
                ["Board → other", '{"type":"call_ended"}',
                 "The far end hung up, or the link dropped."],
                ["Board → caller", '{"type":"line_busy"}',
                 "The callee is already in a call. Undismissable requirement: the app must stop "
                 "ringing and show the exact sentence the board supplies."],
                ["Board → caller", '{"type":"peer_unavailable"}',
                 "No handset is registered under that name."],
                ["Board → app", '{"type":"error","message":"…"}',
                 "Something the board could not parse or accept."],
            ],
            [W * 0.16, W * 0.44, W * 0.40],
            mono_cols=(1,),
            mono_size=6.8,
        ),
        SP(10),
        H2("Audio messages — binary frames"),
        *BULLETS([
            "<b>Outbound</b> (app → board): <b>1 byte</b> target seat number, then <b>1280 bytes</b> "
            "of PCM. Total 1281 bytes, 25 times per second.",
            "<b>Inbound</b> (board → app): <b>1280 bytes</b> of PCM with no header; the board has "
            "already stripped the target byte and knows who the sender is.",
            "Target <b>0</b> means “everyone” — used only for testing.",
            "PCM layout: little-endian signed 16-bit, mono, 16 000 Hz. 40 ms = 640 samples = 1280 "
            "bytes.",
            "The app ignores incoming audio addressed to any seat except its own (or 0), which is "
            "what stops two calls in the same room bleeding into each other.",
        ]),
        SP(8),
        H2("Connection rules"),
        *BULLETS([
            "The board listens on port <b>81</b> and creates the network "
            "<b>ESP32-VOIP</b> (password <b>voip12345</b>).",
            "A handset has <b>2 seconds</b> after connecting to send <font face='Mono' size='8'>"
            "register</font>, or the board closes the socket.",
            "Names are unique while in use: a second registration of the same name is refused.",
            "Up to <b>8</b> handsets, <b>1</b> simultaneous call in the current sketch.",
            "A ping/heartbeat keeps idle sockets from being reaped; the app reconnects "
            "automatically and re-registers.",
        ]),
    ]


def appendix_b() -> list:
    W = CONTENT_W
    return [
        CondPageBreak(330),
        *H1("B", "Appendix: build it, verify it"),
        LEAD("The exact commands, in order, from a clean machine to an installed app. This is also "
             "the checklist to repeat after any change."),
        SP(6),
        H2("Flutter app"),
        CODE("""flutter --version                 # 3.47.9 stable or newer, Dart 3.13+
flutter pub get
flutter analyze                   # must print: No issues found!
flutter test                      # must print: All tests passed!  (22 tests)

# run on a phone plugged in over USB (this is the fastest loop)
flutter run

# or build an installable file, for phones with a 64-bit ARM chip
flutter build apk --release --target-platform=android-arm64
#   → build/app/outputs/flutter-apk/app-release.apk

# point the app at a different board without editing any code
flutter build apk --release --target-platform=android-arm64 \\
  --dart-define=VOIP_SERVER_URL=ws://192.168.4.1:81"""),
        SP(8),
        H2("Checking the build is what you think it is"),
        CODE("""# version number and permissions baked into the APK
aapt2 dump badging app-release.apk | head -3
#   package: name='com.example.esp32_voip' versionCode='2' versionName='1.1.0'

# signature, so you know it will install
apksigner verify --print-certs app-release.apk"""),
        SP(8),
        H2("Firmware"),
        CODE("""1. Arduino IDE → Boards Manager → install "esp32" by Espressif
2. Library Manager → install "WebSockets" by Markus Sattler
3. Board: "ESP32 Dev Module"; open firmware/esp32_voip_router/esp32_voip_router.ino
4. Set the real audio pins in the configuration block at the top
5. Upload, then open the Serial Monitor at 115200 baud
6. Look for:  AP started: ESP32-VOIP   and   WebSocket server on port 81"""),
        SP(8),
        H2("The ten-minute acceptance test"),
        *NUMBERED([
            "Join the phone to <b>ESP32-VOIP</b> and open the app; the badge turns green.",
            "Register as <b>User_A</b>; the board’s serial monitor shows the name and a seat number.",
            "Second phone, second name. Dial the first; it rings within a second.",
            "Answer. Speak: audio is clear <b>and you do not hear yourself</b>.",
            "Press <b>Speaker</b>: the voice moves to the loudspeaker. Press again to return.",
            "Press <b>Mute</b>: the far side goes silent. Un-mute: it returns.",
            "Hang up from either side; both return to the dial pad.",
            "Call a name that is not registered: “not online”, immediately.",
            "Start a call from a third phone to a busy one: the pop-up reads exactly "
            "<i>“Please wait, the user is on another call.”</i> and the ring tone has stopped.",
            "Turn the board off mid-call: the call ends with a clear message, and the app "
            "reconnects by itself when the board returns.",
        ]),
        SP(10),
        H2("Kitchen-table cheat sheet"),
        P("Everything you need to run this tomorrow morning, on one card:"),
    ] + [
        TABLE(
            ["The system", "The numbers that matter"],
            [
                ["Wi-Fi network the board creates",
                 "<font face='Mono' size='7.5'>ESP32-VOIP</font> \u00b7 password "
                 "<font face='Mono' size='7.5'>voip12345</font>"],
                ["Address the app dials",
                 "<font face='Mono' size='7.5'>ws://192.168.4.1:81</font> \u2014 the board is "
                 "always 192.168.4.1 when it runs its own network"],
                ["Audio format",
                 "16\u202f000 samples/sec \u00b7 16-bit \u00b7 mono \u00b7 40 ms frames \u00b7 "
                 "1280 bytes + 1 byte address"],
                ["Bandwidth per call",
                 "\u2248 256 kbit/s each way \u00b7 25 packets per second"],
                ["Delay, mouth to ear", "\u2248 200\u2013250 ms, mostly the 160 ms jitter cushion"],
                ["Call states the app can be in",
                 "Initial \u00b7 Ringing \u00b7 Active \u00b7 LineBusy \u00b7 Ended"],
                ["Two things that must be flashed together",
                 "The sample rate and the frame size \u2014 app and firmware must agree"],
            ],
            [W * 0.40, W * 0.60],
        ),
        SP(8),
        CALLOUT("And if you only remember one thing",
                ["A call is <b>not</b> a stream of audio that happens to be arranged. It is a "
                 "<b>conversation about who is talking to whom</b> \u2014 a handful of short "
                 "messages \u2014 and then a very simple, very fast pipe that carries numbers "
                 "between two seats. Get the conversation right and the audio has somewhere to go; "
                 "get it wrong, and no amount of audio engineering will save the call."],
                kind="good"),
    ]


# ---------------------------------------------------------------------------
# Document assembly
# ---------------------------------------------------------------------------
def build(out_path: str) -> None:
    doc = BaseDocTemplate(
        out_path,
        pagesize=A4,
        leftMargin=MARGIN, rightMargin=MARGIN,
        topMargin=MARGIN + 22, bottomMargin=MARGIN + 18,
        title="Talking Over Thin Air — Local Wi-Fi VoIP over an ESP32",
        author="Local VoIP project",
        subject="How the ESP32 + Flutter voice-call system works, and how to grow it",
        creator="tools/build_pdf.py",
    )

    cover_frame = Frame(MARGIN, MARGIN, CONTENT_W, PAGE_H - 2 * MARGIN - 40,
                        leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0,
                        id="cover")
    body_frame = Frame(MARGIN, MARGIN, CONTENT_W, PAGE_H - 2 * MARGIN - 40,
                       leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0,
                       id="body")

    doc.addPageTemplates([
        PageTemplate(id="cover", frames=[cover_frame], onPage=cover_page),
        PageTemplate(id="body", frames=[body_frame], onPage=body_page),
    ])

    story = []
    story += cover_story()
    story += contents_story()
    story += section_one()
    story += section_two()
    story += section_three()
    story += section_four()
    story += section_five()
    story += section_six()
    story += section_seven()
    story += section_eight()
    story += section_nine()
    story += section_ten()
    story += appendix_a()
    story += appendix_b()

    doc._show_page_number = True
    doc.build(story)
    return out_path


def scan_pages(pdf_path: str) -> dict:
    """Map every section label to the page it starts on."""
    import re as _re
    import pymupdf                      # only needed for this bookkeeping pass
    found = {}
    with pymupdf.open(pdf_path) as doc:
        for index, page in enumerate(doc, start=1):
            for m in _re.finditer(r"SECTION ([0-9]+|[AB])\b", page.get_text()):
                found.setdefault(m.group(1), str(index))
    return found


def build_with_contents(out_path: str) -> None:
    tmp = out_path + ".tmp.pdf"
    PAGES.clear()
    build(tmp)                          # pass 1: placeholders, layout is final
    PAGES.update(scan_pages(tmp))
    build(out_path)                     # pass 2: real page numbers in the contents
    if os.path.exists(tmp):
        os.remove(tmp)
    missing = [k for k in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "A", "B"]
               if k not in PAGES]
    print("pages:", PAGES, "missing:", missing or "none")
    print(f"wrote {out_path}  ({os.path.getsize(out_path) / 1024:.0f} KB)")


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "docs", "ESP32_VoIP_Project_Guide.pdf")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build_with_contents(os.path.normpath(out))
