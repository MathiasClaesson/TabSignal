// Tests for the pure decision logic in TabSignal.cs.
//
// Compiled together with TabSignal.cs into a separate test exe by test.ps1
// (csc /main:TabSignalTests), so the shipped TabSignal.exe carries no test code.
// The functions under test are internal, which is why one assembly holds both.
//
// What is covered: which hook event produces which ring state, how a color spec
// turns into an escape sequence, the automatic color derived from a session name,
// clamping of the progress values, and the JSON field extraction.
//
// What is NOT covered, and cannot be without a real terminal and a live session:
// AttachConsole, the walk up the process tree, Recolor, and whether Windows
// Terminal actually renders what we send.

using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

static class TabSignalTests
{
    static int passed, failed;
    static readonly string ESC = ((char)27).ToString(), BEL = ((char)7).ToString();

    static void Ok(bool cond, string what)
    {
        if (cond) passed++;
        else { failed++; Console.WriteLine("FAIL  " + what); }
    }

    static void Eq(object actual, object expected, string what)
    {
        bool same = Equals(actual, expected);
        if (same) passed++;
        else
        {
            failed++;
            Console.WriteLine("FAIL  " + what);
            Console.WriteLine("        expected: " + Show(expected));
            Console.WriteLine("        actual:   " + Show(actual));
        }
    }

    static string Show(object o)
    {
        if (o == null) return "<null>";
        string s = o.ToString();
        return s.Replace(ESC, "<ESC>").Replace(BEL, "<BEL>");
    }

    // ---------------- ForHook: event -> ring state ----------------

    static string HookJson(string ev, string tool, string notification)
    {
        return "{\"hook_event_name\":\"" + ev + "\",\"tool_name\":\"" + tool +
               "\",\"notification_type\":\"" + notification + "\",\"cwd\":\"C:\\\\proj\"}";
    }

    static void TestForHook()
    {
        // The lifecycle events.
        Eq(TabSignal.ForHook(HookJson("SessionStart", "", ""), null), TabSignal.Mode.Start, "SessionStart hides the ring");
        Eq(TabSignal.ForHook(HookJson("SessionEnd", "", ""), null), TabSignal.Mode.End, "SessionEnd hides the ring");
        Eq(TabSignal.ForHook(HookJson("UserPromptSubmit", "", ""), null), TabSignal.Mode.Working, "UserPromptSubmit starts the spin");
        Eq(TabSignal.ForHook(HookJson("Stop", "", ""), null), TabSignal.Mode.NeedsYou, "Stop means Claude needs you");
        Eq(TabSignal.ForHook(HookJson("PermissionRequest", "", ""), null), TabSignal.Mode.NeedsYou, "PermissionRequest means Claude needs you");

        // Tool events only matter for AskUserQuestion: everything else must leave
        // the ring alone, or it would stop spinning on every file read.
        Eq(TabSignal.ForHook(HookJson("PreToolUse", "AskUserQuestion", ""), null), TabSignal.Mode.NeedsYou, "PreToolUse AskUserQuestion means Claude needs you");
        Eq(TabSignal.ForHook(HookJson("PostToolUse", "AskUserQuestion", ""), null), TabSignal.Mode.Working, "PostToolUse AskUserQuestion resumes the spin");
        Eq(TabSignal.ForHook(HookJson("PreToolUse", "Bash", ""), null), TabSignal.Mode.Keep, "PreToolUse Bash keeps the ring as it is");
        Eq(TabSignal.ForHook(HookJson("PostToolUse", "Read", ""), null), TabSignal.Mode.Keep, "PostToolUse Read keeps the ring as it is");

        // Notifications, read from the JSON payload.
        Eq(TabSignal.ForHook(HookJson("Notification", "", "permission_prompt"), null), TabSignal.Mode.NeedsYou, "Notification permission_prompt means Claude needs you");
        Eq(TabSignal.ForHook(HookJson("Notification", "", "idle_prompt"), null), TabSignal.Mode.NeedsYou, "Notification idle_prompt means Claude needs you");
        Eq(TabSignal.ForHook(HookJson("Notification", "", "elicitation_dialog"), null), TabSignal.Mode.NeedsYou, "Notification elicitation_dialog means Claude needs you");
        Eq(TabSignal.ForHook(HookJson("Notification", "", "elicitation_complete"), null), TabSignal.Mode.Working, "Notification elicitation_complete resumes the spin");
        Eq(TabSignal.ForHook(HookJson("Notification", "", "something_new"), null), TabSignal.Mode.Keep, "An unknown notification type keeps the ring as it is");

        // install.ps1 registers the notification hooks with --matcher, which wins
        // over the payload. This is the path actually used in a real install.
        Eq(TabSignal.ForHook(HookJson("Notification", "", ""), "idle_prompt"), TabSignal.Mode.NeedsYou, "--matcher supplies the notification type");
        Eq(TabSignal.ForHook(HookJson("Notification", "", "idle_prompt"), "elicitation_complete"), TabSignal.Mode.Working, "--matcher wins over the payload");

        // An event Claude Code may add later must never disturb the ring.
        Eq(TabSignal.ForHook(HookJson("SomeFutureEvent", "", ""), null), TabSignal.Mode.Keep, "An unknown event keeps the ring as it is");
        Eq(TabSignal.ForHook("{}", null), TabSignal.Mode.Keep, "Empty JSON keeps the ring as it is");
    }

