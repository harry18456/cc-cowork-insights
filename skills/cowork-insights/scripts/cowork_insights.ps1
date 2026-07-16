<#
cowork-insights: Cowork-only usage aggregation for HOST Claude Code.
PowerShell port of cowork_insights.py for machines WITHOUT Python.

  !! KEEP IN SYNC WITH cowork_insights.py -- same discriminator, same        !!
  !! aggregation, same output files. Outputs are byte-identical by design    !!
  !! (verified by differential testing); any behavior change must be made   !!
  !! in BOTH files.                                                          !!

Read-only. Scans the host projects tree AND the Cowork
(local-agent-mode-sessions) tree, keeps only Cowork-origin sessions, and
reports usage with NO 30-day limit and NO startup cleanup deletion.

Validated discriminator (same as the Python implementation):
    is_cowork = entrypoint in {"local-agent", "claude-desktop"}
                OR  file located under a local-agent-mode-sessions tree
    (single-line "ai-title" junk files are excluded first)

Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File cowork_insights.ps1 `
        [output_dir] [-Days N|all] [-Stage DIR]

    Argument mapping vs the Python CLI:
        output_dir  ->  positional, same
        --days N    ->  -Days N        (default 30, 'all' for full history)
        --stage DIR ->  -Stage DIR

    The -ExecutionPolicy Bypass flag above is for HUMANS running this
    from a stock shell: fresh Windows desktops default to Restricted.
    The SKILL.md invocation deliberately omits it -- Claude Code's
    native PowerShell tool already runs with a Process-scope Bypass,
    git-cloned files carry no mark-of-the-web (so RemoteSigned machines
    run them as-is), and the literal "Bypass" string trips automated
    permission classifiers. When a run does hit Restricted, retrying
    WITH the flag is the only working fallback (Unblock-File does not
    lift Restricted; GPO-forced policies override even the flag).

Optional overrides via env (same as Python):
    CLAUDE_CONFIG_DIR   -> host config dir (default: %USERPROFILE%\.claude)
    CLAUDE_COWORK_ROOT  -> explicit local-agent-mode-sessions path

Runtime: Windows PowerShell 5.1 (in-box on Windows 10/11, zero install) or
PowerShell 7+. The hot path (JSONL parsing/aggregation) is embedded C#
compiled via Add-Type, restricted to C# 5 syntax so the 5.1 CodeDOM
compiler accepts it; it depends only on core BCL types so it also compiles
under pwsh's Roslyn. The JSON parser and serializer intentionally mimic
Python's json module (raw non-ASCII output, indent style, float repr) and
file writes mimic Path.write_text on Windows (UTF-8 no BOM, LF -> CRLF) so
outputs diff clean against the Python implementation.

Known deviations from cowork_insights.py, all on inputs or environments
that do not occur with real transcripts (where Python would crash or
misbehave, this port keeps going):
  * non-object top-level JSON lines are ignored; a null tool_use name
    counts as "?"; non-dict usage/message values are treated as empty;
    string token counts that do not parse as integers count as 0
  * NaN/Infinity JSON literals: Python's json accepts them, this parser
    rejects the line; integers beyond Int64 fall back to double
  * dict-typed message.content is treated as empty (Python iterates its
    keys as if they were user text)
  * U+001C-U+001F are whitespace to Python's strip()/\s but not to .NET
  * paths are deduplicated textually (case-folded full path), not
    canonically like Path.resolve(): a junction alias of a tree that is
    also scanned directly would double-count where Python dedupes
  * Windows PowerShell 5.1 runs on .NET Framework, which cannot see paths
    longer than 260 chars -- such sessions are silently skipped there; on
    machines with long paths run the Python version or pwsh 7 instead
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$OutputDir,
    [string]$Days = '30',
    [string]$Stage
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:TOKEN_FIELDS = @('input_tokens', 'output_tokens',
                         'cache_read_input_tokens', 'cache_creation_input_tokens')
$script:COWORK_ENTRYPOINTS = @('local-agent', 'claude-desktop')

# ---------------------------------------------------------------------------
# Embedded C# engine (C# 5 only: PS 5.1 compiles Add-Type with the legacy
# CodeDOM csc). Core BCL types only, so the same source compiles on pwsh 7.
# ---------------------------------------------------------------------------
$engineSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace CoworkInsights
{
    // PowerShell hands PSObject wrappers to object-typed .NET parameters;
    // unwrap them at every PS-facing boundary (reflection keeps this
    // assembly free of a System.Management.Automation reference).
    public static class Ps
    {
        public static object Unwrap(object o)
        {
            if (o == null) { return null; }
            Type t = o.GetType();
            if (t.FullName == "System.Management.Automation.PSObject")
            {
                System.Reflection.PropertyInfo pi = t.GetProperty("BaseObject");
                if (pi != null) { return pi.GetValue(o, null); }
            }
            return o;
        }
    }

    // Insertion-ordered string->object map mirroring Python dict semantics:
    // missing key reads as null, overwrite keeps original position.
    public class PyDict
    {
        // Stand-in for a Python dict key of None (only the entrypoints
        // aggregate can produce one): json.dumps coerces it to "null",
        // str(dict) renders a bare None -- writers special-case this.
        public const string NoneKey = "<<cowork-insights-none-key>>";

        private List<string> _keys = new List<string>();
        private Dictionary<string, object> _map =
            new Dictionary<string, object>(StringComparer.Ordinal);

        public object this[string k]
        {
            get { object v; if (_map.TryGetValue(k, out v)) { return v; } return null; }
            set { if (!_map.ContainsKey(k)) { _keys.Add(k); } _map[k] = Ps.Unwrap(value); }
        }
        public bool Has(string k) { return _map.ContainsKey(k); }
        public List<string> Keys { get { return _keys; } }
        public int Count { get { return _keys.Count; } }
    }

    // collections.Counter equivalent: insertion-ordered, most_common ties
    // resolved by first insertion (Python's sort is stable).
    public class Counter
    {
        private List<string> _keys = new List<string>();
        private Dictionary<string, long> _map =
            new Dictionary<string, long>(StringComparer.Ordinal);

        public void Add(string k, long n)
        {
            long cur;
            if (_map.TryGetValue(k, out cur)) { _map[k] = cur + n; }
            else { _keys.Add(k); _map[k] = n; }
        }
        public long Get(string k)
        {
            long v; if (_map.TryGetValue(k, out v)) { return v; } return 0;
        }
        public long Total()
        {
            long t = 0;
            for (int i = 0; i < _keys.Count; i++) { t += _map[_keys[i]]; }
            return t;
        }
        public string Top()  // most_common(1) key, or null when empty
        {
            string best = null; long bc = long.MinValue;
            for (int i = 0; i < _keys.Count; i++)
            {
                long v = _map[_keys[i]];
                if (best == null || v > bc) { best = _keys[i]; bc = v; }
            }
            return best;
        }
        public PyDict ToDict()  // dict(counter): insertion order
        {
            PyDict d = new PyDict();
            for (int i = 0; i < _keys.Count; i++) { d[_keys[i]] = _map[_keys[i]]; }
            return d;
        }
        public PyDict MostCommon(int n)  // n < 0 means all
        {
            List<int> order = new List<int>();
            for (int i = 0; i < _keys.Count; i++) { order.Add(i); }
            List<string> ks = _keys;
            Dictionary<string, long> mp = _map;
            order.Sort(delegate(int a, int b)
            {
                long ca = mp[ks[a]], cb = mp[ks[b]];
                if (ca != cb) { return cb.CompareTo(ca); }
                return a.CompareTo(b);
            });
            int lim = order.Count;
            if (n >= 0 && n < lim) { lim = n; }
            PyDict d = new PyDict();
            for (int i = 0; i < lim; i++) { d[ks[order[i]]] = mp[ks[order[i]]]; }
            return d;
        }
    }

    // Minimal strict JSON parser matching Python json.loads for transcript
    // data: objects -> PyDict (duplicate key: last wins, keeps position),
    // arrays -> List<object>, integral numbers -> long, others -> double.
    public static class Json
    {
        public static object Parse(string s)
        {
            int i = 0;
            object v = ParseValue(s, ref i);
            SkipWs(s, ref i);
            if (i != s.Length) { throw new FormatException("trailing data"); }
            return v;
        }

        private static void SkipWs(string s, ref int i)
        {
            while (i < s.Length)
            {
                char c = s[i];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { i++; }
                else { break; }
            }
        }

        private static object ParseValue(string s, ref int i)
        {
            SkipWs(s, ref i);
            if (i >= s.Length) { throw new FormatException("unexpected end"); }
            char c = s[i];
            if (c == '{') { return ParseObject(s, ref i); }
            if (c == '[') { return ParseArray(s, ref i); }
            if (c == '"') { return ParseString(s, ref i); }
            if (c == 't') { Expect(s, ref i, "true"); return true; }
            if (c == 'f') { Expect(s, ref i, "false"); return false; }
            if (c == 'n') { Expect(s, ref i, "null"); return null; }
            return ParseNumber(s, ref i);
        }

        private static void Expect(string s, ref int i, string lit)
        {
            if (i + lit.Length > s.Length ||
                string.CompareOrdinal(s, i, lit, 0, lit.Length) != 0)
            {
                throw new FormatException("bad literal");
            }
            i += lit.Length;
        }

        private static PyDict ParseObject(string s, ref int i)
        {
            i++;  // {
            PyDict d = new PyDict();
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return d; }
            while (true)
            {
                SkipWs(s, ref i);
                if (i >= s.Length || s[i] != '"') { throw new FormatException("expected key"); }
                string k = ParseString(s, ref i);
                SkipWs(s, ref i);
                if (i >= s.Length || s[i] != ':') { throw new FormatException("expected colon"); }
                i++;
                object v = ParseValue(s, ref i);
                d[k] = v;
                SkipWs(s, ref i);
                if (i >= s.Length) { throw new FormatException("unterminated object"); }
                char c = s[i];
                if (c == ',') { i++; continue; }
                if (c == '}') { i++; return d; }
                throw new FormatException("bad object separator");
            }
        }

        private static List<object> ParseArray(string s, ref int i)
        {
            i++;  // [
            List<object> a = new List<object>();
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return a; }
            while (true)
            {
                object v = ParseValue(s, ref i);
                a.Add(v);
                SkipWs(s, ref i);
                if (i >= s.Length) { throw new FormatException("unterminated array"); }
                char c = s[i];
                if (c == ',') { i++; continue; }
                if (c == ']') { i++; return a; }
                throw new FormatException("bad array separator");
            }
        }

        private static string ParseString(string s, ref int i)
        {
            i++;  // opening quote
            StringBuilder sb = new StringBuilder();
            while (true)
            {
                if (i >= s.Length) { throw new FormatException("unterminated string"); }
                char c = s[i];
                if (c == '"') { i++; return sb.ToString(); }
                if (c == '\\')
                {
                    i++;
                    if (i >= s.Length) { throw new FormatException("bad escape"); }
                    char e = s[i];
                    if (e == '"') { sb.Append('"'); }
                    else if (e == '\\') { sb.Append('\\'); }
                    else if (e == '/') { sb.Append('/'); }
                    else if (e == 'b') { sb.Append('\b'); }
                    else if (e == 'f') { sb.Append('\f'); }
                    else if (e == 'n') { sb.Append('\n'); }
                    else if (e == 'r') { sb.Append('\r'); }
                    else if (e == 't') { sb.Append('\t'); }
                    else if (e == 'u')
                    {
                        if (i + 4 >= s.Length) { throw new FormatException("bad \\u"); }
                        int code = 0;
                        for (int j = 1; j <= 4; j++)
                        {
                            code = code * 16 + HexVal(s[i + j]);
                        }
                        sb.Append((char)code);
                        i += 4;
                    }
                    else { throw new FormatException("bad escape char"); }
                    i++;
                }
                else if (c < '\x20')
                {
                    throw new FormatException("raw control char");  // json strict mode
                }
                else
                {
                    sb.Append(c);
                    i++;
                }
            }
        }

        private static int HexVal(char c)
        {
            if (c >= '0' && c <= '9') { return c - '0'; }
            if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
            if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
            throw new FormatException("bad hex digit");
        }

        private static object ParseNumber(string s, ref int i)
        {
            int start = i;
            if (i < s.Length && s[i] == '-') { i++; }
            int digitsStart = i;
            while (i < s.Length && s[i] >= '0' && s[i] <= '9') { i++; }
            if (i == digitsStart) { throw new FormatException("bad number"); }
            // Python json rejects leading zeros ("01")
            if (s[digitsStart] == '0' && i - digitsStart > 1) { throw new FormatException("leading zero"); }
            bool isInt = true;
            if (i < s.Length && s[i] == '.')
            {
                isInt = false;
                i++;
                int fs = i;
                while (i < s.Length && s[i] >= '0' && s[i] <= '9') { i++; }
                if (i == fs) { throw new FormatException("bad fraction"); }
            }
            if (i < s.Length && (s[i] == 'e' || s[i] == 'E'))
            {
                isInt = false;
                i++;
                if (i < s.Length && (s[i] == '+' || s[i] == '-')) { i++; }
                int es = i;
                while (i < s.Length && s[i] >= '0' && s[i] <= '9') { i++; }
                if (i == es) { throw new FormatException("bad exponent"); }
            }
            string num = s.Substring(start, i - start);
            if (isInt)
            {
                long l;
                if (long.TryParse(num, NumberStyles.Integer, CultureInfo.InvariantCulture, out l))
                {
                    return l;
                }
            }
            double d;
            if (double.TryParse(num, NumberStyles.Float, CultureInfo.InvariantCulture, out d))
            {
                return d;
            }
            throw new FormatException("unparseable number");
        }
    }

    // json.dumps(obj, ensure_ascii=False, indent=N) work-alike so output
    // files diff clean against the Python implementation.
    public static class PyJson
    {
        public static string Dumps(object o, int indent)
        {
            StringBuilder sb = new StringBuilder();
            WriteVal(sb, o, indent, 0);
            return sb.ToString();
        }

        private static void Pad(StringBuilder sb, int indent, int level)
        {
            sb.Append('\n');
            sb.Append(' ', indent * level);
        }

        private static void WriteVal(StringBuilder sb, object o, int indent, int level)
        {
            o = Ps.Unwrap(o);
            if (o == null) { sb.Append("null"); return; }
            if (o is bool) { sb.Append(((bool)o) ? "true" : "false"); return; }
            string s = o as string;
            if (s != null) { WriteStr(sb, s); return; }
            if (o is long) { sb.Append(((long)o).ToString(CultureInfo.InvariantCulture)); return; }
            if (o is int) { sb.Append(((int)o).ToString(CultureInfo.InvariantCulture)); return; }
            if (o is double) { sb.Append(Engine.FormatDouble((double)o)); return; }
            PyDict pd = o as PyDict;
            if (pd != null)
            {
                if (pd.Count == 0) { sb.Append("{}"); return; }
                sb.Append('{');
                for (int i = 0; i < pd.Keys.Count; i++)
                {
                    Pad(sb, indent, level + 1);
                    string key = pd.Keys[i];
                    WriteStr(sb, (key == PyDict.NoneKey) ? "null" : key);
                    sb.Append(": ");
                    WriteVal(sb, pd[pd.Keys[i]], indent, level + 1);
                    if (i < pd.Keys.Count - 1) { sb.Append(','); }
                }
                Pad(sb, indent, level);
                sb.Append('}');
                return;
            }
            IList l = o as IList;
            if (l != null)
            {
                if (l.Count == 0) { sb.Append("[]"); return; }
                sb.Append('[');
                for (int i = 0; i < l.Count; i++)
                {
                    Pad(sb, indent, level + 1);
                    WriteVal(sb, l[i], indent, level + 1);
                    if (i < l.Count - 1) { sb.Append(','); }
                }
                Pad(sb, indent, level);
                sb.Append(']');
                return;
            }
            throw new InvalidOperationException("not JSON-serializable: " + o.GetType().FullName);
        }

        private static void WriteStr(StringBuilder sb, string s)
        {
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '"') { sb.Append("\\\""); }
                else if (c == '\\') { sb.Append("\\\\"); }
                else if (c == '\n') { sb.Append("\\n"); }
                else if (c == '\r') { sb.Append("\\r"); }
                else if (c == '\t') { sb.Append("\\t"); }
                else if (c == '\b') { sb.Append("\\b"); }
                else if (c == '\f') { sb.Append("\\f"); }
                else if (c < '\x20')
                {
                    sb.Append("\\u");
                    sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                }
                else { sb.Append(c); }  // ensure_ascii=False: raw non-ASCII
            }
            sb.Append('"');
        }
    }

    public static class Engine
    {
        private static readonly string[] TokenFields = new string[] {
            "input_tokens", "output_tokens",
            "cache_read_input_tokens", "cache_creation_input_tokens" };

        // ------------------------------------------------------------------
        // file discovery: os.walk work-alike (top-down, current dir's files
        // first, then subdirs in listing order; skips unreadable dirs).
        // Python's followlinks=False skips only true SYMLINK dirs -- it DOES
        // descend into junctions and cloud placeholders (os.path.islink is
        // False for those) -- so reparse points are filtered by tag, not
        // wholesale.
        // ------------------------------------------------------------------
        private const uint IO_REPARSE_TAG_SYMLINK = 0xA000000C;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WIN32_FIND_DATAW
        {
            public uint dwFileAttributes;
            public uint ftCreationLow; public uint ftCreationHigh;
            public uint ftAccessLow; public uint ftAccessHigh;
            public uint ftWriteLow; public uint ftWriteHigh;
            public uint nFileSizeHigh; public uint nFileSizeLow;
            public uint dwReserved0; public uint dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
            public string cAlternateFileName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileW(string lpFileName, out WIN32_FIND_DATAW data);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindClose(IntPtr hFindFile);

        private static bool IsSymlinkReparse(string dir)
        {
            WIN32_FIND_DATAW d;
            IntPtr h = FindFirstFileW(dir, out d);
            if (h == new IntPtr(-1)) { return false; }  // undecidable: descend; a dead dir fails GetFiles below and is skipped there
            try { return d.dwReserved0 == IO_REPARSE_TAG_SYMLINK; }
            finally { FindClose(h); }
        }

        public static List<string> WalkJsonl(string root)
        {
            List<string> outp = new List<string>();
            bool exists = false;
            try { exists = Directory.Exists(root); } catch (Exception) { exists = false; }
            if (exists) { Walk(root, outp); }
            return outp;
        }

        private static void Walk(string dir, List<string> outp)
        {
            string[] files = null;
            string[] dirs = null;
            try
            {
                files = Directory.GetFiles(dir);
                dirs = Directory.GetDirectories(dir);
            }
            catch (Exception) { return; }  // os.walk(onerror=None): skip silently
            for (int i = 0; i < files.Length; i++)
            {
                if (Path.GetFileName(files[i]).EndsWith(".jsonl", StringComparison.Ordinal))
                {
                    outp.Add(files[i]);
                }
            }
            for (int i = 0; i < dirs.Length; i++)
            {
                try
                {
                    FileAttributes a = File.GetAttributes(dirs[i]);
                    if ((a & FileAttributes.ReparsePoint) != 0
                        && IsSymlinkReparse(dirs[i])) { continue; }
                }
                catch (Exception) { continue; }
                Walk(dirs[i], outp);
            }
        }

        // ------------------------------------------------------------------
        // read_records equivalent, streaming: skip blank/unparseable lines,
        // unreadable file -> no records. BOM intentionally NOT stripped
        // (Python reads it as U+FEFF and the line fails json.loads).
        // Invalid UTF-8 bytes are DROPPED, mirroring errors="ignore" (the
        // default decoder would substitute U+FFFD instead). Built by cloning
        // the preamble-free UTF8Encoding: Encoding.GetEncoding("utf-8")
        // carries a BOM preamble, and StreamReader strips a matching
        // preamble even with BOM detection off -- which would silently make
        // the BOM line parseable, unlike Python.
        // ------------------------------------------------------------------
        private static readonly Encoding Utf8IgnoreErrors = BuildUtf8IgnoreErrors();

        private static Encoding BuildUtf8IgnoreErrors()
        {
            Encoding e = (Encoding)new UTF8Encoding(false).Clone();
            e.DecoderFallback = new DecoderReplacementFallback("");
            return e;
        }

        private static IEnumerable<object> Records(string path)
        {
            StreamReader sr = null;
            try { sr = new StreamReader(path, Utf8IgnoreErrors, false); }
            catch (Exception) { sr = null; }
            if (sr == null) { yield break; }
            try
            {
                while (true)
                {
                    string line = null;
                    try { line = sr.ReadLine(); }
                    catch (Exception) { line = null; }  // mid-file IO error: keep records so far
                    if (line == null) { break; }
                    line = line.Trim();
                    if (line.Length == 0) { continue; }
                    object rec = null;
                    bool ok = true;
                    try { rec = Json.Parse(line); }
                    catch (Exception) { ok = false; }
                    if (ok) { yield return rec; }
                }
            }
            finally { sr.Dispose(); }
        }

        private static bool Truthy(object v)
        {
            if (v == null) { return false; }
            if (v is bool) { return (bool)v; }
            string s = v as string;
            if (s != null) { return s.Length > 0; }
            if (v is long) { return (long)v != 0; }
            if (v is int) { return (int)v != 0; }
            if (v is double) { return (double)v != 0.0; }
            PyDict pd = v as PyDict;
            if (pd != null) { return pd.Count > 0; }
            IList l = v as IList;
            if (l != null) { return l.Count > 0; }
            return true;
        }

        private static long ToLong(object v)  // int(usage.get(k) or 0)
        {
            if (v == null) { return 0; }
            if (v is long) { return (long)v; }
            if (v is int) { return (int)v; }
            if (v is double) { return (long)(double)v; }  // int() truncates toward zero
            if (v is bool) { return ((bool)v) ? 1L : 0L; }
            string s = v as string;
            if (s != null)
            {
                long r;
                if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out r))
                {
                    return r;
                }
            }
            return 0;
        }

        // ------------------------------------------------------------------
        // analyze_file equivalent: session facts, or null when unreadable /
        // ai-title junk (no real user/assistant turn).
        // ------------------------------------------------------------------
        public static PyDict AnalyzeFile(string path)
        {
            bool sawRec = false, anyTurn = false;
            Counter eps = new Counter(), models = new Counter(), tools = new Counter();
            long msgs = 0;
            long[] tok = new long[TokenFields.Length];
            string cwd = null, tsMin = null, tsMax = null;
            foreach (object recO in Records(path))
            {
                sawRec = true;
                PyDict r = recO as PyDict;
                if (r == null) { continue; }  // non-object JSON line: see header
                string type = r["type"] as string;
                if (type == "user" || type == "assistant") { msgs++; anyTurn = true; }
                object epO = r["entrypoint"];
                if (Truthy(epO))
                {
                    string ep = epO as string;
                    if (ep != null) { eps.Add(ep, 1); }
                }
                if (cwd == null)
                {
                    object cw = r["cwd"];
                    if (Truthy(cw))
                    {
                        string cs = cw as string;
                        if (cs != null) { cwd = cs; }
                    }
                }
                object tsO = r["timestamp"];
                if (Truthy(tsO))
                {
                    string ts = tsO as string;
                    if (ts != null)
                    {
                        if (tsMin == null || string.CompareOrdinal(ts, tsMin) < 0) { tsMin = ts; }
                        if (tsMax == null || string.CompareOrdinal(ts, tsMax) > 0) { tsMax = ts; }
                    }
                }
                if (type == "assistant")
                {
                    PyDict msg = r["message"] as PyDict;
                    if (msg != null)
                    {
                        object mo = msg["model"];
                        if (Truthy(mo))
                        {
                            string ms = mo as string;
                            if (ms != null) { models.Add(ms, 1); }
                        }
                        PyDict usage = msg["usage"] as PyDict;
                        if (usage != null)
                        {
                            for (int i = 0; i < TokenFields.Length; i++)
                            {
                                tok[i] += ToLong(usage[TokenFields[i]]);
                            }
                        }
                        IList content = msg["content"] as IList;  // string content: no tool_use blocks
                        if (content != null)
                        {
                            for (int i = 0; i < content.Count; i++)
                            {
                                PyDict item = content[i] as PyDict;
                                if (item != null && (item["type"] as string) == "tool_use")
                                {
                                    string nm = "?";
                                    if (item.Has("name"))
                                    {
                                        string nv = item["name"] as string;
                                        if (nv != null) { nm = nv; }
                                    }
                                    tools.Add(nm, 1);
                                }
                            }
                        }
                    }
                }
            }
            if (!sawRec) { return null; }
            if (!anyTurn) { return null; }  // ai-title junk
            long total = 0;
            PyDict tokens = new PyDict();
            for (int i = 0; i < TokenFields.Length; i++)
            {
                tokens[TokenFields[i]] = tok[i];
                total += tok[i];
            }
            long fbytes = 0;
            try
            {
                FileInfo fi = new FileInfo(path);
                if (fi.Exists) { fbytes = fi.Length; }
            }
            catch (Exception) { fbytes = 0; }
            PyDict sess = new PyDict();
            sess["file"] = path;
            sess["entrypoints"] = eps.ToDict();
            sess["entrypoint"] = eps.Top();
            sess["cwd"] = cwd;
            sess["model"] = models.Top();  // most-frequent = stable
            sess["messages"] = msgs;
            sess["tool_calls"] = tools.Total();
            sess["tools"] = tools.ToDict();
            sess["tokens"] = tokens;
            sess["token_total"] = total;
            sess["first"] = tsMin;
            sess["last"] = tsMax;
            sess["bytes"] = fbytes;
            return sess;
        }

        // ------------------------------------------------------------------
        // extract_signals equivalent: qualitative raw material per session.
        // ------------------------------------------------------------------
        public static PyDict ExtractSignals(string path, int maxUser, int maxErr)
        {
            List<object> users = new List<object>();
            List<object> errors = new List<object>();
            long interruptions = 0;
            foreach (object recO in Records(path))
            {
                PyDict r = recO as PyDict;
                if (r == null) { continue; }
                if ((r["type"] as string) != "user") { continue; }
                PyDict msg = r["message"] as PyDict;
                object content = null;
                if (msg != null) { content = msg["content"]; }
                List<object> parts = new List<object>();
                string contentStr = content as string;
                if (contentStr != null) { parts.Add(contentStr); }
                else
                {
                    IList cl = content as IList;
                    if (cl != null)
                    {
                        for (int i = 0; i < cl.Count; i++) { parts.Add(cl[i]); }
                    }
                }
                for (int p = 0; p < parts.Count; p++)
                {
                    object c = parts[p];
                    PyDict cd = c as PyDict;
                    if (cd != null)
                    {
                        if ((cd["type"] as string) == "tool_result" && Truthy(cd["is_error"]))
                        {
                            if (errors.Count < maxErr) { errors.Add(Clip(cd["content"], 200)); }
                            continue;
                        }
                        if ((cd["type"] as string) == "text") { c = cd["text"]; }
                        else { c = null; }
                    }
                    string cs = c as string;
                    if (cs == null || cs.Length == 0) { continue; }
                    if (cs.IndexOf("[Request interrupted", StringComparison.Ordinal) >= 0)
                    {
                        interruptions++;
                    }
                    else
                    {
                        string head = PyCut(cs, 80);
                        if (head.IndexOf("<system-reminder>", StringComparison.Ordinal) >= 0)
                        {
                            continue;  // injected context, not the user's own words
                        }
                        if (users.Count < maxUser) { users.Add(Clip(cs, 280)); }
                    }
                }
            }
            PyDict d = new PyDict();
            d["user_messages"] = users;
            d["tool_errors"] = errors;
            d["interruptions"] = interruptions;
            return d;
        }

        // Python s[:n] slices by CODEPOINT; .NET strings are UTF-16, so a
        // surrogate pair (emoji) counts as one, not two.
        public static string PyCut(string s, int n)
        {
            if (s.Length <= n) { return s; }
            int units = 0, points = 0;
            while (units < s.Length && points < n)
            {
                if (char.IsHighSurrogate(s[units]) && units + 1 < s.Length
                    && char.IsLowSurrogate(s[units + 1])) { units += 2; }
                else { units += 1; }
                points++;
            }
            return s.Substring(0, units);
        }

        // _clip equivalent: str(s), collapse \s+ runs to one space, strip,
        // truncate to n codepoints.
        public static string Clip(object o, int n)
        {
            string s = PyToStr(o);
            StringBuilder sb = new StringBuilder(s.Length);
            bool pendingWs = false;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (char.IsWhiteSpace(c)) { pendingWs = true; continue; }
                if (pendingWs && sb.Length > 0) { sb.Append(' '); }
                pendingWs = false;
                sb.Append(c);
            }
            return PyCut(sb.ToString(), n);
        }

        // Python str(x) for JSON-derived values (dict/list render as repr).
        public static string PyToStr(object o)
        {
            o = Ps.Unwrap(o);
            string s = o as string;
            if (s != null) { return s; }
            return PyRepr(o);
        }

        public static string PyRepr(object o)
        {
            o = Ps.Unwrap(o);
            if (o == null) { return "None"; }
            if (o is bool) { return ((bool)o) ? "True" : "False"; }
            string s = o as string;
            if (s != null) { return StrRepr(s); }
            if (o is long) { return ((long)o).ToString(CultureInfo.InvariantCulture); }
            if (o is int) { return ((int)o).ToString(CultureInfo.InvariantCulture); }
            if (o is double) { return FormatDouble((double)o); }
            PyDict pd = o as PyDict;
            if (pd != null)
            {
                StringBuilder sb = new StringBuilder("{");
                for (int i = 0; i < pd.Keys.Count; i++)
                {
                    if (i > 0) { sb.Append(", "); }
                    string key = pd.Keys[i];
                    sb.Append((key == PyDict.NoneKey) ? "None" : StrRepr(key));
                    sb.Append(": ");
                    sb.Append(PyRepr(pd[pd.Keys[i]]));
                }
                sb.Append('}');
                return sb.ToString();
            }
            IList l = o as IList;
            if (l != null)
            {
                StringBuilder sb = new StringBuilder("[");
                for (int i = 0; i < l.Count; i++)
                {
                    if (i > 0) { sb.Append(", "); }
                    sb.Append(PyRepr(l[i]));
                }
                sb.Append(']');
                return sb.ToString();
            }
            return o.ToString();
        }

        // Python repr() for str: prefers single quotes, escapes controls as
        // \xXX, common invisible Cf chars as \uXXXX. Approximates Python's
        // printability table for the ranges that occur in transcripts.
        private static string StrRepr(string s)
        {
            char quote = '\'';
            if (s.IndexOf('\'') >= 0 && s.IndexOf('"') < 0) { quote = '"'; }
            StringBuilder sb = new StringBuilder();
            sb.Append(quote);
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '\\') { sb.Append("\\\\"); }
                else if (c == quote) { sb.Append('\\'); sb.Append(quote); }
                else if (c == '\n') { sb.Append("\\n"); }
                else if (c == '\r') { sb.Append("\\r"); }
                else if (c == '\t') { sb.Append("\\t"); }
                else if (c < '\x20' || c == '\x7f' || (c >= '\x80' && c <= '\xa0') || c == '\xad')
                {
                    sb.Append("\\x");
                    sb.Append(((int)c).ToString("x2", CultureInfo.InvariantCulture));
                }
                else if ((c >= '\u200b' && c <= '\u200f') || c == '\u2028' || c == '\u2029'
                         || (c >= '\u202a' && c <= '\u202e') || c == '\ufeff')
                {
                    sb.Append("\\u");
                    sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                }
                else { sb.Append(c); }
            }
            sb.Append(quote);
            return sb.ToString();
        }

        // repr(float) / json float formatting (shortest round-trip-ish).
        public static string FormatDouble(double d)
        {
            if (double.IsNaN(d)) { return "nan"; }
            if (double.IsPositiveInfinity(d)) { return "inf"; }
            if (double.IsNegativeInfinity(d)) { return "-inf"; }
            string r = d.ToString("R", CultureInfo.InvariantCulture);
            if (r.IndexOf('E') >= 0) { r = r.Replace("E", "e"); }
            else if (r.IndexOf('.') < 0) { r = r + ".0"; }
            return r;
        }

        // html.escape(str(x)) equivalent (quote=True).
        public static string EscPy(object o)
        {
            string s = PyToStr(o);
            StringBuilder sb = new StringBuilder(s.Length);
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '&') { sb.Append("&amp;"); }
                else if (c == '<') { sb.Append("&lt;"); }
                else if (c == '>') { sb.Append("&gt;"); }
                else if (c == '"') { sb.Append("&quot;"); }
                else if (c == '\'') { sb.Append("&#x27;"); }
                else { sb.Append(c); }
            }
            return sb.ToString();
        }

        // sorted(..., key=last-or-empty, reverse=True) index order: ordinal
        // key desc, original position preserved on ties (Python stable sort).
        public static int[] SortDescStable(string[] keys)
        {
            List<int> order = new List<int>();
            for (int i = 0; i < keys.Length; i++) { order.Add(i); }
            order.Sort(delegate(int a, int b)
            {
                int cmp = string.CompareOrdinal(keys[b], keys[a]);
                if (cmp != 0) { return cmp; }
                return a.CompareTo(b);
            });
            return order.ToArray();
        }

        // Path.write_text(..., encoding="utf-8") on Windows: UTF-8 no BOM,
        // text mode translates \n to \r\n.
        public static void WriteFileUtf8Crlf(string path, string content)
        {
            string t = content.Replace("\n", "\r\n");
            File.WriteAllText(path, t, new UTF8Encoding(false));
        }
    }
}
'@
# Note: assemblies cannot unload in-process, so if a NEWER script version is
# dot-sourced into a session that already compiled an older engine, the old
# types win until the session restarts. The supported invocation is
# `powershell -File` (fresh process per run), where this cannot happen.
if (-not ('CoworkInsights.Engine' -as [type])) {
    Add-Type -TypeDefinition $engineSource -Language CSharp
}

# ---------------------------------------------------------------------------
# PS orchestration layer (mirrors the Python functions one-to-one)
# ---------------------------------------------------------------------------

# str(Path(p)) work-alike for the common cases: forward slashes to
# backslashes, trailing separator trimmed (drive roots keep theirs).
function Get-PyPathStr([string]$p) {
    $q = $p -replace '/', '\'
    if ($q.Length -gt 3 -and $q.EndsWith('\')) { $q = $q.TrimEnd('\') }
    return $q
}

function Find-HostProjects {
    $cfg = $env:CLAUDE_CONFIG_DIR
    if ($cfg) { $base = Get-PyPathStr $cfg }
    else { $base = Join-Path $env:USERPROFILE '.claude' }
    $p = Join-Path $base 'projects'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Find-LamsRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $ov = $env:CLAUDE_COWORK_ROOT
    if ($ov -and (Test-Path -LiteralPath $ov)) { $roots.Add((Get-PyPathStr $ov)) }
    $la = $env:LOCALAPPDATA
    if ($la) {  # MSIX-packaged Desktop app redirects %APPDATA% here
        $pkg = Join-Path $la 'Packages'
        if (Test-Path -LiteralPath $pkg) {
            $pkgDirs = @()
            try { $pkgDirs = [System.IO.Directory]::GetDirectories($pkg, 'Claude_*') }
            catch { $pkgDirs = @() }  # glob.glob swallows OSError; so do we
            foreach ($d in $pkgDirs) {
                $cand = Join-Path $d 'LocalCache\Roaming\Claude\local-agent-mode-sessions'
                if (Test-Path -LiteralPath $cand) { $roots.Add($cand) }
            }
        }
    }
    $ap = $env:APPDATA
    if ($ap) {  # non-packaged fallback
        $cand2 = Join-Path $ap 'Claude\local-agent-mode-sessions'
        if (Test-Path -LiteralPath $cand2) { $roots.Add($cand2) }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $roots) {
        $k = [System.IO.Path]::GetFullPath($r).ToLowerInvariant()
        if ($seen.Add($k)) { $out.Add($r) }
    }
    return ,$out
}

function Test-UnderAny([string]$path, [string[]]$roots) {
    $fp = [System.IO.Path]::GetFullPath($path)
    foreach ($r in $roots) {
        $rr = [System.IO.Path]::GetFullPath($r).TrimEnd('\') + '\'
        if ($fp.StartsWith($rr, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-FileRole([string]$fp) {
    if ([System.IO.Path]::GetFileName($fp) -ceq 'audit.jsonl') { return 'audit' }
    $parentName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($fp))
    if ($parentName -ceq 'subagents') { return 'subagent' }
    return 'main'
}

# Report home when no output_dir argument is given. Same plugin-install
# detection as the Python version: .../plugins/cache/<marketplace>/<plugin>/
# maps to ~/.claude/plugins/data/<plugin>-<marketplace>/, else
# <config_dir>/usage-data/cowork-insights. Never the cwd.
function Get-DefaultOutputDir {
    $full = [System.IO.Path]::GetFullPath($PSCommandPath)
    $root = [System.IO.Path]::GetPathRoot($full)
    $rest = @($full.Substring($root.Length) -split '\\' | Where-Object { $_ -ne '' })
    $parts = @($root) + $rest
    for ($i = 0; $i -lt $parts.Count - 3; $i++) {
        if ($parts[$i] -ceq 'plugins' -and $parts[$i + 1] -ceq 'cache') {
            $marketplace = $parts[$i + 2]
            $plugin = $parts[$i + 3]
            $pluginId = ("$plugin@$marketplace") -replace '[^a-zA-Z0-9_-]', '-'
            $base = $root
            for ($j = 1; $j -le $i; $j++) { $base = Join-Path $base $parts[$j] }
            return Join-Path (Join-Path $base 'data') $pluginId
        }
    }
    $cfg = $env:CLAUDE_CONFIG_DIR
    if ($cfg) { $base2 = Get-PyPathStr $cfg }
    else { $base2 = Join-Path $env:USERPROFILE '.claude' }
    return Join-Path (Join-Path $base2 'usage-data') 'cowork-insights'
}

function Get-Kind($sess, [bool]$inLams) {
    $cwd = ''
    if ($sess['cwd']) { $cwd = [string]$sess['cwd'] }
    if ($inLams) {
        if ($null -eq $sess['entrypoint'] -or
            $cwd.StartsWith('/sessions', [System.StringComparison]::Ordinal)) {
            return 'iso-vm'
        }
        return 'iso-local'
    }
    return 'mounted'  # host tree + cowork entrypoint (claude-desktop)
}

# stage_sources equivalent: copy windowed Cowork transcripts (and their
# subagent files) into <stage>/projects/ preserving slug dir names. Copies
# get a fresh mtime (shutil.copy behavior) so the native engine's startup
# cleanup leaves them alone -- Copy-Item would preserve the old mtime, so
# timestamps are reset explicitly. File.Copy carries the read-only
# attribute over and .NET Framework's SetLastWriteTimeUtc refuses to touch
# read-only files, so the flag is dropped around the reset and restored
# (end state matches shutil.copy + copymode: read-only kept, mtime fresh).
function Set-FreshMtime([string]$path) {
    $fi = New-Object System.IO.FileInfo $path
    $ro = $fi.IsReadOnly
    if ($ro) { $fi.IsReadOnly = $false }
    [System.IO.File]::SetLastWriteTimeUtc($path, [System.DateTime]::UtcNow)
    if ($ro) { $fi.IsReadOnly = $true }
}

function Invoke-StageSources([string]$stageDir, $live, $subagentFiles, $liveParentKeys) {
    $proj = Join-Path $stageDir 'projects'
    [void][System.IO.Directory]::CreateDirectory($proj)
    $n = 0
    foreach ($s in $live) {
        $src = [string]$s['file']
        $dstDir = Join-Path $proj ([System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($src)))
        [void][System.IO.Directory]::CreateDirectory($dstDir)
        $dst = Join-Path $dstDir ([System.IO.Path]::GetFileName($src))
        [System.IO.File]::Copy($src, $dst, $true)
        Set-FreshMtime $dst
        $n++
    }
    foreach ($fp in $subagentFiles) {  # keep subagent transcripts with their parent
        $parentDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($fp))
        $parentParent = [System.IO.Path]::GetDirectoryName($parentDir)
        $key = ([System.IO.Path]::GetFullPath($parentParent)).ToLowerInvariant() + '|' +
               [System.IO.Path]::GetFileName($parentDir)
        if ($liveParentKeys.Contains($key)) {
            $dstDir2 = Join-Path (Join-Path (Join-Path $proj ([System.IO.Path]::GetFileName($parentParent))) `
                ([System.IO.Path]::GetFileName($parentDir))) 'subagents'
            [void][System.IO.Directory]::CreateDirectory($dstDir2)
            $dst2 = Join-Path $dstDir2 ([System.IO.Path]::GetFileName($fp))
            [System.IO.File]::Copy($fp, $dst2, $true)
            Set-FreshMtime $dst2
            $n++
        }
    }
    return $n
}

