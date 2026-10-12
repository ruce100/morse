<#
.SYNOPSIS
    Morse code decoder - the reverse of morse.ps1.

.DESCRIPTION
    Reads Morse code and converts it back to uppercase text.

    Accepts the classic symbols ( . - ) as well as the visual symbols that
    morse.ps1 prints (dot / dash glyphs), and both common ways of writing
    Morse:

      explicit layout   ".... . .-.. .-.. --- / .-- --- .-. .-.. -.."
                        one space between letters, "/" between words

      gap layout        exactly what morse.ps1 prints: 1 space between the
                        symbols inside one letter, 3 spaces between letters,
                        10 spaces between words

    The layout is auto-detected; -Mode can force one.  Unknown sequences
    decode as "?" (use -Detail to see what was not understood).

.PARAMETER Morse
    Morse text to decode.  If omitted it is read from stdin (when piped)
    or asked for interactively.

.PARAMETER Mode
    auto (default), explicit or gap.

.PARAMETER FromFile
    Read the Morse text from a file instead (UTF-8).

.PARAMETER Detail
    Print how the input was interpreted, and the alternative reading when
    the two layouts disagree.

.PARAMETER Prosigns
    Decode prosign groups (letter groups keyed as one continuous character).
    ...---... decodes to SOS, ...-.- to SK, -.-.- to KA, ...-. to VE and
    ........ to HH.  With -Prosigns the conflicting groups win over the
    punctuation they share a pattern with: .-.-. AR (not +), -...- BT
    (not =), .-... AS (not &), -.--. KN (not ().

.EXAMPLE
    .\morse_decode.ps1 -Morse ".... . .-.. .-.. --- / .-- --- .-. .-.. -.."
    HELLO WORLD

.EXAMPLE
    $raw = (& .\morse.ps1 "SOS" 6>&1 | ForEach-Object ToString) -join ""
    .\morse_decode.ps1 -Morse $raw
#>
param(
    [string]$Morse = "",

    [ValidateSet('auto', 'explicit', 'gap')]
    [string]$Mode = 'auto',

    [string]$FromFile = "",

    [switch]$Detail,

    [switch]$Prosigns
)

Set-StrictMode -Version Latest

# ---- character table: morse.ps1's set + the ITU-R M.1677-1 punctuation ----
# ---- marks + common practice for non-ITU symbols (! & ; _ $) ---------------
$CodeTable = [ordered]@{
    'A' = '.-';     'B' = '-...';   'C' = '-.-.';   'D' = '-..'
    'E' = '.';      'F' = '..-.';   'G' = '--.';    'H' = '....'
    'I' = '..';     'J' = '.---';   'K' = '-.-';    'L' = '.-..'
    'M' = '--';     'N' = '-.';     'O' = '---';    'P' = '.--.'
    'Q' = '--.-';   'R' = '.-.';    'S' = '...';    'T' = '-'
    'U' = '..-';    'V' = '...-';   'W' = '.--';    'X' = '-..-'
    'Y' = '-.--';   'Z' = '--..'
    '1' = '.----';  '2' = '..---';  '3' = '...--';  '4' = '....-'
    '5' = '.....';  '6' = '-....';  '7' = '--...';  '8' = '---..'
    '9' = '----.';  '0' = '-----'
    '?' = '..--..'; '!' = '-.-.--'; '.' = '.-.-.-'; ',' = '--..--'
    "'" = '.----.'; ':' = '---...'; '+' = '.-.-.';  '-' = '-....-'
    '/' = '-..-.';  '(' = '-.--.';  ')' = '-.--.-'; '&' = '.-...'
    ';' = '-.-.-.'; '=' = '-...-';  '_' = '..--.-'; '"' = '.-..-.'
    '$' = '...-..-'; '@' = '.--.-.'; '*' = '-..-'
}
$CodeTable[[string][char]0x00F7] = '-..-.'    # division sign

# reverse table (morse -> character); on collisions the more standard
# character wins: letters/digits > ASCII punctuation > other symbols
# (-..- is X/* -> X;  -..-. is / and the division sign -> /)
function Get-CharacterRank {
    param([string]$Character)
    if ($Character -cmatch '^[A-Za-z0-9]$') { return 0 }
    if ([int][char]$Character -le 127) { return 1 }
    return 2
}

$Reverse = @{}
foreach ($entry in $CodeTable.GetEnumerator()) {
    $sequence  = [string]$entry.Value
    $character = [string]$entry.Key
    $rank      = Get-CharacterRank $character
    if (-not $Reverse.ContainsKey($sequence)) {
        $Reverse[$sequence] = $character
    }
    elseif ($rank -lt (Get-CharacterRank $Reverse[$sequence])) {
        $Reverse[$sequence] = $character
    }
}

# prosigns: letter groups keyed as ONE character (no letter gaps).  The
# default set shares no pattern with a single character; AR/BT/AS/KN share
# their pattern with + = & ( and only win when -Prosigns is given.
$AllProsigns = @{
    '...---...' = 'SOS'    # distress signal - transmitted as a single signal
    '...-.-'    = 'SK'     # end of work
    '-.-.-'     = 'KA'     # starting signal
    '...-.'     = 'VE'     # understood
    '........'  = 'HH'     # error (eight dots)
    '.-.-.'     = 'AR'     # end of message / over
    '-...-'     = 'BT'     # separator
    '.-...'     = 'AS'     # wait
    '-.--.'     = 'KN'     # go ahead, specific station only
}
$DefaultProsigns = @{}
foreach ($entry in $AllProsigns.GetEnumerator()) {
    if (-not $Reverse.ContainsKey([string]$entry.Key)) {
        $DefaultProsigns[[string]$entry.Key] = [string]$entry.Value
    }
}

# symbol sets the decoder accepts
$script:DotChars    = @(0x2E, 0xB7, 0x2022, 0x2024, 0x2219, 0x25CF, 0x25E6, 0xFF0E) | ForEach-Object { [char]$_ }
$script:DashChars   = @(0x2D, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0x2500, 0xFF0D) | ForEach-Object { [char]$_ }   # no 0x5F: "_" is a real character (..--.-), not a dash
$script:VisualChars = @(0x25CF, 0x2022, 0x25E6, 0x2015, 0x2500) | ForEach-Object { [char]$_ }

function ConvertTo-MorseSymbols {
    param([string]$Text)
    $Text = $Text.Replace("`r", '')
    $Text = $Text.Replace([string][char]0xFEFF, '')   # UTF-8 BOM (e.g. from PS 5.1 pipes)
    foreach ($symbol in $script:DotChars)  { $Text = $Text.Replace([string]$symbol, '.') }
    foreach ($symbol in $script:DashChars) { $Text = $Text.Replace([string]$symbol, '-') }
    return $Text
}

function Test-MorseSymbol {
    param([char]$Char)
    return ($script:DotChars -contains $Char) -or ($script:DashChars -contains $Char)
}

function Close-LetterGroup {
    param(
        [System.Text.StringBuilder]$Buffer,
        [System.Text.StringBuilder]$Out,
        [System.Collections.Generic.List[string]]$Unknown,
        [System.Collections.Generic.List[string]]$Notes,
        [bool]$ProsignMode
    )
    if ($Buffer.Length -eq 0) { return }
    $sequence = $Buffer.ToString()
    [void]$Buffer.Clear()
    $table = $script:DefaultProsigns
    if ($ProsignMode) { $table = $script:AllProsigns }
    if ($table.ContainsKey($sequence)) {
        [void]$Out.Append([string]$table[$sequence])
        $Notes.Add([string]$table[$sequence])
    }
    elseif ($Reverse.ContainsKey($sequence)) {
        [void]$Out.Append($Reverse[$sequence])
    }
    else {
        $Unknown.Add("'$sequence'")
        [void]$Out.Append('?')
    }
}

# Decode a normalized string, using gap widths to tell the levels apart:
#   IntraMax  - longest space run still inside one letter
#   LetterMax - longest space run still between two letters; longer = word
function Invoke-MorseParse {
    param([string]$Text, [int]$IntraMax, [int]$LetterMax, [bool]$ProsignMode)

    $out     = New-Object System.Text.StringBuilder
    $buffer  = New-Object System.Text.StringBuilder
    $unknown = New-Object 'System.Collections.Generic.List[string]'
    $notes   = New-Object 'System.Collections.Generic.List[string]'

    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ([char]::IsWhiteSpace($c)) {
            $j = $i
            while ($j -lt $Text.Length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            $run = $j - $i
            if ($buffer.Length -gt 0 -and $run -gt $IntraMax) {
                Close-LetterGroup $buffer $out $unknown $notes $ProsignMode
                if ($run -gt $LetterMax) { [void]$out.Append(' ') }
            }
            $i = $j
        }
        elseif ($c -eq '/') {
            Close-LetterGroup $buffer $out $unknown $notes $ProsignMode
            [void]$out.Append(' ')
            $i++
        }
        elseif ($c -eq '.' -or $c -eq '-') {
            [void]$buffer.Append($c)
            $i++
        }
        else {
            # anything that is not a symbol / separator: report and skip
            $unknown.Add("junk '$c'")
            [void]$out.Append('?')
            $i++
        }
    }
    Close-LetterGroup $buffer $out $unknown $notes $ProsignMode

    $text = ($out.ToString() -replace '\s+', ' ').Trim()
    return @{ Text = $text; Unknown = $unknown; Notes = $notes }
}

# Guess which layout the user pasted.
function Get-PreferredLayout {
    param([string]$Raw)
    if ($Raw.Contains('/')) { return 'explicit' }
    foreach ($visual in $script:VisualChars) {
        if ($Raw.IndexOf($visual) -ge 0) { return 'gap' }
    }
    foreach ($chunk in ($Raw -split '\s+')) {
        if ($chunk -eq '') { continue }
        $symbols = 0
        foreach ($character in $chunk.ToCharArray()) {
            if (Test-MorseSymbol $character) { $symbols++ }
        }
        if ($symbols -ge 2) { return 'explicit' }
    }
    foreach ($match in [regex]::Matches($Raw, '\s+')) {
        if ($match.Length -ge 2) { return 'gap' }
    }
    return 'explicit'
}

# Read piped stdin as text: try UTF-8 first, fall back to Windows-1252.
function Read-AllStdin {
    $stream = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($stream)
    $bytes = $stream.ToArray()
    try {
        return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    catch {
        return [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
    }
}

try {
    $raw = $Morse

    if ($FromFile) {
        $raw = Get-Content -LiteralPath $FromFile -Raw -Encoding UTF8
    }
    elseif (-not $raw) {
        if ([Console]::IsInputRedirected) { $raw = Read-AllStdin }
        else { $raw = Read-Host 'Enter morse code to read' }
    }
    if (-not $raw -or $raw.Trim() -eq '') {
        Write-Warning 'nothing to decode'
        return
    }

    $normalized = ConvertTo-MorseSymbols $raw
    $explicit   = Invoke-MorseParse $normalized 0 2 ([bool]$Prosigns)   # one space between letters
    $gap        = Invoke-MorseParse $normalized 1 4 ([bool]$Prosigns)   # morse.ps1 timing gaps
    $preferred  = Get-PreferredLayout $raw

    if ($Mode -ne 'auto') {
        $chosen = $Mode
    }
    elseif ($explicit.Unknown.Count -ne $gap.Unknown.Count) {
        if ($explicit.Unknown.Count -lt $gap.Unknown.Count) { $chosen = 'explicit' }
        else { $chosen = 'gap' }
    }
    else {
        $chosen = $preferred
    }

    if ($chosen -eq 'explicit') {
        $result = $explicit; $other = $gap; $otherName = 'gap'
    }
    else {
        $result = $gap; $other = $explicit; $otherName = 'explicit'
    }

    Write-Output $result.Text

    if ($Detail) {
        Write-Host ("mode    : {0}  (auto preference: {1})" -f $chosen, $preferred)
        Write-Host ("unknown : {0}   (explicit layout: {1}, gap layout: {2})" -f $result.Unknown.Count, $explicit.Unknown.Count, $gap.Unknown.Count)
        if ($result.Unknown.Count -gt 0) {
            Write-Host ("          " + ($result.Unknown -join '  '))
        }
        if ($result.Notes.Count -gt 0) {
            Write-Host ("prosign : " + ($result.Notes -join '  '))
        }
        if (-not $Prosigns) {
            $tokens = @($normalized -split '\s+')
            foreach ($entry in $AllProsigns.GetEnumerator()) {
                $seq = [string]$entry.Key
                if ($Reverse.ContainsKey($seq) -and ($tokens -contains $seq)) {
                    Write-Host ("note    : {0} is also the prosign {1} (use -Prosigns)" -f $seq, $entry.Value)
                }
            }
        }
        if ($other.Text -and $other.Text -ne $result.Text) {
            Write-Host ("also reads as ({0} layout): {1}" -f $otherName, $other.Text)
        }
    }
}
catch {
    Write-Host ("ERROR: {0} (script line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
    exit 1
}
