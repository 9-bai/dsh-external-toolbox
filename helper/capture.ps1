# capture.ps1 - global hotkey selection capture + floating translate card (dsh-external-toolbox).
#
# Modes:
#   -SelfTest   create an off-screen window with a selected TextBox, read it back
#               through UI Automation, print the result, exit.
#   -CardTest   render the floating card with sample text, screenshot it to
#               -ShotPath, exit. Used to verify the layout without a hotkey.
#   -Once       capture the current focus once, print the result, exit.
#   (default)   register the global hotkey, wait in a message loop, and for every
#               press: capture the selection in the focused app, then show the
#               floating card in place so translating never needs the DSH window.
#
# Output contract (one JSON object per line, UTF-8):
#   {"type":"ready","hotkey":"Ctrl+Alt+Q"}
#   {"type":"selection","id":"...","text":"...","via":"uia|clipboard","chars":123}
#   {"type":"intent","intent":"ask","id":"..."}
#   {"type":"error","message":"..."}
#
# The script body must stay pure ASCII: Windows PowerShell 5.1 decodes a BOM-less
# .ps1 as the ANSI code page, so any non-ASCII byte breaks parsing. UI strings are
# built from code points with U.

[CmdletBinding()]
param(
  [string]$Hotkey = "Ctrl+Alt+Q",
  [string]$WindowTitle = "DeepSeek Harness",
  [string]$TranslateUrl = "",
  # CardTest only: which task to run ("translate" or "explain").
  [string]$Task = "translate",
  [string]$Target = "auto",
  [int]$ParentPid = 0,
  [switch]$Once,
  [switch]$SelfTest,
  [switch]$CardTest,
  [switch]$LangTest,
  [switch]$ProbeWindows,
  [switch]$MinimizeTest,
  [switch]$HideTest,
  [switch]$BarTest,
  [switch]$ReviewTest,
  [switch]$ReviewAnswer,
  [string]$ReviewGrade = "",
  [switch]$ReviewSpeak,
  [switch]$ActivateTest,
  [string]$ShotPath = "",
  [switch]$NoAuto,
  [int]$AutoInterval = 350,
  [switch]$CaptureSelf,
  [switch]$AutoTest,
  [switch]$DragTest,
  [switch]$NoActivate,
  [switch]$NoRestoreClipboard,
  # CardTest only: keep the machine quiet.
  [switch]$SurfaceTest,
  [switch]$FilterTest,
  [switch]$NoSpeak,
  [string]$Word = "",
  [switch]$WordTest
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Target language shown on the card: "auto" lets the host pick the direction of
# a Chinese/English (or Japanese, Korean) pair, any other code forces that one.
$script:LANG_CODES = @("auto", "zh", "en", "ja", "ko", "es", "fr", "de", "ru", "pt", "it")
# Selections longer than this are almost always a stray Ctrl+A.
# The card scrolls, so long selections are welcome; this is only a guard against
# an accidental Ctrl+A over a huge file.
$script:MAX_CAPTURE_CHARS = 100000
$script:LANG_LABELS = @{
  auto = "AUTO"; zh = "ZH"; en = "EN"; ja = "JA"; ko = "KO"
  es = "ES"; fr = "FR"; de = "DE"; ru = "RU"; pt = "PT"; it = "IT"
}
$script:lang = "auto"
if ($script:LANG_CODES -contains $Target) { $script:lang = $Target }

# Same trace file the host half writes, so a failed start leaves evidence even
# though the DSH desktop app's stderr is not reachable from outside.
$script:LogPath = Join-Path $env:TEMP "dsh-external-toolbox-host.log"
function Write-Trace([string]$Text) {
  try {
    $stamp = (Get-Date).ToString("o")
    Add-Content -LiteralPath $script:LogPath -Value ($stamp + " helper " + $Text) -Encoding ASCII
  } catch { }
}
# Only one helper may live at a time: a second copy would install a second
# mouse hook and pop the card twice.
try {
  $script:singleInstance = New-Object System.Threading.Mutex($false, "Global\dsh-external-toolbox-helper")
  if (-not $SelfTest -and -not $CardTest -and -not $BarTest -and -not $DragTest -and -not $ActivateTest -and -not $AutoTest -and (-not $script:singleInstance.WaitOne(0))) {
    Write-Json @{ type = "error"; message = "another helper is already running" }
    exit 0
  }
} catch { }

Write-Trace ("start pid=" + $PID + " ps=" + $PSVersionTable.PSVersion.ToString())
trap {
  try { Write-Trace ("fatal line=" + $_.InvocationInfo.ScriptLineNumber + " " + $_.Exception.GetType().Name + " " + $_.Exception.Message) } catch { }
  try { Write-Json @{ type = "error"; message = [string]$_.Exception.Message } } catch { }
  exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ("QuickAsk.CardForm" -as [type])) {
  $refs = @(
    [System.Windows.Forms.Form].Assembly.Location,
    [System.Drawing.Point].Assembly.Location
  )
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace QuickAsk {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    public static class Native {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int processId);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern short GetKeyState(int vk);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool AttachThreadInput(int idAttach, int idAttachTo, bool attach);
        [DllImport("kernel32.dll")]
        public static extern int GetCurrentThreadId();
        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr SetFocus(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr extraInfo);
        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    public static void KeyTap(byte vk) {
      keybd_event(vk, (byte)MapVirtualKey(vk, 0), 0, IntPtr.Zero);
      keybd_event(vk, (byte)MapVirtualKey(vk, 0), 2, IntPtr.Zero);
    }
    public static void KeyCombo(byte mod, byte vk) {
      keybd_event(mod, (byte)MapVirtualKey(mod, 0), 0, IntPtr.Zero);
      keybd_event(vk, (byte)MapVirtualKey(vk, 0), 0, IntPtr.Zero);
      keybd_event(vk, (byte)MapVirtualKey(vk, 0), 2, IntPtr.Zero);
      keybd_event(mod, (byte)MapVirtualKey(mod, 0), 2, IntPtr.Zero);
    }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextLengthW(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")]
        public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")]
        public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr param);

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr param);

        // The DSH window belongs to a renderer process, so looking at the
        // process name or MainWindowHandle of the host process finds nothing.
        // Match the window title instead and take the largest hit; a minimized
        // (hidden) window still counts, the caller restores it afterwards.
        public static IntPtr FindWindowByTitle(string needle) {
            IntPtr best = IntPtr.Zero;
            int bestArea = 0;
            EnumWindows(delegate(IntPtr h, IntPtr param) {
                if (IsWindowVisible(h)) {
                    int len = GetWindowTextLengthW(h);
                    if (len > 0) {
                        System.Text.StringBuilder sb = new System.Text.StringBuilder(len + 2);
                        GetWindowTextW(h, sb, sb.Capacity);
                        if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) {
                            RECT r;
                            if (GetWindowRect(h, out r)) {
                                int area = (r.Right - r.Left) * (r.Bottom - r.Top);
                                if (area > bestArea) { bestArea = area; best = h; }
                            }
                        }
                    }
                }
                return true;
            }, IntPtr.Zero);
            return best;
        }

        // Diagnostics: every top level window whose title or executable name
        // contains the needle, visible or not.
        public static string[] DescribeWindows(string needle) {
            System.Collections.Generic.List<string> list = new System.Collections.Generic.List<string>();
            EnumWindows(delegate(IntPtr h, IntPtr param) {
                int len = GetWindowTextLengthW(h);
                if (len <= 0) return true;
                System.Text.StringBuilder sb = new System.Text.StringBuilder(len + 2);
                GetWindowTextW(h, sb, sb.Capacity);
                string title = sb.ToString();
                int pid = 0;
                GetWindowThreadProcessId(h, out pid);
                string pname = "";
                try { pname = System.Diagnostics.Process.GetProcessById(pid).ProcessName; } catch { }
                bool hit = title.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0 ||
                           pname.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0;
                if (hit) list.Add(string.Format("hwnd={0} vis={1} pid={2} proc={3} title={4}", h, IsWindowVisible(h), pid, pname, title));
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        // Fallback that does not depend on the title at all: any top level window
        // owned by an executable with this name (visible or not).
        public static IntPtr FindWindowByProcessName(string exeName) {
            IntPtr best = IntPtr.Zero;
            int bestArea = 0;
            EnumWindows(delegate(IntPtr h, IntPtr param) {
                // A window hidden to the tray may already have lost its title,
                // so the process name has to be enough on its own.
                int pid = 0;
                int tid = GetWindowThreadProcessId(h, out pid);
                if (pid == 0) return true;
                string name = null;
                try { name = System.Diagnostics.Process.GetProcessById(pid).ProcessName; } catch { return true; }
                if (name == null) return true;
                if (name.IndexOf(exeName, StringComparison.OrdinalIgnoreCase) < 0) return true;
                RECT r;
                if (!GetWindowRect(h, out r)) return true;
                int area = (r.Right - r.Left) * (r.Bottom - r.Top);
                // Message-only and helper windows are 0x0; only real app windows count.
                if (area < 200 * 120) return true;
                bool visible = IsWindowVisible(h);
                // The BrowserWindow is always Chrome_WidgetWin_1. Chrome_WidgetWin_0
                // and friends are internal Electron surfaces: showing one of those
                // instead of the UI is exactly the "nothing appeared" failure.
                System.Text.StringBuilder cls = new System.Text.StringBuilder(64);
                GetClassName(h, cls, 64);
                bool real = cls.ToString() == "Chrome_WidgetWin_1";
                int score = (visible ? 1000 : 0) + (real ? 500 : 0) + System.Math.Min(area / 100000, 400);
                if (score > bestArea) { bestArea = score; best = h; }
                return true;
            }, IntPtr.Zero);
            return best;
        }

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
    public static void ClickAt(int x, int y) {
      SetCursorPos(x, y);
      System.Threading.Thread.Sleep(40);
      mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
      System.Threading.Thread.Sleep(40);
      mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    }
        [DllImport("user32.dll")]
        public static extern bool ReleaseCapture();
        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(POINT point);
        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(POINT point, uint flags);
        [DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int maxCount);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        // Windows treats this one as if the user asked for the switch, which the
        // plain SetForegroundWindow call is often not allowed to do.
        [DllImport("user32.dll")]
        public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")]
        public static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);
        [DllImport("user32.dll")]
        public static extern bool UpdateWindow(IntPtr hWnd);
        // Lets this process take the foreground without an input-queue attach,
        // which is what used to wedge the target window.
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
        public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // 0x08000000 = WS_EX_NOACTIVATE: the card shows without stealing focus from
    // the app the user just selected text in.
    public sealed class CardForm : Form {
        public bool ActivateOnShow = true;
        protected override bool ShowWithoutActivation { get { return !ActivateOnShow; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000;
                return cp;
            }
        }

        // Dragging from a PowerShell event handler would re-enter the script
        // engine inside the modal move loop (the "unhandled exception" dialog),
        // so the whole gesture lives in C#.
        public void MakeDraggable(Control target) {
            target.MouseDown += delegate(object sender, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                Native.ReleaseCapture();
                Native.SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero);
            };
        }
    }

    public sealed class HotkeyWindow : NativeWindow {
        public const int WM_HOTKEY = 0x0312;
        public const int WM_HOOK = 0x8001;
        private readonly int id;
        public event Action<int> Pressed;
        public event Action<int> HookPing;
        public MouseWatcher Mouse;
        public KeyboardWatcher Keyboard;

        public HotkeyWindow(int id) {
            this.id = id;
            CreateHandle(new CreateParams {
                Caption = "external-toolbox-hotkey",
                X = -4000,
                Y = -4000,
                Width = 1,
                Height = 1,
            });
        }

        public bool Register(uint mods, uint vk) {
            return Native.RegisterHotKey(Handle, id, mods, vk);
        }

        public void Unregister() {
            try { Native.UnregisterHotKey(Handle, id); } catch { }
            try { DestroyHandle(); } catch { }
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_HOTKEY) {
                var handler = Pressed;
                if (handler != null) {
                    try { handler(m.WParam.ToInt32()); } catch { }
                }
            } else if (m.Msg == WM_HOOK) {
                int code = m.WParam.ToInt32();
                if (Mouse != null) Mouse.ClearPending(code);
                if (Keyboard != null) Keyboard.ClearPending(code);
                var ping = HookPing;
                if (ping != null) { try { ping(code); } catch { } }
            }
            base.WndProc(ref m);
        }
    }

    // A low level hook that takes too long makes Windows drop input for the
    // whole desktop, and script execution is far too slow for that path. The
    // hooks only post a message to the hotkey window; the UI thread runs the
    // script side afterwards.
    public sealed class MouseWatcher : IDisposable {
        public const int PingClick = 1;
        public const int PingGesture = 2;

        private const int WH_MOUSE_LL = 14;
        private const int WM_LBUTTONDOWN = 0x0201;
        private const int WM_LBUTTONUP = 0x0202;
        private const int WM_MOUSEWHEEL = 0x020A;
        private const int EM_LINESCROLL = 0x00B6;

        private Native.HookProc proc;
        private IntPtr hook = IntPtr.Zero;
        private POINT down;
        private bool downSeen;
        private bool doubleClick;
        // A low level hook never sees WM_LBUTTONDBLCLK (that is generated by the
        // target window), so the second click has to be recognised by timing.
        private int lastDownTime;
        private POINT lastDownPt;
        private bool hasLastDown;
        private int pendingClick;
        private int pendingGesture;

        public IntPtr Notify = IntPtr.Zero;
        // Wheel events are swallowed and forwarded to a text box when the cursor
        // is over our own card; otherwise the window under it would scroll.
        public IntPtr WheelWindow = IntPtr.Zero;
        public IntPtr WheelTarget = IntPtr.Zero;
        // The card has two panes; scrolling has to follow the one under the
        // pointer instead of always landing on the translation.
        public IntPtr WheelSrc = IntPtr.Zero;
        public IntPtr WheelDst = IntPtr.Zero;

        // Where the last drag started and ended. Kept for diagnostics: it lets a
        // trace say how far the pointer travelled for a gesture.
        public bool HasDrag = false;
        public POINT DragStart;
        public POINT DragEnd;

        public bool Start() {
            if (hook != IntPtr.Zero) return true;
            proc = OnHook;
            hook = Native.SetWindowsHookEx(WH_MOUSE_LL, proc, Native.GetModuleHandle(null), 0);
            return hook != IntPtr.Zero;
        }

        public void Stop() {
            if (hook != IntPtr.Zero) {
                Native.UnhookWindowsHookEx(hook);
                hook = IntPtr.Zero;
            }
        }

        public void Dispose() { Stop(); }

        public void ClearPending(int code) {
            if (code == PingClick) System.Threading.Interlocked.Exchange(ref pendingClick, 0);
            if (code == PingGesture) System.Threading.Interlocked.Exchange(ref pendingGesture, 0);
        }

        private void Post(int code, ref int pending) {
            if (Notify == IntPtr.Zero) return;
            if (System.Threading.Interlocked.Exchange(ref pending, 1) != 0) return;
            Native.PostMessage(Notify, HotkeyWindow.WM_HOOK, (IntPtr)code, IntPtr.Zero);
        }

        private IntPtr OnHook(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                int msg = (int)(long)wParam;
                MSLLHOOKSTRUCT info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                if (msg == WM_MOUSEWHEEL && WheelWindow != IntPtr.Zero && WheelTarget != IntPtr.Zero) {
                    RECT box;
                    if (Native.GetWindowRect(WheelWindow, out box)
                        && info.pt.X >= box.Left && info.pt.X <= box.Right
                        && info.pt.Y >= box.Top && info.pt.Y <= box.Bottom) {
                        IntPtr pane = IntPtr.Zero;
                        RECT area;
                        if (WheelDst != IntPtr.Zero && Native.IsWindowVisible(WheelDst)
                            && Native.GetWindowRect(WheelDst, out area)
                            && info.pt.Y >= area.Top && info.pt.Y <= area.Bottom) {
                            pane = WheelDst;
                        } else if (WheelSrc != IntPtr.Zero && Native.GetWindowRect(WheelSrc, out area)
                            && info.pt.Y >= area.Top && info.pt.Y <= area.Bottom) {
                            pane = WheelSrc;
                        }
                        // inside the card but outside both panes (header, lane,
                        // footer): scrolling nothing is better than scrolling the
                        // wrong box.
                        int delta = (short)((info.mouseData >> 16) & 0xffff);
                        int lines = -(delta / 120) * 3;
                        if (lines != 0 && pane != IntPtr.Zero) Native.PostMessage(pane, EM_LINESCROLL, IntPtr.Zero, (IntPtr)lines);
                        if (Notify != IntPtr.Zero) Native.PostMessage(Notify, HotkeyWindow.WM_HOOK, (IntPtr)6, IntPtr.Zero);
                        return (IntPtr)1;
                    }
                }
                if (msg == WM_LBUTTONDOWN) {
                    bool second = hasLastDown
                        && (int)info.time - lastDownTime <= 500
                        && Math.Abs(info.pt.X - lastDownPt.X) <= 4
                        && Math.Abs(info.pt.Y - lastDownPt.Y) <= 4;
                    down = info.pt;
                    downSeen = true;
                    doubleClick = second;
                    hasLastDown = !second;
                    lastDownTime = (int)info.time;
                    lastDownPt = info.pt;
                    Post(PingClick, ref pendingClick);
                } else if (msg == WM_LBUTTONUP) {
                    bool dragged = downSeen && (Math.Abs(info.pt.X - down.X) > 5 || Math.Abs(info.pt.Y - down.Y) > 5);
                    bool fire = dragged || doubleClick;
                    if (fire) {
                        DragStart = down;
                        DragEnd = info.pt;
                        HasDrag = true;
                    }
                    downSeen = false;
                    doubleClick = false;
                    if (fire) Post(PingGesture, ref pendingGesture);
                }
            }
            return Native.CallNextHookEx(hook, code, wParam, lParam);
        }
    }

    // Ctrl+A and Shift+arrows create a selection without touching the mouse,
    // so the mouse hook cannot see them; watch those key ups instead.
    public sealed class KeyboardWatcher : IDisposable {
        public const int PingGesture = 3;
        public const int PingEscape = 4;

        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYUP = 0x0105;
        private const int VK_SHIFT = 0x10;
        private const int VK_CONTROL = 0x11;
        private const int VK_ESCAPE = 0x1B;

        private Native.HookProc proc;
        private IntPtr hook = IntPtr.Zero;
        private int pendingGesture;

        public IntPtr Notify = IntPtr.Zero;
        // Our own windows. Escape is only swallowed while one of them is on
        // screen; checking that here keeps the hook free of script calls.
        public IntPtr[] Guarded = new IntPtr[0];

        public bool Start() {
            if (hook != IntPtr.Zero) return true;
            proc = OnHook;
            hook = Native.SetWindowsHookEx(WH_KEYBOARD_LL, proc, Native.GetModuleHandle(null), 0);
            return hook != IntPtr.Zero;
        }

        public void Stop() {
            if (hook != IntPtr.Zero) {
                Native.UnhookWindowsHookEx(hook);
                hook = IntPtr.Zero;
            }
        }

        public void Dispose() { Stop(); }

        public void ClearPending(int code) {
            if (code == PingGesture) System.Threading.Interlocked.Exchange(ref pendingGesture, 0);
        }

        private bool GuardVisible() {
            if (Guarded == null) return false;
            foreach (IntPtr h in Guarded) {
                if (h != IntPtr.Zero && Native.IsWindowVisible(h)) return true;
            }
            return false;
        }

        private void Post(int code) {
            if (Notify == IntPtr.Zero) return;
            Native.PostMessage(Notify, HotkeyWindow.WM_HOOK, (IntPtr)code, IntPtr.Zero);
        }

        private void PostGesture() {
            if (Notify == IntPtr.Zero) return;
            if (System.Threading.Interlocked.Exchange(ref pendingGesture, 1) != 0) return;
            Native.PostMessage(Notify, HotkeyWindow.WM_HOOK, (IntPtr)PingGesture, IntPtr.Zero);
        }

        private IntPtr OnHook(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                int msg = (int)(long)wParam;
                int vk = Marshal.ReadInt32(lParam);
                if ((msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) && vk == VK_ESCAPE) {
                    if (GuardVisible()) {
                        Post(PingEscape);
                        return (IntPtr)1;
                    }
                }
                if (msg == WM_KEYUP || msg == WM_SYSKEYUP) {
                    bool ctrl = (Native.GetKeyState(VK_CONTROL) & 0x8000) != 0;
                    bool shift = (Native.GetKeyState(VK_SHIFT) & 0x8000) != 0;
                    bool all = ctrl && vk == 0x41;
                    bool extend = shift && (vk >= 0x21 && vk <= 0x28);
                    if (all || extend) PostGesture();
                }
            }
            return Native.CallNextHookEx(hook, code, wParam, lParam);
        }
    }
}
'@ -ReferencedAssemblies $refs
}