function Write-HtmlReport([string]$path, $summary, $live) {
    $esc = [CoworkInsights.Engine]
    $win = $summary['window']
    if ($win['days']) {
        # Python "{:g}": 6 significant digits, lowercase exponent
        $daysG = ([double]$win['days']).ToString('G6', $script:Inv).Replace('E', 'e')
        $h1 = "<h1>Cowork-only Insights &mdash; last $daysG days (analysis window only; nothing deleted)</h1>"
    } else {
        $h1 = '<h1>Cowork-only Insights &mdash; full history</h1>'
    }
    $lastKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $live) {
        $v = ''
        if ($s['last']) { $v = [string]$s['last'] }
        $lastKeys.Add($v)
    }
    $order = $esc::SortDescStable($lastKeys.ToArray())
    $rowsSb = New-Object System.Text.StringBuilder
    foreach ($ix in $order) {
        $s = $live[$ix]
        $first10 = ''
        if ($s['first']) { $first10 = [string]$s['first'] }
        $first10 = $esc::PyCut($first10, 10)
        $cwd64 = ''
        if ($s['cwd']) { $cwd64 = [string]$s['cwd'] }
        $cwd64 = $esc::PyCut($cwd64, 64)
        $tokN = ([long]$s['token_total']).ToString('N0', $script:Inv)
        [void]$rowsSb.Append('<tr><td>' + $esc::EscPy($s['kind']) + '</td><td>' + $esc::EscPy($s['entrypoint']) +
            '</td><td>' + $esc::EscPy($s['model']) + '</td><td class=n>' + $s['messages'] +
            '</td><td class=n>' + $s['tool_calls'] + '</td><td class=n>' + $tokN +
            '</td><td class=n>' + $s['subagents'] + '</td><td>' + $esc::EscPy($first10) +
            '</td><td class=c>' + $esc::EscPy($cwd64) + '</td></tr>')
    }
    $rows = $rowsSb.ToString()
    $tk = $summary['tokens']
    $spanFirst10 = ''
    if ($summary['span']['first']) { $spanFirst10 = [string]$summary['span']['first'] }
    $spanFirst10 = $esc::PyCut($spanFirst10, 10)
    $spanLast10 = ''
    if ($summary['span']['last']) { $spanLast10 = [string]$summary['span']['last'] }
    $spanLast10 = $esc::PyCut($spanLast10, 10)
    $auditC = $summary['audit_consistency']
    $doc = '<!doctype html><meta charset="utf-8"><title>Cowork Insights</title>' + "`n" +
        '<style>body{font-family:system-ui,Segoe UI,Arial;margin:24px;color:#222}' + "`n" +
        'h1{font-size:20px;margin:0 0 4px}p{margin:6px 0;font-size:13px}' + "`n" +
        'table{border-collapse:collapse;width:100%;font-size:12px;margin-top:12px}' + "`n" +
        'td,th{border:1px solid #ddd;padding:4px 8px}th{background:#f4f4f4;text-align:left}' + "`n" +
        '.n{text-align:right}.c{font-size:11px;color:#555}' + "`n" +
        '.kpi{display:inline-block;margin:8px 20px 8px 0}.kpi b{font-size:22px;display:block}</style>' + "`n" +
        $h1 + "`n" +
        '<div class=kpi>Sessions<b>' + $summary['cowork_sessions'] + '</b></div>' + "`n" +
        '<div class=kpi>Grand total tokens<b>' + ([long]$summary['token_grand_total']).ToString('N0', $script:Inv) + '</b></div>' + "`n" +
        '<div class=kpi>input+output only<b>' + ([long]$summary['token_input_output_only']).ToString('N0', $script:Inv) + '</b></div>' + "`n" +
        '<div class=kpi>Span<b>' + $esc::EscPy($spanFirst10) + ' &rarr; ' + $esc::EscPy($spanLast10) + '</b></div>' + "`n" +
        '<p>kinds = ' + $esc::EscPy($summary['kinds']) + ' &middot; entrypoints = ' + $esc::EscPy($summary['entrypoints']) + '</p>' + "`n" +
        '<p>tokens (incl. subagents): input=' + ([long]$tk['input_tokens']).ToString('N0', $script:Inv) +
        ' &middot; output=' + ([long]$tk['output_tokens']).ToString('N0', $script:Inv) +
        ' &middot; cache_read=' + ([long]$tk['cache_read_input_tokens']).ToString('N0', $script:Inv) +
        ' &middot; cache_creation=' + ([long]$tk['cache_creation_input_tokens']).ToString('N0', $script:Inv) + '</p>' + "`n" +
        '<p>subagent files counted: ' + $summary['subagent_files_counted'] +
        ' (' + ([long]$summary['subagent_token_total']).ToString('N0', $script:Inv) + ' tokens) &middot; audit.jsonl excluded: ' +
        $auditC['audit_files_excluded'] + ' (duplicate usage log; cross-check vs ' +
        $auditC['isolated_sessions'] + ' isolated sessions)</p>' + "`n" +
        '<p>models: ' + $esc::EscPy($summary['models']) + '</p>' + "`n" +
        '<p>top tools: ' + $esc::EscPy($summary['tools_top']) + '</p>' + "`n" +
        '<table><tr><th>kind</th><th>entrypoint</th><th>model</th><th>msgs</th><th>tools</th><th>tokens</th><th>subs</th><th>date</th><th>cwd</th></tr>' + "`n" +
        $rows + '</table>'
    [CoworkInsights.Engine]::WriteFileUtf8Crlf($path, $doc)
}

