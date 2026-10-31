"""ws_hook.py — make WindowServer draw a transparent menu bar without loading
any code into it.

Why this exists: dlopen'ing our dylib into WindowServer is refused by AMFI
("mapping process is a platform binary, but mapped file is not"), and that gate
has nothing to do with SIP. Debugging, however, is allowed — lldb may stop the
process, inspect arguments, run expressions and call real functions.

How it works: the live menu bar CALayer tree is reached from SkyLight's own
`resize_one_pill(...)` (its CALayer argument sits inside that tree). One lldb
expression climbs to the bar's root, then for every child (and grandchild)
whose name contains T26_PATTERN it sets hidden / opacity 0 / contents nil /
filters nil. The backdrop is a sibling of the text, icon, pill and shadow
layers, so only the Liquid Glass disappears.

Why "deep": WindowServer resets `hidden` on every rebuild (log: "already
hidden: 0" on each pass) but does not restore opacity/contents/filters. That
is what lets `settle` disable its breakpoints and detach — after it, nothing
stops the server and the bar stays transparent.

Modes (T26_MODE):
  settle  neutralise, then `breakpoint disable` + detach  (recommended)
  fix     stay attached, re-fix on every rebuild          (fallback)
  tree    dump the live menu bar layer tree, change nothing
  probe   CALayer naming plumbing (setName: / CA::Layer::setter)
  hunt    render-layer glass setters (filters, backgroundFilters, ...)
  theme   CoreUI theme renderer (objc_msgSend$updateLayer:key:rendererWork:)

Env:
  T26_MODE      settle (default) | fix | tree | probe | hunt | theme
  T26_PATTERN   layer-name substring to act on (default MenuBarBackdrop)
  T26_MAXFIX    stop after this many neutralised layers (0 = never stop)
  T26_DEEP      1 (default) = also drop contents/filters/opacity; 0 = hidden only
  T26_MAXHITS   mute logging after this many hits (never stops the process)
  T26_TREECAP   how many distinct menu bar roots `tree` dumps (default 8)
  T26_LOG       log file (default /tmp/t26hook.log)

Docs: docs/01-how-it-works.md, 02-reverse-engineering.md, 03-dead-ends.md,
04-performance.md.
"""

import os
import time

import lldb

LOG = os.environ.get("T26_LOG", "/tmp/t26hook.log")
MODE = os.environ.get("T26_MODE", "settle")
PATTERN = os.environ.get("T26_PATTERN", "MenuBarBackdrop")
MAXFIX = int(os.environ.get("T26_MAXFIX", "8"))
# Deep neutralisation: also drop contents/filters/opacity, so a
# rebuild that only resets `hidden` cannot bring the glass back.
DEEP = os.environ.get("T26_DEEP", "1") != "0"   # 0 = only set hidden
MAXHITS = int(os.environ.get("T26_MAXHITS", "4000"))
# settle gives up waiting for a confirmed-everywhere fix after this many seconds
SETTLE_MAX = float(os.environ.get("T26_SETTLE_MAX", "60"))
SETTLE_MIN = float(os.environ.get("T26_SETTLE_MIN", "4"))

NAME_ATTR = 0x17c  # attribute id used by -[CALayer setName:]

RENDER_SET_NAME = "CA::Render::Layer::set_name(CA::Render::String*)"
RENDER_CF_STRING = "CA::Render::String::unsafe_cf_string() const"
RENDER_SET_BG_FILTERS = ("CA::Render::Layer::set_background_filters("
                         "CA::Render::TypedArray<CA::Render::Filter>*)")
RENDER_SET_FILTERS = ("CA::Render::Layer::set_filters("
                      "CA::Render::TypedArray<CA::Render::Filter>*)")
RENDER_SET_CONTENTS = "CA::Render::Layer::set_contents(CA::Render::Object*)"
MENU_BAR_LAYERS = ("update_menu_bar_layers(PKGManagedMenuSpace*, unsigned int, "
                   "AppMenuBarInfo_t const*, CGXWindow*)")


def log(msg):
    with open(LOG, "a") as fh:
        fh.write("t26: " + msg + "\n")


class State(object):
    hits = 0
    matched = 0
    fixed = 0
    names = []
    done = False
    syms = {}
    traced = False
    hunt_silent = 0
    theme_logged = 0
    tree_logged = 0
    trees = set()      # root pointers already dumped (one per display)
    last_tree = 0.0
    fast_logged = 0
    passes = 0
    hitlimit = False
    t0 = time.time()
    settled = False
    last_pass = 0.0
    roots = {}             # root layer -> how many times we repaired it
    displays = set()       # display ids WindowServer rebuilt the bar for
    clean_streak = 0       # consecutive passes that needed no repair


