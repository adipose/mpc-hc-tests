/*
 * (C) 2026 see Authors.txt
 *
 * This file is part of MPC-HC.
 *
 * MPC-HC is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * MPC-HC is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include "stdafx.h"
#include "TestUtil.h"
#include "../../src/Subtitles/RTS.h"
#include "../../src/SubPic/MemSubPic.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <map>
#include <string>
#include <thread>
#include <vector>
#include <DbgHelp.h>
#pragma comment(lib, "dbghelp.lib")

// A render benchmark for the internal subtitle renderer (CRenderedTextSubtitle,
// ISR), not a pass/fail test. It renders a script frame by frame into a
// 1920x1080 RGB32 buffer the way the subpic queue does, times each Render
// call, and hashes every frame (bbox and pixels), so a speed change can be
// checked for an unchanged output by comparing the two hash lists.
//
// Skipped unless MPCTEST_RTS_BENCH is set. Further variables:
//   MPCTEST_RTS_BENCH_SCRIPT  an .ass to render instead of the built-in
//                             synthetic one
//   MPCTEST_RTS_BENCH_FONTS   a folder of fonts to load privately first
//   MPCTEST_RTS_BENCH_FROM / _TO   range in seconds (default: whole script)
//   MPCTEST_RTS_BENCH_STEP    render every Nth frame (default 1)
//   MPCTEST_RTS_BENCH_OUT     file for the per-frame "index ms hash" lines
//   MPCTEST_RTS_BENCH_PROFILE samples the rendering thread every millisecond
//                             and prints the functions it was found in, self
//                             and inclusive (symbols from the exe's pdb)
//
// The synthetic script contains two rows of faded dialogue, signs animating
// \frz, \bord and \blur in fractional steps (cache keys that differ only
// below the integer), \be at several strengths, stacked layers with their
// fill or outline at zero alpha, and a vector drawing rotating fractionally.

using namespace testutil;

namespace
{
    CStringW Env(LPCWSTR name)
    {
        WCHAR buf[MAX_PATH * 2];
        DWORD n = GetEnvironmentVariableW(name, buf, _countof(buf));
        return (n && n < _countof(buf)) ? CStringW(buf, n) : CStringW();
    }

    std::string Time(int cs)
    {
        char buf[32];
        sprintf_s(buf, "%d:%02d:%02d.%02d", cs / 360000, cs / 6000 % 60, cs / 100 % 60, cs % 100);
        return buf;
    }

    std::string SyntheticScript()
    {
        std::string s =
            "[Script Info]\r\n"
            "ScriptType: v4.00+\r\n"
            "PlayResX: 1920\r\n"
            "PlayResY: 1080\r\n"
            "ScaledBorderAndShadow: yes\r\n"
            "WrapStyle: 0\r\n"
            "\r\n"
            "[V4+ Styles]\r\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n"
            "Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00202020,&H80000000,-1,0,0,0,100,100,0,0,1,3,2,2,40,40,50,1\r\n"
            "Style: Sign,Arial,48,&H00E0F0FF,&H000000FF,&H00403020,&H00000000,0,0,0,0,100,100,0,0,1,2,0,5,10,10,10,1\r\n"
            "\r\n"
            "[Events]\r\n"
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n";

        const int seconds = 60;
        char line[1024];
        for (int t = 0; t < seconds; t += 4) {
            const std::string a = Time(t * 100), b = Time((t + 4) * 100);
            // dialogue, two lines
            sprintf_s(line, "Dialogue: 0,%s,%s,Default,,0,0,0,,{\\fad(200,200)}This is line %d of the benchmark\\Nwith a second row of ordinary dialogue\r\n",
                      a.c_str(), b.c_str(), t / 4);
            s += line;
            // rotating signs: \frz in fractional steps, bord and blur moving below the integer
            for (int i = 0; i < 12; i++) {
                sprintf_s(line, "Dialogue: 5,%s,%s,Sign,,0,0,0,,{\\pos(%d,%d)\\frz%.3f\\bord1.2\\blur0.3\\t(\\frz%.3f\\bord2.8\\blur1.7)}Sign text %d\r\n",
                          a.c_str(), b.c_str(), 200 + (i % 4) * 450, 150 + (i / 4) * 200, -0.004 * i, 2.5 + 0.13 * i, i);
                s += line;
            }
            // \be at several strengths
            for (int i = 0; i < 4; i++) {
                sprintf_s(line, "Dialogue: 6,%s,%s,Sign,,0,0,0,,{\\pos(%d,780)\\bord4\\be%d\\3c&H3060C0&}Edge blur %d\r\n",
                          a.c_str(), b.c_str(), 250 + i * 470, 2 + i * 4, 2 + i * 4);
                s += line;
            }
            // zero-alpha layers: an outline-only and a shadow-only copy, as typesetters stack them
            for (int i = 0; i < 4; i++) {
                sprintf_s(line, "Dialogue: 4,%s,%s,Sign,,0,0,0,,{\\pos(%d,920)\\1a&HFF&\\bord3\\shad3\\4a&HFF&\\blur0.6}Layered %d\r\n",
                          a.c_str(), b.c_str(), 250 + i * 470, i);
                s += line;
                sprintf_s(line, "Dialogue: 3,%s,%s,Sign,,0,0,0,,{\\pos(%d,920)\\1a&HFF&\\3a&HFF&\\shad4\\4c&H101010&\\blur2}Layered %d\r\n",
                          a.c_str(), b.c_str(), 250 + i * 470, i);
                s += line;
            }
            // vector drawing animated in fractional rotation
            sprintf_s(line, "Dialogue: 2,%s,%s,Sign,,0,0,0,,{\\pos(960,540)\\p1\\bord2\\1a&H80&\\frz0.01\\t(\\frz1.99)}m 0 0 l 300 0 300 120 0 120\r\n",
                      a.c_str(), b.c_str());
            s += line;
        }
        return s;
    }

    unsigned __int64 Fnv1a(unsigned __int64 h, const void* p, size_t n)
    {
        const BYTE* b = (const BYTE*)p;
        for (size_t i = 0; i < n; i++) {
            h = (h ^ b[i]) * 0x100000001b3ull;
        }
        return h;
    }

    int EnvInt(LPCWSTR name, int def)
    {
        CStringW v = Env(name);
        return v.IsEmpty() ? def : _wtoi(v);
    }

    double EnvDouble(LPCWSTR name, double def)
    {
        CStringW v = Env(name);
        return v.IsEmpty() ? def : _wtof(v);
    }

    // A poor man's sampling profiler: suspends the target thread and unwinds
    // its stack into a preallocated buffer. Nothing that may take a lock the
    // suspended thread holds (the heap, dbghelp) runs while it is suspended;
    // the return addresses are resolved to functions afterwards.
    class Sampler
    {
        static const int kDepth = 48;
        HANDLE m_thread = nullptr;
        std::atomic<bool> m_stop{ false };
        std::thread m_worker;
        std::vector<DWORD64> m_stacks; // kDepth entries per sample, zero padded
        size_t m_samples = 0;

        void Run()
        {
            m_stacks.resize(size_t(kDepth) * 400000);
            const size_t maxSamples = m_stacks.size() / kDepth;
            while (!m_stop && m_samples < maxSamples) {
                if (SuspendThread(m_thread) != DWORD(-1)) {
                    CONTEXT ctx = {};
                    ctx.ContextFlags = CONTEXT_FULL;
                    if (GetThreadContext(m_thread, &ctx)) {
                        DWORD64* stack = &m_stacks[m_samples * kDepth];
                        for (int depth = 0; depth < kDepth && ctx.Rip; depth++) {
                            stack[depth] = ctx.Rip;
                            DWORD64 base = 0;
                            PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(ctx.Rip, &base, nullptr);
                            if (!rf) {
                                // leaf function: the return address is at rsp
                                ctx.Rip = *(DWORD64*)ctx.Rsp;
                                ctx.Rsp += 8;
                            } else {
                                PVOID handlerData;
                                DWORD64 establisher;
                                RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, ctx.Rip, rf, &ctx, &handlerData, &establisher, nullptr);
                            }
                        }
                        m_samples++;
                    }
                    ResumeThread(m_thread);
                }
                Sleep(1);
            }
        }

        static DWORD64 Function(DWORD64 pc)
        {
            BYTE buf[sizeof(SYMBOL_INFO) + 256];
            SYMBOL_INFO* si = (SYMBOL_INFO*)buf;
            si->SizeOfStruct = sizeof(SYMBOL_INFO);
            si->MaxNameLen = 255;
            DWORD64 disp = 0;
            return SymFromAddr(GetCurrentProcess(), pc, &disp, si) ? si->Address : pc;
        }

        static std::string Name(DWORD64 addr)
        {
            BYTE buf[sizeof(SYMBOL_INFO) + 256];
            SYMBOL_INFO* si = (SYMBOL_INFO*)buf;
            si->SizeOfStruct = sizeof(SYMBOL_INFO);
            si->MaxNameLen = 255;
            DWORD64 disp = 0;
            if (SymFromAddr(GetCurrentProcess(), addr, &disp, si)) {
                return si->Name;
            }
            char hex[32];
            sprintf_s(hex, "0x%llx", addr);
            return hex;
        }

        void Print(const char* title, const std::map<DWORD64, size_t>& m, size_t top) const
        {
            std::vector<std::pair<size_t, DWORD64>> v;
            for (auto& kv : m) {
                v.emplace_back(kv.second, kv.first);
            }
            std::sort(v.rbegin(), v.rend());
            printf("[ RtsBench ] %s (%zu samples)\n", title, m_samples);
            for (size_t i = 0; i < std::min(top, v.size()); i++) {
                printf("  %6.2f%%  %s\n", 100.0 * v[i].first / m_samples, Name(v[i].second).c_str());
            }
        }

    public:
        Sampler()
        {
            DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &m_thread, 0, FALSE, DUPLICATE_SAME_ACCESS);
            SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
            SymInitialize(GetCurrentProcess(), nullptr, TRUE);
            m_worker = std::thread([this] { Run(); });
        }
        ~Sampler()
        {
            Stop();
            SymCleanup(GetCurrentProcess());
            CloseHandle(m_thread);
        }
        void Stop()
        {
            if (m_worker.joinable()) {
                m_stop = true;
                m_worker.join();
            }
        }
        void Report()
        {
            Stop();
            std::map<DWORD64, DWORD64> fnOf;
            std::map<DWORD64, size_t> self, incl;
            for (size_t s = 0; s < m_samples; s++) {
                const DWORD64* stack = &m_stacks[s * kDepth];
                std::vector<DWORD64> seen;
                for (int depth = 0; depth < kDepth && stack[depth]; depth++) {
                    auto it = fnOf.find(stack[depth]);
                    if (it == fnOf.end()) {
                        it = fnOf.emplace(stack[depth], Function(stack[depth])).first;
                    }
                    if (depth == 0) {
                        self[it->second]++;
                    }
                    if (std::find(seen.begin(), seen.end(), it->second) == seen.end()) {
                        seen.push_back(it->second);
                        incl[it->second]++;
                    }
                }
            }
            Print("self", self, 30);
            Print("inclusive", incl, 45);
        }
    };
}

TEST(RtsBench, RenderFrames)
{
    if (Env(L"MPCTEST_RTS_BENCH").IsEmpty()) {
        GTEST_SKIP() << "benchmark; set MPCTEST_RTS_BENCH=1 to run";
    }

    CStringW fonts = Env(L"MPCTEST_RTS_BENCH_FONTS");
    int fontCount = 0;
    if (!fonts.IsEmpty()) {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW(fonts + L"\\*", &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                    fontCount += AddFontResourceExW(fonts + L"\\" + fd.cFileName, FR_PRIVATE, nullptr) ? 1 : 0;
                }
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
    }

    CStringW script = Env(L"MPCTEST_RTS_BENCH_SCRIPT");
    if (script.IsEmpty()) {
        std::string text = SyntheticScript();
        script = WriteTemp(L"rts_bench_synthetic.ass", text.data(), text.size());
    }

    CCritSec lock;
    CRenderedTextSubtitle rts(&lock);
    ASSERT_TRUE(rts.Open(CString(script), DEFAULT_CHARSET, _T("bench"))) << mpctest::ToUtf8(script);
    ASSERT_GT(rts.GetCount(), 0u);

    REFERENCE_TIME first = rts[0].start, last = rts[0].end;
    for (size_t i = 1; i < rts.GetCount(); i++) {
        first = std::min(first, rts[i].start);
        last = std::max(last, rts[i].end);
    }
    const double from = EnvDouble(L"MPCTEST_RTS_BENCH_FROM", -1), to = EnvDouble(L"MPCTEST_RTS_BENCH_TO", -1);
    if (from >= 0) {
        first = REFERENCE_TIME(from * 10000000);
    }
    if (to >= 0) {
        last = REFERENCE_TIME(to * 10000000);
    }
    const int step = std::max(1, EnvInt(L"MPCTEST_RTS_BENCH_STEP", 1));

    const int w = 1920, h = 1080;
    const double fps = 24000.0 / 1001;
    const REFERENCE_TIME frameDur = REFERENCE_TIME(10000000 / fps);
    std::vector<DWORD> bits(size_t(w) * h);

    SubPicDesc spd;
    spd.type = MSP_RGB32;
    spd.w = w;
    spd.h = h;
    spd.bpp = 32;
    spd.pitch = w * 4;
    spd.bits = reinterpret_cast<BYTE*>(bits.data());
    spd.vidrect = { 0, 0, w, h };

    FILE* out = nullptr;
    CStringW outPath = Env(L"MPCTEST_RTS_BENCH_OUT");
    if (!outPath.IsEmpty()) {
        _wfopen_s(&out, outPath, L"w");
    }

    std::unique_ptr<Sampler> sampler;
    if (!Env(L"MPCTEST_RTS_BENCH_PROFILE").IsEmpty()) {
        sampler = std::make_unique<Sampler>();
    }

    std::vector<double> ms;
    unsigned __int64 all = 0xcbf29ce484222325ull;
    CRect dirty(0, 0, w, h);
    for (__int64 n = 0;; n += step) {
        const REFERENCE_TIME rt = first + n * frameDur + frameDur / 2;
        if (rt >= last) {
            break;
        }
        // clear what the previous frame drew, as the subpic does, to transparent
        for (int y = dirty.top; y < dirty.bottom; y++) {
            std::fill(&bits[size_t(y) * w + dirty.left], &bits[size_t(y) * w + dirty.right], 0xFF000000u);
        }

        RECT bbox = {};
        const auto t0 = std::chrono::steady_clock::now();
        rts.Render(spd, rt, fps, bbox);
        const auto t1 = std::chrono::steady_clock::now();
        ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());

        dirty = CRect(bbox) & CRect(0, 0, w, h);
        unsigned __int64 fh = Fnv1a(0xcbf29ce484222325ull, &bbox, sizeof(bbox));
        for (int y = dirty.top; y < dirty.bottom; y++) {
            fh = Fnv1a(fh, &bits[size_t(y) * w + dirty.left], size_t(dirty.Width()) * 4);
        }
        all = Fnv1a(all, &fh, sizeof(fh));
        if (out) {
            fprintf(out, "%lld %.3f %016llx\n", n, ms.back(), fh);
        }
    }
    if (sampler) {
        sampler->Stop();
    }
    if (out) {
        fclose(out);
    }

    ASSERT_FALSE(ms.empty());
    std::vector<double> sorted = ms;
    std::sort(sorted.begin(), sorted.end());
    double total = 0;
    for (double v : ms) {
        total += v;
    }
    printf("[ RtsBench ] fonts=%d frames=%zu total=%.1f ms mean=%.3f ms median=%.3f ms p99=%.3f ms max=%.3f ms hash=%016llx\n",
           fontCount, ms.size(), total, total / ms.size(), sorted[sorted.size() / 2],
           sorted[std::min(sorted.size() - 1, sorted.size() * 99 / 100)], sorted.back(), all);
    if (sampler) {
        sampler->Report();
    }
}
