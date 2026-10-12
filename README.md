# morse — text ⇄ Morse code

| file | purpose |
|---|---|
| `morse.ps1` | text → plays Morse on screen (dots/dashes with 1/3/10-unit gaps). The original script. |
| `morse_decode.ps1` | PowerShell: Morse → text (the reverse of `morse.ps1`). |
| `morse.py` | Python: the same decoder, plus an encoder and a self-test. |

## Decode with PowerShell

```powershell
# classic written Morse (one space between letters, "/" between words)
.\morse_decode.ps1 -Morse ".... . .-.. .-.. --- / .-- --- .-. .-.. -.."   # HELLO WORLD

# decode exactly what morse.ps1 printed (visual symbols + 1/3/10-space gaps)
$raw = (& .\morse.ps1 "HELLO WORLD" 6>&1 | ForEach-Object ToString) -join ""
.\morse_decode.ps1 -Morse $raw

# from a file, or interactively
.\morse_decode.ps1 -FromFile raw.txt
.\morse_decode.ps1
```

Options: `-Mode auto|explicit|gap` to force an interpretation, `-Detail` for a report,
`-Prosigns` to prefer the prosign reading for groups that share a pattern with punctuation.

## Decode with Python

```bash
python morse.py ".... . .-.. .-.. --- / .-- --- .-. .-.. -.."    # HELLO WORLD
python morse.py -m gap -f raw.txt
type raw.txt | python morse.py
python morse.py --encode "SOS 42"        # -> visual Morse, same as morse.ps1 prints
python morse.py --encode --style plain "SOS 42"   # -> "... --- ... / ....- ..---"
python morse.py --encode -               # encode text piped via stdin
python morse.py "...---..."              # SOS (prosign group, gapless)
python morse.py --prosigns ".-.-."       # AR  (default reads it as +)
python morse.py --encode --prosigns "SOS"   # formal single-signal form, no letter gaps
python morse.py --self-test
```

> Quoting tip: Windows PowerShell 5.1 truncates a native argument at an embedded
> `"`, so use the stdin form there —
> `'. , ? '' ! / ( ) & : ; = - _ " $ @' | python morse.py --encode -`
> (PowerShell 7 accepts the quoted form directly; cmd.exe wants the quote
> doubled: `--encode ". , ? ' ! ( ) & : ; = - _ "" $ @"`).

> Windows PowerShell 5.1 tip: piping between the two `python` commands mangles
> the ●/― glyphs unless UTF-8 is enabled first —
> `[Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8`
> (cmd, bash and PowerShell 7 pipe fine as-is).

## What it understands

* classic symbols `.` `-` (and variants `· – — − …`) as well as the visual
  symbols `●` `―` that `morse.ps1` prints
* the full punctuation set: the ITU-R M.1677-1 marks
  (`.` `,` `?` `'` `/` `(` `)` `"` `=` `-` `:` `@` …) and the common
  extensions (`!` `&` `;` `_` `$`), plus the original script's `*` and `÷`.
  An actual underscore is a character (`..--.-`) — no longer a dash variant.
* prosigns — letter groups keyed as one continuous character, no letter gaps:
  `...---...` → SOS (the distress signal's formal single-signal form,
  47 CFR §80.314), `...-.-` → SK, `-.-.-` → KA, `...-.` → VE, `........` → HH
  (error).  With `--prosigns` / `-Prosigns`, `.-.-.` `-...-` `.-...` `-.--.`
  read as AR, BT, AS, KN instead of `+` `=` `&` `(`; `--encode --prosigns "SOS"`
  emits the gapless single-signal form.
* **explicit layout** — one space between letters, `/` (or 3+ spaces) between words
* **gap layout** — raw `morse.ps1` output: 1 space between the symbols inside a
  letter, 3 between letters, 10 between words
* auto-detects which layout you pasted; `-Mode` / `--mode` forces one when both
  readings are plausible (`-Detail` / `-v` shows the alternative reading)

## Known limits

* `-..-` is both `X` and `*` in `morse.ps1` and `-..-.` is both `/` and `÷`;
  decoding returns the standard character (`X`, `/`).
* characters `morse.ps1` has no code for (e.g. `#`) were played as a word gap,
  so decoding cannot bring them back.
* unknown Morse sequences decode as `?`; Python `--strict` exits with code 2
  instead of printing.