S = State()


# --- lldb helpers ---------------------------------------------------------
def _target():
    dbg = lldb.debugger
    return dbg.GetSelectedTarget() if dbg else None


def _sym(name):
    """Load address of a (C++, mangled) function in the target."""
    if name in S.syms:
        return S.syms[name]
    addr = 0
    target = _target()
    if target:
        found = target.FindFunctions(name, lldb.eFunctionNameTypeFull)
        for i in range(found.GetSize()):
            fn = found.GetContextAtIndex(i).GetFunction()
            if fn.IsValid():
                a = fn.GetStartAddress().GetLoadAddress(target)
                if a != lldb.LLDB_INVALID_ADDRESS:
                    addr = a
                    break
    S.syms[name] = addr
    if not addr:
        log("symbol not found: %s" % name)
    return addr


def _call(frame, name, sig, args):
    """Call a function in the target by symbol name."""
    addr = _sym(name)
    if not addr:
        return False
    text = "((%s)%#x)(%s)" % (sig, addr, ", ".join(args))
    v = _eval(frame, text)
    if v.GetError().Fail():
        log("call failed: %s -> %s" % (text, v.GetError().GetCString()))
        return False
    return True


def _eval(frame, text):
    opts = lldb.SBExpressionOptions()
    opts.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    opts.SetTryAllThreads(False)
    opts.SetUnwindOnError(True)
    opts.SetTimeoutInMicroSeconds(3000000)
    return frame.EvaluateExpression(text, opts)


def _cstr(proc, addr, limit=256):
    if not addr:
        return None
    err = lldb.SBError()
    s = proc.ReadCStringFromMemory(addr, limit, err)
    return s if err.Success() else None


def _hexdump(proc, addr, n=64):
    err = lldb.SBError()
    data = proc.ReadMemory(addr, n, err)
    if not err.Success():
        return "<unreadable>"
    out = []
    for i in range(0, n, 8):
        bytes_ = [data.GetUnsignedInt8(err, i + j) for j in range(8)]
        out.append("%+04x %s |%s|" % (
            i, " ".join("%02x" % b for b in bytes_),
            "".join(chr(b) if 32 <= b < 127 else "." for b in bytes_)))
    return "\n".join(out)


def _strings_in(proc, addr, n=128, minlen=4):
    """Printable runs in a blob — fallback when the String layout is unknown."""
    err = lldb.SBError()
    data = proc.ReadMemory(addr, n, err)
    if not err.Success():
        return []
    runs, cur = [], []
    for i in range(n):
        b = data.GetUnsignedInt8(err, i)
        if 32 <= b < 127:
            cur.append(chr(b))
        else:
            if len(cur) >= minlen:
                runs.append("".join(cur))
            cur = []
    if len(cur) >= minlen:
        runs.append("".join(cur))
    return runs


def _render_string(frame, proc, strp):
    """CA::Render::String* -> python str, via QuartzCore's own accessor."""
    if not strp:
        return None
    cf = _eval(frame, "(void *)((__CFString *(*)(void *))%#x)((void *)%#x)"
               % (_sym(RENDER_CF_STRING) or 0, strp))
    if cf.GetError().Success():
        ptr = cf.GetValueAsUnsigned()
        if ptr:
            v = _eval(frame, "(const char *)[(id)%#x UTF8String]" % ptr)
            if v.GetError().Success():
                s = _cstr(proc, v.GetValueAsUnsigned(), 256)
                if s:
                    return s
    runs = _strings_in(proc, strp, 96, 5)
    return runs[0] if runs else None


def _backtrace(frame, limit=14):
    th = frame.GetThread()
    if th is None:
        return "?"
    total = th.GetNumFrames()
    start = 0
    for i in range(total):
        if th.GetFrameAtIndex(i).GetFrameID() == frame.GetFrameID():
            start = i
            break
    names = []
    for i in range(start, min(total, start + limit)):
        f = th.GetFrameAtIndex(i)
        names.append(f.GetFunctionName() or f.GetSymbol().GetName() or "?")
    return " <- ".join(names)