function Write-Json([hashtable]$Payload) {
  $json = $Payload | ConvertTo-Json -Compress -Depth 4
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}

# This process IS per-monitor DPI aware (see the dpi block below): Windows does
# not bitmap-stretch the card, and Sz()/Fs() scale the 96 dpi design to pixels.

# Builds a string from code points so this file stays ASCII.
function U {
  param([int[]]$Codes)
  return (($Codes | ForEach-Object { [char]$_ }) -join "")
}

$T_SCRAPE      = U 0x5212, 0x8BCD                       # "scrape" (card title)
$T_TRANSLATE   = U 0x7FFB, 0x8BD1                       # translate
$T_ASK         = U 0x5F15, 0x7528                       # quote
$T_COPY        = U 0x590D, 0x5236                       # copy
$T_CLOSE       = U 0x5173, 0x95ED                       # close
$T_TRANSLATING = (U 0x7FFB, 0x8BD1, 0x4E2D) + "..."     # translating...
$T_EXPLAIN     = U 0x89E3, 0x91CA                       # explain
$T_EXPLAINING  = (U 0x89E3, 0x91CA, 0x4E2D) + "..."     # explaining...
$T_SAVE        = U 0x6536, 0x85CF                       # save (to vocabulary)
$T_SAVED       = U 0x5DF2, 0x6536, 0x85CF               # saved
$T_SAVE_FAILED = U 0x6536, 0x85CF, 0x5931, 0x8D25       # save failed
$T_SPEAKING    = U 0x6717, 0x8BFB, 0x4E2D               # speaking
$T_COPIED      = U 0x5DF2, 0x590D, 0x5236               # copied
$T_COPY_DST    = U 0x590D, 0x5236, 0x8BD1, 0x6587       # copy translation
$T_COPY_SRC    = U 0x590D, 0x5236, 0x539F, 0x6587       # copy original
$T_NO_TEXT     = U 0x6CA1, 0x53D6, 0x5230, 0x9009, 0x4E2D, 0x6587, 0x672C   # nothing selected
$T_NO_SERVICE  = (U 0x7FFB, 0x8BD1, 0x670D, 0x52A1, 0x672A, 0x8FDE, 0x63A5) + " (DSH)"   # translate service offline
$T_FAILED      = U 0x7FFB, 0x8BD1, 0x5931, 0x8D25       # translation failed
$T_ASKED       = (U 0x5DF2, 0x590D, 0x5236, 0x5E76, 0x5524, 0x8D77) + " DSH"   # copied + DSH activated
$T_HINT        = (U 0x9009, 0x4E2D, 0x6587, 0x672C, 0x540E, 0x6309) + " Ctrl+Alt+Q"   # select text, press Ctrl+Alt+Q

# Display names for the drop-down; kept as code points so this file stays ASCII.
$script:LANG_NAMES = @{
  auto = "Detect"; zh = (U 0x4E2D, 0x6587); en = "English"; ja = (U 0x65E5, 0x672C, 0x8A9E)
  ko = (U 0xD55C, 0xAD6D, 0xC5B4); es = ("Espa" + [char]0x00F1 + "ol"); fr = ("Fran" + [char]0x00E7 + "ais")
  de = "Deutsch"; ru = (U 0x0420, 0x0443, 0x0441, 0x0441, 0x043A, 0x0438, 0x0439)
  pt = ("Portugu" + [char]0x00EA + "s"); it = "Italiano"
}

# ---------------------------------------------------------------- window focus

function Get-HostWindow {
  # The DSH window often belongs to a renderer process, so MainWindowHandle on
  # the host process is zero; match the window title first.
  foreach ($needle in @("DeepSeek Harness", $WindowTitle, "DeepSeek")) {
    if ([string]::IsNullOrWhiteSpace($needle)) { continue }
    try {
      $h = [QuickAsk.Native]::FindWindowByTitle($needle)
      if ($h -ne [IntPtr]::Zero) { return $h }
    } catch { }
  }
  # Titles change with the conversation, and a window sent to the tray is not
  # "visible" any more, so fall back to the executable name.
  try {
    $h = [QuickAsk.Native]::FindWindowByProcessName("DeepSeek Harness")
    if ($h -ne [IntPtr]::Zero) { return $h }
  } catch { }
  try {
    $h = [QuickAsk.Native]::FindWindowByProcessName("DeepseekHaeness")
    if ($h -ne [IntPtr]::Zero) { return $h }
  } catch { }
  $patterns = @($WindowTitle, "DeepSeek Harness", "DeepSeek")
  foreach ($pattern in $patterns) {
    $procs = Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -like "*$pattern*" }
    foreach ($p in $procs) { return $p.MainWindowHandle }
  }
  return [IntPtr]::Zero
}

# Runs in a background runspace: activating another process's window can block
# for as long as that process takes to pump messages, and doing it on the UI
# thread is what made DSH look frozen.
$script:ActivateScript = @'
param($Handle, $LogPath)
function AL($m) {
  try { Add-Content -LiteralPath $LogPath -Value (("{0} activate[bg]: {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $m)) -Encoding UTF8 } catch { }
}
function CheckTop {
  # Keep this dumb and ordered. Earlier versions asked "who owns the centre
  # pixel" and retried, but Electron shows its window a few hundred ms after we
  # quote, so every answer was stale and the retries only logged noise. A fixed
  # sequence is predictable: raise to the topmost band (which puts us above the
  # editor), hold long enough for the app to finish its own restore, then drop
  # the topmost flag. HWND_NOTOPMOST keeps the current z position, so the
  # window stays above the editor without floating over everything forever.
  $top = New-Object System.IntPtr(-1)
  $notTop = New-Object System.IntPtr(-2)
  try {
    Start-Sleep -Milliseconds 350
    [void][QuickAsk.Native]::SetWindowPos($h, $top, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
    [void][QuickAsk.Native]::SetForegroundWindow($h)
    AL 'top raised'
    Start-Sleep -Milliseconds 600
    [void][QuickAsk.Native]::SetWindowPos($h, $notTop, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
    AL 'top released'
    $rc = New-Object QuickAsk.RECT
    if ([QuickAsk.Native]::GetWindowRect($h, [ref]$rc)) {
      $pt = New-Object QuickAsk.POINT
      $pt.X = [int](($rc.L + $rc.R) / 2)
      $pt.Y = [int](($rc.T + $rc.B) / 2)
      $owner = [QuickAsk.Native]::GetAncestor([QuickAsk.Native]::WindowFromPoint($pt), 2)
      AL ("top=" + [string]$owner.ToInt64() + " self=" + [string]$h.ToInt64())
    }
  } catch { AL ("top failed: " + $_.Exception.Message) }
}
$h = [IntPtr]([int64]$Handle)
# Remember the pre-activation window state: SW_RESTORE un-maximises a
# maximised window, so if it was zoomed before we must put it back.
$wasZoomed = $false
try { $wasZoomed = [QuickAsk.Native]::IsZoomed($h) } catch { }
$relaunched = $false
$mem = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
$altDown = $false
try {
  # Showing a window the app hid itself is only half the job: Chromium stops
  # compositing for a window it believes is hidden, so the HWND can be visible,
  # foreground and still show a stale (or blank) frame. A one pixel resize makes
  # the compositor lay out and emit a fresh frame, and the invalidate/redraw pair
  # quotes for the paint explicitly.
  if (-not [QuickAsk.Native]::IsWindowVisible($h)) {
    # The only way to get live frames back is to let the application show its
    # own window: Electron keeps its own idea of visibility, and Chromium stops
    # compositing for a window it still considers hidden, which is exactly the
    # "window appears but the picture is frozen" symptom. Relaunching the exe
    # hits the single-instance path in the app, which calls focusPrimaryWindow()
    # -> window.show(), so the renderer starts producing frames again.
    # External ShowWindow (even SW_RESTORE) makes pixels appear but leaves the
    # compositor parked, so it is only the fallback.
    $wpid = 0
    try { [void][QuickAsk.Native]::GetWindowThreadProcessId($h, [ref]$wpid) } catch { }
    $exe = $null
    if ($wpid -gt 0) { try { $exe = (Get-Process -Id $wpid -ErrorAction Stop).Path } catch { AL ("exe lookup failed for pid " + [string]$wpid + ": " + $_.Exception.Message) } }
    if (-not $exe) {
      try {
        $parentId = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + [string]$PID)).ParentProcessId
        $exe = (Get-Process -Id $parentId -ErrorAction Stop).Path
        AL ("exe from parent pid " + [string]$parentId)
      } catch { }
    }
    if (-not $exe) {
      $known = "D:\DeepseekHaeness\DeepSeek Harness.exe"
      if (Test-Path -LiteralPath $known) { $exe = $known; AL 'exe from known path' }
    }
    if ($exe) {
      try {
        # The helper runs under the DSH host, which is itself an Electron process
        # started with ELECTRON_RUN_AS_NODE=1. If that variable leaks into the
        # relaunched exe it starts as a plain Node script and no window is
        # created, so strip it before starting.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.UseShellExecute = $false
        try { $psi.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE") } catch { }
        try { $psi.EnvironmentVariables.Remove("ELECTRON_NO_ATTACH_CONSOLE") } catch { }
        [void][System.Diagnostics.Process]::Start($psi)
        AL ("relaunched " + $exe)
      } catch { AL ("relaunch failed: " + $_.Exception.Message) }
      for ($k = 0; $k -lt 24; $k++) {
        Start-Sleep -Milliseconds 250
        if ([QuickAsk.Native]::IsWindowVisible($h)) { break }
      }
      AL ("visible after relaunch=" + [string]([QuickAsk.Native]::IsWindowVisible($h)))
      if ([QuickAsk.Native]::IsWindowVisible($h)) { $relaunched = $true }
    }
    if (-not [QuickAsk.Native]::IsWindowVisible($h)) {
      if ($wasZoomed) { [void][QuickAsk.Native]::ShowWindow($h, 3) } else { [void][QuickAsk.Native]::ShowWindow($h, 9) }
    }
    Start-Sleep -Milliseconds 120
    if (-not [QuickAsk.Native]::IsWindowVisible($h)) {
      [void][QuickAsk.Native]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0040 -bor 0x0002 -bor 0x0001 -bor 0x0010)
      Start-Sleep -Milliseconds 150
    }
    AL ("forced visible=" + [string]([QuickAsk.Native]::IsWindowVisible($h)))
    if ($wasZoomed -and -not [QuickAsk.Native]::IsZoomed($h)) {
      [void][QuickAsk.Native]::ShowWindow($h, 3)
      AL "re-maximized"
    }
    Start-Sleep -Milliseconds 150
    $rc = New-Object QuickAsk.RECT
    if ((-not $relaunched) -and [QuickAsk.Native]::GetWindowRect($h, [ref]$rc)) {
      $w = $rc.R - $rc.L
      $hh = $rc.B - $rc.T
      [void][QuickAsk.Native]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, ($w + 1), $hh, 0x0002 -bor 0x0004 -bor 0x0010)
      Start-Sleep -Milliseconds 60
      [void][QuickAsk.Native]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $w, $hh, 0x0002 -bor 0x0004 -bor 0x0010)
      [void][QuickAsk.Native]::InvalidateRect($h, [IntPtr]::Zero, $true)
      [void][QuickAsk.Native]::UpdateWindow($h)
      AL 'paint nudged'
    }
    # Shown and repainted is still not the same as "on top": raise the window
    # above every other window (including always-on-top ones) for a moment, so
    # it cannot stay buried behind the editor it was invoked from.
    try {
      $top = New-Object System.IntPtr(-1)
      $notTop = New-Object System.IntPtr(-2)
      [void][QuickAsk.Native]::SetWindowPos($h, $top, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010 -bor 0x0020)
      Start-Sleep -Milliseconds 200
      [void][QuickAsk.Native]::SetWindowPos($h, $notTop, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
      AL 'raised'
    } catch { AL ("raise failed: " + $_.Exception.Message) }
  } else {
    AL 'already visible'
  }
  if ([QuickAsk.Native]::IsIconic($h)) { [void][QuickAsk.Native]::ShowWindow($h, 9); AL 'restored from minimize' }
  if (([QuickAsk.Native]::GetForegroundWindow() -eq $h) -and [QuickAsk.Native]::IsWindowVisible($h)) { AL 'ok already'; CheckTop; return }
  $prev = 200000
  try {
    [void][QuickAsk.Native]::SystemParametersInfo(0x2000, 0, $mem, 0)
    $prev = [System.Runtime.InteropServices.Marshal]::ReadInt32($mem)
  } catch { }
  try {
    [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, 0)
    [void][QuickAsk.Native]::SystemParametersInfo(0x2001, 0, $mem, 0)
  } catch { }
  try {
    [void][QuickAsk.Native]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 120
    if ([QuickAsk.Native]::GetForegroundWindow() -eq $h) { AL 'ok direct'; CheckTop; return }
    [QuickAsk.Native]::SwitchToThisWindow($h, $true)
    Start-Sleep -Milliseconds 150
    if ([QuickAsk.Native]::GetForegroundWindow() -eq $h) { AL 'ok switch'; CheckTop; return }
    [QuickAsk.Native]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
    $altDown = $true
    Start-Sleep -Milliseconds 25
    [void][QuickAsk.Native]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 25
    [QuickAsk.Native]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    $altDown = $false
    Start-Sleep -Milliseconds 150
    AL ("final=" + [string]([QuickAsk.Native]::GetForegroundWindow() -eq $h))
    CheckTop
  } finally {
    if ($altDown) { try { [QuickAsk.Native]::keybd_event(0x12, 0, 2, [IntPtr]::Zero) } catch { } }
    try {
      [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, $prev)
      [void][QuickAsk.Native]::SystemParametersInfo(0x2001, 0, $mem, 0)
    } catch { }
  }
} catch {
  AL ("error: " + $_.Exception.Message)
} finally {
  AL 'finally entered'
}
'@
# The app's own activation path. On Windows open-url never fires, so a dsh://
# URL is ignored; launching the executable again is what works, because the
# running instance receives second-instance and runs focusPrimaryWindow()
# (restore + show + focus). That is the tray-click path, and the only one that
# keeps Electron's visibility state and the real HWND in step.
function Get-HostExe {
  if (-not [string]::IsNullOrWhiteSpace($script:hostExe)) { return $script:hostExe }
  $path = ""
  try {
    if ($script:parentPid -gt 0) { $path = (Get-Process -Id $script:parentPid -ErrorAction Stop).Path }
  } catch { }
  if ([string]::IsNullOrWhiteSpace($path)) {
    try {
      $p = @(Get-Process "DeepSeek Harness" -ErrorAction SilentlyContinue)[0]
      if ($null -ne $p) { $path = $p.Path }
    } catch { }
  }
  if (-not [string]::IsNullOrWhiteSpace($path)) { $script:hostExe = $path }
  return $path
}

function Start-HostProtocol {
  $exe = Get-HostExe
  if ([string]::IsNullOrWhiteSpace($exe)) {
    Write-Trace "activate: host exe not found"
    return $false
  }
  try {
    Start-Process -FilePath $exe -ErrorAction Stop
    Write-Trace ("activate: second instance " + $exe)
    return $true
  } catch {
    Write-Trace ("activate: second instance failed " + $_.Exception.Message)
    return $false
  }
}

function Show-HostWindow {
  if ($NoActivate) { return }
  # One activation in flight at a time: repeated hotkeys must not stack up.
  $now = Get-Date
  if ($null -ne $script:activateAt -and ($now - $script:activateAt).TotalSeconds -lt 3) {
    Write-Trace "activate: busy"
    return
  }
  $hwnd = Get-HostWindow
  # No "already foreground" shortcut: GetForegroundWindow() also reports a hidden
  # (or covered) window, so the test can pass while nothing is on screen.
  $script:activateAt = $now
  $activateUrl = ""
  if (-not [string]::IsNullOrWhiteSpace($TranslateUrl)) {
    $marker = $TranslateUrl.IndexOf("/toolbox/translate")
    if ($marker -ge 0) { $activateUrl = $TranslateUrl.Substring(0, $marker) + "/toolbox/activate" }
  }
  if ($hwnd -eq [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 150
    $hwnd = Get-HostWindow
  }
  if ($hwnd -eq [IntPtr]::Zero) {
    $cand = @()
    try { $cand = [QuickAsk.Native]::DescribeWindows("DeepSeek") } catch { }
    Write-Trace ("activate: host window not found; candidates=" + ($cand -join " || "))
    return
  }
  # The background runspace owns the whole show/nudge/raise sequence: doing a
  # ShowWindow here first would make it take the "already visible" branch and
  # skip the repaint nudge, which is exactly what leaves a stale frame.
  $visible = $false
  try { $visible = [QuickAsk.Native]::IsWindowVisible($hwnd) } catch { }
  if (-not $visible) { Write-Trace "activate: window hidden, background script will show it" }
  try {
    # Keep the runner alive: an unreferenced PowerShell object can be collected
    # while its background script is still running, which aborts it mid-flight
    # and skips its finally block (losing the evidence screenshot).
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ActivateScript).AddArgument([string]$hwnd.ToInt64()).AddArgument($script:LogPath)
    [void]$ps.BeginInvoke()
    $script:activateRunner = $ps
    Write-Trace "activate: spawned bg"
  } catch {
    Write-Trace ("activate: spawn failed " + $_.Exception.Message)
  }
}
# ---------------------------------------------------------------- UIA capture

function Get-UiaSelectionText {
  param([System.Windows.Automation.AutomationElement]$Element)

  if ($null -eq $Element) { return $null }
  for ($depth = 0; $depth -lt 6 -and $null -ne $Element; $depth++) {
    $hasText = $false
    try {
      foreach ($p in $Element.GetSupportedPatterns()) {
        if ($p.Id -eq [System.Windows.Automation.TextPattern]::Pattern.Id) { $hasText = $true; break }
      }
    } catch { }
    if ($hasText) {
      try {
        $tp = [System.Windows.Automation.TextPattern]$Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        $ranges = $tp.GetSelection()
        if ($null -ne $ranges -and $ranges.Count -gt 0) {
          $text = $ranges[0].GetText(-1)
          if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
        }
      } catch { }
    }
    try {
      $Element = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($Element)
    } catch { $Element = $null }
  }
  return $null
}

# Electron/Chromium apps (VS Code, TRAE) put the TextPattern on the document
# node, which is often a *descendant* of the focused element, not an ancestor.
# Walking up therefore misses the selection; look down as a second pass.
function Get-UiaSelectionTextDeep {
  param([System.Windows.Automation.AutomationElement]$Element, [int]$Limit = 24)
  if ($null -eq $Element) { return $null }
  $cond = $null
  try {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty, $true)
  } catch { return $null }
  $found = $null
  try { $found = $Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond) } catch { return $null }
  if ($null -eq $found) { return $null }
  $n = [Math]::Min($found.Count, $Limit)
  for ($i = 0; $i -lt $n; $i++) {
    try {
      $tp = [System.Windows.Automation.TextPattern]$found[$i].GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
      $ranges = $tp.GetSelection()
      if ($null -ne $ranges -and $ranges.Count -gt 0) {
        $text = $ranges[0].GetText(-1)
        if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
      }
    } catch { }
  }
  return $null
}

