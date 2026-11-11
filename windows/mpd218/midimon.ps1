<#
.SYNOPSIS
    Print the MIDI messages a controller is actually sending.

.DESCRIPTION
    Opens a MIDI input port through winmm and logs incoming messages for a
    fixed window, so you can see what the hardware transmits independently of
    any DAW. Written for the Akai MPD218, but -Device takes any port name.

    The callback is implemented in C# rather than PowerShell because winmm
    invokes it on a driver thread, which cannot re-enter a PowerShell runspace.

    Opening the port succeeds only when no other application holds it, so a
    MMSYSERR_ALLOCATED result doubles as proof that something else has it.

.EXAMPLE
    .\midimon.ps1
    .\midimon.ps1 -Seconds 60 -Show 100
#>
param(
    [int]    $Seconds = 30,
    [string] $Device  = 'MPD218',
    [int]    $Show    = 40
)

$cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class MidiMon {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public struct MIDIINCAPS {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]
        public string szPname;
        public uint dwSupport;
    }

    [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
    [DllImport("winmm.dll", CharSet=CharSet.Ansi)] public static extern uint midiInGetDevCaps(IntPtr id, ref MIDIINCAPS caps, uint cb);
    public delegate void MidiInProc(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2);
    [DllImport("winmm.dll")] public static extern uint midiInOpen(out IntPtr lph, uint id, MidiInProc cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] public static extern uint midiInStart(IntPtr h);
    [DllImport("winmm.dll")] public static extern uint midiInStop(IntPtr h);
    [DllImport("winmm.dll")] public static extern uint midiInClose(IntPtr h);

    public static List<string> Log = new List<string>();
    public static int Count = 0;
    static MidiInProc _proc;
    static IntPtr _h = IntPtr.Zero;

    static void Cb(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2) {
        if (msg != 0x3C3) return;
        int d = p1.ToInt32();
        int status = d & 0xFF, d1 = (d >> 8) & 0xFF, d2 = (d >> 16) & 0xFF;
        int type = status & 0xF0, ch = (status & 0x0F) + 1;
        string name;
        if (type == 0x90) name = (d2 > 0) ? "NoteOn" : "NoteOff";
        else if (type == 0x80) name = "NoteOff";
        else if (type == 0xB0) name = "CC";
        else if (type == 0xD0) name = "ChanPressure";
        else if (type == 0xA0) name = "PolyPressure";
        else name = "status 0x" + type.ToString("X2");
        lock (Log) {
            Count++;
            if (Log.Count < 300)
                Log.Add(String.Format("ch {0,-2}  {1,-13} note/cc {2,-4} value {3}", ch, name, d1, d2));
        }
    }

    public static string Names() {
        StringBuilder sb = new StringBuilder();
        uint n = midiInGetNumDevs();
        sb.AppendLine("MIDI input devices: " + n);
        for (uint i = 0; i < n; i++) {
            MIDIINCAPS c = new MIDIINCAPS();
            midiInGetDevCaps((IntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(MIDIINCAPS)));
            sb.AppendLine("  [" + i + "] " + c.szPname);
        }
        return sb.ToString();
    }

    public static int Find(string want) {
        uint n = midiInGetNumDevs();
        for (uint i = 0; i < n; i++) {
            MIDIINCAPS c = new MIDIINCAPS();
            midiInGetDevCaps((IntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(MIDIINCAPS)));
            if (c.szPname != null && c.szPname.ToUpper().Contains(want.ToUpper())) return (int)i;
        }
        return -1;
    }

    public static uint Start(uint id) {
        _proc = new MidiInProc(Cb);
        uint r = midiInOpen(out _h, id, _proc, IntPtr.Zero, 0x30000);
        if (r != 0) { _h = IntPtr.Zero; return r; }
        return midiInStart(_h);
    }

    public static void Stop() {
        if (_h != IntPtr.Zero) { midiInStop(_h); midiInClose(_h); _h = IntPtr.Zero; }
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp

Write-Output ([MidiMon]::Names())

$id = [MidiMon]::Find($Device)
if ($id -lt 0) { Write-Output "$Device NOT FOUND among MIDI inputs"; exit 1 }
Write-Output "Opening device index $id ..."

$rc = [MidiMon]::Start([uint32]$id)
if ($rc -ne 0) {
    $why = switch ($rc) {
        4 { "MMSYSERR_ALLOCATED - another application holds the port (likely MPC Beats)" }
        2 { "MMSYSERR_BADDEVICEID" }
        default { "winmm error code $rc" }
    }
    Write-Output "COULD NOT OPEN PORT: $why"
    exit 2
}

Write-Output "LISTENING for $Seconds seconds - hit the $Device pads now..."
Start-Sleep -Seconds $Seconds
[MidiMon]::Stop()

Write-Output ""
Write-Output ("Total MIDI messages received: " + [MidiMon]::Count)
Write-Output "--- first messages ---"
[MidiMon]::Log | Select-Object -First $Show