def _done(reason):
    if not S.done:
        S.done = True
        if MODE in ("fix", "settle"):
            log("done: %s — %d hits, %d fix pass(es), %d layer(s) matched '%s', "
                "%d hidden" % (reason, S.hits, S.passes, S.matched, PATTERN,
                               S.fixed))
        else:
            log("done: %s — %d hits (nothing was modified)" % (reason, S.hits))
        if State.hunt_silent:
            log("%d further breakpoint hit(s) outside the menu-bar stack "
                "(not logged)" % State.hunt_silent)
        if MODE == "fix" and not S.matched:
            log("no '%s' name was seen. Layer names that were seen:" % PATTERN)
            for n in S.names[:80]:
                log("  '" + n + "'")
    return S.done


# --- breakpoint C: the menu bar rebuild itself ----------------------------
def on_menu_bar_layers(frame, bp_loc, internal_dict):
    try:
        S.hits += 1
        if MODE in ("fix", "settle"):
            # Only bookkeeping here: the repair itself runs in the pill handler,
            # which has a real CALayer. This call is made once per display.
            S.displays.add(frame.FindRegister("x1").GetValueAsUnsigned() & 0xffffffff)
            return True
        log("update_menu_bar_layers called (display=%d)"
            % (frame.FindRegister("x1").GetValueAsUnsigned() & 0xffffffff))
    except Exception:
        import traceback
        log("menu_bar_layers error:\n" + traceback.format_exc())
    return True


# --- breakpoint A: render tree naming ------------------------------------
def on_render_name(frame, bp_loc, internal_dict):
    try:
        return _on_render_name(frame)
    except Exception:
        import traceback
        log("render callback error:\n" + traceback.format_exc())
        return not _done("callback error")


def _on_render_name(frame):
    if S.done:
        return False
    proc = frame.GetThread().GetProcess()
    this = frame.FindRegister("x0").GetValueAsUnsigned()
    strp = frame.FindRegister("x1").GetValueAsUnsigned()
    S.hits += 1

    if not S.traced:
        S.traced = True
        log("first render set_name at %#x; caller stack:\n    %s"
            % (this, _backtrace(frame)))

    text = _render_string(frame, proc, strp)
    if text is None:
        log("render set_name at %#x, unreadable string at %#x:\n%s"
            % (this, strp, _hexdump(proc, strp, 64)))
    else:
        if text not in S.names and len(S.names) < 500:
            S.names.append(text)
            if "MenuBar" in text:
                log("render name: '%s'" % text)
        if PATTERN in text:
            S.matched += 1
            log("MATCH render name '%s' layer=%#x" % (text, this))
            if MODE == "fix":
                _strip_glass(frame, proc, this, text, "render")

    if MODE == "fix" and S.fixed >= MAXFIX:
        return not _done("neutralised %d layer(s)" % S.fixed)
    if S.hits >= MAXHITS:
        return not _done("hit limit %d" % MAXHITS)
    return True


# --- breakpoint B: CALayer property setter -------------------------------
def on_ca_setter(frame, bp_loc, internal_dict):
    try:
        S.hits += 1
        attr = frame.FindRegister("x1").GetValueAsUnsigned() & 0xffffffff
        if attr != NAME_ATTR:
            if S.hits >= MAXHITS:
                return not _done("hit limit %d" % MAXHITS)
            return True

        proc = frame.GetThread().GetProcess()
        this = frame.FindRegister("x0").GetValueAsUnsigned()
        vtype = frame.FindRegister("x2").GetValueAsUnsigned() & 0xffffffff
        val = frame.FindRegister("x3").GetValueAsUnsigned()

        text = None
        if vtype == 3 and val:
            # the value is a pointer to the object (NSString*) for the name attr
            v = _eval(frame, "(const char *)[(id)*(void **)%#x UTF8String]" % val)
            if v.GetError().Success():
                text = _cstr(proc, v.GetValueAsUnsigned(), 256)
            if not text:
                text = _cstr(proc, val, 256)

        if text and "MenuBar" in text and text not in S.names:
            S.names.append(text)
            log("calayer name: '%s'" % text)
        if text and PATTERN in text:
            S.matched += 1
            log("MATCH calayer name '%s' CA::Layer=%#x\n    %s"
                % (text, this, _backtrace(frame, 6)))
            if MODE == "fix":
                _strip_glass(frame, proc, this, text, "calayer")
        if MODE == "fix" and S.fixed >= MAXFIX:
            return not _done("neutralised %d layer(s)" % S.fixed)
        if S.hits >= MAXHITS:
            return not _done("hit limit %d" % MAXHITS)
        return True
    except Exception:
        import traceback
        log("setter callback error:\n" + traceback.format_exc())
        return not _done("callback error")