# ---------------------------------------------------------------- clipboard path

function Get-ClipboardSelectionText {
  param([string]$Keys = "^c")
  $previous = $null
  $hadText = $false
  try { $previous = Get-Clipboard -Raw -ErrorAction SilentlyContinue; $hadText = $true } catch { $previous = $null }

  # Park a unique marker on the clipboard instead of clearing it: clearing can
  # fail while another process holds the clipboard, and then a stale copy from
  # an earlier selection would look like a fresh one. Only a value that differs
  # from both the marker and the old clipboard counts as a real copy.
  $marker = "dsh-toolbox-" + [guid]::NewGuid().ToString("N")
  $seeded = $false
  for ($seedTry = 0; $seedTry -lt 3 -and -not $seeded; $seedTry++) {
    try { Set-Clipboard -Value $marker } catch { }
    try { $seeded = ((Get-Clipboard -Raw) -eq $marker) } catch { $seeded = $false }
    if (-not $seeded) { Start-Sleep -Milliseconds 40 }
  }
  if (-not $seeded) {
    # Another process kept the clipboard, so nothing here can be trusted: the
    # old value would look like a fresh copy.
    Write-Trace "capture: clipboard marker blocked"
    return $null
  }

  # A single Ctrl+C is often swallowed (focus still moving, app busy), so try a
  # few times before giving up; the clipboard stays cleared between attempts.
  $text = $null
  for ($attempt = 0; $attempt -lt 3 -and [string]::IsNullOrEmpty($text); $attempt++) {
    if ($attempt -gt 0) { Start-Sleep -Milliseconds 120 }
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    for ($i = 0; $i -lt 10; $i++) {
      Start-Sleep -Milliseconds 50
      try {
        $candidate = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        # The marker is the only reliable signal: the clipboard changes only if
        # something wrote to it, so "still the marker" means the app ignored the
        # key. Comparing against the previous value would reject a legitimate
        # re-copy of the same text.
        if ($candidate -eq $marker) { continue }
        $text = $candidate
        break
      } catch { }
    }
  }

  if (-not $NoRestoreClipboard -and $hadText) {
    try {
      if ($null -ne $previous) { Set-Clipboard -Value $previous } else { [System.Windows.Forms.Clipboard]::Clear() }
    } catch { }
  }
  return $text
}

# ---------------------------------------------------------------- capture

function Invoke-Capture {
  $text = $null
  $via = $null
  $uiaNote = ""
  $clipNote = ""


  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    $uiaNote = "el=" + $focused.Current.Name + "|" + $focused.Current.ClassName + "|" + $focused.Current.ControlType.ProgrammaticName
    $text = Get-UiaSelectionText -Element $focused
    if (-not [string]::IsNullOrWhiteSpace($text)) { $via = "uia" }
  } catch {
    $uiaNote = "error=" + $_.Exception.GetType().Name + ":" + $_.Exception.Message
  }

  if ([string]::IsNullOrWhiteSpace($text)) {
    try {
      $text = Get-ClipboardSelectionText
      if (-not [string]::IsNullOrWhiteSpace($text)) { $via = "clipboard" }
      else { $clipNote = "clip=empty" }
    } catch {
      $clipNote = "clip-error=" + $_.Exception.Message
    }
  }

  if ($env:QUICKASK_DEBUG) {
    Write-Json @{ type = "dbg"; uia = $uiaNote; clip = $clipNote; got = [int]($text -ne $null -and $text -ne "") }
  }

  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  $text = $text -replace "`r`n", "`n"
  return @{ type = "selection"; id = [guid]::NewGuid().ToString("N"); text = $text; via = $via; chars = $text.Length }
}

# ------------------------------------------------------------ dpi scaling
# The card is laid out in 96 dpi design pixels; Sz()/Fs() turn those into
# physical pixels for the current monitor. Without the awareness call Windows
# bitmap-stretches this process's windows on high-dpi screens, which is both
# blurry and makes GetWindowRect report virtualized coordinates.
$script:dpi = 96
$script:scale = 1.0
try {
  [void][QuickAsk.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch {
  try { [void][QuickAsk.Native]::SetProcessDPIAware() } catch { }
}
try {
  # The card is laid out once, so key the scale off the primary display:
  # following the cursor would rebuild the whole card when it crosses screens.
  $cur = New-Object QuickAsk.POINT
  $cur.X = 0
  $cur.Y = 0
  $mon = [QuickAsk.Native]::MonitorFromPoint($cur, 2)
  $dx = [uint32]0
  $dy = [uint32]0
  if ($mon -ne [IntPtr]::Zero -and [QuickAsk.Native]::GetDpiForMonitor($mon, 0, [ref]$dx, [ref]$dy) -eq 0 -and $dx -gt 0) {
    $script:dpi = [int]$dx
  }
} catch { }
if ($script:dpi -le 96) {
  try {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    if ($g.DpiX -gt 96) { $script:dpi = [int]$g.DpiX }
    $g.Dispose()
  } catch { }
}
$script:scale = $script:dpi / 96.0
# Never let the card outgrow the screen in the smallest dimension available.
try {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $capW = ($wa.Width * 0.86) / 620.0
  $capH = ($wa.Height * 0.86) / 420.0
  $cap = [Math]::Min($capW, $capH)
  if ($cap -gt 0.5 -and $script:scale -gt $cap) { $script:scale = $cap }
} catch { }
Write-Trace ("dpi=" + $script:dpi + " scale=" + [Math]::Round($script:scale, 3))

function Sz([double]$v) { return [int][Math]::Round($v * $script:scale) }
# Font sizes below are design pixels at 96 dpi, the same unit as Sz(), so text and
# layout stay in step. Points are 0.75 px at 96 dpi, and the control converts
# points with the monitor dpi on its own, so multiply by scale exactly once.
function Fs([double]$px) { return (New-Object System.Drawing.Font("Microsoft YaHei UI", [float]($px * 0.75))) }
function FsB([double]$px) { return (New-Object System.Drawing.Font("Microsoft YaHei UI", [float]($px * 0.75), [System.Drawing.FontStyle]::Bold)) }

# ---------------------------------------------------------------- card styles

$CARD_BG   = [System.Drawing.Color]::FromArgb(27, 28, 31)
$BAR_BG    = [System.Drawing.Color]::FromArgb(36, 37, 41)
$INK       = [System.Drawing.Color]::FromArgb(232, 233, 235)
$INK_DIM   = [System.Drawing.Color]::FromArgb(154, 160, 166)
$ACCENT    = [System.Drawing.Color]::FromArgb(138, 180, 248)
$OK_INK    = [System.Drawing.Color]::FromArgb(163, 216, 165)
$ERR_INK   = [System.Drawing.Color]::FromArgb(240, 160, 160)
$BTN_BG    = [System.Drawing.Color]::FromArgb(48, 50, 56)
$BTN_HOVER = [System.Drawing.Color]::FromArgb(62, 65, 72)
$LINE      = [System.Drawing.Color]::FromArgb(78, 82, 92)
$DROPDOWN_BG = [System.Drawing.Color]::FromArgb(44, 46, 52)
$THUMB     = [System.Drawing.Color]::FromArgb(96, 101, 112)
$ACCENT_BG = [System.Drawing.Color]::FromArgb(52, 88, 150)

function New-CardButton {
  param([string]$Text, [int]$Width = 76)
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text
  $b.AutoSize = $true
  $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $b.MinimumSize = New-Object System.Drawing.Size((Sz $Width), (Sz 22))
  $b.Padding = New-Object System.Windows.Forms.Padding((Sz 9), 0, (Sz 9), 0)
  $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $b.BackColor = $BTN_BG
  $b.ForeColor = $INK
  $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 67, 74)
  $b.FlatAppearance.MouseOverBackColor = $BTN_HOVER
  $b.Margin = New-Object System.Windows.Forms.Padding((Sz 5), 0, 0, 0)
  $b.TabStop = $false
  return $b
}

function Set-CardRegion {
  param([System.Windows.Forms.Form]$Form)
  $w = $Form.Width
  $h = $Form.Height
  $r = (Sz 13)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, $r, $r, 180, 90)
  $path.AddArc($w - $r, 0, $r, $r, 270, 90)
  $path.AddArc($w - $r, $h - $r, $r, $r, 0, 90)
  $path.AddArc(0, $h - $r, $r, $r, 90, 90)
  $path.CloseFigure()
  $Form.Region = New-Object System.Drawing.Region($path)
}


# ---------------------------------------------------------------- card UI

$script:card = $null
$script:srcText = ""
$script:dstText = ""
$script:lastId = ""
$script:busy = $false
$script:activeTask = "translate"
$script:activeBtn = $null
$script:activeLabel = ""
$script:autoCandidate = ""
$script:autoCount = 0
$script:autoShown = ""
$script:autoShownAt = [DateTime]::MinValue
$script:pollN = 0
$script:dismissed = ""
$script:ownGestureUntil = [DateTime]::MinValue
$script:clipBlockedUntil = [DateTime]::MinValue
$script:poll = $null
$script:runner = $null
$script:async = $null
$script:statusTimer = $null
$script:langMenu = $null

# ---------------------------------------------------------------- language menu

function Hide-LangMenu {
  if ($null -ne $script:langMenu -and $script:langMenu.Visible) { $script:langMenu.Hide() }
}

function Set-Lang([string]$Code) {
  if ($script:LANG_CODES -notcontains $Code) { return }
  $script:lang = $Code
  if ($null -ne $script:btnLang) { $script:btnLang.Text = ($script:LANG_LABELS[$Code] + " " + (U 0x25BE)) }
  Hide-LangMenu
  Set-CardStatus ("-> " + $Code) $INK_DIM
  # A visible translation follows the new choice instead of going stale.
  if (-not $script:busy -and $script:lastId -ne "" -and $script:dstText -ne "") { Start-Task $script:activeTask }
}

function New-LangMenu {
  $pad = (Sz 5)
  $rowH = (Sz 21)
  $w = (Sz 150)
  $f = New-Object QuickAsk.CardForm
  $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $f.ShowInTaskbar = $false
  $f.TopMost = $true
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $f.BackColor = $DROPDOWN_BG
  $f.ClientSize = New-Object System.Drawing.Size($w, ($pad * 2 + $rowH * $script:LANG_CODES.Count))
  $i = 0
  foreach ($code in $script:LANG_CODES) {
    $b = New-CardButton ($script:LANG_LABELS[$code] + "  " + $script:LANG_NAMES[$code]) 60
    $b.AutoSize = $false
    $b.MinimumSize = New-Object System.Drawing.Size(0, 0)
    $b.Size = New-Object System.Drawing.Size(($w - $pad * 2), $rowH)
    $b.Location = New-Object System.Drawing.Point($pad, ($pad + $rowH * $i))
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $DROPDOWN_BG
    $b.ForeColor = $(if ($code -eq $script:lang) { $ACCENT } else { $INK })
    $b.Font = Fs 12.5
    $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.Padding = New-Object System.Windows.Forms.Padding((Sz 6), 0, 0, 0)
    $b.Tag = $code
    $b.Add_Click({ param($sender, $e) Set-Lang ([string]$sender.Tag) })
    $f.Controls.Add($b)
    $i++
  }
  Set-CardRegion $f
  return $f
}

function Show-LangMenu {
  if ($null -eq $script:btnLang) { return }
  if ($null -eq $script:langMenu) { $script:langMenu = New-LangMenu }
  $origin = $script:btnLang.PointToScreen((New-Object System.Drawing.Point(0, ($script:btnLang.Height + (Sz 2)))))
  $scr = [System.Windows.Forms.Screen]::FromPoint($origin).WorkingArea
  $x = [Math]::Min([Math]::Max($origin.X, $scr.Left), ($scr.Right - $script:langMenu.Width))
  $y = [Math]::Min($origin.Y, ($scr.Bottom - $script:langMenu.Height))
  $script:langMenu.Location = New-Object System.Drawing.Point($x, $y)
  $script:langMenu.Show()
  $script:langMenu.BringToFront()
}

function Toggle-LangMenu {
  if ($null -ne $script:langMenu -and $script:langMenu.Visible) { Hide-LangMenu; return }
  Show-LangMenu
}


