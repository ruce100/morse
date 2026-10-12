#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Morse code decoder and encoder - the Python twin of morse_decode.ps1.

The reverse of morse.ps1 (text -> timed dots/dashes): reads Morse code back
into uppercase text.  Accepts both the classic symbols ( . - ) and the
visual symbols morse.ps1 prints (dot / dash glyphs), and auto-detects the
two common ways of writing Morse.  The character set is morse.ps1's table
plus the ITU-R M.1677-1 punctuation marks, plus common practice for
non-ITU symbols (! & ; _ $):

  explicit layout   ".... . .-.. .-.. --- / .-- --- .-. .-.. -.."
                    one space between letters, "/" between words
  gap layout        what morse.ps1 prints: 1 space between the symbols of
                    a letter, 3 between letters, 10 between words

Examples:
    python morse.py ".... . .-.. .-.. --- / .-- --- .-. .-.. -.."
    python morse.py -m gap "<visual morse pasted from morse.ps1>"
    python morse.py -f raw_output.txt
    type raw_output.txt | python morse.py
    python morse.py --encode "HELLO WORLD"      # text -> visual morse
    python morse.py --self-test
"""
import argparse
import io
import re
import sys

# anything in DOTS reads as "." and anything in DASHES reads as "-"
# (an actual underscore is a real character - ..--.- - not a dash variant)
DOTS = set(".\u00b7\u2022\u2024\u2219\u25cf\u25e6\uff0e")
DASHES = set("-\u2010\u2011\u2012\u2013\u2014\u2015\u2212\uff0d")

# the symbols morse.ps1 itself prints (used as a style hint)
VISUAL = set("\u25cf\u2022\u25e6\u2015\u2500")

# ---- character table: morse.ps1's set + the ITU-R M.1677-1 punctuation ----
# ---- marks + common practice for non-ITU symbols (! & ; _ $) ---------------
CODE = {
    "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.",
    "G": "--.", "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..",
    "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
    "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
    "Y": "-.--", "Z": "--..",
    "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....",
    "6": "-....", "7": "--...", "8": "---..", "9": "----.", "0": "-----",
    "?": "..--..", "!": "-.-.--", ".": ".-.-.-", ",": "--..--", "'": ".----.",
    ":": "---...", "+": ".-.-.", "-": "-....-", "/": "-..-.", "(": "-.--.",
    ")": "-.--.-", "&": ".-...", ";": "-.-.-.", "=": "-...-", "_": "..--.-",
    '"': ".-..-.", "$": "...-..-", "@": ".--.-.",
    "*": "-..-", "\u00f7": "-..-.",
}

# reverse table (morse -> character); on collisions the more standard
# character wins: letters/digits > ASCII punctuation > other symbols
# (-..- is X/* -> X;  -..-. is / and the division sign -> /)
def _char_rank(c: str) -> int:
    if c.isalnum() and c.isascii():
        return 0
    return 1 if c.isascii() else 2


MORSE2CHAR = {}
for _ch, _m in CODE.items():
    _cur = MORSE2CHAR.get(_m)
    if _cur is None or _char_rank(_ch) < _char_rank(_cur):
        MORSE2CHAR[_m] = _ch


def normalize(text):
    """Map every accepted dot/dash variant to plain '.' or '-'."""
    out = []
    for c in text:
        if c == "\r" or c == "\ufeff":
            continue
        if c in DOTS:
            out.append(".")
        elif c in DASHES:
            out.append("-")
        else:
            out.append(c)
    return "".join(out)


def parse_morse(s, intra_max, letter_max):
    """Decode a normalized string, using gap widths to tell levels apart.

    intra_max  - longest space run still inside one letter
    letter_max - longest space run still between two letters; longer = word
    """
    out = []
    buf = []
    unknown = []

    def close_letter():
        if not buf:
            return
        token = "".join(buf)
        buf.clear()
        ch = MORSE2CHAR.get(token)
        if ch is None:
            unknown.append(repr(token))
            out.append("?")
        else:
            out.append(ch)

    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c.isspace():
            j = i
            while j < n and s[j].isspace():
                j += 1
            run = j - i
            if buf and run > intra_max:
                close_letter()
                if run > letter_max and out and out[-1] != " ":
                    out.append(" ")
            i = j
        elif c == "/":
            close_letter()
            if out and out[-1] != " ":
                out.append(" ")
            i += 1
        elif c in ".-":
            buf.append(c)
            i += 1
        else:                       # anything else: report and keep going
            unknown.append(f"junk {c!r}")
            out.append("?")
            i += 1
    close_letter()
    return "".join(out).strip(), unknown


def preferred_mode(raw):
    """Guess which layout was pasted (mirrors Get-PreferredLayout in PS)."""
    if "/" in raw:
        return "explicit"
    if any(c in VISUAL for c in raw):
        return "gap"
    for chunk in raw.split():
        symbols = [c for c in chunk if c in DOTS or c in DASHES]
        if len(symbols) >= 2:
            return "explicit"
    if any(m.end() - m.start() >= 2 for m in re.finditer(r"\s+", raw)):
        return "gap"
    return "explicit"


def decode(raw, mode="auto", verbose=False):
    """Decode Morse text.  Returns (text, list_of_unknown_tokens)."""
    norm = normalize(raw)
    e_text, e_unk = parse_morse(norm, intra_max=0, letter_max=2)  # explicit layout
    g_text, g_unk = parse_morse(norm, intra_max=1, letter_max=4)  # gap layout

    pref = preferred_mode(raw)
    if mode == "auto":
        if len(e_unk) != len(g_unk):
            chosen = "explicit" if len(e_unk) < len(g_unk) else "gap"
        else:
            chosen = pref
    else:
        chosen = mode

    if chosen == "explicit":
        text, unknown, alt_text, alt_unk = e_text, e_unk, g_text, g_unk
    else:
        text, unknown, alt_text, alt_unk = g_text, g_unk, e_text, e_unk

    if verbose:
        print(f"[morse] mode={chosen} (auto preference: {pref})", file=sys.stderr)
        print(f"[morse] unknown counts: explicit={len(e_unk)} gap={len(g_unk)}", file=sys.stderr)
        if unknown:
            print("[morse] unknown: " + ", ".join(unknown), file=sys.stderr)
        if alt_text.strip() and alt_text.strip() != text:
            marker = "" if alt_unk else "   (that reading has no errors)"
            other = "gap" if chosen == "explicit" else "explicit"
            print(f"[morse] alternative ({other} layout): {alt_text.strip()}{marker}", file=sys.stderr)
    return text, unknown


def encode_visual(text):
    """Encode to exactly what morse.ps1 prints (1/3/10-space gaps)."""
    parts = []
    for ch in text.upper():
        morse = CODE.get(ch)
        if morse is None:
            parts.append(" " * 7)          # like morse.ps1: word gap for spaces/unknown
        else:
            parts.append(" ".join("\u25cf" if s == "." else "\u2015" for s in morse) + "   ")
    return "".join(parts)


def encode_plain(text):
    """Encode to the classic written form: ".... . .-.. .-.. --- / ..."."""
    words = []
    for word in text.upper().split():
        tokens = [CODE[c] for c in word if c in CODE]
        words.append(" ".join(tokens))
    return " / ".join(w for w in words if w)


def self_test():
    checks = []

    def check(name, got, expected):
        checks.append((name, got, expected))

    # 1. every symbol round-trips through both layouts
    shared = {"*": "X", "\u00f7": "/"}      # -..- is X/*; -..-. is /, division sign
    for ch in CODE:
        expected = shared.get(ch, ch)
        check(f"visual {ch}", decode(encode_visual(ch))[0], expected)
        check(f"plain  {ch}", decode(encode_plain(ch))[0], expected)

    # 2. every symbol at once, no spaces
    full = "".join(c for c in CODE if c not in shared)
    check("visual all", decode(encode_visual(full))[0], full)
    check("plain  all", decode(encode_plain(full))[0], full)

    # 3. sentences / word gaps
    sentence = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789"
    check("visual sentence", decode(encode_visual(sentence))[0], sentence)
    check("plain  sentence", decode(encode_plain(sentence))[0], sentence)

    # 4. classic pasted layouts
    check("explicit hello",
          decode(".... . .-.. .-.. --- / .-- --- .-. .-.. -..")[0], "HELLO WORLD")
    check("explicit words 3-spaces",
          decode(".... . .-.. .-.. ---   .-- --- .-. .-.. -..")[0], "HELLO WORLD")
    check("gap hello", decode(encode_visual("HELLO"))[0], "HELLO")
    check("gap sos 42", decode(encode_visual("SOS 42"))[0], "SOS 42")
    check("gap dotty sentence",
          decode(encode_visual("HELLO DOTTY. HOW ARE YOU TODAY?"))[0],
          "HELLO DOTTY. HOW ARE YOU TODAY?")
    challenge = ". , ? ' ! / ( ) & : ; = - _ \" $ @"
    check("challenge visual", decode(encode_visual(challenge))[0], challenge)
    check("challenge plain", decode(encode_plain(challenge))[0], challenge)
    check("challenge compact",
          decode(encode_visual(challenge.replace(" ", "")))[0],
          challenge.replace(" ", ""))

    # 5. error handling
    text, unknown = decode("........")
    check("unknown -> ?", text, "?")
    check("unknown counted", len(unknown) >= 1, True)
    text, unknown = decode(".- x -...")
    check("junk char reported", bool(unknown), True)
    check("junk char placeholder", "A" in text and "B" in text, True)

    failed = [(n, g, x) for n, g, x in checks if g != x]
    for name, got, expected in failed:
        print(f"FAIL {name}: got {got!r}, expected {expected!r}")
    print(f"self-test: {len(checks) - len(failed)}/{len(checks)} checks passed")
    return 1 if failed else 0


def read_input(args):
    if args.file:
        with open(args.file, encoding="utf-8-sig") as fh:
            return fh.read()
    if args.morse:
        return " ".join(args.morse)
    if not sys.stdin.isatty():
        return sys.stdin.read()
    try:
        return input("Enter morse code to read: ")
    except EOFError:
        return ""


def main(argv=None):
    # Make console/file redirection survive non-UTF-8 defaults.  reconfigure()
    # only exists on real TextIOWrapper streams (not on None, or on replacers
    # such as pytest's), hence the isinstance guard.
    try:
        for stream in (sys.stdout, sys.stderr):
            if isinstance(stream, io.TextIOWrapper):
                stream.reconfigure(encoding="utf-8")
        if isinstance(sys.stdin, io.TextIOWrapper):
            sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    parser = argparse.ArgumentParser(
        description="Decode (or encode) Morse code. Reverse of morse.ps1.")
    parser.add_argument("morse", nargs="*",
                        help="morse code string(s), joined with spaces")
    parser.add_argument("-m", "--mode", choices=("auto", "explicit", "gap"),
                        default="auto", help="layout of the input (default: auto-detect)")
    parser.add_argument("-f", "--file", help="read morse code from a text file")
    parser.add_argument("-e", "--encode", metavar="TEXT",
                        help="encode TEXT to morse instead of decoding (- reads stdin)")
    parser.add_argument("--style", choices=("visual", "plain"), default="visual",
                        help="output style for --encode (default: visual)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="explain how the input was interpreted")
    parser.add_argument("--strict", action="store_true",
                        help="exit with code 2 when unknown morse sequences are found")
    parser.add_argument("--self-test", action="store_true",
                        help="run built-in round-trip tests")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    if args.encode is not None:
        text = args.encode
        if text == "-":                     # read from stdin (PowerShell 5.1 pipes)
            text = sys.stdin.read().rstrip("\r\n")
        print(encode_visual(text) if args.style == "visual"
              else encode_plain(text))
        return 0

    raw = read_input(args)
    if not raw.strip():
        print("nothing to decode", file=sys.stderr)
        return 0

    text, unknown = decode(raw, args.mode, args.verbose)

    if args.strict and unknown:
        print(f"morse: {len(unknown)} unknown sequence(s): {', '.join(unknown)}",
              file=sys.stderr)
        return 2

    print(text)
    if unknown:
        print(f"morse: warning - {len(unknown)} unknown sequence(s) decoded as '?' "
              f"({', '.join(unknown)})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