# --- hunt mode: who gives the menu bar its glass? ------------------------
# Names are useless here (WindowServer never calls -[CALayer setName:] nor
# CA::Render::Layer::set_name for these layers), so instead watch every setter
# that can make a layer look like frosted glass. Only hits whose call stack
# mentions the menu bar are logged, everything else is just counted.
TREE_CAP = int(os.environ.get("T26_TREECAP", "8"))
TREE_QUIET = 4.0   # seconds without a new root before `tree` ends
TREE_LIMIT = 8.0   # hard cap on how long `tree` keeps dumping
HUNT_CAP = 240
HUNT_NEEDLES = ("menu_bar", "MenuBar", "menubar")


def _stack_has(frame, depth=12):
    th = frame.GetThread()
    if th is None:
        return False
    for i in range(1, min(th.GetNumFrames(), depth)):
        f = th.GetFrameAtIndex(i)
        nm = f.GetFunctionName() or f.GetSymbol().GetName() or ""
        for needle in HUNT_NEEDLES:
            if needle in nm:
                return True
    return False


def _reg(frame, name):
    r = frame.FindRegister(name)
    return r.GetValueAsUnsigned() if r else 0


def _keypath(frame, proc, addr, count=3):
    """Render property key paths are 4-char codes: 'name', 'opac', 'hidd'…"""
    out = []
    for i in range(count):
        err = lldb.SBError()
        v = proc.ReadMemory(addr + 4 * i, 4, err)
        if not err.Success():
            break
        code = v.GetUnsignedInt32(err, 0)
        out.append("".join(chr((code >> s) & 0xff) if 32 <= ((code >> s) & 0xff) < 127
                           else "?" for s in (0, 8, 16, 24)))
    return "/".join(out)


def _hunt(frame, tag, arg="ptr", report_always=False):
    proc = frame.GetThread().GetProcess()
    S.hits += 1
    if S.hits >= MAXHITS:
        return not _done("hit limit %d" % MAXHITS)
    this = _reg(frame, "x0")

    if not report_always and not _stack_has(frame):
        State.hunt_silent += 1
        return True

    detail = ""
    addr = _reg(frame, "x1")
    if arg == "ptr":
        detail = "arg=%#x" % addr
    elif arg == "keypath":
        detail = "keypath='%s' count=%d" % (_keypath(frame, proc, addr),
                                            _reg(frame, "x4") & 0xffffffff)
    elif arg == "str":
        detail = "string=%r" % (_cstr(proc, addr, 96) if addr else None)
    log("HUNT %s this=%#x %s\n    %s"
        % (tag, this, detail, _backtrace(frame, 7)))

    if MODE != "fix" or S.fixed >= MAXFIX:
        return True
    if arg not in ("ptr",):
        return True
    if not addr:
        return True          # already null, nothing to null out
    reg = frame.FindRegister("x1")
    if reg and reg.SetValueFromCString("0").Success():
        S.fixed += 1
        S.matched += 1
        log("neutralized: %s called with %#x — passed nullptr instead"
            % (tag, addr))
        if S.fixed >= MAXFIX:
            return not _done("neutralised %d setter call(s)" % S.fixed)
    return True


def on_hunt_bg_filters(frame, bp_loc, internal_dict):
    return _hunt(frame, "set_background_filters")


def on_hunt_filters(frame, bp_loc, internal_dict):
    return _hunt(frame, "set_filters")


def on_hunt_comp_filter(frame, bp_loc, internal_dict):
    return _hunt(frame, "set_compositing_filter")


def on_hunt_subclass(frame, bp_loc, internal_dict):
    return _hunt(frame, "set_subclass")


def on_hunt_property(frame, bp_loc, internal_dict):
    return _hunt(frame, "set_property_value", arg="keypath")


def on_hunt_retain_group(frame, bp_loc, internal_dict):
    return _hunt(frame, "BackdropGroup::retain_group", arg="str")



# --- CUICoreThemeRenderer: who paints the glass? -------------------------
# SkyLight builds a CUIDescriptor (kCUIWidgetKey, kCUIBackdropCompatibleKey, …)
# and hands it to -[CUICoreThemeRenderer updateLayer:key:rendererWork:], which
# paints the material straight into a CALayer. Hook that one selector and the
# layer in x2 is, by definition, the layer that carries the frosted glass.
def _objc_str(frame, ptr, sel):
    v = _eval(frame, "(id)[(id)%#x %s]" % (ptr, sel))
    if v.GetError().Fail():
        return None
    ns = v.GetValueAsUnsigned()
    if not ns:
        return None
    s = _eval(frame, "(const char *)[(id)%#x UTF8String]" % ns)
    if s.GetError().Fail():
        return None
    return _cstr(frame.GetThread().GetProcess(), s.GetValueAsUnsigned(), 400)


