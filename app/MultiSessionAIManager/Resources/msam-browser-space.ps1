# AI Manager browser space, for a Windows host.
#
# Runs in a Herdr pane and marks that pane out: every cell is filled, and the
# top left says which browser space this is and how big the pane is. AI Manager
# finds the mark in the terminal it draws and lays its browser over exactly
# these cells. Any other terminal attached to the same Herdr shows this fill
# instead. The Unix twin is msam-browser-space.sh.
#
# Kept to ASCII: Windows PowerShell reads a script without a byte order mark in
# the system's own code page.
param([string]$id = '000000')

$ui = $Host.UI.RawUI
$fill = [char]0x2591

function Draw($size, $at) {
    # Written straight into the screen buffer, the way Clear-Host clears it: the
    # cursor does not move, so filling the last cell cannot scroll the pane.
    $ui.SetBufferContents(
        @{Left = $at.X; Top = $at.Y; Right = $at.X + $size.Width - 1; Bottom = $at.Y + $size.Height - 1},
        @{Character = $fill; ForegroundColor = $ui.ForegroundColor; BackgroundColor = $ui.BackgroundColor})
    $mark = "[[AIM-BROWSER $id $($size.Width)x$($size.Height)]]"
    # A mark cut short would be read as nothing at all, so leave it out.
    if ($mark.Length -le $size.Width) {
        $ui.SetBufferContents($at, $ui.NewBufferCellArray(@($mark), $ui.ForegroundColor, $ui.BackgroundColor))
    }
}

# A stray Ctrl-C must not close the space: it arrives as a key, and keys are
# thrown away below. Herdr closes a pane by closing its console.
try { [Console]::TreatControlCAsInput = $true } catch {}
try { [Console]::CursorVisible = $false } catch {}

$drawn = ''
$said = $false
try {
    while ($true) {
        # Windows sends no signal when a console changes size, so look.
        $size = $ui.WindowSize
        $at = $ui.WindowPosition
        $now = "$($size.Width)x$($size.Height)+$($at.X)+$($at.Y)"
        if ($now -ne $drawn -and $size.Width -gt 0 -and $size.Height -gt 0) {
            try {
                Draw $size $at
                $drawn = $now
            } catch {
                # Tried again on the next round. Said once, where it can be seen.
                if (-not $said) {
                    $said = $true
                    [Console]::WriteLine('AI Manager browser space: ' + $_.Exception.Message)
                }
            }
        }
        # What is typed at the pane is not kept for the shell underneath.
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch {}
        [System.Threading.Thread]::Sleep(100)
    }
} finally {
    try {
        [Console]::TreatControlCAsInput = $false
        [Console]::CursorVisible = $true
    } catch {}
}
