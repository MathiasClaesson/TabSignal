// TabSignal - visar Claude Code-sessionens status i Windows Terminal-fliken.
//
// Statusen ar Windows Terminals progressring i flikens ikonplats (OSC 9;4):
//   arbetar      ringen snurrar (state 3)
//   behover dig  stilla ring (state 1, 100 %): klar, tillstand eller fraga
//   ny/avslutad  ingen ring (state 0)
// Ringens farg och form ar Windows Terminals egna (systemets accentfarg) och
// kan inte andras. Claude Codes egen titelglyf (◐/✳) undviks genom att cs
// oppnar sessionen i en flik med fast titel (wt --suppressApplicationTitle).
//
// Skrivningen sker till den konsol som ager fliken (AttachConsole), eftersom
// hooks kors utan egen konsol. Flikfarg satts med DECAC.
//
// Anvandning:
//   TabSignal.exe hook [--matcher NAMN] [--bell] [--log FIL]   (laser hook-JSON fran stdin)
//   TabSignal.exe title "text"                              (satt titeln nu)
//   TabSignal.exe color <farg|#rrggbb|0-255|none> | color --for "namn"
//   TabSignal.exe set <state 0-4> [progress] | clear        (ringen manuellt)
//   TabSignal.exe bell | raw <sekvens>

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class TabSignal
{
    // ---------------- Win32 ----------------
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleW(IntPtr h, string s, uint n, out uint written, IntPtr reserved);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    const uint ATTACH_PARENT_PROCESS = 0xFFFFFFFF;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
    static readonly string ESC = ((char)27).ToString(), BEL = ((char)7).ToString();

    static string logFile;
    static void Log(string s)
    {
        if (logFile == null) return;
        try { File.AppendAllText(logFile, DateTime.Now.ToString("HH:mm:ss.fff ") + "[" + Process.GetCurrentProcess().Id + "] " + s + Environment.NewLine); } catch { }
    }

    // ---------------- Hitta konsolen ----------------
    struct Proc { public uint Parent; public string Name; }

    static Dictionary<uint, Proc> Snapshot()
    {
        var map = new Dictionary<uint, Proc>();
        IntPtr snap = CreateToolhelp32Snapshot(0x2, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return map;
        try
        {
            var e = new PROCESSENTRY32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (Process32FirstW(snap, ref e))
                do { map[e.th32ProcessID] = new Proc { Parent = e.th32ParentProcessID, Name = e.szExeFile }; }
                while (Process32NextW(snap, ref e));
        }
        finally { CloseHandle(snap); }
        return map;
    }

    static uint claudePid;   // claude.exe i foraldrakedjan, om hittad

    // Gar uppat i processtradet: hook -> cmd -> claude -> skal -> WindowsTerminal.
    // Returnerar processen direkt under WindowsTerminal (skalet som ager fliken).
    static uint FindTarget()
    {
        var map = Snapshot();
        uint pid = (uint)Process.GetCurrentProcess().Id;
        uint aboveClaude = 0;
        var chain = new StringBuilder();
        for (int depth = 0; depth < 32; depth++)
        {
            Proc p; if (!map.TryGetValue(pid, out p)) break;
            chain.Append(pid).Append(':').Append(p.Name).Append(" <- ");
            if (p.Name.StartsWith("claude", StringComparison.OrdinalIgnoreCase) && claudePid == 0) { claudePid = pid; aboveClaude = p.Parent; }
            Proc parent; if (p.Parent == 0 || !map.TryGetValue(p.Parent, out parent)) break;
            if (string.Equals(parent.Name, "WindowsTerminal.exe", StringComparison.OrdinalIgnoreCase)) { Log("chain " + chain + parent.Name); return pid; }
            pid = p.Parent;
        }
        Log("chain (no WT) " + chain);
        return aboveClaude != 0 ? aboveClaude : ATTACH_PARENT_PROCESS;
    }

    static bool Send(string seq) { return SendTo(FindTarget(), seq); }

    static bool SendTo(uint target, string seq)
    {
        FreeConsole();
        if (!AttachConsole(target)) { Log("AttachConsole(" + target + ") failed: " + Marshal.GetLastWin32Error()); return false; }
        IntPtr h = CreateFileW("CONOUT$", 0xC0000000u, 0x3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) { Log("CONOUT$ open failed: " + Marshal.GetLastWin32Error()); FreeConsole(); return false; }
        try
        {
            uint mode; bool hadMode = GetConsoleMode(h, out mode);
            if (hadMode && (mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            uint written; bool ok = WriteConsoleW(h, seq, (uint)seq.Length, out written, IntPtr.Zero);
            if (hadMode && (mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) SetConsoleMode(h, mode);
            Log("sent to pid " + target + " ok=" + ok + " (" + Escape(seq) + ")");
            return ok;
        }
        finally { CloseHandle(h); FreeConsole(); }
    }

    static string Escape(string s) { return s.Replace(ESC, "ESC").Replace(BEL, "BEL"); }

    static string Progress(int state, int progress)
    {
        if (state < 0) state = 0; if (state > 4) state = 4;
        if (progress < 0) progress = 0; if (progress > 100) progress = 100;
        return ESC + "]9;4;" + state + ";" + progress + BEL;
    }

    static string TitleSeq(string title) { return ESC + "]2;" + title + BEL; }

    // ---------------- Sessionsnamn ----------------
    static string Json(string json, string key)
    {
        var m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
        return m.Success ? Regex.Unescape(m.Groups[1].Value) : "";
    }

    // Namn, i samma ordning som Claude Code sjalv visar det:
    //   1. namn satt av anvandaren (--name eller /rename)   ~/.claude/sessions/<claude-pid>.json, nameSource=user
    //   2. AI-genererad sessionstitel                        sista "aiTitle" i transkriptet
    //   3. mappnamnet
    static string SessionName(uint pid, string fallbackCwd)
    {
        string cwd = fallbackCwd;
        try
        {
            string home = Environment.GetEnvironmentVariable("USERPROFILE");
            string f = Path.Combine(home, ".claude", "sessions", pid + ".json");
            if (pid != 0 && File.Exists(f))
            {
                string j = File.ReadAllText(f);
                string n = Json(j, "name");
                if (n.Length > 0 && Json(j, "nameSource") == "user") return n;
                if (Json(j, "cwd").Length > 0) cwd = Json(j, "cwd");
                string sid = Json(j, "sessionId");
                if (sid.Length > 0 && cwd != null)
                {
                    string proj = Regex.Replace(cwd, "[^A-Za-z0-9]", "-");
                    string t = Path.Combine(home, ".claude", "projects", proj, sid + ".jsonl");
                    string ai = LastAiTitle(t);
                    if (ai.Length > 0) return ai;
                }
            }
        }
        catch (Exception ex) { Log("name lookup: " + ex.Message); }
        if (!string.IsNullOrEmpty(cwd)) return Path.GetFileName(cwd.TrimEnd('\\', '/'));
        return "Claude";
    }

    static string LastAiTitle(string transcript)
    {
        if (!File.Exists(transcript)) return "";
        using (var fs = new FileStream(transcript, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            long take = Math.Min(fs.Length, 512 * 1024);
            fs.Seek(fs.Length - take, SeekOrigin.Begin);
            var buf = new byte[take]; int n = fs.Read(buf, 0, buf.Length);
            string tail = Encoding.UTF8.GetString(buf, 0, n);
            var ms = Regex.Matches(tail, "\"aiTitle\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            return ms.Count > 0 ? Regex.Unescape(ms[ms.Count - 1].Groups[1].Value) : "";
        }
    }

    // ---------------- Flikfarg ----------------
    // Fliken far en egen RGB-farg: OSC 4 definierar om index TabSlot i just den
    // flikens fargtabell och DECAC (ESC [ 2 ; fg ; bg , |) pekar fliken pa det.
    // Index 17 (#00005f i xterm-kuben) anvands inte av Claude Code (truecolor) eller
    // av terminalens fargschema (0-15), sa texten i fliken paverkas inte.
    const int TabSlot = 17;
    static readonly string[][] Palette = {
        new[] { "green",   "gron",   "1f5c3a" },
        new[] { "teal",    "teal",   "175a5f" },
        new[] { "blue",    "bla",    "1f4a80" },
        new[] { "purple",  "lila",   "4a3582" },
        new[] { "red",     "rod",    "7a2530" },
        new[] { "orange",  "orange", "8a3e14" },
        new[] { "brown",   "brun",   "5e4520" },
        new[] { "magenta", "rosa",   "7a2a5c" },
        new[] { "gray",    "gra",    "3a4250" },   // valjs aldrig automatiskt
    };

    static string Fold(string s) { return s.ToLowerInvariant().Replace("ö", "o").Replace("ä", "a").Replace("å", "a").Replace("é", "e"); }

    static string HexFor(string name)
    {
        uint h = 2166136261;
        foreach (char c in Fold(name)) { h ^= c; h *= 16777619; }
        int auto = Palette.Length - 1;
        return Palette[(int)(h % (uint)auto)][2];
    }

    static string RgbSeq(string hex)
    {
        return ESC + "]4;" + TabSlot + ";rgb:" + hex.Substring(0, 2) + "/" + hex.Substring(2, 2) + "/" + hex.Substring(4, 2) + BEL
             + ESC + "[2;15;" + TabSlot + ",|";
    }

    static string ColorSeq(string spec, string forName)
    {
        if (forName != null) return RgbSeq(HexFor(forName));
        if (spec == null) return null;
        string f = Fold(spec);
        if (f == "none" || f == "ingen" || f == "reset") return ESC + "[2;0;0,|" + ESC + "]104;" + TabSlot + BEL;
        int idx;
        if (int.TryParse(f, out idx) && idx >= 0 && idx <= 255) return ESC + "[2;15;" + idx + ",|";
        if (Regex.IsMatch(f, "^#?[0-9a-f]{6}$")) return RgbSeq(f.TrimStart('#'));
        foreach (var p in Palette) if (p[0] == f || p[1] == f) return RgbSeq(p[2]);
        return null;
    }

    static string PaletteHelp()
    {
        var sb = new StringBuilder();
        foreach (var p in Palette) sb.Append(p[0]).Append('/').Append(p[1]).Append(' ');
        return sb.ToString().TrimEnd();
    }

    // ---------------- Hook-logik ----------------
    enum Mode { Keep, Working, NeedsYou, Start, End }

    static Mode ForHook(string json, string matcher)
    {
        string ev = Json(json, "hook_event_name");
        string tool = Json(json, "tool_name");
        string kind = matcher != null ? matcher : Json(json, "notification_type");
        Log("event=" + ev + " tool=" + tool + " kind=" + kind);
        switch (ev)
        {
            case "SessionStart":      return Mode.Start;        // ny session: ingen ring
            case "SessionEnd":        return Mode.End;
            case "UserPromptSubmit":  return Mode.Working;
            case "Stop":              return Mode.NeedsYou;
            case "PermissionRequest": return Mode.NeedsYou;
            case "PreToolUse":        return tool == "AskUserQuestion" ? Mode.NeedsYou : Mode.Keep;
            case "PostToolUse":       return tool == "AskUserQuestion" ? Mode.Working : Mode.Keep;
            case "Notification":
                switch (kind)
                {
                    case "permission_prompt":
                    case "elicitation_dialog":
                    case "idle_prompt":          return Mode.NeedsYou;
                    case "elicitation_complete": return Mode.Working;
                }
                return Mode.Keep;
        }
        return Mode.Keep;
    }

    static int Main(string[] args)
    {
        try
        {
            var rest = new List<string>(); bool bell = false;
            string matcher = null, forName = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--matcher" && i + 1 < args.Length) matcher = args[++i];
                else if (args[i] == "--for" && i + 1 < args.Length) forName = args[++i];
                else if (args[i] == "--log" && i + 1 < args.Length) logFile = args[++i];
                else if (args[i] == "--bell") bell = true;
                else if (args[i] == "--no-bell") { }
                else rest.Add(args[i]);
            }
            if (logFile == null && Environment.GetEnvironmentVariable("TABSIGNAL_LOG") != null) logFile = Environment.GetEnvironmentVariable("TABSIGNAL_LOG");
            string cmd = rest.Count > 0 ? rest[0] : "hook";
            string seq = null;
            switch (cmd)
            {
                case "hook":
                {
                    string json = Console.In.ReadToEnd();      // las stdin innan konsolen byts
                    Mode m = ForHook(json, matcher);
                    if (m == Mode.Keep) return 0;
                    uint t = FindTarget();
                    // OSC 9;9 talar om for Windows Terminal vilken mapp fliken star i, sa att
                    // "Duplicera flik" / "Dela ruta" oppnar i sessionens mapp.
                    string hcwd = Json(json, "cwd");
                    string cwdSeq = hcwd.Length > 0 ? ESC + "]9;9;\"" + hcwd + "\"" + ESC + "\\" : "";
                    switch (m)
                    {
                        case Mode.Working:  SendTo(t, cwdSeq + Progress(3, 0)); break;                       // ringen snurrar
                        case Mode.NeedsYou: SendTo(t, cwdSeq + Progress(1, 100) + (bell ? BEL : "")); break; // stilla ring
                        case Mode.Start:    SendTo(t, cwdSeq + Progress(0, 0)); break;                       // ingen ring
                        case Mode.End:      SendTo(t, Progress(0, 0)); break;
                    }
                    return 0;
                }
                case "title":
                    seq = TitleSeq(rest.Count > 1 ? string.Join(" ", rest.GetRange(1, rest.Count - 1).ToArray()) : "");
                    break;
                case "cwd":   // tala om mappen for Windows Terminal (OSC 9;9)
                    seq = ESC + "]9;9;\"" + (rest.Count > 1 ? rest[1] : Environment.CurrentDirectory) + "\"" + ESC + "\\";
                    break;
                case "set":
                    int state = rest.Count > 1 ? int.Parse(rest[1]) : 0;
                    int progress = rest.Count > 2 ? int.Parse(rest[2]) : (state == 3 ? 0 : 100);
                    seq = Progress(state, progress) + (bell ? BEL : "");
                    break;
                case "bell":  seq = BEL; break;
                case "raw":   seq = Regex.Unescape(string.Join(" ", rest.GetRange(1, rest.Count - 1).ToArray())); break;
                case "clear": seq = Progress(0, 0); break;
                case "color":
                    seq = ColorSeq(rest.Count > 1 ? rest[1] : null, forName);
                    if (seq == null) { Console.Error.WriteLine("Farger: " + PaletteHelp() + " | #rrggbb | 0-255 | none  (eller --for \"arbetsnamn\")"); return 1; }
                    break;
                default:
                    Console.Error.WriteLine("Usage: TabSignal.exe hook [--matcher NAME] | title <text> | color <farg|#rrggbb|0-255|none> | color --for <namn> | set <0-4> [0-100] | clear | bell | raw <sekvens>");
                    return 0;
            }
            if (seq != null) Send(seq);
        }
        catch (Exception ex) { Log("error: " + ex); }
        return 0; // blockera aldrig Claude Code
    }
}