def _objc_class(frame, ptr):
    v = _eval(frame, "(id)[(id)%#x class]" % ptr)
    if v.GetError().Fail():
        return "?"
    cls = v.GetValueAsUnsigned()
    if not cls:
        return "?"
    return _objc_str(frame, cls, "description") or "?"


def on_theme_update(frame, bp_loc, internal_dict):
    try:
        return _on_theme_update(frame)
    except Exception:
        import traceback
        log("theme callback error:\n" + traceback.format_exc())
        return not _done("callback error")


def _on_theme_update(frame):
    S.hits += 1
    if S.hits >= MAXHITS:
        return not _done("hit limit %d" % MAXHITS)

    layer = _reg(frame, "x2")
    key = _reg(frame, "x3")
    if not layer:
        return True

    name = _objc_str(frame, layer, "name")
    menu = _stack_has(frame)
    interesting = menu or S.hits <= 20

    if interesting and S.theme_logged < HUNT_CAP:
        S.theme_logged += 1
        cls = _objc_class(frame, layer)
        log("THEME layer=%#x class=%s name=%r%s"
            % (layer, cls, name, "  [menu bar]" if menu else ""))
        if S.theme_logged <= 3:
            log("      descriptor key=%#x: %s"
                % (key, (_objc_str(frame, key, "description") or "?")[:400]
                   if key else "nil"))
            log("      stack: %s" % _backtrace(frame, 8))

    if name and name not in S.names and len(S.names) < 500:
        S.names.append(name)

    if MODE == "fix" and name and PATTERN in name:
        S.matched += 1
        v = _eval(frame, "(int)[(id)%#x setHidden:YES]" % layer)
        ok = v.GetError().Success()
        chk = _eval(frame, "(BOOL)[(id)%#x isHidden]" % layer)
        hidden = chk.GetValueAsUnsigned() if chk.GetError().Success() else -1
        if ok and hidden:
            S.fixed += 1
            log("neutralized '%s' at %#x  [hidden=%d]" % (name, layer, hidden))
        else:
            log("could not neutralise '%s' at %#x (hidden=%s)"
                % (name, layer, hidden))
        if S.fixed >= MAXFIX:
            return not _done("neutralised %d layer(s)" % S.fixed)
    return True


# --- menu bar CALayer tree ------------------------------------------------
# resize_one_pill(PKGManagedMenuSpace*, PKGMenuBarContext*, CALayer*, ...) gets
# a real menu bar CALayer in x2. WindowServer's bar is a plain CALayer tree, so
# walk it: names, classes, filters, and the glass shows itself.
def _objc_desc(frame, ptr, sel):
    v = _eval(frame, "(id)[(id)%#x %s]" % (ptr, sel))
    if v.GetError().Fail():
        return None
    obj = v.GetValueAsUnsigned()
    if not obj:
        return None
    return _objc_str(frame, obj, "description")


def _layer_ptr(frame, ptr, sel):
    v = _eval(frame, "(id)[(id)%#x %s]" % (ptr, sel))
    if v.GetError().Fail():
        return 0
    return v.GetValueAsUnsigned()


def _subarray(frame, ptr):
    """The layer's sublayers array (0 when it has none)."""
    v = _eval(frame, "(id)[(id)%#x sublayers]" % ptr)
    return v.GetValueAsUnsigned() if v.GetError().Success() else 0


def _count(frame, arr):
    v = _eval(frame, "(unsigned long)[(id)%#x count]" % arr)
    return v.GetValueAsUnsigned() if v.GetError().Success() else 0


def _layer_at(frame, arr, i):
    v = _eval(frame, "(id)[(id)%#x objectAtIndex:%d]" % (arr, i))
    return v.GetValueAsUnsigned() if v.GetError().Success() else 0