function New-Card {
  $form = New-Object QuickAsk.CardForm
  $form.Text = "dsh-external-toolbox"
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.ShowInTaskbar = $false
  $form.TopMost = $true
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.ClientSize = New-Object System.Drawing.Size((Sz 400), (Sz 214))
  $form.BackColor = $CARD_BG
  $form.ForeColor = $INK
  $form.Font = Fs 12
  $form.KeyPreview = $true
  $form.Padding = New-Object System.Windows.Forms.Padding(1)

  $head = New-Object System.Windows.Forms.Panel
  $head.Dock = [System.Windows.Forms.DockStyle]::Top
  $head.Height = (Sz 34)
  $head.BackColor = $BAR_BG

  $title = New-Object System.Windows.Forms.Label
  $title.Text = $T_SCRAPE + (U 0x00B7) + (U 0x5916, 0x90E8, 0x5DE5, 0x5177, 0x7BB1)
  $title.ForeColor = $ACCENT
  $title.Font = FsB 15
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point((Sz 14), (Sz 9))

  # Explicit placement beats docking here: the header must read
  # [title ............ language picker] [x]
  $btnX = New-CardButton (U 0x2715) 22
  $btnX.AutoSize = $false
  $btnX.MinimumSize = New-Object System.Drawing.Size((Sz 22), (Sz 16))
  $btnX.Size = New-Object System.Drawing.Size((Sz 22), (Sz 18))
  $btnX.Location = New-Object System.Drawing.Point((Sz 372), (Sz 8))
  $btnX.FlatAppearance.BorderSize = 1
  $btnX.FlatAppearance.BorderColor = $LINE
  $btnX.BackColor = $BTN_BG
  $btnX.ForeColor = $INK
  $btnX.Font = Fs 12
  $btnX.FlatAppearance.MouseOverBackColor = $BTN_HOVER

  # Language picker: a styled button plus our own drop-down panel, because the
  # native ComboBox can only be half-themed (white arrow strip, clipped text).
  $btnLang = New-CardButton ($script:LANG_LABELS[$script:lang] + " " + (U 0x25BE)) 60
  $btnLang.AutoSize = $false
  $btnLang.MinimumSize = New-Object System.Drawing.Size((Sz 78), (Sz 16))
  $btnLang.Size = New-Object System.Drawing.Size((Sz 78), (Sz 18))
  $btnLang.Location = New-Object System.Drawing.Point((Sz 286), (Sz 8))
  $btnLang.FlatAppearance.BorderSize = 1
  $btnLang.FlatAppearance.BorderColor = $LINE
  $btnLang.BackColor = $BTN_BG
  $btnLang.ForeColor = $INK
  $btnLang.Font = Fs 12
  $btnLang.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $btnLang.Add_Click({ Toggle-LangMenu })

  $btnVocab = New-CardButton (U 0x751F, 0x8BCD) 56
  $btnVocab.AutoSize = $false
  $btnVocab.MinimumSize = New-Object System.Drawing.Size((Sz 56), (Sz 16))
  $btnVocab.Size = New-Object System.Drawing.Size((Sz 56), (Sz 18))
  $btnVocab.Location = New-Object System.Drawing.Point((Sz 222), (Sz 8))
  $btnVocab.FlatAppearance.BorderSize = 1
  $btnVocab.FlatAppearance.BorderColor = $LINE
  $btnVocab.BackColor = $BTN_BG
  $btnVocab.ForeColor = $INK_DIM
  $btnVocab.Font = Fs 12
  $btnVocab.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $btnVocab.Add_Click({ Show-Review })

  $head.Controls.Add($btnX)
  $head.Controls.Add($btnLang)
  $head.Controls.Add($btnVocab)
  $head.Controls.Add($title)
  $tip = New-Object System.Windows.Forms.ToolTip
  $tip.SetToolTip($btnLang, "Translate into")
  $tip.SetToolTip($btnX, "Close")

  $grid = New-Object System.Windows.Forms.TableLayoutPanel
  $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
  $grid.ColumnCount = 1
  $grid.RowCount = 3
  $grid.Padding = New-Object System.Windows.Forms.Padding((Sz 14), (Sz 12), (Sz 14), (Sz 5))
  $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  # Row 1 is the divider: one hair line with a little air above and below.
  $grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  $grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (Sz 10)))) | Out-Null
  $grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 0))) | Out-Null

  $divider = New-Object System.Windows.Forms.Panel
  $divider.Dock = [System.Windows.Forms.DockStyle]::Fill
  $divider.BackColor = $LINE
  $divider.Margin = New-Object System.Windows.Forms.Padding(0, (Sz 4), 0, (Sz 5))
  $divider.Visible = $false

  $txtSrc = New-Object System.Windows.Forms.TextBox
  $txtSrc.Multiline = $true
  $txtSrc.ReadOnly = $true
  $txtSrc.BorderStyle = [System.Windows.Forms.BorderStyle]::None
  $txtSrc.BackColor = $CARD_BG
  $txtSrc.ForeColor = $INK
  $txtSrc.Dock = [System.Windows.Forms.DockStyle]::Fill
  $txtSrc.ScrollBars = [System.Windows.Forms.ScrollBars]::None
  $txtSrc.Font = Fs 13.5
  $txtSrc.TabStop = $false

  $txtDst = New-Object System.Windows.Forms.TextBox
  $txtDst.Multiline = $true
  $txtDst.ReadOnly = $true
  $txtDst.BorderStyle = [System.Windows.Forms.BorderStyle]::None
  $txtDst.BackColor = $CARD_BG
  $txtDst.ForeColor = $OK_INK
  $txtDst.Dock = [System.Windows.Forms.DockStyle]::Fill
  $txtDst.ScrollBars = [System.Windows.Forms.ScrollBars]::None
  $txtDst.Font = Fs 13.5
  $txtDst.Visible = $false
  $txtDst.TabStop = $false

  # Each pane gets its own speaker button: reading is opt-in per side, so the
  # card never starts talking on its own.
  $btnSaySrc = New-CardButton (U 0x25B6) 30
  $btnSaySrc.MinimumSize = New-Object System.Drawing.Size((Sz 30), (Sz 26))
  $btnSaySrc.Margin = New-Object System.Windows.Forms.Padding((Sz 6), 0, 0, 0)
  $btnSaySrc.Visible = $true

  $btnSayDst = New-CardButton (U 0x25B6) 30
  $btnSayDst.MinimumSize = New-Object System.Drawing.Size((Sz 30), (Sz 26))
  $btnSayDst.Margin = New-Object System.Windows.Forms.Padding((Sz 6), 0, 0, 0)

  $srcRow = New-Object System.Windows.Forms.TableLayoutPanel
  $srcRow.Dock = [System.Windows.Forms.DockStyle]::Fill
  $srcRow.ColumnCount = 3
  $srcRow.RowCount = 1
  $srcRow.Margin = New-Object System.Windows.Forms.Padding(0)
  $srcRow.BackColor = $CARD_BG
  $srcRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  $srcRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Sz 10)))) | Out-Null
  $srcRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Sz 40)))) | Out-Null
  $srcRow.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  $script:sbSrc = New-Scrollbar $txtSrc
  $script:sbDst = New-Scrollbar $txtDst
  $srcRow.Controls.Add($txtSrc, 0, 0)
  $srcRow.Controls.Add($script:sbSrc, 1, 0)
  $srcRow.Controls.Add($btnSaySrc, 2, 0)

  $dstRow = New-Object System.Windows.Forms.TableLayoutPanel
  $dstRow.Dock = [System.Windows.Forms.DockStyle]::Fill
  $dstRow.ColumnCount = 3
  $dstRow.RowCount = 1
  $dstRow.Margin = New-Object System.Windows.Forms.Padding(0)
  $dstRow.BackColor = $CARD_BG
  $dstRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  $dstRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Sz 10)))) | Out-Null
  $dstRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Sz 40)))) | Out-Null
  $dstRow.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  $dstRow.Controls.Add($txtDst, 0, 0)
  $dstRow.Controls.Add($script:sbDst, 1, 0)
  $dstRow.Controls.Add($btnSayDst, 2, 0)

  $grid.Controls.Add($srcRow, 0, 0)
  $grid.Controls.Add($divider, 0, 1)
  $grid.Controls.Add($dstRow, 0, 2)

  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = [System.Windows.Forms.DockStyle]::Bottom
  $foot.Height = (Sz 46)
  $foot.BackColor = $BAR_BG

  $status = New-Object System.Windows.Forms.Label
  $status.Text = ""
  $status.ForeColor = $INK_DIM
  $status.AutoSize = $false
  $status.Dock = [System.Windows.Forms.DockStyle]::Left
  $status.Width = (Sz 200)
  $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $status.Padding = New-Object System.Windows.Forms.Padding((Sz 11), 0, 0, 0)

  $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
  $buttons.Dock = [System.Windows.Forms.DockStyle]::Right
  $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
  $buttons.WrapContents = $false
  $buttons.AutoSize = $true
  $buttons.Padding = New-Object System.Windows.Forms.Padding(0, (Sz 10), (Sz 12), (Sz 10))
  $buttons.BackColor = $BAR_BG

  $btnTranslate = New-CardButton $T_TRANSLATE 64
  $btnExplain = New-CardButton $T_EXPLAIN 64
  $btnAsk = New-CardButton $T_ASK 56
  $btnSave = New-CardButton $T_SAVE 56
  $btnCopy = New-CardButton $T_COPY 56
  $buttons.Controls.Add($btnTranslate)
  $buttons.Controls.Add($btnExplain)
  $buttons.Controls.Add($btnAsk)
  $buttons.Controls.Add($btnSave)
  $buttons.Controls.Add($btnCopy)

  $foot.Controls.Add($buttons)
  $foot.Controls.Add($status)

  $form.Controls.Add($grid)
  $form.Controls.Add($foot)
  $form.Controls.Add($head)

  $script:head = $head
  Set-CardRegion $form
  $form.MakeDraggable($head)
  $form.MakeDraggable($title)

  $btnX.Add_Click({ Hide-Card })
  $form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Hide-Card }
  })

  $btnCopy.Add_Click({
    # What the user highlighted inside the card wins over the whole pane.
    $text = ""
    if ($null -ne $script:txtDst -and $script:txtDst.SelectionLength -gt 0) { $text = $script:txtDst.SelectedText }
    elseif ($null -ne $script:txtSrc -and $script:txtSrc.SelectionLength -gt 0) { $text = $script:txtSrc.SelectedText }
    elseif (-not [string]::IsNullOrEmpty($script:dstText)) { $text = $script:dstText }
    else { $text = $script:srcText }
    try { Set-Clipboard -Value $text } catch { }
    Set-CardStatus $T_COPIED $INK_DIM
    $script:btnCopy.Text = $T_COPIED
    if ($null -ne $script:statusTimer) { $script:statusTimer.Stop() }
    $script:statusTimer = New-Object System.Windows.Forms.Timer
    $script:statusTimer.Interval = 1400
    $script:statusTimer.Add_Tick({
      $script:statusTimer.Stop()
      $script:btnCopy.Text = $T_COPY
      Set-CardStatus "" $INK_DIM
    })
    $script:statusTimer.Start()
  })

  $btnAsk.Add_Click({
    Write-Json @{ type = "intent"; intent = "ask"; id = $script:lastId }
    try { Set-Clipboard -Value $script:srcText } catch { }
    Show-HostWindow
    Hide-Card
  })

  $btnTranslate.Add_Click({ Start-Task "translate" })
  $btnExplain.Add_Click({ Start-Task "explain" })

  # Vocabulary: the host owns the file, the card only reports the pair.
  $btnSaySrc.Add_Click({
    $text = [string]$script:srcText
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $script:btnSaySrc.Text = U 0x25A0
    Speak-Text $text $script:srcLang
    $script:btnSaySrc.Text = U 0x25B6
  })

  $btnSayDst.Add_Click({
    $text = [string]$script:dstText
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $script:btnSayDst.Text = U 0x25A0
    Speak-Text $text $script:dstLang
    $script:btnSayDst.Text = U 0x25B6
  })

  $btnSave.Add_Click({
    # Select a word in the source pane and this saves that word instead of the
    # whole sentence - the usual case: one or two words per sentence are new.
    $picked = ""
    if ($null -ne $script:txtSrc -and $script:txtSrc.SelectionLength -gt 0) {
      $picked = [string]$script:txtSrc.SelectedText
    }
    $picked = $picked.Trim()
    if ($picked -ne "") {
      Write-Json @{
        type = "vocab"
        word = $picked
        translation = ""
        context = [string]$script:srcText
        lang = $script:srcLang
        task = $script:activeTask
      }
      Set-CardStatus ((U 0x5DF2, 0x6536, 0x85CF) + " " + $picked) $OK_INK
      return
    }
    if ([string]::IsNullOrWhiteSpace($script:srcText)) { return }
    Write-Json @{
      type        = "vocab"
      word        = $script:srcText
      translation = $script:dstText
      context     = $script:srcText
      lang        = $script:lang
      task        = $script:activeTask
    }
    Set-CardStatus $T_SAVED $OK_INK
    $script:btnSave.Text = $T_SAVED
  })

  $script:brushDrop = New-Object System.Drawing.SolidBrush($DROPDOWN_BG)
  $script:brushInk = New-Object System.Drawing.SolidBrush($INK)

  $script:card = $form
  $script:head = $head
  $script:grid = $grid
  $script:txtSrc = $txtSrc
  $txtSrc.Add_MouseUp({
    $sel = [string]$script:txtSrc.SelectedText
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $sel = $sel.Trim()
    # Only a single word: a phrase belongs to translate/explain.
    if ($sel.Length -lt 2 -or $sel.Length -gt 40 -or $sel -match "\s") { return }
    try { Invoke-WordLookup $sel } catch { Write-Trace ("word lookup error: " + $_.Exception.Message) }
  })
  $script:divider = $divider
  $script:txtDst = $txtDst
  $script:status = $status
  $script:btnLang = $btnLang
  $script:btnVocab = $btnVocab
  $script:btnTranslate = $btnTranslate
  $script:btnExplain = $btnExplain
  $script:btnAsk = $btnAsk
  $script:btnCopy = $btnCopy
  $script:btnSave = $btnSave
  $script:btnSaySrc = $btnSaySrc
  $script:btnSayDst = $btnSayDst
  $btnCopy.Visible = $false

  $script:poll = New-Object System.Windows.Forms.Timer
  $script:poll.Interval = 150
  $script:poll.Add_Tick({ Poll-Translate })
}

# ---------------------------------------------------------------- quick bar
#
# Selecting text pops a small pill instead of the full card, like the toolbar
# Doubao shows: pick translate and the card opens with the translation, pick
# quote and the text goes to the DSH composer, pick x and nothing else happens.
$script:bar = $null
$script:barCapture = $null

function Set-PillRegion {
  param([System.Windows.Forms.Form]$Form)
  $w = $Form.Width
  $h = $Form.Height
  $r = [int]($h / 2)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, $r, $r, 180, 90)
  $path.AddArc($w - $r, 0, $r, $r, 270, 90)
  $path.AddArc($w - $r, $h - $r, $r, $r, 0, 90)
  $path.AddArc(0, $h - $r, $r, $r, 90, 90)
  $path.CloseFigure()
  $Form.Region = New-Object System.Drawing.Region($path)
}

function New-Bar {
  $f = New-Object QuickAsk.CardForm
  $f.Text = "dsh-external-toolbox-bar"
  $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $f.ShowInTaskbar = $false
  $f.TopMost = $true
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $f.BackColor = $BAR_BG
  $f.ForeColor = $INK
  $f.Font = Fs 12
  $f.Padding = New-Object System.Windows.Forms.Padding(1)

  $flow = New-Object System.Windows.Forms.FlowLayoutPanel
  $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
  $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
  $flow.WrapContents = $false
  $flow.BackColor = $BAR_BG
  $flow.Padding = New-Object System.Windows.Forms.Padding((Sz 5), (Sz 4), (Sz 5), (Sz 4))

  # No close button: clicking anywhere outside the pill, or dropping the
  # selection, hides it already, and the pill is meant to be two actions only.
  $bTranslate = New-CardButton $T_TRANSLATE 56
  $bExplain = New-CardButton $T_EXPLAIN 56
  $bAsk = New-CardButton $T_ASK 50
  $bVocab = New-CardButton (U 0x751F, 0x8BCD) 50
  $bVocab.Add_Click({ Hide-Bar; Show-Review })
  $bCopy = New-CardButton (U 0x590D, 0x5236) 50
  $bCopy.Add_Click({
    Write-Trace "bar copy clicked"
    $captured = $script:barCapture
    Hide-Bar
    if ($null -eq $captured) { return }
    try { Set-Clipboard -Value ([string]$captured.text) } catch { }
  })
  foreach ($b in @($bTranslate, $bExplain, $bAsk, $bVocab, $bCopy)) {
    $b.MinimumSize = New-Object System.Drawing.Size($b.MinimumSize.Width, (Sz 22))
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $BAR_BG
    $b.Margin = New-Object System.Windows.Forms.Padding((Sz 4), 0, 0, 0)
    $flow.Controls.Add($b)
  }
  $bTranslate.ForeColor = $ACCENT

  $bTranslate.Add_Click({
    Write-Trace "bar translate clicked"
    $captured = $script:barCapture
    Hide-Bar
    if ($null -eq $captured) { return }
    Show-Card $captured
    Start-Task "translate"
  })
  $bExplain.Add_Click({
    Write-Trace "bar explain clicked"
    $captured = $script:barCapture
    Hide-Bar
    if ($null -eq $captured) { return }
    Show-Card $captured
    Start-Task "explain"
  })
  $bAsk.Add_Click({
    Write-Trace "bar ask clicked"
    $captured = $script:barCapture
    Hide-Bar
    if ($null -eq $captured) { return }
    Write-Json @{ type = "intent"; intent = "ask"; id = [string]$captured.id }
    try { Set-Clipboard -Value ([string]$captured.text) } catch { }
    Show-HostWindow
  })


  $f.Controls.Add($flow)
  $f.AutoSize = $false
  $f.ClientSize = New-Object System.Drawing.Size((Sz 204), (Sz 38))
  # Buttons grow to fit their text at the current dpi, so let the flow panel
  # report the size it actually wants instead of guessing one.
  $flow.PerformLayout()
  $pref = $flow.PreferredSize
  $f.ClientSize = New-Object System.Drawing.Size(($pref.Width + (Sz 2)), ($pref.Height + (Sz 2)))
  Set-PillRegion $f
  $f.MakeDraggable($flow)

  $script:barTranslate = $bTranslate
  $script:barExplain = $bExplain
  $script:barAsk = $bAsk
  return $f
}

function Show-Bar {
  param([hashtable]$Captured)
  if ($null -eq $script:bar) { $script:bar = New-Bar }
  $script:barCapture = $Captured

  $p = New-Object QuickAsk.POINT
  [void][QuickAsk.Native]::GetCursorPos([ref]$p)
  $cursor = New-Object System.Drawing.Point($p.X, $p.Y)
  $wa = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
  $x = $p.X + 12
  $y = $p.Y + 18
  if ($x + $script:bar.Width -gt $wa.Right) { $x = $wa.Right - $script:bar.Width - 6 }
  if ($y + $script:bar.Height -gt $wa.Bottom) { $y = $p.Y - $script:bar.Height - 12 }
  if ($x -lt $wa.Left) { $x = $wa.Left + 6 }
  if ($y -lt $wa.Top) { $y = $wa.Top + 6 }
  $script:bar.Location = New-Object System.Drawing.Point($x, $y)
  $script:bar.Show()
  Write-Trace ("bar shown at " + [string]$x + "," + [string]$y + " " + [string]$script:bar.Width + "x" + [string]$script:bar.Height)
  $script:bar.BringToFront()
  if ($env:QUICKASK_DEBUG) { Write-Json @{ type = "bar"; bounds = $script:bar.Bounds.ToString() } }
}

function Hide-Bar {
  if ($null -ne $script:bar -and $script:bar.Visible) { $script:bar.Hide() }
}

function Set-CardStatus {
  param([string]$Text, [System.Drawing.Color]$Color)
  if ($null -eq $script:status) { return }
  $script:status.Text = $Text
  $script:status.ForeColor = $Color
}

# Compact height (source only) and tall height (source + divider + translation),
# both in 96 dpi design pixels.
$script:CARD_H_COMPACT = 214
$script:CARD_H_TALL = 330

# keyed by textbox handle: paint/mouse handlers need to find their own state
$script:scrollbars = @{}
function Set-CardHeight {
  param([int]$Design)
  if ($null -eq $script:card) { return }
  $h = Sz $Design
  if ($script:card.Height -eq $h) { return }
  $script:card.Height = $h
  Set-CardRegion $script:card
  # growing downwards near the bottom edge would push the buttons off screen
  $wa = [System.Windows.Forms.Screen]::FromPoint($script:card.Location).WorkingArea
  $y = $script:card.Top
  if ($y + $h -gt ($wa.Bottom - 8)) { $y = $wa.Bottom - $h - 8 }
  if ($y -lt ($wa.Top + 8)) { $y = $wa.Top + 8 }
  $script:card.Top = $y
  # A taller pane fits more lines, so the overflow decision has to be redone.
  Update-Scrollbar $script:txtSrc
  Update-Scrollbar $script:txtDst
}

# The card is WS_EX_NOACTIVATE, so WinForms never sees a wheel: the mouse hook
# forwards it into whichever pane is on screen instead (see MouseWatcher).
function Update-WheelTarget {
  if ($null -eq $script:mouseWatcher -or $null -eq $script:card) { return }
  $script:mouseWatcher.WheelWindow = $script:card.Handle
  $script:mouseWatcher.WheelSrc = $script:txtSrc.Handle
  $script:mouseWatcher.WheelDst = $script:txtDst.Handle
  if ($script:txtDst.Visible) { $script:mouseWatcher.WheelTarget = $script:txtDst.Handle }
  else { $script:mouseWatcher.WheelTarget = $script:txtSrc.Handle }
}

# A slim scrolling lane drawn by ourselves: the stock TextBox scrollbar is 17px
# of white chrome that fights the card, and it cannot be themed. The lane only
# appears when the pane actually overflows, and its thumb length is the visible
# fraction, so "how much is left" stays readable at a glance.
function Get-ScrollGeometry($Box, $Track) {
  $perLine = [Math]::Max(1, [int]$Box.Font.Height)
  $visible = [Math]::Max(1, [int](($Box.ClientSize.Height - (Sz 6)) / $perLine))
  $total = $Box.GetLineFromCharIndex([Math]::Max(0, $Box.TextLength - 1)) + 1
  $first = [int][QuickAsk.Native]::SendMessage($Box.Handle, 0x00CE, [IntPtr]::Zero, [IntPtr]::Zero)
  $over = $total -gt $visible
  $lane = [Math]::Max(1, $Track.ClientSize.Height)
  $thumb = if ($over) {
    [Math]::Max((Sz 16), [int]($lane * $visible / [Math]::Max(1, $total)))
  } else {
    $lane
  }
  $span = [Math]::Max(1, $total - $visible)
  $top = if ($over -and $span -gt 0) {
    [int](($lane - $thumb) * ([Math]::Min([Math]::Max(0, $first), $span)) / $span)
  } else {
    0
  }
  return @{ over = $over; total = $total; visible = $visible; first = $first; height = $thumb; top = $top }
}

function Update-Scrollbar($Box) {
  if ($null -eq $Box) { return }
  $state = $script:scrollbars[$Box.Handle.ToInt64()]
  if ($null -eq $state) { return }
  try {
    $track = $state.track
    $geo = Get-ScrollGeometry $Box $track
    $state.geometry = $geo
    $track.Tag = $state
    if ($track.Visible -ne $geo.over) { $track.Visible = $geo.over }
    if ($geo.over) { $track.Invalidate() }
  } catch {
    Write-Trace ("scrollbar failed: " + $_.Exception.Message)
  }
}

function Update-AllScrollbars {
  Update-Scrollbar $script:txtSrc
  Update-Scrollbar $script:txtDst
}

function Move-ScrollbarTo($Track, [int]$Y) {
  $state = $Track.Tag
  if ($null -eq $state -or $null -eq $state.geometry) { return }
  $geo = $state.geometry
  $lane = [Math]::Max(1, $Track.ClientSize.Height)
  $room = [Math]::Max(1, $lane - $geo.height)
  $span = [Math]::Max(1, $geo.total - $geo.visible)
  $want = [int]([Math]::Round(($Y - $state.grabOffset) * $span / $room))
  $want = [Math]::Min([Math]::Max(0, $want), $span)
  $delta = $want - $geo.first
  if ($delta -ne 0) {
    [void][QuickAsk.Native]::SendMessage($state.box.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr]$delta)
    $state.box.Refresh()
    Update-Scrollbar $state.box
  }
}