    // ---------------- ColorSeq: spec -> escape sequence ----------------

    static string Rgb(string hex)
    {
        return ESC + "]4;" + TabSignal.TabSlot + ";rgb:" + hex.Substring(0, 2) + "/" + hex.Substring(2, 2) + "/" + hex.Substring(4, 2) + BEL
             + ESC + "[2;15;" + TabSignal.TabSlot + ",|";
    }

    static void TestColorSeq()
    {
        Eq(TabSignal.ColorSeq("teal", null), Rgb("175a5f"), "A palette name gives its RGB sequence");
        Eq(TabSignal.ColorSeq("TEAL", null), Rgb("175a5f"), "Palette names are case-insensitive");
        Eq(TabSignal.ColorSeq("#3a7ca5", null), Rgb("3a7ca5"), "#rrggbb is accepted");
        Eq(TabSignal.ColorSeq("3a7ca5", null), Rgb("3a7ca5"), "rrggbb without # is accepted");
        Eq(TabSignal.ColorSeq("#3A7CA5", null), Rgb("3a7ca5"), "#RRGGBB is lowercased");

        // An xterm-256 index points the tab at an existing palette slot instead.
        Eq(TabSignal.ColorSeq("42", null), ESC + "[2;15;42,|", "An xterm-256 index is accepted");
        Eq(TabSignal.ColorSeq("0", null), ESC + "[2;15;0,|", "Index 0 is accepted");
        Eq(TabSignal.ColorSeq("255", null), ESC + "[2;15;255,|", "Index 255 is accepted");

        Eq(TabSignal.ColorSeq("none", null), ESC + "[2;0;0,|" + ESC + "]104;" + TabSignal.TabSlot + BEL, "none resets the tab color");
        Eq(TabSignal.ColorSeq("reset", null), ESC + "[2;0;0,|" + ESC + "]104;" + TabSignal.TabSlot + BEL, "reset is a synonym for none");

        // Rejected input must return null so that Main can print the usage line
        // and exit 1, rather than sending a malformed sequence to the terminal.
        Eq(TabSignal.ColorSeq("256", null), null, "An index above 255 is rejected");
        Eq(TabSignal.ColorSeq("-1", null), null, "A negative index is rejected");
        Eq(TabSignal.ColorSeq("nosuchcolor", null), null, "An unknown color name is rejected");
        Eq(TabSignal.ColorSeq("#abc", null), null, "A three-digit hex code is rejected");
        Eq(TabSignal.ColorSeq("#gggggg", null), null, "Non-hex characters are rejected");
        Eq(TabSignal.ColorSeq(null, null), null, "A missing spec is rejected");

        // --for wins: tab.ps1 calls `color --for <name>` for the automatic color.
        Eq(TabSignal.ColorSeq(null, "Booki"), Rgb(TabSignal.HexFor("Booki")), "--for derives the color from the name");
        Eq(TabSignal.ColorSeq("red", "Booki"), Rgb(TabSignal.HexFor("Booki")), "--for wins over a spec");

        foreach (var p in TabSignal.Palette)
            Ok(TabSignal.ColorSeq(p[0], null) == Rgb(p[1]), "Palette entry " + p[0] + " resolves to its own hex");
    }