def _layer_line(frame, depth, ptr, label=""):
    name = _objc_str(frame, ptr, "name")
    cls = _objc_class(frame, ptr)
    bg = _objc_desc(frame, ptr, "backgroundFilters") or ""
    fl = _objc_desc(frame, ptr, "filters") or ""
    cf = _objc_desc(frame, ptr, "compositingFilter") or ""
    hid = _eval(frame, "(BOOL)[(id)%#x isHidden]" % ptr)
    hidden = hid.GetValueAsUnsigned() if hid.GetError().Success() else 0
    # The expression JIT returns garbage for a `double` method result and fails
    # on `ptr == 0`, so read opacity as float and compare as an integer.
    op = _eval(frame, "(float)[(id)%#x opacity]" % ptr)
    try:
        opa = float(op.GetValue()) if op.GetError().Success() else 1.0
    except (TypeError, ValueError):
        opa = 1.0
    con = _eval(frame, "(int)((unsigned long long)[(id)%#x contents] != 0)" % ptr)
    has_con = con.GetValueAsUnsigned() if con.GetError().Success() else 0
    bits = []
    if opa < 0.999:
        bits.append("op=%.2f" % opa)
    if has_con:
        bits.append("contents")
    if bg and bg not in ("nil", "(null)"):
        bits.append("bg=" + bg[:160])
    if fl and fl not in ("nil", "(null)"):
        bits.append("fl=" + fl[:160])
    if cf and cf not in ("nil", "(null)"):
        bits.append("cf=" + cf[:80])
    return ("%s%s%#x %-28s %-22s%s%s"
            % ("  " * depth, label, ptr, "'%s'" % (name or ""), cls,
               " hidden" if hidden else "",
               ("  " + " ".join(bits)) if bits else ""))


def _walk(frame, ptr, depth, budget):
    subs = _subarray(frame, ptr)
    if not subs:
        return
    for i in range(min(_count(frame, subs), 24)):
        if budget[0] <= 0:
            return
        budget[0] -= 1
        child = _layer_at(frame, subs, i)
        if not child:
            continue
        log(_layer_line(frame, depth, child))
        _walk(frame, child, depth + 1, budget)


def _neutralize_tree(frame, ptr, budget):
    subs = _subarray(frame, ptr)
    if not subs:
        return
    for i in range(min(_count(frame, subs), 32)):
        if budget[0] <= 0:
            return
        budget[0] -= 1
        child = _layer_at(frame, subs, i)
        if not child:
            continue
        name = _objc_str(frame, child, "name")
        if name and PATTERN in name:
            S.matched += 1
            # (int), not (void): lldb reports a bogus "unknown error" for the
            # void cast of a void method, the call itself is fine.
            v = _eval(frame, "(int)[(id)%#x setHidden:YES]" % child)
            chk = _eval(frame, "(BOOL)[(id)%#x isHidden]" % child)
            hidden = chk.GetValueAsUnsigned() if chk.GetError().Success() else -1
            if v.GetError().Success() and hidden:
                S.fixed += 1
                log("neutralized '%s' at %#x  [hidden=%d]" % (name, child, hidden))
            else:
                log("could not neutralise '%s' at %#x (hidden=%s)"
                    % (name, child, hidden))
        _neutralize_tree(frame, child, budget)


# Every lldb EvaluateExpression is a JIT compile *plus* a call into the stopped
# process, which is exactly what the user feels as stutter. So the whole fix is
# done in one expression: climb to the bar's root layer, then hide every
# matching layer in the two levels below it.
_ROOT_EXPR = ("(id)({ id p=(id)%#x;"
              " for (int i=0;i<6;i++){ id u=(id)[p superlayer]; if(!u) break; p=u; } p; })")

# The expression returns n * 1000 + m:
#   n = layers it had to hide right now, m = matching layers that were already
#   hidden (i.e. the fix survived the rebuild untouched).
_FIX_HEAD = ("(int)({ id p=(id)%#x;"
             " for (int k=0;k<6;k++){ id u=(id)[p superlayer]; if(!u) break; p=u; }"
             " int n=0; int m=0; id s=(id)[p sublayers];"
             " unsigned long c=(unsigned long)[s count];")

# WindowServer resets `hidden` on every rebuild, so in deep mode the layer is
# also emptied out: no contents, no filters, no opacity. Whichever of these it
# does not reset is what keeps the bar transparent without us holding the
# process at a breakpoint. Its children get the same treatment: on some displays
# SLMenuBarEnhancementLayer (cf=darkenBlendMode) is what still paints the glass
# once the parent itself is already empty.
_FIX_DEEP = ("(int)[l{i} setOpacity:0.0]; (int)[l{i} setContents:(id)0];"
             " (int)[l{i} setFilters:(id)0];"
             " (int)[l{i} setBackgroundFilters:(id)0];"
             " {{ id cs{i}=(id)[l{i} sublayers];"
             " unsigned long cc{i}=(unsigned long)[cs{i} count];"
             " for (unsigned long q{i}=0;q{i}<cc{i};q{i}++){{"
             " id mq{i}=(id)[cs{i} objectAtIndex:q{i}];"
             " (int)[mq{i} setHidden:YES]; (int)[mq{i} setOpacity:0.0];"
             " (int)[mq{i} setContents:(id)0]; (int)[mq{i} setFilters:(id)0];"
             " (int)[mq{i} setBackgroundFilters:(id)0]; }} }}")