function New-Scrollbar($Box) {
  $track = New-Object System.Windows.Forms.Panel
  $track.Dock = [System.Windows.Forms.DockStyle]::Fill
  $track.Margin = New-Object System.Windows.Forms.Padding((Sz 2), (Sz 4), (Sz 2), 0)
  $track.BackColor = $CARD_BG
  $track.Cursor = [System.Windows.Forms.Cursors]::Hand
  $track.Visible = $false
  $state = @{ track = $track; box = $Box; geometry = $null; dragging = $false; grabOffset = 0 }
  $track.Tag = $state
  $track.Add_Paint({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state -or $null -eq $state.geometry) { return }
    $geo = $state.geometry
    if (-not $geo.over) { return }
    $brush = New-Object System.Drawing.SolidBrush($THUMB)
    $e.Graphics.FillRectangle($brush, 1, $geo.top, ($sender.Width - 2), $geo.height)
    $brush.Dispose()
  })
  $track.Add_MouseDown({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state -or $null -eq $state.geometry) { return }
    if (-not $state.geometry.over) { return }
    if ($e.Y -ge $state.geometry.top -and $e.Y -le ($state.geometry.top + $state.geometry.height)) {
      $state.dragging = $true
      $state.grabOffset = $e.Y - $state.geometry.top
    } else {
      # clicking the lane pages one screen towards the click
      $step = [Math]::Max(1, $state.geometry.visible - 2)
      if ($e.Y -lt $state.geometry.top) { $step = -$step }
      [void][QuickAsk.Native]::SendMessage($state.box.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr]$step)
      $state.box.Refresh()
      Update-Scrollbar $state.box
    }
  })
  $track.Add_MouseMove({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -ne $state -and $state.dragging) { Move-ScrollbarTo $sender $e.Y }
  })
  $track.Add_MouseUp({
    param($sender, $e)
    if ($null -ne $sender.Tag) { $sender.Tag.dragging = $false }
  })
  $script:scrollbars[$Box.Handle.ToInt64()] = $state
  return $track
}
function Show-CardTranslation {
  param([string]$Text, [System.Drawing.Color]$Color)
  $script:txtDst.ForeColor = $Color
  $script:txtDst.Text = $Text
  $script:txtDst.Visible = $true
  $script:txtDst.SelectionStart = 0
  $script:divider.Visible = $true
  $script:grid.RowStyles[1].Height = (Sz 10)
  $script:grid.RowStyles[0].Height = 46
  $script:grid.RowStyles[2].Height = 54
  $script:dstText = $Text
  Set-CardHeight $script:CARD_H_TALL
  Update-Scrollbar $script:txtSrc
  Update-Scrollbar $script:txtDst
  Update-WheelTarget
  if (
    $Text -ne $T_TRANSLATING -and
    $Text -ne $T_EXPLAINING -and
    -not $Text.StartsWith($T_NO_SERVICE) -and
    -not $Text.StartsWith($T_FAILED)
  ) {
    $script:btnCopy.Text = $T_COPY
    $script:btnCopy.Visible = $true
  }
}

function Hide-CardTranslation {
  $script:txtDst.Visible = $false
  $script:txtDst.Text = ""
  $script:divider.Visible = $false
  $script:grid.RowStyles[1].Height = 0
  $script:grid.RowStyles[0].Height = 100
  $script:grid.RowStyles[2].Height = 0
  $script:dstText = ""
  $script:btnCopy.Text = $T_COPY
  $script:btnCopy.Visible = $false
  Set-CardHeight $script:CARD_H_COMPACT
  Update-Scrollbar $script:txtSrc
  Update-Scrollbar $script:txtDst
  Update-WheelTarget
}

function Show-Card {
  param([hashtable]$Captured)
  if ($null -eq $script:card) { New-Card }

  if ($null -eq $Captured) {
    $script:lastId = ""
    $script:srcText = ""
    $script:txtSrc.Text = $T_NO_TEXT + " - " + $T_HINT
    Hide-CardTranslation
    $script:btnTranslate.Enabled = $false
    $script:btnAsk.Enabled = $false
    $script:btnCopy.Enabled = $false
  } else {
    $script:lastId = [string]$Captured.id
    $script:srcText = [string]$Captured.text
  # Only two voices exist on this machine (zh/en); anything else reads as en.
  $script:srcLang = if ($script:srcText -match "[\u4e00-\u9fff]") { "zh" } else { "en" }
    $script:txtSrc.Text = $script:srcText
    Hide-CardTranslation
    $script:btnTranslate.Enabled = $true
    $script:btnExplain.Enabled = $true
    $script:btnAsk.Enabled = $true
    $script:btnSave.Enabled = $true
    $script:btnCopy.Enabled = $true
    $script:txtSrc.SelectionStart = 0
    $script:txtSrc.SelectionLength = 0
  }

  $script:busy = $false
  $script:btnTranslate.Text = $T_TRANSLATE
  $script:btnExplain.Text = $T_EXPLAIN
  $script:btnSave.Text = $T_SAVE
  Set-CardStatus "" $INK_DIM

  # place near the cursor, clamped to the screen it is on
  $p = New-Object QuickAsk.POINT
  [void][QuickAsk.Native]::GetCursorPos([ref]$p)
  $cursor = New-Object System.Drawing.Point($p.X, $p.Y)
  $wa = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
  $x = $p.X + 16
  $y = $p.Y + 16
  if ($x + $script:card.Width -gt $wa.Right) { $x = $wa.Right - $script:card.Width - 8 }
  if ($y + $script:card.Height -gt $wa.Bottom) { $y = $wa.Bottom - $script:card.Height - 8 }
  if ($x -lt $wa.Left) { $x = $wa.Left + 8 }
  if ($y -lt $wa.Top) { $y = $wa.Top + 8 }
  $script:card.Location = New-Object System.Drawing.Point($x, $y)

  $script:card.Show()
  Update-Scrollbar $script:txtSrc
  Update-Scrollbar $script:txtDst
  Update-WheelTarget
  $script:card.BringToFront()
  if ($env:QUICKASK_DEBUG) {
    Write-Json @{ type = "card"; bounds = $script:card.Bounds.ToString(); client = $script:card.ClientSize.ToString() }
  }
}

function Hide-Card {
  Hide-LangMenu
  Hide-WordPopup
  if ($null -ne $script:card) { $script:card.Hide() }
  # A hidden card still has a rect: stop swallowing the wheel over it.
  if ($null -ne $script:mouseWatcher) {
    $script:mouseWatcher.WheelWindow = [IntPtr]::Zero
    $script:mouseWatcher.WheelTarget = [IntPtr]::Zero
    $script:mouseWatcher.WheelSrc = [IntPtr]::Zero
    $script:mouseWatcher.WheelDst = [IntPtr]::Zero
  }
  Hide-Bar
  # Once dismissed, selecting the same text again should pop the card again,
  # but a selection that is merely still highlighted must not reopen it.
  $script:dismissed = $script:autoShown
  $script:autoShown = ""
}

# ---------------------------------------------------------------- auto watch
#
# Two triggers, both ending in Show-AutoCapture:
#  * mouse gestures (drag select, double click word select). A low level mouse
#    hook fires right after the selection exists; the capture then tries UIA and
#    falls back to copying the selection, restoring the clipboard right after.
#  * a slow poll of the focused element's TextPattern, for selections made with
#    the keyboard in applications that expose text over UIA.

function Get-ForegroundOwnerPid {
  try {
    $h = [QuickAsk.Native]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return 0 }
    $owner = 0
    [void][QuickAsk.Native]::GetWindowThreadProcessId($h, [ref]$owner)
    return $owner
  } catch {
    return 0
  }
}

function Get-ForegroundClassName {
  try {
    $h = [QuickAsk.Native]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return "" }
    $sb = New-Object System.Text.StringBuilder 256
    [void][QuickAsk.Native]::GetClassName($h, $sb, 256)
    return $sb.ToString()
  } catch {
    return ""
  }
}

# Ctrl+C inside a console interrupts the running command instead of copying, so
# the clipboard fallback never runs there.
function Test-ConsoleForeground {
  $cls = Get-ForegroundClassName
  return ($cls -eq "ConsoleWindowClass" -or $cls -eq "CASCADIA_HOSTING_WINDOW_CLASS" -or $cls -eq "mintty")
}

# Rubber-band selection in a PCB/schematic editor picks objects, not text, so a
# click there must not open the pill. These are the editors people actually use
# on Windows; the match is a substring test on the process name.
$script:QUIET_PROCS = @(
  "pcbnew", "eeschema", "kicad", "altium", "dxp", "x2", "pads", "powerpcb",
  "allegro", "apldesigner", "designspark", "proteus", "multsim", "vivado", "quartus"
)

function Test-QuietApp {
  $name = Get-ForegroundProcessName
  if ([string]::IsNullOrWhiteSpace($name)) { return $false }
  foreach ($proc in $script:QUIET_PROCS) {
    if ($name -like ("*" + $proc + "*")) { return $true }
  }
  return $false
}

# Not every selection is text: object picks in CAD tools hand us a bare
# designator such as "R12", and a test sweep hands us a stray digit.
# Inside an editor that selects objects, only prose is interesting: a reference
# designator or a net name is one bare token, while real text has spaces or CJK.
function Test-ProseLike([string]$Text) {
  $trim = $Text.Trim()
  if ($trim -match "\s") { return $true }
  if ($trim -match "[\p{IsCJKUnifiedIdeographs}\p{IsHiragana}\p{IsKatakana}\p{IsHangulSyllables}]") { return $true }
  return $false
}

function Test-WorthShowing([string]$Text) {
  $trim = $Text.Trim()
  if ($trim.Length -lt 3) { return $false }
  $letters = ([regex]::Matches($trim, "[\p{L}]")).Count
  if ($letters -lt 2) { return $false }
  # A lone reference designator is a picked component, not a word to look up.
  if ($trim -match "^[\p{Lu}\p{Ll}]{1,3}[0-9]{1,4}$") { return $false }
  return $true
}

function Show-AutoCapture {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $Text = $Text -replace "`r`n", "`n"
  if ($Text.Trim().Length -lt 2) { return }
  # A whole-document Ctrl+A is a mis-gesture, not a selection to act on.
  if ($Text.Length -gt 20000) {
    Write-Trace ("auto skip huge chars=" + $Text.Length + " app=" + (Get-ForegroundProcessName))
    return
  }
  if (-not (Test-WorthShowing $Text)) {
    Write-Trace ("auto skip not-text chars=" + $Text.Length + " app=" + (Get-ForegroundProcessName))
    return
  }
  # Object-picking editors still get prose: dropping the pill there entirely was
  # wrong, since people do select real text in a schematic.
  # Dragging a symbol in KiCad copies that symbol to the clipboard, which lands
  # here as prose. Only a real UI Automation selection counts in those editors.
  if ((Test-QuietApp) -and ($script:lastVia -ne "uia")) {
    Write-Trace ("auto skip quiet clipboard app=" + (Get-ForegroundProcessName) + " chars=" + $Text.Length)
    return
  }
  if ((Test-QuietApp) -and -not (Test-ProseLike $Text)) {
    Write-Trace ("auto skip quiet app " + (Get-ForegroundProcessName) + " chars=" + $Text.Length)
    return
  }
  # A whole-page Ctrl+A would otherwise pop a 60k character card nobody asked for.
  if ($Text.Length -gt $script:MAX_CAPTURE_CHARS) { Write-Trace ("capture truncated " + [string]$Text.Length); $Text = $Text.Substring(0, $script:MAX_CAPTURE_CHARS) + "..." }
  if ($Text -eq $script:autoShown -and ((Get-Date) - $script:autoShownAt).TotalSeconds -lt 1.2) { return }
  # A dismissed selection can still be live (the browser keeps it highlighted);
  # the poll must not reopen the card for it until the user selects again.
  if ($Text -eq $script:dismissed) { return }
  $captured = @{ type = "selection"; id = [guid]::NewGuid().ToString("N"); text = $Text; via = "auto"; chars = $Text.Length }
  if ($env:QUICKASK_DEBUG) { Write-Json @{ type = "auto"; chars = $Text.Length; via = $captured.via } }
  $script:autoShown = $Text
  $script:autoShownAt = Get-Date
  Write-Trace ("auto capture chars=" + $Text.Length + " via=" + $captured.via)
  Write-Json $captured
  # A selection only pops the pill: the full card (and the translation round
  # trip) waits for the user to pick translate.
  Show-Bar $captured
}

# Mouse and keyboard hooks both land here: give the application a moment to
# finish its own selection handling, then retry a few times.
function Start-GestureCapture {
  $script:hb.step = "gesture"
  if ($null -eq $script:gestureTimer) { return }
  # Dragging our own card or pill is not a selection gesture.
  if ((Get-Date) -lt $script:ownGestureUntil) { return }
  # An explicit gesture means intent, even for text the user just dismissed.
  $script:dismissed = ""
  $script:gestureTimer.Stop()
  $script:gestureAttempt = 0
  $script:gestureTimer.Interval = 160
  $script:gestureTimer.Start()
}

function Get-AutoSelectionText {
  $script:hb.step = "uia"
  $text = $null
  $script:lastVia = ""

  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    $text = Get-UiaSelectionText -Element $focused
    if ([string]::IsNullOrWhiteSpace($text)) { $text = Get-UiaSelectionTextDeep -Element $focused -Limit 16 }
    if ([string]::IsNullOrWhiteSpace($text)) {
      $fgHwnd = [QuickAsk.Native]::GetForegroundWindow()
      if ($fgHwnd -ne [IntPtr]::Zero) {
        $fgRoot = [System.Windows.Automation.AutomationElement]::FromHandle($fgHwnd)
        if ($null -ne $fgRoot) { $text = Get-UiaSelectionTextDeep -Element $fgRoot -Limit 40 }
      }
    }
  } catch {
    $text = $null
  }
  if (-not [string]::IsNullOrWhiteSpace($text)) { $script:lastVia = "uia" }
  # Ctrl+C copies in an editor but interrupts a shell, so terminals get
  # Ctrl+Insert: the copy chord that never reaches the program. When even that
  # yields nothing we stay quiet for a few seconds instead of poking again.
  if ([string]::IsNullOrWhiteSpace($text) -and ((Get-Date) -ge $script:clipBlockedUntil)) {
    $keys = "^c"
    if ((Test-KeyboardSurface) -or (Test-ConsoleForeground)) { $keys = "^{INSERT}" }
    try { $text = Get-ClipboardSelectionText -Keys $keys } catch { $text = $null }
    if ([string]::IsNullOrWhiteSpace($text)) {
      $script:clipBlockedUntil = (Get-Date).AddSeconds(3)
    } else {
      $script:lastVia = "clipboard"
    }
  }
  return $text
}


# Screen capture tools (PixPin, Snipaste, ...) grab the screen with a borderless
# overlay that covers a whole monitor; while that overlay is up, a drag is the
# user framing a screenshot, not selecting text. Capturing there would also
# fire Ctrl+C into their tool and empty the clipboard they are about to use.
$script:SKIP_PROCS = @("pixpin", "snipaste", "sharex", "screentogif", "snippingtool", "screenclippinghost", "greenshot", "faststone")

$script:lastVia = ""
$script:fgProcPid = 0
$script:fgProcName = ""

function Get-ForegroundProcessName {
  $hwnd = [QuickAsk.Native]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { return "" }
  $fgPid = 0
  [void][QuickAsk.Native]::GetWindowThreadProcessId($hwnd, [ref]$fgPid)
  if ($fgPid -eq $script:fgProcPid) { return $script:fgProcName }
  $name = ""
  try { $name = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName } catch { $name = "" }
  $script:fgProcPid = $fgPid
  $script:fgProcName = $name
  return $name
}

# Terminals treat Ctrl+C as "interrupt", not "copy", so the clipboard fallback
# would fire a literal ^C into the user shell. xterm.js (VS Code, Windows
# Terminal) focuses a hidden textarea called xterm-helper-textarea, which gives
# the case away even though the window class looks like any Chromium window.
$script:TERM_PROCS = @("windowsterminal", "conhost", "openconsole", "mintty", "cmd", "powershell", "pwsh", "bash", "wsl", "wt")

function Test-KeyboardSurface {
  $name = (Get-ForegroundProcessName).ToLowerInvariant()
  if ($script:TERM_PROCS -contains $name) { return $true }
  $cls = (Get-ForegroundClassName).ToLowerInvariant()
  foreach ($known in @("consolewindowclass", "cascadia_hosting_window_class", "mintty")) {
    if ($cls -eq $known) { return $true }
  }

  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -ne $focused) {
      $fc = [string]$focused.Current.ClassName
      $fn = [string]$focused.Current.Name
      if ($fc -like "*xterm*" -or $fn -like "*xterm*") { return $true }
    }
  } catch { }
  return $false
}




function Test-ForegroundOverlay {
  $hwnd = [QuickAsk.Native]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { return $false }
  # A maximized app also covers the whole monitor, so "covers the monitor" alone
  # is not enough: real capture overlays are borderless (no WS_CAPTION).
  $style = [QuickAsk.Native]::GetWindowLongW($hwnd, -16)
  if (($style -band 0x00C00000) -ne 0) { return $false }
  $r = New-Object QuickAsk.RECT
  if (-not [QuickAsk.Native]::GetWindowRect($hwnd, [ref]$r)) { return $false }
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $b = $s.Bounds
    if ($r.Left -le $b.Left -and $r.Top -le $b.Top -and $r.Right -ge $b.Right -and $r.Bottom -ge $b.Bottom) { return $true }
  }
  return $false
}

# The DSH window itself is not "another application": polling its UIA tree
# makes Chromium rebuild its accessibility tree on every tick, which stalls the
# renderer and looks like the whole app freezing.
function Test-ForegroundIsHost {
  $hwnd = [QuickAsk.Native]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { return $false }
  $fgPid = 0
  [void][QuickAsk.Native]::GetWindowThreadProcessId($hwnd, [ref]$fgPid)
  if ($script:parentPid -gt 0 -and $fgPid -eq $script:parentPid) { return $true }
  # Our own card: selecting text inside it is copying, not a new capture.
  if ($fgPid -eq $PID) { return $true }
  $name = (Get-ForegroundProcessName).ToLowerInvariant()
  # The settings window and the desktop shell names look like ours too.
  return ($name -like "*deepseek*")
}

function Test-CaptureBlocked {
  $name = (Get-ForegroundProcessName).ToLowerInvariant()
  if ($script:SKIP_PROCS -contains $name) { return "capture tool " + $name }
  if (Test-ForegroundOverlay) { return "fullscreen overlay" }
  return ""
}

function Invoke-AutoCapture {
  if ($script:busy) { Write-Trace "auto skip busy"; return $false }
  $owner = Get-ForegroundOwnerPid
  if ($owner -eq $PID) { Write-Trace "auto skip foreground-self"; return $false }
  # Selection inside the DSH window is fair game: the user gestured, so this is
  # a one-shot capture rather than the background polling that used to hammer
  # Chromium UIA. Watch-Selection below still skips the host window.
  if (Test-ForegroundIsHost) { Write-Trace ("auto host-window capture allowed pid=" + [string](Get-ForegroundOwnerPid)) }
  $blocked = Test-CaptureBlocked
  if ($blocked -ne "") { Write-Trace ("auto skip " + $blocked); return $false }
  $text = Get-AutoSelectionText
  Write-Trace ("auto try fg=" + (Get-ForegroundClassName) + " owner=" + $owner + " console=" + (Test-ConsoleForeground) + " len=" + [int]($text.Length))
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  Show-AutoCapture $text
  return $true
}