    // ---------------- HexFor: session name -> automatic color ----------------

    static void TestHexFor()
    {
        // The README promises that the same name always gives the same color, so
        // that a session keeps its color when it is reopened.
        Eq(TabSignal.HexFor("Booki"), TabSignal.HexFor("Booki"), "The same name gives the same color");
        Eq(TabSignal.HexFor("Booki"), TabSignal.HexFor("BOOKI"), "The color does not depend on case");
        Eq(TabSignal.HexFor(""), TabSignal.HexFor(""), "An empty name is stable too");

        // gray is the last palette entry and is excluded from the automatic pick,
        // which is what makes it mean "I chose this one myself".
        string gray = TabSignal.Palette[TabSignal.Palette.Length - 1][1];
        Eq(TabSignal.Palette[TabSignal.Palette.Length - 1][0], "gray", "gray is the last palette entry");

        var seen = new HashSet<string>();
        var known = new HashSet<string>();
        foreach (var p in TabSignal.Palette) known.Add(p[1]);
        string grayName = null, strayName = null;
        for (int i = 0; i < 2000; i++)
        {
            string name = "session-" + i;
            string hex = TabSignal.HexFor(name);
            if (hex == gray && grayName == null) grayName = name;
            if (!known.Contains(hex) && strayName == null) strayName = name;
            seen.Add(hex);
        }
        Ok(grayName == null, "The automatic color is never gray (first offender: " + grayName + ")");
        Ok(strayName == null, "The automatic color always comes from the palette (first offender: " + strayName + ")");
        Eq(seen.Count, TabSignal.Palette.Length - 1, "Every palette color except gray is reachable");
    }

    // ---------------- Progress and TitleSeq ----------------

    static void TestProgress()
    {
        Eq(TabSignal.Progress(3, 0), ESC + "]9;4;3;0" + BEL, "State 3 is the spinning ring");
        Eq(TabSignal.Progress(1, 100), ESC + "]9;4;1;100" + BEL, "State 1 at 100 is the steady ring");
        Eq(TabSignal.Progress(0, 0), ESC + "]9;4;0;0" + BEL, "State 0 hides the ring");

        // Clamping keeps a bad argument from turning into a malformed sequence.
        Eq(TabSignal.Progress(9, 200), ESC + "]9;4;4;100" + BEL, "State and progress are clamped upwards");
        Eq(TabSignal.Progress(-1, -5), ESC + "]9;4;0;0" + BEL, "State and progress are clamped downwards");

        Eq(TabSignal.TitleSeq("Test"), ESC + "]2;Test" + BEL, "The title sequence is OSC 2");
        Eq(TabSignal.TitleSeq(""), ESC + "]2;" + BEL, "An empty title is allowed");
    }

    // ---------------- Json ----------------

