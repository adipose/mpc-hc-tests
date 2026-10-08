<#
.SYNOPSIS
    Which of steps.mkv's tone segments sounds in each window of a captured WAV.

.DESCRIPTION
    steps.mkv's audio is one sine stepping 300, 400, ... 1200 Hz every 2 s. For each -WindowSec window
    this returns the strongest of those ten frequencies (a Goertzel per candidate), or 0 when the
    window is silent, so a case can read back the order the segments played in: an A-B loop shows as
    the timeline going back to a lower segment.

    Reads RIFF/WAVE PCM 16/24/32-bit and IEEE float 32/64, plain or WAVE_FORMAT_EXTENSIBLE (what the
    vaudio endpoint writes); the first channel is analysed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Wav,
    [double] $WindowSec = 0.25,
    [double] $SilenceRms = 0.005
)

if (-not ('MpcTest.ToneTimeline' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

namespace MpcTest {
public static class ToneTimeline {
    public static double[] ReadFirstChannel(string path, out int rate) {
        using (var br = new BinaryReader(File.OpenRead(path))) {
            if (new string(br.ReadChars(4)) != "RIFF") throw new InvalidDataException("not RIFF");
            br.ReadInt32();
            if (new string(br.ReadChars(4)) != "WAVE") throw new InvalidDataException("not WAVE");
            int format = 0, channels = 0, bits = 0; rate = 0;
            while (br.BaseStream.Position + 8 <= br.BaseStream.Length) {
                string id = new string(br.ReadChars(4));
                int size = br.ReadInt32();
                long next = br.BaseStream.Position + size + (size & 1);
                if (id == "fmt ") {
                    format = br.ReadUInt16(); channels = br.ReadUInt16(); rate = br.ReadInt32();
                    br.ReadInt32(); br.ReadUInt16(); bits = br.ReadUInt16();
                    if (format == 0xFFFE && size >= 40) {     // WAVE_FORMAT_EXTENSIBLE: the subformat GUID starts with the tag
                        br.ReadUInt16(); br.ReadUInt16(); br.ReadUInt32();
                        format = br.ReadUInt16();
                    }
                } else if (id == "data") {
                    int bytes = bits / 8, frame = bytes * channels;
                    long frames = Math.Min(size, br.BaseStream.Length - br.BaseStream.Position) / frame;
                    var x = new double[frames];
                    for (long i = 0; i < frames; i++) {
                        byte[] f = br.ReadBytes(frame);
                        if (format == 3 && bits == 32) x[i] = BitConverter.ToSingle(f, 0);
                        else if (format == 3 && bits == 64) x[i] = BitConverter.ToDouble(f, 0);
                        else if (bits == 16) x[i] = BitConverter.ToInt16(f, 0) / 32768.0;
                        else if (bits == 24) x[i] = ((f[0] | (f[1] << 8) | (f[2] << 16)) << 8 >> 8) / 8388608.0;
                        else if (bits == 32) x[i] = BitConverter.ToInt32(f, 0) / 2147483648.0;
                        else throw new InvalidDataException("unsupported sample format " + format + "/" + bits);
                    }
                    return x;
                }
                br.BaseStream.Position = next;
            }
            throw new InvalidDataException("no data chunk");
        }
    }

    static double Goertzel(double[] x, int start, int n, double freq, int rate) {
        double w = 2 * Math.PI * freq / rate, c = 2 * Math.Cos(w), s1 = 0, s2 = 0;
        for (int i = 0; i < n; i++) { double s = x[start + i] + c * s1 - s2; s2 = s1; s1 = s; }
        return s1 * s1 + s2 * s2 - c * s1 * s2;
    }

    public static List<double[]> Timeline(string path, double windowSec, double silenceRms) {
        int rate;
        double[] x = ReadFirstChannel(path, out rate);
        int n = (int)(rate * windowSec);
        var result = new List<double[]>();
        for (int start = 0; start + n <= x.Length; start += n) {
            double sum = 0;
            for (int i = 0; i < n; i++) sum += x[start + i] * x[start + i];
            double rms = Math.Sqrt(sum / n);
            double best = 0, bestPower = -1;
            if (rms >= silenceRms) {
                for (int f = 300; f <= 1200; f += 100) {
                    double p = Goertzel(x, start, n, f, rate);
                    if (p > bestPower) { bestPower = p; best = f; }
                }
            }
            result.Add(new double[] { (double)start / rate, best, rms });
        }
        return result;
    }
}
}
'@
}

foreach ($w in [MpcTest.ToneTimeline]::Timeline((Resolve-Path $Wav).Path, $WindowSec, $SilenceRms)) {
    [pscustomobject]@{ t = [math]::Round($w[0], 2); hz = [int]$w[1]; rms = [math]::Round($w[2], 4) }
}
