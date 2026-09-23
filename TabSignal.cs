// TabSignal - shows the state of a Claude Code session in the Windows Terminal tab.
//
// The state is Windows Terminal's progress ring, drawn in the tab's icon slot (OSC 9;4):
//   working    spinning ring (state 3)
//   needs you  steady ring (state 1, 100 %): done, permission request or question
//   new/ended  no ring (state 0)
// The ring's shape and color belong to Windows Terminal (the system accent color)
// and cannot be changed. The tab title is the session name and the git branch;
// Claude Code's own title is turned off by install.ps1.
//
// Hooks run without a console of their own, so the sequences are written to the
// console that owns the tab (AttachConsole). The tab color is set with DECAC.
//
// Usage:
//   TabSignal.exe hook [--matcher NAME] [--bell] [--log FILE]   (reads hook JSON from stdin)
//   TabSignal.exe title "text"                               (set the tab title now)
//   TabSignal.exe color <name|#rrggbb|0-255|none> | color --for "session name"
//   TabSignal.exe colors [--for "session name"]               (print the palette as data)
//   TabSignal.exe recolor                                     (recolor every Claude tab)
//   TabSignal.exe set <state 0-4> [progress] | clear          (drive the ring manually)
//   TabSignal.exe cwd [path] | bell | raw <sequence>

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

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
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr overlapped);
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
    const int STD_OUTPUT_HANDLE = -11;
    internal static readonly string ESC = ((char)27).ToString(), BEL = ((char)7).ToString();

    static string logFile;
    static void Log(string s)
    {
        if (logFile == null) return;
        try { File.AppendAllText(logFile, DateTime.Now.ToString("HH:mm:ss.fff ") + "[" + Process.GetCurrentProcess().Id + "] " + s + Environment.NewLine); } catch { }
    }

    // ---------------- Finding the console ----------------
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

    static uint claudePid;   // claude.exe in the parent chain, if found

    // Walks up the process tree: hook -> cmd -> claude -> shell -> WindowsTerminal.
    // Returns the process directly below WindowsTerminal (the shell that owns the tab).
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

    internal static string Progress(int state, int progress)
    {
        if (state < 0) state = 0; if (state > 4) state = 4;
        if (progress < 0) progress = 0; if (progress > 100) progress = 100;
        return ESC + "]9;4;" + state + ";" + progress + BEL;
    }

    internal static string TitleSeq(string title) { return ESC + "]2;" + title + BEL; }

    internal static string TabTitle(string name, string branch)
    {
        string title = string.IsNullOrEmpty(branch) ? name : name + " \u00b7 " + branch;
        return Regex.Replace(title ?? "", "[\\x00-\\x1f\\x7f]", "");
    }

    internal static string GitBranch(string dir)
    {
        try
        {
            for (string d = dir; !string.IsNullOrEmpty(d); d = Path.GetDirectoryName(d))
            {
                string git = Path.Combine(d, ".git");
                string gitDir;
                if (Directory.Exists(git)) gitDir = git;
                else if (File.Exists(git))
                {
                    Match m = Regex.Match(File.ReadAllText(git), "^gitdir:\\s*(.+?)\\s*$", RegexOptions.Multiline);
                    if (!m.Success) return "";
                    gitDir = Path.IsPathRooted(m.Groups[1].Value) ? m.Groups[1].Value : Path.GetFullPath(Path.Combine(d, m.Groups[1].Value));
                }
                else continue;
                string head = Path.Combine(gitDir, "HEAD");
                return File.Exists(head) ? BranchFromHead(File.ReadAllText(head)) : "";
            }
        }
        catch (Exception ex) { Log("git branch: " + ex.Message); }
        return "";
    }

    internal static string BranchFromHead(string head)
    {
        head = head.Trim();
        if (head.StartsWith("ref: refs/heads/")) return head.Substring("ref: refs/heads/".Length);
        if (head.StartsWith("ref: ")) return head.Substring("ref: ".Length);
        return head.Length >= 7 ? head.Substring(0, 7) : head;
    }

    // ---------------- Session name ----------------
    // Deliberately a regex rather than a JSON parser: the hook payloads are small and
    // flat, and this keeps the program to one dependency-free file. The key is matched
    // together with its opening quote, so a longer key ending the same way (tool_name
    // vs name) does not shadow it. The limitation is that the first match anywhere
    // wins, so a nested object using the same key would be picked up instead.
    internal static string Json(string json, string key)
    {
        var m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
        return m.Success ? Regex.Unescape(m.Groups[1].Value) : "";
    }

    // A path is embedded in OSC 9;9 between quotes, so strip anything that would end
    // the sequence early or start one of its own: a quote, or a control character
    // such as ESC or BEL.
    internal static string SafePath(string path)
    {
        return path == null ? "" : Regex.Replace(path, "[\\x00-\\x1f\\x7f\"]", "");
    }

    internal static string CwdSeq(string path)
    {
        return ESC + "]9;9;\"" + SafePath(path) + "\"" + ESC + "\\";
    }

    // The name, resolved the way Claude Code itself shows it:
    //   1. a name set by the user (--name or /rename)  ~/.claude/sessions/<claude-pid>.json, nameSource=user
    //   2. the AI-generated session title               the last "aiTitle" in the transcript
    //   3. the directory name
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
            var buf = new byte[take];
            int n = 0, r;
            while (n < buf.Length && (r = fs.Read(buf, n, buf.Length - n)) > 0) n += r;   // one Read may return less
            // Seeking to a fixed offset can land inside a multi-byte character, so skip
            // the continuation bytes rather than decoding them into U+FFFD.
            int start = 0;
            if (take < fs.Length) while (start < n && (buf[start] & 0xC0) == 0x80) start++;
            string tail = Encoding.UTF8.GetString(buf, start, n - start);
            var ms = Regex.Matches(tail, "\"aiTitle\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            return ms.Count > 0 ? Regex.Unescape(ms[ms.Count - 1].Groups[1].Value) : "";
        }
    }

    // ---------------- Tab color ----------------
    // The tab gets an RGB color of its own: OSC 4 redefines index TabSlot in that
    // one tab's color table, and DECAC (ESC [ 2 ; fg ; bg , |) points the tab at it.
    // Index 17 (#00005f in the xterm cube) is used neither by the terminal's color
    // scheme (0-15) nor by Claude Code, which draws in truecolor, so the text inside
    // the tab is unaffected.
    internal const int TabSlot = 17;
    // The colors of the Dark+ scheme that ships with Windows Terminal, unchanged.
    // Windows Terminal picks the tab text (black or white) from the tab color, so
    // the bright ones (yellow, cyan, green) get black text.
    internal static readonly string[][] Palette = {
        new[] { "red",    "cd3131" },
        new[] { "green",  "0dbc79" },
        new[] { "yellow", "e5e510" },
        new[] { "blue",   "2472c8" },
        new[] { "purple", "bc3fbc" },
        new[] { "cyan",   "11a8cd" },
        new[] { "gray",   "666666" },   // Dark+ brightBlack; never picked automatically
    };

    internal static string Fold(string s) { return s.ToLowerInvariant(); }

    // The same name always yields the same color, so a session keeps its color
    // when it is reopened. The last palette entry is excluded from the automatic
    // pick, which makes it the neutral "I chose this myself" color.
    internal static string HexFor(string name)
    {
        uint h = 2166136261;
        foreach (char c in Fold(name)) { h ^= c; h *= 16777619; }
        int auto = Palette.Length - 1;
        return Palette[(int)(h % (uint)auto)][1];
    }

    internal static string RgbSeq(string hex)
    {
        return ESC + "]4;" + TabSlot + ";rgb:" + hex.Substring(0, 2) + "/" + hex.Substring(2, 2) + "/" + hex.Substring(4, 2) + BEL
             + ESC + "[2;15;" + TabSlot + ",|";
    }

    internal static string ColorSeq(string spec, string forName)
    {
        if (forName != null) return RgbSeq(HexFor(forName));
        if (spec == null) return null;
        string f = Fold(spec);
        if (f == "none" || f == "reset") return ESC + "[2;0;0,|" + ESC + "]104;" + TabSlot + BEL;
        int idx;
        if (int.TryParse(f, out idx) && idx >= 0 && idx <= 255) return ESC + "[2;15;" + idx + ",|";
        if (Regex.IsMatch(f, "^#?[0-9a-f]{6}$")) return RgbSeq(f.TrimStart('#'));
        foreach (var p in Palette) if (p[0] == f) return RgbSeq(p[1]);
        return null;
    }

    // The color last set per tab (keyed by the shell's pid), so recolor can send it again.
    static string ColorStore()
    {
        string d = Path.Combine(Path.GetTempPath(), "TabSignal", "colors");
        Directory.CreateDirectory(d);
        return d;
    }

    static void SaveColor(uint shell, string seq)
    {
        if (shell == 0 || shell == ATTACH_PARENT_PROCESS) return;
        string f = Path.Combine(ColorStore(), shell.ToString());
        if (seq.StartsWith(ESC + "[2;0;0,|")) File.Delete(f);
        else File.WriteAllText(f, seq);
    }

    // Recolors every open tab that is running Claude: the stored color if there is
    // one, otherwise the automatic color derived from the session name. Useful after
    // editing the palette or switching the Windows Terminal theme.
    static int Recolor()
    {
        var map = Snapshot();
        var done = new HashSet<uint>();
        // AttachConsole replaces this process's standard handles, so after the first
        // SendTo, Console.Out writes succeed but reach nothing - which is why recolor
        // used to print no report at all. Keep the real handle and the lines, and
        // write them once at the end.
        var report = new List<string>();
        IntPtr savedOut = GetStdHandle(STD_OUTPUT_HANDLE);
        bool redirected = Console.IsOutputRedirected;
        foreach (var kv in map)
        {
            if (!kv.Value.Name.StartsWith("claude", StringComparison.OrdinalIgnoreCase)) continue;
            uint shell = 0, pid = kv.Key;
            for (int depth = 0; depth < 32; depth++)
            {
                Proc p, parent;
                if (!map.TryGetValue(pid, out p) || p.Parent == 0 || !map.TryGetValue(p.Parent, out parent)) break;
                if (string.Equals(parent.Name, "WindowsTerminal.exe", StringComparison.OrdinalIgnoreCase)) { shell = pid; break; }
                pid = p.Parent;
            }
            if (shell == 0 || !done.Add(shell)) continue;
            string f = Path.Combine(ColorStore(), shell.ToString());
            string seq = File.Exists(f) ? File.ReadAllText(f) : RgbSeq(HexFor(SessionName(kv.Key, null)));
            bool ok = SendTo(shell, seq);
            report.Add((ok ? "colored " : "missed  ") + shell + "  " + SessionName(kv.Key, null));
        }
        foreach (string f in Directory.GetFiles(ColorStore()))
        {
            uint id; Proc p;
            if (!uint.TryParse(Path.GetFileName(f), out id) || !map.TryGetValue(id, out p)) File.Delete(f);   // closed tabs
        }
        WriteReport(report, savedOut, redirected);
        return 0;
    }

    // Writes the recolor report once SendTo has taken our standard handles away.
    // A redirected stdout is a file or pipe, and that handle is still open even
    // though the process no longer points at it, so write to it directly. A stdout
    // that was a console is gone, so re-attach to the shell that launched us.
    static void WriteReport(List<string> lines, IntPtr savedOut, bool redirected)
    {
        if (lines.Count == 0) return;
        var sb = new StringBuilder();
        foreach (string l in lines) sb.Append(l).Append("\r\n");
        string s = sb.ToString();
        if (redirected)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(s);
            uint n; WriteFile(savedOut, bytes, (uint)bytes.Length, out n, IntPtr.Zero);
            return;
        }
        FreeConsole();
        if (!AttachConsole(ATTACH_PARENT_PROCESS)) return;
        IntPtr h = CreateFileW("CONOUT$", 0xC0000000u, 0x3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) { FreeConsole(); return; }
        try { uint n; WriteConsoleW(h, s, (uint)s.Length, out n, IntPtr.Zero); }
        finally { CloseHandle(h); FreeConsole(); }
    }

    // The palette as data, for the color menu in tab.ps1.  number|name|rrggbb
    static int ListColors(string forName)
    {
        for (int i = 0; i < Palette.Length; i++)
            Console.WriteLine((i + 1) + "|" + Palette[i][0] + "|" + Palette[i][1]);
        if (forName != null) Console.WriteLine("0|auto|" + HexFor(forName));
        return 0;
    }

    static string PaletteHelp()
    {
        var sb = new StringBuilder();
        foreach (var p in Palette) sb.Append(p[0]).Append(' ');
        return sb.ToString().TrimEnd();
    }

    // ---------------- Hook logic ----------------
    internal enum Mode { Keep, Working, NeedsYou, Start, End }

    internal static Mode ForHook(string json, string matcher)
    {
        string ev = Json(json, "hook_event_name");
        string tool = Json(json, "tool_name");
        string kind = matcher != null ? matcher : Json(json, "notification_type");
        Log("event=" + ev + " tool=" + tool + " kind=" + kind);
        switch (ev)
        {
            case "SessionStart":      return Mode.Start;        // new session: no ring
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
                    string json = Console.In.ReadToEnd();      // read stdin before switching console
                    Mode m = ForHook(json, matcher);
                    if (m == Mode.Keep) return 0;
                    uint t = FindTarget();
                    // OSC 9;9 tells Windows Terminal which directory the tab is in, so that
                    // "Duplicate tab" / "Split pane" opens in the session's directory.
                    string hcwd = Json(json, "cwd");
                    string cwdSeq = hcwd.Length > 0 ? CwdSeq(hcwd) : "";
                    string titleSeq = m == Mode.End ? "" : TitleSeq(TabTitle(SessionName(claudePid, hcwd), GitBranch(hcwd)));
                    switch (m)
                    {
                        case Mode.Working:  SendTo(t, cwdSeq + titleSeq + Progress(3, 0)); break;                       // spinning ring
                        case Mode.NeedsYou: SendTo(t, cwdSeq + titleSeq + Progress(1, 100) + (bell ? BEL : "")); break; // steady ring
                        case Mode.Start:    SendTo(t, cwdSeq + titleSeq + Progress(0, 0)); break;                       // no ring
                        case Mode.End:      SendTo(t, Progress(0, 0)); break;
                    }
                    return 0;
                }
                case "title":
                    seq = TitleSeq(rest.Count > 1 ? string.Join(" ", rest.GetRange(1, rest.Count - 1).ToArray()) : "");
                    break;
                case "cwd":   // tell Windows Terminal the current directory (OSC 9;9)
                    seq = CwdSeq(rest.Count > 1 ? rest[1] : Environment.CurrentDirectory);
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
                    if (seq == null) { Console.Error.WriteLine("Colors: " + PaletteHelp() + " | #rrggbb | 0-255 | none  (or --for \"session name\")"); return 1; }
                    {
                        uint t = FindTarget();
                        SendTo(t, seq);
                        try { SaveColor(t, seq); } catch (Exception ex) { Log("save color: " + ex.Message); }
                    }
                    return 0;
                case "recolor":
                    return Recolor();
                case "colors":
                    return ListColors(forName);
                default:
                    Console.Error.WriteLine("Usage: TabSignal.exe hook [--matcher NAME] | title <text> | color <name|#rrggbb|0-255|none> | color --for <name> | colors [--for <name>] | recolor | set <0-4> [0-100] | clear | cwd [path] | bell | raw <sequence>");
                    return 0;
            }
            if (seq != null) Send(seq);
        }
        catch (Exception ex) { Log("error: " + ex); }
        return 0; // never block Claude Code
    }
}