# Runs on its own runspace: it must keep logging even when the UI thread is
# stuck inside a blocking UIA or Win32 call.
$script:WatchdogScript = @'
param($hb, $logPath, $hostHwnd)
Add-Type -Namespace Watch -Name Probe -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);'
function Test-Alive([IntPtr]$h) {
  if ($h -eq [IntPtr]::Zero) { return $true }
  $res = [IntPtr]::Zero
  $ok = [Watch.Probe]::SendMessageTimeout($h, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1200, [ref]$res)
  return ($ok -ne [IntPtr]::Zero)
}
Add-Content -Path $logPath -Value ((Get-Date).ToString("o") + " watchdog: started host=" + [string]$hostHwnd) -Encoding ASCII
$last = -1
$same = 0
$badRun = 0
$iter = 0
while ($true) {
  Start-Sleep -Seconds 2
  $n = [int]$hb.n
  if ($n -eq $last) {
    $same += 1
    if ($same -ge 2) {
      Add-Content -Path $logPath -Value ((Get-Date).ToString("o") + " watchdog: UI STALL at step=" + [string]$hb.step + " n=" + [string]$n) -Encoding ASCII
      $same = 0
    }
  } else {
    $last = $n
    $same = 0
  }
  $iter += 1
  if (($iter % 15) -eq 0) {
    Add-Content -Path $logPath -Value ((Get-Date).ToString("o") + " watchdog: alive tick=" + [string]$hb.n + " dsh=" + [string](Test-Alive ([IntPtr]$hostHwnd))) -Encoding ASCII
  }
  if (-not (Test-Alive ([IntPtr]$hostHwnd))) {
    $badRun += 1
    Add-Content -Path $logPath -Value ((Get-Date).ToString("o") + " watchdog: DSH not answering (#" + $badRun + ")") -Encoding ASCII
  } elseif ($badRun -gt 0) {
    Add-Content -Path $logPath -Value ((Get-Date).ToString("o") + " watchdog: DSH recovered after " + $badRun) -Encoding ASCII
    $badRun = 0
$iter = 0
  }
}
'@

function Start-Watchdog {
  if ($null -ne $script:watchdog) { return }
  $script:hb = [hashtable]::Synchronized(@{ n = 0; step = "idle" })
  $runner = [powershell]::Create()
  $hostHwnd = [IntPtr]::Zero
  try { $hostHwnd = Get-HostWindow } catch { }
  [void]$runner.AddScript($script:WatchdogScript).AddArgument($script:hb).AddArgument($script:LogPath).AddArgument($hostHwnd)
  $script:watchdog = $runner.BeginInvoke()
  $script:watchdogRunner = $runner
}

function Update-Guarded {
  # Escape is only swallowed while our own UI is on screen; the hook checks the
  # handles natively, so they have to be kept current.
  if ($null -eq $script:keyWatcher) { return }
  $handles = New-Object "System.IntPtr[]" 3
  if ($null -ne $script:card) { $handles[0] = $script:card.Handle }
  if ($null -ne $script:bar) { $handles[1] = $script:bar.Handle }
  if ($null -ne $script:langMenu) { $handles[2] = $script:langMenu.Handle }
  $script:keyWatcher.Guarded = $handles
}

function Watch-Selection {
  param($Element = $null)
  Update-Guarded
  # The heartbeat counter lets the watchdog thread prove the UI thread is alive
  # and name the last step it entered.
  $script:hb.n = $script:hb.n + 1
  $script:hb.step = "watch"
  if ($script:busy) { return }
  if (-not $CaptureSelf -and (Get-ForegroundOwnerPid) -eq $PID) { return }
  if (Test-CaptureBlocked -ne "") { return }
  # See Test-ForegroundIsHost: never hammer the DSH window with UIA queries.
  if (-not $CaptureSelf -and (Test-ForegroundIsHost)) { return }

  $text = $null
  try {
    if ($null -eq $Element) { $Element = [System.Windows.Automation.AutomationElement]::FocusedElement }
    $text = Get-UiaSelectionText -Element $Element
  } catch {
    $text = $null
  }

  if ([string]::IsNullOrWhiteSpace($text)) {
    # A deep scan is expensive, so the poll only pays for it occasionally.
    $script:pollN += 1
    if (($script:pollN % 6) -eq 0) {
      try { $text = Get-UiaSelectionTextDeep -Element $Element -Limit 12 } catch { $text = $null }
    }
  }
  if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim().Length -lt 2) {
    $script:autoCandidate = ""
    $script:autoCount = 0
    $script:dismissed = ""
    return
  }

  $text = $text -replace "`r`n", "`n"
  if ($text -eq $script:autoShown) { return }
  if ($text -eq $script:autoCandidate) { $script:autoCount += 1 } else { $script:autoCandidate = $text; $script:autoCount = 1 }
  if ($script:autoCount -lt 2) { return }
  Show-AutoCapture $text
}
# ---------------------------------------------------------------- translation

function Get-TaskUrl([string]$Task) {
  if ([string]::IsNullOrWhiteSpace($TranslateUrl)) { return "" }
  # Translation keeps using the plain /translate route so an older host (one
  # that predates the task parameter) still answers; every other task needs
  # /run, which only newer hosts serve.
  $base = $TranslateUrl
  $sep = "?"
  if ($base.Contains("?")) { $sep = "&" }
  $url = $base + $sep + "id=" + [uri]::EscapeDataString($script:lastId) + "&to=" + [uri]::EscapeDataString($script:lang)
  if ($Task -eq "translate") { return $url }
  if ($base -match '/translate$') {
    $base = $base -replace '/translate$', '/run'
    $sep = "?"
    if ($base.Contains("?")) { $sep = "&" }
    $url = $base + $sep + "id=" + [uri]::EscapeDataString($script:lastId) + "&to=" + [uri]::EscapeDataString($script:lang)
  }
  return $url + "&task=" + [uri]::EscapeDataString($Task)
}

$script:speaker = $null
$script:media = $null
$script:nodePath = $null
$script:lastAudio = ""

function Get-NodePath {
  if ($null -ne $script:nodePath) { return $script:nodePath }
  $script:nodePath = ""
  $candidates = @(
    (Join-Path $env:ProgramFiles "nodejs\node.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\nodejs\node.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { $script:nodePath = $candidate; break }
  }
  if ($script:nodePath -eq "") {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $script:nodePath = [string]$cmd.Source }
  }
  return $script:nodePath
}