def _fix_expr(ptr, deep=DEEP):
    def body(i, arr, idx, tail=""):
        setts = _FIX_DEEP.format(i=i) if deep else ""
        return (" id l{i}=(id)[{arr} objectAtIndex:{idx}];"
                " id nm{i}=(id)[l{i} name];"
                ' if ((int)[nm{i} containsString:@"' + PATTERN + '"]) {{'
                " if ((int)[l{i} isHidden]) m++;"
                " else {{ (int)[l{i} setHidden:YES]; n++; }}"
                " {setts} {tail} }}").format(i=i, arr=arr, idx=idx,
                                            setts=setts, tail=tail)

    inner = (" id s2=(id)[l1 sublayers]; unsigned long c2=(unsigned long)[s2 count];"
             " for (unsigned long j=0;j<c2;j++){" + body(2, "s2", "j") + " }")
    return (_FIX_HEAD % ptr
            + " for (unsigned long i=0;i<c;i++){"
            + body(1, "s", "i", "continue;")
            + inner
            + " } n*1000+m; })")


def _root_of(frame, ptr):
    """Top-most superlayer of the bar, in one expression."""
    v = _eval(frame, _ROOT_EXPR % ptr)
    return v.GetValueAsUnsigned() if v.GetError().Success() else ptr


def _fix_pass(frame, ptr, deep=False):
    """Climb to the bar's root and hide every matching layer, in one expression.

    ptr is the CALayer resize_one_pill() was given; the backdrop is a sibling of
    it, so the climb is what makes the layers reachable. Returns (count, ms).
    """
    t0 = time.time()
    v = _eval(frame, _fix_expr(ptr, deep))
    ms = (time.time() - t0) * 1000.0
    if v.GetError().Fail():
        log("fix expression failed: %s" % v.GetError().GetCString())
        return -1, ms, 0
    raw = v.GetValueAsUnsigned() & 0xffffffff
    return raw // 1000, ms, raw % 1000


def on_resize_pill(frame, bp_loc, internal_dict):
    try:
        return _on_resize_pill(frame)
    except Exception:
        import traceback
        log("pill callback error:\n" + traceback.format_exc())
        return not _done("callback error")