    static void TestJson()
    {
        Eq(TabSignal.Json("{\"a\":\"b\"}", "a"), "b", "A plain field is read");
        Eq(TabSignal.Json("{\"a\" : \"b\"}", "a"), "b", "Whitespace around the colon is allowed");
        Eq(TabSignal.Json("{\"a\":\"b\"}", "missing"), "", "A missing field gives an empty string");
        Eq(TabSignal.Json("", "a"), "", "Empty input gives an empty string");

        // The two cases that matter in practice: a Windows path in cwd, and a
        // session name containing quotes.
        Eq(TabSignal.Json("{\"cwd\":\"C:\\\\proj\\\\sub\"}", "cwd"), "C:\\proj\\sub", "Backslashes in a path are unescaped");
        Eq(TabSignal.Json("{\"name\":\"say \\\"hi\\\"\"}", "name"), "say \"hi\"", "Escaped quotes are unescaped");
        Eq(TabSignal.Json("{\"name\":\"\\u00e5\"}", "name"), "\u00e5", "A \\u escape is decoded");

        // The key is matched together with its opening quote, so a longer key that
        // merely ends the same way does not shadow the one being asked for. Hook
        // payloads carry both tool_name and name, so this matters.
        Eq(TabSignal.Json("{\"tool_name\":\"Bash\",\"name\":\"real\"}", "name"), "real", "tool_name does not shadow name");
        Eq(TabSignal.Json("{\"tool_name\":\"Bash\"}", "name"), "", "tool_name alone is not read as name");
    }

    // ---------------- SafePath / CwdSeq ----------------

    static void TestSafePath()
    {
        Eq(TabSignal.SafePath("C:\\proj\\sub"), "C:\\proj\\sub", "An ordinary path is left alone");
        Eq(TabSignal.SafePath("C:\\my proj (2)"), "C:\\my proj (2)", "Spaces and parentheses are left alone");
        Eq(TabSignal.SafePath(null), "", "A null path becomes empty");

        // A quote would close the OSC string early, and a control character could
        // terminate the sequence and let the rest be interpreted as a new one.
        Eq(TabSignal.SafePath("C:\\a\"b"), "C:\\ab", "A quote is stripped");
        Eq(TabSignal.SafePath("C:\\a" + ((char)27) + "]0;x" + ((char)7)), "C:\\a]0;x", "ESC and BEL are stripped");
        Eq(TabSignal.SafePath("C:\\a\r\nb"), "C:\\ab", "CR and LF are stripped");

        Eq(TabSignal.CwdSeq("C:\\proj"), ESC + "]9;9;\"C:\\proj\"" + ESC + "\\", "CwdSeq is OSC 9;9 with the path in quotes");
        int quotes = 0;
        foreach (char c in TabSignal.CwdSeq("C:\\a\"b")) if (c == '"') quotes++;
        Eq(quotes, 2, "A quote in the path cannot add quotes to the sequence");
    }

    // ---------------- Palette integrity ----------------

    static void TestPalette()
    {
        var names = new HashSet<string>();
        foreach (var p in TabSignal.Palette)
        {
            Ok(p.Length == 2, "Palette entry " + p[0] + " has a name and a hex");
            Ok(Regex.IsMatch(p[1], "^[0-9a-f]{6}$"), "Palette hex " + p[1] + " is six lowercase hex digits");
            Ok(p[0] == p[0].ToLowerInvariant(), "Palette name " + p[0] + " is lowercase");
            Ok(names.Add(p[0]), "Palette name " + p[0] + " is unique");
        }
        Ok(TabSignal.Palette.Length >= 2, "The palette has at least two entries");

        // The tab slot must stay outside the range the color scheme owns (0-15),
        // or setting a tab color would repaint text inside the terminal.
        Ok(TabSignal.TabSlot > 15 && TabSignal.TabSlot <= 255, "The tab color slot is outside the scheme range 0-15");
    }

    static int Main()
    {
        TestForHook();
        TestColorSeq();
        TestHexFor();
        TestProgress();
        TestJson();
        TestSafePath();
        TestPalette();

        Console.WriteLine();
        Console.WriteLine(failed == 0
            ? "All " + passed + " assertions passed."
            : failed + " of " + (passed + failed) + " assertions FAILED.");
        return failed == 0 ? 0 : 1;
    }
}