# Edge neural voices sound far better than the SAPI ones Windows ships with.
# Synthesis happens in a node child (see tools/say.mjs), playback through WPF.
function Speak-Neural([string]$Text, [string]$Lang) {
  $node = Get-NodePath
  if ($node -eq "") { return $false }
  $tool = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\say.mjs"
  if (-not (Test-Path -LiteralPath $tool)) { return $false }
  $voice = "en-US-AriaNeural"
  if ($Lang -eq "zh") { $voice = "zh-CN-XiaoxiaoNeural" }
  $base = Join-Path $env:TEMP ("dsh-say-" + [guid]::NewGuid().ToString("N"))
  $textFile = $base + ".txt"
  $audio = $base + ".mp3"
  try {
    [System.IO.File]::WriteAllText($textFile, $Text, (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = '"' + $tool + '" --text-file "' + $textFile + '" "' + $audio + '" "' + $voice + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(12000)) {
      try { $proc.Kill() } catch { }
      Write-Trace "say: node timed out"
      return $false
    }
    if (-not (Test-Path -LiteralPath $audio)) {
      $err = $proc.StandardError.ReadToEnd()
      Write-Trace ("say: no audio; " + $err.Trim())
      return $false
    }
    if ($null -eq $script:media) {
      Add-Type -AssemblyName PresentationCore
      $script:media = New-Object System.Windows.Media.MediaPlayer
    }
    $script:media.Close()
    $script:media.Open((New-Object System.Uri($audio)))
    $script:media.Volume = 1.0
    $script:media.Play()
    # Only keep the file we are playing; earlier clips are dead weight.
    if ($script:lastAudio -ne "" -and $script:lastAudio -ne $audio) {
      try { Remove-Item -LiteralPath $script:lastAudio -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:lastAudio = $audio
    Write-Trace ("say: neural " + $voice)
    return $true
  } catch {
    Write-Trace ("say: " + $_.Exception.Message)
    return $false
  } finally {
    # Keep the mp3 (it may still be playing), drop the text file.
    try { Remove-Item -LiteralPath $textFile -Force -ErrorAction SilentlyContinue } catch { }
  }
}

function Speak-Sapi([string]$Text, [string]$Lang) {
  try {
    if ($null -eq $script:speaker) {
      Add-Type -AssemblyName System.Speech
      $script:speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
    }
    $prefix = "en-"
    if ($Lang -eq "zh") { $prefix = "zh-" }
    $voice = ""
    foreach ($installed in $script:speaker.GetInstalledVoices()) {
      if ($installed.VoiceInfo.Culture.Name -like ($prefix + "*")) {
        $voice = $installed.VoiceInfo.Name
        break
      }
    }
    # No voice for this language is a normal outcome, not an error.
    if ($voice -eq "") { return }
    $script:speaker.SpeakAsyncCancelAll()
    $script:speaker.SelectVoice($voice)
    [void]$script:speaker.SpeakAsync($Text)
  } catch {
    Write-Trace ("speak failed: " + $_.Exception.Message)
  }
}

function Speak-Text([string]$Text, [string]$Lang) {
  if ($NoSpeak) { return }
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  if (Speak-Neural $Text $Lang) { return }
  Speak-Sapi $Text $Lang
}
function Invoke-ToolboxJson([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  try {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.Timeout = 8000
    $request.ReadWriteTimeout = 8000
    $response = $request.GetResponse()
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Dispose()
    $response.Close()
    return ($body | ConvertFrom-Json)
  } catch {
    Write-Trace ("review request failed: " + $_.Exception.Message)
    return $null
  }
}

function Get-ReviewUrl([string]$Query) {
  $base = $script:TranslateUrl
  if ([string]::IsNullOrWhiteSpace($base)) { return "" }
  if ($base -match "/translate$") { $base = $base -replace "/translate$", "/review" }
  return $base + $Query
}

$script:reviewWord = ""
$script:reviewMeaning = ""
$script:reviewDetail = ""
$script:reviewContext = ""
$script:reviewDue = 0
$script:reviewTotal = 0

$script:reviewForm = $null

# ------------------------------------------------------- word lookup popup
# Selecting a single word in the source pane is a "what does this mean" gesture:
# ask the host for the dictionary lines plus the fragment of the translation that
# renders it, then show it in a small panel beside the card. Nothing is sent for
# multi-word selections (that is what translate/explain are for).
$script:wordPop = $null

function Get-WordUrl {
  # Derive from the bare translate URL: Get-TaskUrl already appends query
  # parameters, and a trailing "/translate?to=..." would not match a suffix test.
  $base = $script:TranslateUrl
  if ([string]::IsNullOrWhiteSpace($base)) { return "" }
  if ($base -match "/translate") { $base = $base -replace "/translate.*$", "/word" }
  return $base
}

function New-WordPopup {
  $f = New-Object QuickAsk.CardForm
  $f.Text = "dsh-external-toolbox-word"
  $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $f.TopMost = $true
  $f.ShowInTaskbar = $false
  $f.BackColor = $CARD_BG
  $f.Font = Fs 12
  $f.ClientSize = New-Object System.Drawing.Size((Sz 430), (Sz 190))

  # Docking is resolved in reverse control order, so the Fill body goes in
  # first: the header and the match line then dock around the space left over.
  $body = New-Object System.Windows.Forms.TextBox
  $body.Multiline = $true
  $body.ReadOnly = $true
  $body.BorderStyle = [System.Windows.Forms.BorderStyle]::None
  $body.BackColor = $CARD_BG
  $body.ForeColor = $INK
  $body.Font = Fs 12.5
  $body.Dock = [System.Windows.Forms.DockStyle]::Fill
  $body.ScrollBars = [System.Windows.Forms.ScrollBars]::None
  $body.TabStop = $false

  # A padding host keeps the text off the window edge; the TextBox itself has
  # no usable Padding property.
  $pad = New-Object System.Windows.Forms.Panel
  $pad.Dock = [System.Windows.Forms.DockStyle]::Fill
  $pad.BackColor = $CARD_BG
  $pad.Padding = New-Object System.Windows.Forms.Padding((Sz 14), (Sz 6), (Sz 14), (Sz 6))
  $body.Dock = [System.Windows.Forms.DockStyle]::Fill
  $pad.Controls.Add($body)
  $f.Controls.Add($pad)

  $head = New-Object System.Windows.Forms.Panel
  $head.Dock = [System.Windows.Forms.DockStyle]::Top
  $head.Height = (Sz 42)
  $head.BackColor = $BAR_BG
  $f.Controls.Add($head)

  $word = New-Object System.Windows.Forms.Label
  $word.Text = ""
  $word.AutoSize = $true
  $word.Dock = [System.Windows.Forms.DockStyle]::None
  $word.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $word.Location = New-Object System.Drawing.Point((Sz 14), (Sz 2))
  $word.Font = FsB 15
  $word.ForeColor = $ACCENT
  $word.BackColor = $BAR_BG
  $head.Controls.Add($word)

  # dictionary IPA, shown dim under the headword
  $ipa = New-Object System.Windows.Forms.Label
  $ipa.Text = ""
  $ipa.AutoSize = $true
  $ipa.Font = Fs 11
  $ipa.ForeColor = $INK_DIM
  $ipa.BackColor = $BAR_BG
  $ipa.Location = New-Object System.Drawing.Point((Sz 14), (Sz 23))
  $ipa.Visible = $false
  $head.Controls.Add($ipa)

  $match = New-Object System.Windows.Forms.Label
  $match.Text = ""
  $match.AutoSize = $false
  $match.Dock = [System.Windows.Forms.DockStyle]::Bottom
  $match.Height = (Sz 26)
  $match.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $match.Padding = New-Object System.Windows.Forms.Padding((Sz 14), 0, (Sz 14), 0)
  $match.Font = Fs 12.5
  $match.ForeColor = $OK_INK
  $match.BackColor = $CARD_BG
  $match.Visible = $false
  $f.Controls.Add($match)

  $script:wordPop = $f
  $script:wordPopBody = $body
  $script:wordPopWord = $word
  $script:wordPopIpa = $ipa
  $script:wordPopMatch = $match
}
function Hide-WordPopup {
  if ($null -ne $script:wordPop) { $script:wordPop.Hide() }
}

function Show-WordPopup {
  param([string]$Word, [string]$Entry, [string]$Match, [string]$Ipa = "")
  if ($null -eq $script:wordPop) { New-WordPopup }
  $lines = @()
  foreach ($line in ($Entry -split "`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -ne "") { $lines += $trimmed }
  }
  $script:wordPopWord.Text = $Word
  $script:wordPopIpa.Text = $Ipa
  $script:wordPopIpa.Visible = ($Ipa -ne "")
  $script:wordPopBody.Text = ($lines -join "`r`n")
  # Control.Visible reads false while the form is still hidden, so remember the
  # intent in a local and drive both the label and the height from it.
  $hasMatch = ($Match -ne "")
  if ($hasMatch) {
    $script:wordPopMatch.Text = (U 0x8BD1, 0x6587, 0x5BF9, 0x5E94) + ": " + $Match
    $script:wordPopMatch.Visible = $true
  } else {
    $script:wordPopMatch.Visible = $false
  }
  # Measure the wrapped text with the body's own font: GetPositionFromCharIndex
  # reports stale coordinates until the control is laid out at its final size.
  # One design row per dictionary line: measured heights from TextRenderer are
  # physical pixels and keep disagreeing with the TextBox's own spacing.
  $rows = [Math]::Max(3, [Math]::Min(14, $lines.Count))
  $need = ($rows * (Sz 20)) + (Sz 12)
  $height = (Sz 34) + $need
  if ($hasMatch) { $height += (Sz 26) }
  $script:wordPop.ClientSize = New-Object System.Drawing.Size((Sz 430), $height)
  Set-CardRegion $script:wordPop

  $cp = New-Object QuickAsk.POINT
  [void][QuickAsk.Native]::GetCursorPos([ref]$cp)
  $origin = New-Object System.Drawing.Point($cp.X, $cp.Y)
  $wa = [System.Windows.Forms.Screen]::FromPoint($origin).WorkingArea
  $x = $cp.X + (Sz 12)
  $y = $cp.Y + (Sz 18)
  if (($x + $script:wordPop.Width) -gt $wa.Right) { $x = $wa.Right - $script:wordPop.Width - (Sz 8) }
  if (($y + $script:wordPop.Height) -gt $wa.Bottom) { $y = $wa.Bottom - $script:wordPop.Height - (Sz 8) }
  if ($x -lt ($wa.Left + (Sz 8))) { $x = $wa.Left + (Sz 8) }
  if ($y -lt ($wa.Top + (Sz 8))) { $y = $wa.Top + (Sz 8) }
  $script:wordPop.Location = New-Object System.Drawing.Point($x, $y)
  $script:wordPop.Show()
}
function Invoke-WordLookup {
  param([string]$Word)
  $url = Get-WordUrl
  if ([string]::IsNullOrWhiteSpace($url)) { return }
  $sentence = $script:srcText
  if ($sentence.Length -gt 600) { $sentence = $sentence.Substring(0, 600) }
  $translation = $script:dstText
  if ($translation.Length -gt 600) { $translation = $translation.Substring(0, 600) }
  $full = $url + "?w=" + [uri]::EscapeDataString($Word) +
    "&s=" + [uri]::EscapeDataString($sentence) +
    "&t=" + [uri]::EscapeDataString($translation)
  $data = Invoke-ToolboxJson $full
  if ($null -eq $data -or $data.ok -ne $true) {
    Write-Trace ("word lookup failed: " + $Word)
    return
  }
  Show-WordPopup -Word ([string]$data.word) -Entry ([string]$data.entry) -Match ([string]$data.match) -Ipa ([string]$data.ipa)
  Write-Trace ("word popup: " + $Word + " match=" + [string]$data.match)
  # Selecting the matched fragment inside the translation pane would never be
  # visible: the card refuses focus (WS_EX_NOACTIVATE), and a read-only TextBox
  # only paints its selection while focused. The fragment is shown in the popup
  # instead, and "copy" already prefers the selection when one exists.
}
function New-ReviewForm {
  $f = New-Object QuickAsk.CardForm
  $f.Text = "dsh-external-toolbox-review"
  $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $f.TopMost = $true
  $f.ShowInTaskbar = $false
  $f.BackColor = $CARD_BG
  $f.Font = Fs 12
  $f.ClientSize = New-Object System.Drawing.Size((Sz 420), (Sz 358))

  $head = New-Object System.Windows.Forms.Panel
  $head.Dock = [System.Windows.Forms.DockStyle]::Top
  $head.Height = (Sz 34)
  $head.BackColor = $BAR_BG
  $f.Controls.Add($head)

  $heading = New-Object System.Windows.Forms.Label
  $heading.Text = (U 0x751F, 0x8BCD, 0x672C) + " " + (U 0x00B7) + " " + (U 0x590D, 0x4E60)
  $heading.Font = FsB 12
  $heading.ForeColor = $ACCENT
  $heading.AutoSize = $true
  $heading.Location = New-Object System.Drawing.Point((Sz 14), (Sz 8))
  $head.Controls.Add($heading)

  $close = New-CardButton (U 0x2715) 22
  $close.AutoSize = $false
  $close.Size = New-Object System.Drawing.Size((Sz 22), (Sz 18))
  $close.Location = New-Object System.Drawing.Point((Sz 384), (Sz 8))
  $close.FlatAppearance.BorderSize = 1
  $close.FlatAppearance.BorderColor = $LINE
  $close.BackColor = $BTN_BG
  $close.Font = Fs 12
  $close.Add_Click({ $script:reviewForm.Hide() })
  $head.Controls.Add($close)

  # The book itself stays one click away, but in the header so the body keeps a
  # single action ("show answer") that the grades then replace.
  $openBtn = New-CardButton (U 0x6587, 0x4EF6) 56
  $openBtn.AutoSize = $false
  $openBtn.Size = New-Object System.Drawing.Size((Sz 56), (Sz 18))
  $openBtn.Location = New-Object System.Drawing.Point((Sz 320), (Sz 8))
  $openBtn.FlatAppearance.BorderSize = 1
  $openBtn.FlatAppearance.BorderColor = $LINE
  $openBtn.BackColor = $BTN_BG
  $openBtn.ForeColor = $INK_DIM
  $openBtn.Font = Fs 12
  $openBtn.Add_Click({ Open-VocabBook })
  $head.Controls.Add($openBtn)

  $wordLabel = New-Object System.Windows.Forms.Label
  $wordLabel.Text = ""
  $wordLabel.Font = FsB 26
  $wordLabel.ForeColor = $INK
  $wordLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $wordLabel.Location = New-Object System.Drawing.Point((Sz 16), (Sz 38))
  $wordLabel.Size = New-Object System.Drawing.Size((Sz 320), (Sz 44))
  $f.Controls.Add($wordLabel)

  # dictionary IPA sits right under the headword
  $ipaLabel = New-Object System.Windows.Forms.Label
  $ipaLabel.Text = ""
  $ipaLabel.Font = Fs 12
  $ipaLabel.ForeColor = $INK_DIM
  $ipaLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $ipaLabel.Location = New-Object System.Drawing.Point((Sz 16), (Sz 80))
  $ipaLabel.Size = New-Object System.Drawing.Size((Sz 388), (Sz 18))
  $ipaLabel.Visible = $false
  $f.Controls.Add($ipaLabel)

  $ctxLabel = New-Object System.Windows.Forms.Label
  $ctxLabel.Text = ""
  $ctxLabel.Font = Fs 11
  $ctxLabel.ForeColor = $INK_DIM
  $ctxLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
  $ctxLabel.Location = New-Object System.Drawing.Point((Sz 16), (Sz 100))
  $ctxLabel.Size = New-Object System.Drawing.Size((Sz 388), (Sz 30))
  $f.Controls.Add($ctxLabel)

  $sayWord = New-CardButton (U 0x25B6) 30
  $sayWord.AutoSize = $false
  $sayWord.Size = New-Object System.Drawing.Size((Sz 30), (Sz 26))
  $sayWord.Location = New-Object System.Drawing.Point((Sz 348), (Sz 50))
  $sayWord.FlatAppearance.BorderSize = 1
  $sayWord.FlatAppearance.BorderColor = $LINE
  $sayWord.BackColor = $BTN_BG
  $sayWord.ForeColor = $INK_DIM
  $sayWord.Font = Fs 12
  $sayWord.Add_Click({
    # Everything here runs inside a WinForms event: an exception would take the
    # whole helper down with a .NET dialog, so it never escapes.
    try {
      $text = [string]$script:reviewWord
      # Only speak the example once the answer is on screen; reading it out
      # while the card still hides it gives the meaning away.
      $revealed = ($null -ne $script:reviewMeaningLabel -and $script:reviewMeaningLabel.Visible)
      if ($revealed -and $script:reviewDetail -match "(?m)^\u4F8B\u53E5\s*[\u003A\uFF1A]\s*(.+)$") {
        $text = [string]$script:reviewWord + ". " + $Matches[1]
      }
      $script:lastSpoken = $text
      Speak-Text $text "en"
    } catch {
      Write-Trace ("say failed: " + $_.Exception.Message)
    }
  })
  $f.Controls.Add($sayWord)

  $meanLabel = New-Object System.Windows.Forms.Label
  $meanLabel.Text = ""
  $meanLabel.Font = Fs 13
  $meanLabel.ForeColor = $OK_INK
  $meanLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
  $meanLabel.Location = New-Object System.Drawing.Point((Sz 16), (Sz 134))
  $meanLabel.Size = New-Object System.Drawing.Size((Sz 388), (Sz 112))
  $meanLabel.Visible = $false
  $f.Controls.Add($meanLabel)

  $showBtn = New-CardButton (U 0x770B, 0x7B54, 0x6848) 96
  $showBtn.Location = New-Object System.Drawing.Point((Sz 16), (Sz 244))
  $showBtn.Size = New-Object System.Drawing.Size((Sz 96), (Sz 26))
  $showBtn.Font = Fs 12
  $showBtn.Add_Click({
    # The enriched entry reads better than the one-line translation; fall back
    # to the translation while the lookup is still running (or unavailable).
    $script:reviewMeaningLabel.Text = if ($script:reviewDetail -ne "") { $script:reviewDetail } else { $script:reviewMeaning }
    $script:reviewMeaningLabel.Visible = $true
    $script:reviewTranslate.Visible = $false
    $script:reviewGrades.Visible = $true
  })
  $f.Controls.Add($showBtn)



  $gradePanel = New-Object System.Windows.Forms.Panel
  $gradePanel.Location = New-Object System.Drawing.Point((Sz 16), (Sz 246))
  $gradePanel.Size = New-Object System.Drawing.Size((Sz 388), (Sz 30))
  $gradePanel.Visible = $false
  $f.Controls.Add($gradePanel)

  $gx = 0
  foreach ($spec in @(
    @{ Text = (U 0x5FD8, 0x4E86); Grade = "again"; Color = $ERR_INK },
    @{ Text = (U 0x6A21, 0x7CCA); Grade = "hard"; Color = $INK },
    @{ Text = (U 0x8BB0, 0x5F97); Grade = "good"; Color = $OK_INK }
  )) {
    $b = New-CardButton $spec.Text 110
    $b.Location = New-Object System.Drawing.Point((Sz $gx), 0)
    $b.Size = New-Object System.Drawing.Size((Sz 110), (Sz 28))
    $b.Font = Fs 12
    $b.ForeColor = $spec.Color
    $grade = $spec.Grade
    $b.Add_Click({
      Send-ReviewGrade $grade
    }.GetNewClosure())
    $gradePanel.Controls.Add($b)
    $gx += 126
  }

  $status = New-Object System.Windows.Forms.Label
  $status.Text = ""
  $status.ForeColor = $INK_DIM
  $status.Font = Fs 11
  $status.Location = New-Object System.Drawing.Point((Sz 16), (Sz 300))
  $status.Size = New-Object System.Drawing.Size((Sz 388), (Sz 22))
  $f.Controls.Add($status)

  $f.MakeDraggable($head)
  $f.MakeDraggable($heading)

  $script:reviewWordLabel = $wordLabel
  $script:reviewIpaLabel = $ipaLabel
  $script:reviewCtxLabel = $ctxLabel
  $script:reviewSay = $sayWord
  $script:reviewMeaningLabel = $meanLabel
  $script:reviewTranslate = $showBtn
  $script:reviewGrades = $gradePanel
  $script:reviewStatus = $status
  return $f
}
function Show-Review {
  if ($null -eq $script:reviewForm) {
    $script:reviewForm = New-ReviewForm
    # Centre it on the screen that holds the mouse, like the capture card.
    $cp = New-Object QuickAsk.POINT
    [void][QuickAsk.Native]::GetCursorPos([ref]$cp)
    $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cp.X, $cp.Y))).WorkingArea
    $x = [int](($wa.Width - $script:reviewForm.Width) / 2 + $wa.Left)
    $y = [int](($wa.Height - $script:reviewForm.Height) / 2 + $wa.Top)
    $script:reviewForm.Location = New-Object System.Drawing.Point($x, $y)
  }
  $script:reviewTranslate.Visible = $false
  $script:reviewGrades.Visible = $false
  $script:reviewMeaningLabel.Visible = $false
  $script:reviewMeaningLabel.Text = ""
  $script:reviewWordLabel.Text = "..."
  $script:reviewStatus.Text = ""
  $script:reviewForm.Show()
  $script:reviewForm.Refresh()
  Update-ReviewCard
}

function Update-ReviewCard {
  $data = Invoke-ToolboxJson (Get-ReviewUrl "")
  if ($null -eq $data -or $data.ok -ne $true) {
    $script:reviewWordLabel.Text = (U 0x8BFB, 0x53D6, 0x5931, 0x8D25)
    return
  }
  $script:reviewDue = [int]$data.due
  $script:reviewTotal = [int]$data.total
  $item = $data.item
  if ($null -eq $item) {
    $script:reviewWordLabel.Text = (U 0x6CA1, 0x6709, 0x8981, 0x590D, 0x4E60, 0x7684, 0x5355, 0x8BCD)
    $script:reviewStatus.Text = (U 0x5171) + " " + [string]$script:reviewTotal + " " + (U 0x4E2A)
    $script:reviewTranslate.Visible = $false
    $script:reviewGrades.Visible = $false
    $script:reviewMeaningLabel.Visible = $false
    $script:reviewMeaningLabel.Text = ""
    $script:reviewCtxLabel.Text = ""
  $script:reviewIpaLabel.Text = ""
  $script:reviewIpaLabel.Visible = $false
    return
  }
  $script:reviewWord = [string]$item.word
  $script:reviewMeaning = [string]$item.translation
  $script:reviewDetail = [string]$item.detail
  $script:reviewContext = [string]$item.context
  # A new card starts from the question side again: the previous answer must
  # not linger and spoil the recall.
  $script:reviewMeaningLabel.Text = ""
  $script:reviewMeaningLabel.Visible = $false
  $script:reviewWordLabel.Text = $script:reviewWord
  $ipaText = [string]$item.ipa
  $script:reviewIpaLabel.Text = $ipaText
  $script:reviewIpaLabel.Visible = ($ipaText -ne "")
  $script:reviewCtxLabel.Text = $script:reviewContext
  $dot = [string][char]0x00B7
  $script:reviewStatus.Text = (U 0x4ECA, 0x5929, 0x8FD8, 0x6709) + " " + [string]$script:reviewDue + " " + (U 0x4E2A) + "  " + $dot + "  " + (U 0x5171) + " " + [string]$script:reviewTotal + " " + (U 0x4E2A)
  $script:reviewTranslate.Visible = $true
  $script:reviewGrades.Visible = $false
}

function Send-ReviewGrade([string]$Grade) {
  if ($script:reviewWord -eq "") { return }
  $q = "?word=" + [uri]::EscapeDataString($script:reviewWord) + "&grade=" + [uri]::EscapeDataString($Grade)
  [void](Invoke-ToolboxJson (Get-ReviewUrl $q))
  Update-ReviewCard
}
function Open-VocabBook {
  $dir = Join-Path $env:APPDATA "dsh-external-toolbox"
  $book = Join-Path $dir ((U 0x751F, 0x8BCD, 0x672C) + ".md")
  if (Test-Path -LiteralPath $book) {
    # .md has no handler on plenty of machines, so go straight to notepad:
    # predictable, and it is always installed.
    try {
      Start-Process -FilePath "notepad.exe" -ArgumentList ('"' + $book + '"') | Out-Null
      return
    } catch {
      Write-Trace ("open vocab failed: " + $_.Exception.Message)
    }
    try {
      Start-Process -FilePath "explorer.exe" -ArgumentList ('/select,"' + $book + '"') | Out-Null
      return
    } catch {
      Write-Trace ("reveal vocab failed: " + $_.Exception.Message)
    }
  }
  if ($null -ne $script:status) {
    Set-CardStatus (U 0x8FD8, 0x6CA1, 0x6709, 0x6536, 0x85CF, 0x8FC7, 0x5355, 0x8BCD) $INK_DIM
  }
}
function Start-Task {
  param([string]$Task = "translate")
  if ($script:busy) { return }
  if ([string]::IsNullOrEmpty($script:lastId)) { return }
  $url = Get-TaskUrl $Task
  if ($url -eq "") {
    Show-CardTranslation $T_NO_SERVICE $ERR_INK
    return
  }

  $script:activeTask = $Task
  if ($Task -eq "explain") {
    $script:activeBtn = $script:btnExplain
    $script:activeLabel = $T_EXPLAIN
    $busyText = $T_EXPLAINING
  } else {
    $script:activeBtn = $script:btnTranslate
    $script:activeLabel = $T_TRANSLATE
    $busyText = $T_TRANSLATING
  }

  $script:busy = $true
  $script:btnTranslate.Enabled = $false
  $script:btnExplain.Enabled = $false
  $script:activeBtn.Text = $busyText
  Show-CardTranslation $busyText $INK_DIM
  Set-CardStatus "" $INK_DIM

  $script:runner = [powershell]::Create()
  [void]$script:runner.AddScript({
    param($address)
    try {
      $request = [System.Net.HttpWebRequest]::Create($address)
      $request.Method = "GET"
      $request.Timeout = 90000
      $request.ReadWriteTimeout = 90000
      $response = $request.GetResponse()
      try {
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $reader.Dispose()
        return $body
      } finally { $response.Close() }
    } catch {
      return "@@ERROR@@" + $_.Exception.Message
    }
  }).AddArgument($url)
  $script:async = $script:runner.BeginInvoke()
  $script:poll.Start()
}

function Poll-Translate {
  if ($null -eq $script:async -or -not $script:async.IsCompleted) { return }
  $script:poll.Stop()
  $body = ""
  try {
    $out = $script:runner.EndInvoke($script:async)
    $body = (@($out) | ForEach-Object { "$_" }) -join ""
  } catch {
    $body = "@@ERROR@@" + $_.Exception.Message
  }
  try { $script:runner.Dispose() } catch { }
  $script:runner = $null
  $script:async = $null
  $script:busy = $false
  $script:btnTranslate.Enabled = $true
  $script:btnExplain.Enabled = $true
  if ($null -ne $script:activeBtn) {
    $script:activeBtn.Text = $script:activeLabel
  } else {
    $script:btnTranslate.Text = $T_TRANSLATE
  }

  if ($body.StartsWith("@@ERROR@@")) {
    Show-CardTranslation ($T_FAILED + ": " + $body.Substring(9)) $ERR_INK
    return
  }

  $parsed = $null
  try { $parsed = $body | ConvertFrom-Json } catch { $parsed = $null }
  if ($null -eq $parsed) {
    Show-CardTranslation ($T_FAILED + ": bad response") $ERR_INK
    return
  }
  if ($parsed.ok -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$parsed.text)) {
    Show-CardTranslation ([string]$parsed.text) $OK_INK
    # Reading the result aloud belongs to translation, not to a separate action.
    if ($script:activeTask -eq "translate") {
      if ($null -ne $parsed.target -and [string]$parsed.target -ne "") { $script:dstLang = [string]$parsed.target }
    }
    # In auto mode the host decides the direction, so show what it picked.
    if ($parsed.auto -eq $true -and $null -ne $parsed.target -and "$($parsed.target)" -ne "") {
      Set-CardStatus ("-> " + ([string]$parsed.target).ToUpper()) $INK_DIM
    } else {
      Set-CardStatus "" $INK_DIM
    }
  } else {
    $detail = "unknown"
    if ($null -ne $parsed.error) { $detail = [string]$parsed.error }
    Show-CardTranslation ($T_FAILED + ": " + $detail) $ERR_INK
  }
}

# ---------------------------------------------------------------- hotkey parsing

function ConvertTo-Hotkey([string]$Spec) {
  $mods = 0
  $key = $null
  foreach ($part in ($Spec -split "\+")) {
    $p = $part.Trim()
    switch -Regex ($p) {
      '^(ctrl|control)$' { $mods = $mods -bor 0x2; continue }
      '^(alt)$'          { $mods = $mods -bor 0x1; continue }
      '^(shift)$'        { $mods = $mods -bor 0x4; continue }
      '^(win|meta)$'     { $mods = $mods -bor 0x8; continue }
      default            { $key = $p.ToUpper() }
    }
  }
  if ($null -eq $key) { throw "hotkey has no key: $Spec" }
  $code = [int][char]$key
  if ($key.Length -gt 1) {
    $map = @{ "F1"=112; "F2"=113; "F3"=114; "F4"=115; "F5"=116; "F6"=117; "F7"=118; "F8"=119;
              "F9"=120; "F10"=121; "F11"=122; "F12"=123; "SPACE"=32; "INSERT"=45; "DELETE"=46;
              "HOME"=36; "END"=35; "PGUP"=33; "PGDN"=34 }
    if (-not $map.ContainsKey($key)) { throw "unsupported hotkey key: $key" }
    $code = $map[$key]
  }
  return @{ mods = $mods; key = $code }
}

# ---------------------------------------------------------------- self test


if ($FilterTest) {
  $samples = @("R12", "U1", "1", "pcb", "a b", "C3 10uF", "Hello world", "Rain_Total_mm", "--", "12", "VCC", "See note 4", "Net- (U2.5A)")
  foreach ($sample in $samples) {
    Write-Json @{ type = "filter"; text = $sample; show = (Test-WorthShowing $sample); prose = (Test-ProseLike $sample); quiet = (Test-QuietApp); app = (Get-ForegroundProcessName) }
  }
  exit 0
}


if ($SurfaceTest) {
  # Which clipboard-fallback guard fires for whatever is in front right now.
  $fgCls = Get-ForegroundClassName
  $visible = ($null -ne $script:reviewForm -and $script:reviewForm.Visible)
  Write-Json @{
    type = "surface"
    proc = (Get-ForegroundProcessName)
    class = $fgCls
    console = (Test-ConsoleForeground)
    keyboard = (Test-KeyboardSurface)
    cooldown = ((Get-Date) -lt $script:clipBlockedUntil)
    selfFocus = $visible
  }
  exit 0
}

if ($SelfTest) {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = "external-toolbox-selftest"
  $form.Size = New-Object System.Drawing.Size(320, 160)
  $form.StartPosition = "Manual"
  $form.Location = New-Object System.Drawing.Point(-4000, -4000)
  $form.TopMost = $true
  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.Dock = "Fill"
  $box.Text = "The quick brown fox jumps over the lazy dog. Hello, world."
  $form.Controls.Add($box)
  $script:timer = New-Object System.Windows.Forms.Timer
  $script:timer.Interval = 500
  $script:timer.Add_Tick({
    $script:timer.Stop()
    try {
      $result = Invoke-Capture
      if ($null -eq $result) { Write-Json @{ type = "error"; message = "selftest captured nothing" } }
      else { Write-Json $result }
    } catch {
      Write-Json @{ type = "error"; message = $_.Exception.Message }
    }
    $form.Close()
  })
  $form.Add_Shown({
    $form.Activate()
    $box.Focus()
    $box.SelectAll()
    $script:timer.Start()
  })
  [void]$form.ShowDialog()
  exit 0
}

# ---------------------------------------------------------------- auto test

if ($AutoTest) {
  $CaptureSelf = $true
  New-Card

  # The hook needs a message loop, which this branch has; whether a global hook
  # installs at all is the first thing worth knowing on a locked down machine.
  $script:mouseWatcher = New-Object QuickAsk.MouseWatcher
  $hookOk = [bool]$script:mouseWatcher.Start()

  $script:autoCount = 0
  $script:autoSeen = 0
  $probeText = "Selected text in another application: the quick brown fox jumps over the lazy dog."
  $script:probeTimer = New-Object System.Windows.Forms.Timer
  $script:probeTimer.Interval = 800
  $script:probeTimer.Add_Tick({
    $script:probeTimer.Stop()
    Show-AutoCapture $probeText
    # A selection pops the pill, not the card, so that is what gets checked here.
    $firstVisible = ($null -ne $script:bar) -and $script:bar.Visible
    $firstChars = if ($null -ne $script:barCapture) { ([string]$script:barCapture.text).Length } else { 0 }
    # Same text again must not re-open or re-print the card.
    $beforeSeq = $script:lastId
    Show-AutoCapture $probeText
    $againVisible = ($null -ne $script:bar) -and $script:bar.Visible
    Write-Json @{
      type = "autotest"
      hook = $hookOk
      barVisible = $firstVisible
      cardVisible = (($null -ne $script:card) -and $script:card.Visible)
      srcChars = $firstChars
      sameAsSelection = ($script:autoShown -eq $probeText)
      dedupe = ($beforeSeq -eq $script:lastId) -and $againVisible
    }
    Hide-Bar
    Hide-Card
    $script:mouseWatcher.Stop()
    [System.Windows.Forms.Application]::Exit()
  })
  $script:probeTimer.Start()
  [System.Windows.Forms.Application]::Run()
  exit 0
}
# ---------------------------------------------------------------- card test

if ($DragTest) {
  New-Card
  $script:srcText = "drag test source"
  $script:txtSrc.Text = $script:srcText
  $script:card.Location = New-Object System.Drawing.Point(120, 120)
  $script:card.Show()
  for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  $before = $script:card.Location.ToString()
  Write-Json @{ type = "dragtest"; stage = "shown"; bounds = $script:card.Bounds.ToString() }
  $lp = [IntPtr]((10 -shl 16) -bor 60)
  [void][QuickAsk.Native]::PostMessage($script:head.Handle, 0x0201, [IntPtr]1, $lp)
  for ($i = 0; $i -lt 12; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  [void][QuickAsk.Native]::PostMessage($script:card.Handle, 0x0202, [IntPtr]0, $lp)
  for ($i = 0; $i -lt 12; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  Write-Json @{ type = "dragtest"; stage = "done"; before = $before; after = $script:card.Location.ToString(); alive = $script:card.Visible }
  $script:card.Close()
  exit 0
}

if ($HideTest) {
  # Same story as -MinimizeTest, but the window is hidden (tray-like) instead
  # of iconic: that is the case the title lookup used to miss entirely.
  $hwnd = Get-HostWindow
  Write-Json @{ type = "hide"; hwnd = [string]$hwnd }
  if ($hwnd -ne [IntPtr]::Zero) { [void][QuickAsk.Native]::ShowWindow($hwnd, 0) }
  Start-Sleep -Milliseconds 600
  Write-Json @{ type = "hide"; vis = [string]([QuickAsk.Native]::IsWindowVisible($hwnd)); title_hit = [string]([QuickAsk.Native]::FindWindowByTitle("DeepSeek Harness")); proc_hit = [string]([QuickAsk.Native]::FindWindowByProcessName("DeepSeek Harness")) }
  $found = Get-HostWindow
  Write-Json @{ type = "hide"; found = [string]$found }
  Show-HostWindow
  Start-Sleep -Milliseconds 600
  Write-Json @{ type = "hide"; ok = ([QuickAsk.Native]::GetForegroundWindow() -eq $hwnd); vis = [string]([QuickAsk.Native]::IsWindowVisible($hwnd)); after = [string]([QuickAsk.Native]::GetForegroundWindow()) }
  exit 0
}

if ($MinimizeTest) {
  # Simulates the "DSH is in the background" case that has been failing.
  $hwnd = Get-HostWindow
  Write-Json @{ type = "minimize"; hwnd = [string]$hwnd; iconic_before = [string]([QuickAsk.Native]::IsIconic($hwnd)) }
  if ($hwnd -ne [IntPtr]::Zero) { [void][QuickAsk.Native]::ShowWindow($hwnd, 6) }
  Start-Sleep -Milliseconds 600
  Write-Json @{ type = "minimize"; iconic_after = [string]([QuickAsk.Native]::IsIconic($hwnd)); fg = [string]([QuickAsk.Native]::GetForegroundWindow()) }
  Show-HostWindow
  Start-Sleep -Milliseconds 600
  Write-Json @{ type = "minimize"; ok = ([QuickAsk.Native]::GetForegroundWindow() -eq $hwnd); after = [string]([QuickAsk.Native]::GetForegroundWindow()); iconic = [string]([QuickAsk.Native]::IsIconic($hwnd)) }
  exit 0
}

if ($ActivateTest -or $ProbeWindows) {
  foreach ($line in [QuickAsk.Native]::DescribeWindows("DeepSeek")) { Write-Json @{ type = "window"; line = $line } }
  foreach ($line in [QuickAsk.Native]::DescribeWindows("DeepseekHaeness")) { Write-Json @{ type = "window"; line = $line } }
  if ($ProbeWindows) { exit 0 }
  $hwnd = Get-HostWindow
  Write-Json @{ type = "activate"; hwnd = [string]$hwnd; before = [string]([QuickAsk.Native]::GetForegroundWindow()) }
  Show-HostWindow
  # Activation runs in a background runspace (the dsh://open handoff alone takes
  # the better part of a second), so keep this process alive long enough to see
  # the outcome instead of reporting a race.
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 400
    if (([QuickAsk.Native]::IsWindowVisible($hwnd)) -and ([QuickAsk.Native]::GetForegroundWindow() -eq $hwnd)) { break }
  }
  Write-Json @{ type = "activate"; hwnd = [string]$hwnd; after = [string]([QuickAsk.Native]::GetForegroundWindow()); ok = ([QuickAsk.Native]::GetForegroundWindow() -eq $hwnd); visible = [QuickAsk.Native]::IsWindowVisible($hwnd) }
  # The background runspace still has to paint and photograph; give it room.
  Start-Sleep -Milliseconds 1600
  exit 0
}

if ($BarTest) {
  $captured = @{ type = "selection"; id = "bartest"; text = "The quick brown fox jumps over the lazy dog."; via = "auto"; chars = 44 }
  Show-Bar $captured
  $script:bar.Location = New-Object System.Drawing.Point(200, 200)
  for ($i = 0; $i -lt 15; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  if ($ShotPath -ne "") {
    $script:bar.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 120
    $rect = $script:bar.Bounds
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $rect.Width, $rect.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
    $g.Dispose()
    $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Json @{ type = "shot"; path = $ShotPath; size = $rect.Size.ToString() }
  }
  $script:bar.Close()
  exit 0
}

if ($ReviewTest) {
  Show-Review
  $script:reviewForm.Location = New-Object System.Drawing.Point(200, 200)
  if ($ReviewAnswer) {
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    $script:reviewTranslate.PerformClick()
  }
  if ($ReviewSpeak) {
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    $script:reviewSay.PerformClick()
    Write-Json @{ type = "spoke"; word = $script:reviewWord; revealed = [bool]$script:reviewMeaningLabel.Visible; chars = ([string]$script:lastSpoken).Length; hasExample = ($script:reviewDetail -match "\u4F8B\u53E5") }
  }
  if ($ReviewGrade -ne "") {
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    Send-ReviewGrade $ReviewGrade
  }
  for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  if ($ShotPath -ne "") {
    $script:reviewForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150
    $rect = $script:reviewForm.Bounds
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $rect.Width, $rect.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
    $g.Dispose()
    $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Json @{ type = "shot"; path = $ShotPath; word = $script:reviewWord; due = $script:reviewDue; total = $script:reviewTotal }
  }
  $script:reviewForm.Close()
  exit 0
}
if ($WordTest) {
  # Renders the word panel against whatever -TranslateUrl points at (the mock
  # answers /toolbox/word), so the layout can be checked without a live model.
  $script:srcText = "Address locations 09h through 0Ch contain alarm registers, which define the conditions for an alarm."
  $script:dstText = ""
  $w = if ($Word -ne "") { $Word } else { "conditions" }
  Invoke-WordLookup $w
  for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  if ($ShotPath -ne "" -and $null -ne $script:wordPop) {
    $script:wordPop.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150
    $rect = $script:wordPop.Bounds
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $rect.Width, $rect.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
    $g.Dispose()
    $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Json @{ type = "shot"; path = $ShotPath; word = $w; body = $script:wordPopBody.Text; ipa = $script:wordPopIpa.Text; ipaVisible = $script:wordPopIpa.Visible; ipaBounds = [string]$script:wordPopIpa.Bounds }
  }
  if ($null -ne $script:wordPop) { $script:wordPop.Close() }
  exit 0
}
if ($CardTest) {
  New-Card
  $script:lastId = "cardtest"
  $script:srcText = "The card shows the captured selection here. It keeps the original layout, including line breaks and empty lines, so quoting still reads like the source."
  $script:txtSrc.Text = $script:srcText
  Hide-CardTranslation
  if (-not [string]::IsNullOrWhiteSpace($TranslateUrl)) { Start-Task $Task }
  $script:card.Location = New-Object System.Drawing.Point(120, 120)
  $script:card.Show()
  $script:card.BringToFront()
  $script:card.Activate()
  for ($i = 0; $i -lt 20; $i++) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 40
  }
  if (-not [string]::IsNullOrWhiteSpace($TranslateUrl)) {
    for ($i = 0; $i -lt 300 -and $script:busy; $i++) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 50
    }
    $script:card.BringToFront()
    [System.Windows.Forms.Application]::DoEvents()
  }
  if ($LangTest) {
    Show-LangMenu
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  }
  if ($ShotPath -ne "") {
    $script:card.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 120
    $rect = $script:card.Bounds
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $rect.Width, $rect.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    # PrintWindow renders the window itself, so the shot is right even when
    # another always-on-top app happens to overlap ours on screen.
    $hdc = $g.GetHdc()
    try { [void][QuickAsk.Native]::PrintWindow($script:card.Handle, $hdc, 2) } finally { $g.ReleaseHdc($hdc) }
    $g.Dispose()
    $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    if ($LangTest -and $null -ne $script:langMenu -and $script:langMenu.Visible) {
      $mr = $script:langMenu.Bounds
      $mb = New-Object System.Drawing.Bitmap -ArgumentList $mr.Width, $mr.Height
      $mg = [System.Drawing.Graphics]::FromImage($mb)
      $mhdc = $mg.GetHdc()
      try { [void][QuickAsk.Native]::PrintWindow($script:langMenu.Handle, $mhdc, 2) } finally { $mg.ReleaseHdc($mhdc) }
      $mg.Dispose()
      $mb.Save(($ShotPath + ".menu.png"), [System.Drawing.Imaging.ImageFormat]::Png)
      $mb.Dispose()
    }
Write-Json @{ type = "shot"; path = $ShotPath; copy = $script:btnCopy.Text; dst = $script:dstText; target = $script:lang; chip = $script:btnLang.Text }
      $geo = (Get-ScrollGeometry $script:txtDst $script:sbDst)
      Write-Json @{ type = "lane"; over = $geo.over; total = $geo.total; visible = $geo.visible; height = $geo.height; top = $geo.top }
      [void][QuickAsk.Native]::SendMessage($script:txtDst.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr]5)
      Update-AllScrollbars
      [System.Windows.Forms.Application]::DoEvents()
      $geo2 = (Get-ScrollGeometry $script:txtDst $script:sbDst)
      Write-Json @{ type = "lane2"; first = $geo2.first; top = $geo2.top }
      $bmp2 = New-Object System.Drawing.Bitmap -ArgumentList $script:card.Width, $script:card.Height
      $script:card.Refresh()
      $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
      $g2.CopyFromScreen($script:card.Location, [System.Drawing.Point]::Empty, $script:card.Size)
      $g2.Dispose()
      $bmp2.Save(($ShotPath + ".scrolled.png"), [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp2.Dispose()
  }
  $script:card.Close()
  exit 0
}

# ---------------------------------------------------------------- one shot

if ($Once) {
  try {
    $result = Invoke-Capture
    if ($null -eq $result) { Write-Json @{ type = "error"; message = "no selection" }; exit 2 }
    Write-Json $result
    exit 0
  } catch {
    Write-Json @{ type = "error"; message = $_.Exception.Message }
    exit 1
  }
}

# ---------------------------------------------------------------- hotkey loop

$hotkeyInfo = ConvertTo-Hotkey $Hotkey
$window = New-Object QuickAsk.HotkeyWindow -ArgumentList 1
$script:active = $window.Register([uint32]$hotkeyInfo.mods, [uint32]$hotkeyInfo.key)
if (-not $script:active) {
  # Auto watch still works without a hotkey, so a taken shortcut is not fatal.
  Write-Json @{ type = "error"; message = "RegisterHotKey failed (hotkey already taken?)" }
  if ($NoAuto) { exit 1 }
}
New-Card
Write-Trace ("ready hwnd=" + [string]$window.Handle.ToInt64() + " auto=" + [string](-not $NoAuto))
Write-Json @{ type = "ready"; hotkey = $Hotkey; auto = (-not $NoAuto); pid = $PID; hwnd = [string]$window.Handle.ToInt64() }

if (-not $NoAuto) {
  # Selection made with the mouse: the hook fires right after the button comes
  # up, so the card can open while the text is still selected. A short delay
  # lets the application finish its own selection handling (and hides the card
  # from a plain click that produced no selection).
  # A selection is not readable the instant the button comes up: the app may
  # still be finishing its own handling. Retry a few times before giving up.
  $script:gestureAttempt = 0
  $script:gestureTimer = New-Object System.Windows.Forms.Timer
  $script:gestureTimer.Interval = 160
  $script:gestureTimer.Add_Tick({
    $script:gestureTimer.Stop()
    $script:gestureAttempt += 1
    if (Invoke-AutoCapture) { $script:gestureAttempt = 0; return }
    if ($script:gestureAttempt -ge 4) { $script:gestureAttempt = 0; return }
    $script:gestureTimer.Interval = 260
    $script:gestureTimer.Start()
  })
  $script:keyWatcher = New-Object QuickAsk.KeyboardWatcher
  $keyHookOk = [bool]$script:keyWatcher.Start()
  Write-Trace ("keyboard hook=" + [string]$keyHookOk)

  $script:mouseWatcher = New-Object QuickAsk.MouseWatcher
  $hookOk = $script:mouseWatcher.Start()
  Write-Trace ("mouse hook=" + [string]$hookOk)
  if (-not $hookOk) {
    Write-Json @{ type = "error"; message = "mouse hook failed" }
  }

  # The hook callbacks only post a message (a slow hook freezes mouse input for
  # every application), so the script side is driven from here.
  $script:mouseWatcher.Notify = $window.Handle
  $script:keyWatcher.Notify = $window.Handle
  $window.Mouse = $script:mouseWatcher
  $window.Keyboard = $script:keyWatcher
  $script:keyWatcher.Guarded = @([IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)

  $window.Add_HookPing({
    param($code)
    switch ([int]$code) {
      1 {
        $cp = New-Object QuickAsk.POINT
        [void][QuickAsk.Native]::GetCursorPos([ref]$cp)
        $pt = New-Object System.Drawing.Point($cp.X, $cp.Y)
        $onCard = ($null -ne $script:card -and $script:card.Visible -and $script:card.Bounds.Contains($pt))
        $onBar = ($null -ne $script:bar -and $script:bar.Visible -and $script:bar.Bounds.Contains($pt))
        $onMenu = ($null -ne $script:langMenu -and $script:langMenu.Visible -and $script:langMenu.Bounds.Contains($pt))
        $onPop = ($null -ne $script:wordPop -and $script:wordPop.Visible -and $script:wordPop.Bounds.Contains($pt))
        if (-not $onPop) { Hide-WordPopup }
        if ($onMenu -or $onCard -or $onBar -or $onPop) {
          # Pressing inside our own UI must not look like a selection gesture
          # (dragging the card used to pop the pill again).
          $script:ownGestureUntil = (Get-Date).AddSeconds(2)
          return
        }
        Hide-LangMenu
        if ($null -eq $script:bar -or -not $script:bar.Visible) { return }
        if ($null -ne $script:barCapture) { $script:dismissed = [string]$script:barCapture.text }
        Hide-Bar
      }
      2 { Write-Trace "gesture mouse"; Start-GestureCapture }
      3 { Write-Trace "gesture key"; Start-GestureCapture }
      6 { Write-Trace "wheel scroll"; Update-AllScrollbars }
      4 {
        Write-Trace "escape"
        Hide-LangMenu
        Hide-WordPopup
        Hide-Bar
        Hide-Card
      }
    }
  })


  # Selection made with the keyboard: nothing to hook, so poll the focused
  # element instead (cheap; runs only while the helper lives).
  if ($ParentPid -gt 0) { $script:parentPid = $ParentPid }
  $script:autoTimer = New-Object System.Windows.Forms.Timer
  $script:autoTimer.Interval = [Math]::Max(200, $AutoInterval)
  $script:autoTimer.Add_Tick({ Watch-Selection })
  $script:autoTimer.Start()
  Start-Watchdog
}

# A helper outlives a killed DSH process: it would keep the hotkey registered and
# the next DSH start could not take it. Watch the parent and leave with it.
if ($ParentPid -gt 0) {
  $script:parentPid = $ParentPid
  $script:watch = New-Object System.Windows.Forms.Timer
  $script:watch.Interval = 3000
  $script:watch.Add_Tick({
    if ($null -eq (Get-Process -Id $script:parentPid -ErrorAction SilentlyContinue)) {
      $script:watch.Stop()
      $window.Unregister()
      exit 0
    }
  })
  $script:watch.Start()
}

$window.Add_Pressed({
  param($id)
  if ($env:QUICKASK_DEBUG) { Write-Json @{ type = "hotkey" } }
  try {
    # never read the card's own text back as the selection
    if ($null -ne $script:card -and $script:card.Visible) { $script:card.Hide() }
    $captured = Invoke-Capture
    if ($null -ne $captured) {
      $script:autoShown = [string]$captured.text
      Write-Json $captured
    }
    Hide-Bar
    Show-Card $captured
  } catch {
    Write-Json @{ type = "error"; message = $_.Exception.Message }
  }
})

try {
  [System.Windows.Forms.Application]::Run()
} finally {
  $window.Unregister()
}