def _on_resize_pill(frame):
    S.hits += 1
    if S.hits >= MAXHITS:
        # Never stop the process on the hit limit: that would freeze the
        # desktop until the script's timeout fires. Keep working, just quiet.
        if not S.hitlimit:
            S.hitlimit = True
            log("hit limit %d reached — still fixing, logging muted" % MAXHITS)
        S.hits -= 1000
        return True
    layer = _reg(frame, "x2")
    if not layer:
        return True

    if MODE in ("fix", "settle"):
        # The pill layer is a sibling of the backdrop, so go through the root and
        # hide every layer whose name matches. Text/icon/pill/shadow layers have
        # other names and are left alone.
        #
        # This runs on *every* pill resize (three per rebuild): WindowServer may
        # repaint/unhide the backdrop after the first pill, and each display
        # rebuilds on its own, so "fix once per rebuild" misses displays.
        S.passes += 1
        S.last_pass = time.time()
        n, ms, stuck = _fix_pass(frame, layer, deep=DEEP)
        root = _root_of(frame, layer) if n > 0 else 0
        if n > 0:
            S.fixed += n
            S.matched += n
            S.clean_streak = 0
            if root:
                S.roots[root] = S.roots.get(root, 0) + 1
        else:
            S.clean_streak += 1
        # Log the first few passes and then once every 200, so a long run stays
        # quiet without being blind.
        if S.passes <= 12 or S.passes % 200 == 0:
            S.fast_logged += 1
            if n > 0:
                log("fix pass %d: neutralised %d layer(s) under %#x in %.0f ms"
                    " (already hidden: %d)" % (S.passes, n, root, ms, stuck))
            elif stuck:
                log("fix pass %d: %d matching layer(s) still hidden — the fix "
                    "survived the rebuild (%d/%d display(s) seen)"
                    % (S.passes, stuck, len(S.roots), max(1, len(S.displays))))
            else:
                log("fix pass %d: nothing matched '%s' (%.0f ms)"
                    % (S.passes, PATTERN, ms))
        if MAXFIX > 0 and S.fixed >= MAXFIX:
            return not _done("neutralised %d layer(s)" % S.fixed)
        # settle: get out of the way — but only once the fix has been shown to
        # survive a rebuild on *every* display. Detaching after "two passes and
        # three seconds" is how one screen ended up frosted again: its bar had
        # only been repaired once.
        age = time.time() - S.t0
        # "Every display confirmed" = we have hit at least as many distinct bar
        # roots as WindowServer told us about, and each of them has been
        # repaired more than once (i.e. our repair beat a later rebuild).
        every_display = (len(S.roots) >= max(1, len(S.displays))
                         and min(S.roots.values()) >= 2)
        too_long = age >= SETTLE_MAX
        if (MODE == "settle" and not S.settled and age >= SETTLE_MIN
                and (every_display or too_long)):
            S.settled = True
            log("settle: %d layer(s) hidden over %d pass(es), %d/%d display(s) "
                "confirmed; dropping the breakpoints so WindowServer runs at "
                "full speed again"
                % (S.fixed, S.passes, len(S.roots), max(1, len(S.displays))))
            if not every_display:
                log("settle: WARNING only %d/%d display(s) ever got repaired "
                    "(waited %.0fs) — that bar may come back frosted; rerun "
                    "with a longer T26_SETTLE_MAX if so"
                    % (len(S.roots), max(1, len(S.displays)), age))
            # -G true keeps the process running, so this is a real detach of the
            # breakpoints, not just a message: after it, nothing stops the server.
            try:
                d = lldb.debugger
                if d is None:
                    log("settle: no debugger handle in the callback")
                else:
                    t = d.GetSelectedTarget()
                    n_off = t.GetNumBreakpoints() if t else 0
                    d.HandleCommand("breakpoint disable")
                    log("settle: %d breakpoint(s) disabled" % n_off)
            except Exception:
                import traceback
                log("settle: could not drop the breakpoints:\n"
                    + traceback.format_exc())
            return not _done("settled")
        return True

    now = time.time()
    # Finish once no new display has shown up for a while (or the first tree is
    # older than TREE_LIMIT): with the root-based cap alone a single-display Mac
    # would idle until the whole time budget ran out.
    if S.tree_logged and (now - S.last_tree > TREE_QUIET or now - S.t0 > TREE_LIMIT):
        return not _done("logged %d tree(s)" % S.tree_logged)
    if S.tree_logged >= TREE_CAP:
        return True
    # Walk up to the root of the bar (tree mode only: in fix mode the climb is
    # folded into the single fix expression, every eval is a stop-the-world).
    # The dump is deduplicated by root: one rebuild fires three pill resizes, so
    # counting hits instead of roots would spend the whole budget on the first
    # display and never show the second one.
    root = _root_of(frame, layer)
    if not root or root in S.trees:
        return True
    S.trees.add(root)
    S.tree_logged += 1
    S.last_tree = now
    log(_layer_line(frame, 0, layer, "MENUBAR layer: "))
    log("  tree from root %#x (menu bar %d of at most %d):"
        % (root, S.tree_logged, TREE_CAP))
    _walk(frame, root, 1, [40])

    return True

# --- the actual surgery --------------------------------------------------
def _strip_glass(frame, proc, obj, text, kind):
    """Remove the backdrop/glass from one layer, leaving everything else."""
    if kind == "render":
        ok = True
        ok &= _call(frame, RENDER_SET_BG_FILTERS, "void (*)(void *, void *)",
                    ["(void *)%#x" % obj, "(void *)0"])
        ok &= _call(frame, RENDER_SET_FILTERS, "void (*)(void *, void *)",
                    ["(void *)%#x" % obj, "(void *)0"])
        ok &= _call(frame, RENDER_SET_CONTENTS, "void (*)(void *, void *)",
                    ["(void *)%#x" % obj, "(void *)0"])
    else:
        # The CALayer object is not reachable from CA::Layer (setName: passes
        # CA::Layer in x0), so only report it: this tells us which path the
        # server uses before we pick the neutralisation.
        log("matched on the CALayer path (CA::Layer=%#x); the render-tree "
            "neutralisation is the implemented one" % obj)
        return

    if ok:
        S.fixed += 1
        log("neutralized '%s' (%s) at %#x" % (text, kind, obj))
    else:
        log("could not neutralise '%s' (%s) at %#x" % (text, kind, obj))


log("--- ws_hook loaded (mode %s, pattern '%s', maxfix %d, maxhits %d) ---"
    % (MODE, PATTERN, MAXFIX, MAXHITS))