function Invoke-Main {
    # --- window_cutoff ---
    $daysNorm = $Days.Trim().ToLowerInvariant()
    if ($daysNorm -in @('all', 'full', '0')) {
        $winDays = $null
        $cutoff = $null
    } else {
        $winDays = [double]::Parse($Days, $script:Inv)
        $cut = [System.DateTime]::UtcNow.AddDays(-$winDays)
        # session timestamps are uniform UTC "...Z" strings; ordinal compare works
        $cutoff = $cut.ToString("yyyy-MM-dd'T'HH:mm:ss'.000Z'", $script:Inv)
    }

    $hostProjects = Find-HostProjects
    $lamsRoots = Find-LamsRoots

    $scanRoots = @()
    if ($hostProjects) { $scanRoots += $hostProjects }
    $scanRoots += $lamsRoots
    $files = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($root in $scanRoots) {
        foreach ($fp in [CoworkInsights.Engine]::WalkJsonl($root)) {
            $k = [System.IO.Path]::GetFullPath($fp).ToLowerInvariant()
            if ($seen.Add($k)) { $files.Add($fp) }
        }
    }

    $auditFiles = New-Object 'System.Collections.Generic.List[string]'
    $subagentFiles = New-Object 'System.Collections.Generic.List[string]'
    $mainFiles = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in $files) {
        $role = Get-FileRole $f
        if ($role -eq 'audit') { $auditFiles.Add($f) }
        elseif ($role -eq 'subagent') { $subagentFiles.Add($f) }
        else { $mainFiles.Add($f) }
    }

    # --- main sessions ---
    $sessions = New-Object 'System.Collections.Generic.List[object]'
    $index = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    foreach ($fp in $mainFiles) {
        $inLams = Test-UnderAny $fp $lamsRoots
        $sess = [CoworkInsights.Engine]::AnalyzeFile($fp)
        if ($null -eq $sess) { continue }
        if (-not (($sess['entrypoint'] -cin $script:COWORK_ENTRYPOINTS) -or $inLams)) { continue }
        $sess['kind'] = Get-Kind $sess $inLams
        $sess['subagents'] = [long]0
        $sess['subagent_tokens'] = [long]0
        $sessions.Add($sess)
        $ikey = ([System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($fp))).ToLowerInvariant() +
                '|' + [System.IO.Path]::GetFileNameWithoutExtension($fp)
        $index[$ikey] = $sess
    }

    # analysis window: a session counts when its last activity is inside it
    $live = New-Object 'System.Collections.Generic.List[object]'
    $liveSet = New-Object 'System.Collections.Generic.HashSet[object]'
    foreach ($s in $sessions) {
        $lastS = ''
        if ($s['last']) { $lastS = [string]$s['last'] }
        if ($null -eq $cutoff -or [string]::CompareOrdinal($lastS, $cutoff) -ge 0) {
            $live.Add($s)
            [void]$liveSet.Add($s)
        }
    }

    # subagent transcripts: real extra API usage, but not separate sessions
    $subTokens = New-Object CoworkInsights.Counter
    $subTools = New-Object CoworkInsights.Counter
    $subCount = [long]0
    foreach ($fp in $subagentFiles) {
        $parentDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($fp))  # .../<slug>/<session-uuid>/
        $pkey = ([System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($parentDir))).ToLowerInvariant() +
                '|' + [System.IO.Path]::GetFileName($parentDir)
        $parent = $null
        if ($index.ContainsKey($pkey)) { $parent = $index[$pkey] }
        $info = [CoworkInsights.Engine]::AnalyzeFile($fp)
        if ($null -eq $info) { continue }
        if ($null -eq $parent -and
            -not ($info['entrypoint'] -cin $script:COWORK_ENTRYPOINTS) -and
            -not (Test-UnderAny $fp $lamsRoots)) {
            continue  # subagent of a non-Cowork session
        }
        if ($null -ne $parent) {
            $parent['subagents'] = [long]$parent['subagents'] + 1
            $parent['subagent_tokens'] = [long]$parent['subagent_tokens'] + [long]$info['token_total']
            $inWindow = $liveSet.Contains($parent)  # follow the parent session
        } else {
            $lastS2 = ''
            if ($info['last']) { $lastS2 = [string]$info['last'] }
            $inWindow = ($null -eq $cutoff) -or ([string]::CompareOrdinal($lastS2, $cutoff) -ge 0)
        }
        if (-not $inWindow) { continue }
        $subCount++
        foreach ($k in $info['tokens'].Keys) { $subTokens.Add($k, [long]$info['tokens'][$k]) }
        foreach ($k in $info['tools'].Keys) { $subTools.Add($k, [long]$info['tools'][$k]) }
    }

    # --- aggregates over the live window ---
    $agg = New-Object CoworkInsights.Counter
    $models = New-Object CoworkInsights.Counter
    $tools = New-Object CoworkInsights.Counter
    $kinds = New-Object CoworkInsights.Counter
    $eps = New-Object CoworkInsights.Counter
    $spanFirst = $null
    $spanLast = $null
    foreach ($s in $live) {
        foreach ($k in $s['tokens'].Keys) { $agg.Add($k, [long]$s['tokens'][$k]) }
        if ($s['model']) { $models.Add([string]$s['model'], 1) }
        foreach ($k in $s['tools'].Keys) { $tools.Add($k, [long]$s['tools'][$k]) }
        $kinds.Add([string]$s['kind'], 1)
        $epKey = $s['entrypoint']
        if ($null -eq $epKey) { $epKey = [CoworkInsights.PyDict]::NoneKey }
        $eps.Add([string]$epKey, 1)
        if ($s['first']) {
            $v = [string]$s['first']
            if ($null -eq $spanFirst -or [string]::CompareOrdinal($v, $spanFirst) -lt 0) { $spanFirst = $v }
        }
        if ($s['last']) {
            $v2 = [string]$s['last']
            if ($null -eq $spanLast -or [string]::CompareOrdinal($v2, $spanLast) -gt 0) { $spanLast = $v2 }
        }
    }

    $tokensMain = New-Object CoworkInsights.PyDict
    foreach ($k in $script:TOKEN_FIELDS) { $tokensMain[$k] = $agg.Get($k) }
    foreach ($k in $script:TOKEN_FIELDS) { $agg.Add($k, $subTokens.Get($k)) }  # grand totals include subagent usage
    foreach ($k in $subTools.ToDict().Keys) { $tools.Add($k, $subTools.Get($k)) }

    # drift detector, not a usage stat: always checked over the FULL population
    $isoSessions = [long]0
    foreach ($s in $sessions) { if ([string]$s['kind'] -ne 'mounted') { $isoSessions++ } }

    $window = New-Object CoworkInsights.PyDict
    $window['days'] = $winDays
    $window['cutoff'] = $cutoff
    $window['note'] = 'sessions whose last activity falls inside the window; ' +
                      'use --days all for full history (nothing is ever deleted)'

    $span = New-Object CoworkInsights.PyDict
    $span['first'] = $spanFirst
    $span['last'] = $spanLast

    $tokensAll = New-Object CoworkInsights.PyDict
    foreach ($k in $script:TOKEN_FIELDS) { $tokensAll[$k] = $agg.Get($k) }

    $auditConsistency = New-Object CoworkInsights.PyDict
    $auditConsistency['audit_files_excluded'] = [long]$auditFiles.Count
    $auditConsistency['isolated_sessions'] = $isoSessions
    $auditConsistency['note'] = 'expect ~1:1 (one audit.jsonl per isolated Cowork session); ' +
                                'divergence may signal a Desktop-app layout change; ' +
                                'checked over full history regardless of --days'

    $lamsRootList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $lamsRoots) { $lamsRootList.Add([string]$r) }

    $summary = New-Object CoworkInsights.PyDict
    $summary['cowork_sessions'] = [long]$live.Count
    $summary['window'] = $window
    $summary['kinds'] = $kinds.ToDict()
    $summary['entrypoints'] = $eps.ToDict()
    $summary['span'] = $span
    $summary['tokens'] = $tokensAll
    $summary['token_grand_total'] = $agg.Total()
    $summary['token_input_output_only'] = $agg.Get('input_tokens') + $agg.Get('output_tokens')
    $summary['tokens_main_only'] = $tokensMain
    $summary['subagent_files_counted'] = $subCount
    $summary['subagent_token_total'] = $subTokens.Total()
    $summary['audit_consistency'] = $auditConsistency
    $summary['models'] = $models.MostCommon(-1)
    $summary['tools_top'] = $tools.MostCommon(15)
    if ($hostProjects) { $summary['host_projects'] = [string]$hostProjects }
    else { $summary['host_projects'] = $null }
    $summary['lams_roots'] = $lamsRootList

    # qualitative digest: curated raw material for the model-side analysis
    $keep = @('file', 'kind', 'entrypoint', 'model', 'cwd', 'first', 'last',
              'messages', 'tool_calls', 'token_total', 'subagents')
    $digest = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $live) {
        $d = New-Object CoworkInsights.PyDict
        foreach ($k in $keep) { $d[$k] = $s[$k] }
        $sig = [CoworkInsights.Engine]::ExtractSignals([string]$s['file'], 15, 8)
        foreach ($k in $sig.Keys) { $d[$k] = $sig[$k] }
        $digest.Add($d)
    }

    if ($OutputDir) { $outDir = Get-PyPathStr $OutputDir }
    else { $outDir = Get-DefaultOutputDir }
    [void][System.IO.Directory]::CreateDirectory($outDir)

    $fullRoot = New-Object CoworkInsights.PyDict
    $fullRoot['summary'] = $summary
    $fullRoot['sessions'] = $live
    [CoworkInsights.Engine]::WriteFileUtf8Crlf((Join-Path $outDir 'cowork_full.json'),
        [CoworkInsights.PyJson]::Dumps($fullRoot, 2))

    $digestRoot = New-Object CoworkInsights.PyDict
    $digestRoot['window'] = $window
    $digestRoot['sessions'] = $digest
    [CoworkInsights.Engine]::WriteFileUtf8Crlf((Join-Path $outDir 'cowork_digest.json'),
        [CoworkInsights.PyJson]::Dumps($digestRoot, 1))

    Write-HtmlReport (Join-Path $outDir 'cowork_insights.html') $summary $live

    if ($Stage) {
        $liveParentKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($k in $index.Keys) {
            if ($liveSet.Contains($index[$k])) { [void]$liveParentKeys.Add($k) }
        }
        $staged = Invoke-StageSources (Get-PyPathStr $Stage) $live $subagentFiles $liveParentKeys
        [Console]::Error.WriteLine('STAGED: ' + $staged + ' transcript files -> ' +
            (Join-Path (Get-PyPathStr $Stage) 'projects'))
    }

    [Console]::Out.WriteLine([CoworkInsights.PyJson]::Dumps($summary, 2))
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('WROTE: ' + (Join-Path $outDir 'cowork_full.json'))
    [Console]::Out.WriteLine('WROTE: ' + (Join-Path $outDir 'cowork_digest.json'))
    [Console]::Out.WriteLine('WROTE: ' + (Join-Path $outDir 'cowork_insights.html'))
}

$prevOutputEncoding = $null
try {
    try {
        $prevOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    } catch { }
    $null = Invoke-Main
    exit 0
} catch {
    [Console]::Error.WriteLine('cowork_insights.ps1: ' + $_.Exception.Message)
    [Console]::Error.WriteLine([string]$_.ScriptStackTrace)
    exit 1
} finally {
    if ($null -ne $prevOutputEncoding) {
        try { [Console]::OutputEncoding = $prevOutputEncoding } catch { }
    }
}
