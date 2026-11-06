"""Does a commit change ONLY inline `#[cfg(test)]` code in Rust source files?

Used by red-first-preflight.sh (#552) when a commit touches `.rs` files that
the name rules do not recognise as tests. A STRUCTURAL heuristic: no checkout,
no test run, stdlib only. It is a guard others must audit, so it FAILS CLOSED:
anything it cannot prove returns False and the commit stays implementation. A
false block costs one recorded exception; a false pass defeats the guard.

Per Rust file, compare the file before and after the commit:
  1. Find the `#[cfg(test)]` ITEMS.
     - The attribute must sit at the start of an item in an item list: the
       file, or a `{}` body of a `mod` or `impl` whose every enclosing bracket
       is also such a body. It must follow `{`, `}`, `;` or `]`, or start the
       file. So it is never inside a fn body, parentheses, angle brackets
       (const generics), a struct, enum or trait body, a const block or any
       macro token tree, however deeply a `mod` is nested inside one.
     - The `mod` or `impl` may carry only inert attributes (allow, warn, deny,
       forbid, expect, cfg, doc, inline, must_use). An attribute macro, or
       `cfg_attr` which may expand to one, is handed the whole body before
       inner cfg applies.
     - A well-formed item follows: `mod NAME {..}`, `fn NAME .. {..}`,
       `impl .. {..}`, `use ..;` or `const NAME .. = ..;`.
     - `cfg(test)` and `cfg(all(.., test, ..))` count; `not`, `any`, `cfg_attr`
       and anything else do not. The attributes and `///` doc comments directly
       above an item belong to it.
  2. Everything outside those items (every token and comment, whitespace aside)
     must be IDENTICAL before and after. Operators compare with their spacing
     (`&&` is not `& &`).
  3. The test items' own code must differ (real test code added or changed).
Anything unreadable is "not provably test-only": non-UTF-8; an unterminated
string or comment; an ambiguous quote; a `#!` first line that is not an inner
attribute; non-ASCII outside strings, chars and comments (Python and rustc
disagree on what continues an identifier); a `cr` raw string (its meaning
depends on the edition); a literal suffix (an identifier straight after a
string or char); unmatched brackets; a file over MAX_BYTES (checked
before reading); `mod x;` inside an item (it would pull in another file);
symlinks, submodules, renames, copies and type changes; merge commits
(diff-tree lists no paths for them); and any exception at all.
This is a structural heuristic with no known way through, not a proof of
soundness: it rests on rustc's lexing rules as understood today.
"""
import bisect
import re
import subprocess

MAX_BYTES = 512 * 1024

_SPACE = " \t\r\n\f\v"  # ASCII only; any other space is non-ASCII and unprovable
_WORD = re.compile(r"\w+")
_RAW_STR = re.compile(r"(?:br|cr|r)(#*)\"")
_STR = re.compile(r"(?:b|c)?\"")
_BYTE_CHAR = re.compile(r"b'")
_COMMENT_EDGE = re.compile(r"/\*|\*/")
_MODIFIERS = {"unsafe"}
_INERT = {"allow", "warn", "deny", "forbid", "expect", "cfg", "doc", "inline", "must_use"}


def lex(src):
    """Tokens as (kind, text, start, end), or None if anything is unreadable.
    Kinds: word, punct, str, char, life, comment, doc (`///` and `/**` only)."""
    i = 1 if src.startswith("\ufeff") else 0  # rustc drops one leading BOM...
    body = src[i:]  # ...before it looks for a shebang
    if body.startswith("#!") and not body[2:].lstrip(_SPACE).startswith("["):
        return None  # a shebang line is discarded by rustc; this lexer would not
    toks, n = [], len(src)
    while i < n:
        c = src[i]
        if c in _SPACE:
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            t = src[i:j]
            toks.append(("doc" if t.startswith("///") and not t.startswith("////") else "comment", t, i, j))
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while depth:
                m = _COMMENT_EDGE.search(src, j)
                if m is None:
                    return None
                depth += 1 if m.group() == "/*" else -1
                j = m.end()
            t = src[i:j]
            doc = t.startswith("/**") and not t.startswith("/***") and t != "/**/"
            toks.append(("doc" if doc else "comment", t, i, j))
            i = j
        elif _RAW_STR.match(src, i):
            m = _RAW_STR.match(src, i)
            if m.group().startswith("cr"):
                return None
            end = src.find('"' + m.group(1), m.end())
            if end < 0:
                return None
            j = end + 1 + len(m.group(1))
            toks.append(("str", src[i:j], i, j))
            i = j
        elif _STR.match(src, i):
            j = _STR.match(src, i).end()
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            if j >= n:
                return None
            toks.append(("str", src[i:j + 1], i, j + 1))
            i = j + 1
        elif c == "'" or _BYTE_CHAR.match(src, i):
            q = i if c == "'" else i + 1  # position of the opening quote
            res = _quote_end(src, q)
            if res is None:
                return None
            toks.append(("char" if res[1] else "life", src[i:res[0]], i, res[0]))
            i = res[0]
        elif src.startswith("r#", i) and i + 2 < n and (src[i + 2].isalpha() or src[i + 2] == "_"):
            m = _WORD.match(src, i + 2)
            toks.append(("word", src[i:m.end()], i, m.end()))
            i = m.end()
        elif _WORD.match(src, i):
            m = _WORD.match(src, i)
            toks.append(("word", m.group(), i, m.end()))
            i = m.end()
        else:
            toks.append(("punct", c, i, i + 1))
            i += 1
    if any(t[0] in ("word", "punct", "life") and not t[1].isascii() for t in toks):
        return None
    # an identifier straight after a literal is its suffix (`""r"x"` is the
    # literal `""r` then a string), which this lexer would read differently
    if any(t[0] in ("str", "char") and t[3] < n and (src[t[3]].isalnum() or src[t[3]] == "_") for t in toks):
        return None
    return toks


def _quote_end(src, q):
    """(end, is_char) for the quote at q: a char literal or a lifetime; None if unclear."""
    n = len(src)
    if q + 1 >= n:
        return None
    if src[q + 1] == "\\":
        j = src.find("'", q + 3, q + 16)
        return None if j < 0 else (j + 1, True)
    if q + 2 < n and src[q + 2] == "'" and src[q + 1] not in "'\n":
        return (q + 3, True)
    if src[q + 1].isalpha() or src[q + 1] == "_":
        return (_WORD.match(src, q + 1).end(), False)
    return None


def _brackets(sig):
    """{open index: close index} for ( [ { and the reverse, or None if unbalanced."""
    pairs, stack = {}, []
    for k, t in enumerate(sig):
        if t[0] != "punct":
            continue
        if t[1] in "([{":
            stack.append(k)
        elif t[1] in ")]}":
            if not stack or "([{".index(sig[stack[-1]][1]) != ")]}".index(t[1]):
                return None
            o = stack.pop()
            pairs[o], pairs[k] = k, o
    return None if stack else pairs


def cfg_is_test(toks):
    """True only when the tokens are exactly `cfg(<predicate>)` and the
    predicate holds in tests ONLY: `test`, or `all(..)` with such an argument."""
    t = [x[1] for x in toks if x[0] not in ("comment", "doc")]
    try:
        if t[:2] != ["cfg", "("]:
            return False
        val, i = _pred(t, 2)
        return bool(val) and i == len(t) - 1
    except IndexError:
        return False


def _pred(t, i):
    name = t[i]
    if name == "test" and t[i + 1] in (",", ")"):
        return True, i + 1
    if name == "all" and t[i + 1] == "(":
        i, res = i + 2, False
        while t[i] != ")":
            v, i = _pred(t, i)
            res = res or v
            if t[i] == ",":
                i += 1
        return res, i + 1
    if t[i + 1] == "(":  # any(..), not(..), other calls: skip balanced, never test-only
        depth, i = 0, i + 1
        while True:
            depth += {"(": 1, ")": -1}.get(t[i], 0)
            i += 1
            if depth == 0:
                return False, i
    return False, i + 1


def _is(sig, k, text, kind="punct"):
    return 0 <= k < len(sig) and sig[k][0] == kind and sig[k][1] == text


def _scan(sig, pairs, k, limit, stop_at_brace):
    """From k, find the end of an item: its `{..}` body (if stop_at_brace) or
    its `;`. Brackets are skipped as pairs. Returns the end index, or None when
    the item runs off the end of its list (`limit` is the closing bracket of the
    enclosing body) or, for a body item, hits a `;`."""
    while k < limit:
        t = sig[k]
        s = t[1] if t[0] == "punct" else ""
        if s in ("(", "["):
            k = pairs[k]
        elif s == "{":
            if stop_at_brace:
                return pairs[k]
            k = pairs[k]
        elif s == ";":
            return None if stop_at_brace else k
        k += 1
    return None


def _item_end(sig, pairs, j, limit):
    """End index of the item whose keyword is at j, or None if not well-formed."""
    kw = sig[j][1]
    word = lambda k: k < limit and sig[k][0] == "word"
    if kw == "mod":
        return pairs[j + 2] if word(j + 1) and _is(sig, j + 2, "{") and j + 2 < limit else None
    if kw == "fn":
        return _scan(sig, pairs, j + 2, limit, True) if word(j + 1) else None
    if kw == "impl":
        return _scan(sig, pairs, j + 1, limit, True)
    if kw == "use":
        return _scan(sig, pairs, j + 1, limit, False)
    if kw == "const":
        end = _scan(sig, pairs, j + 2, limit, False) if word(j + 1) else None
        if end is not None and any(_is(sig, x, "=") for x in range(j + 2, end)):
            return end
    return None


def _list_body(sig, pairs, o):
    """Is the `{` at o the body of a `mod` or an `impl` (an item list)?"""
    k = o - 1
    while k >= 0 and not (sig[k][0] == "punct" and sig[k][1] in "{};"):
        k = pairs[k] - 1 if sig[k][0] == "punct" and sig[k][1] in ")]" else k - 1
    k += 1
    while _is(sig, k, "#") and _is(sig, k + 1, "["):  # leading attributes
        # an attribute macro (or cfg_attr, which may expand to one) is handed
        # the whole body before an inner cfg applies: only inert ones pass
        if not (k + 3 < o and sig[k + 2][1] in _INERT and sig[k + 3][1] in ("(", "=", "]")):
            return False
        k = pairs[k + 1] + 1
    while k < o and (sig[k][1] in _MODIFIERS or sig[k][1] == "pub"):
        k += 1
        if _is(sig, k, "("):
            k = pairs[k] + 1
    return _is(sig, k, "mod", "word") or _is(sig, k, "impl", "word")


def _split(src):
    """(residue, test_code) token lists for one file version, or None if unprovable."""
    toks = lex(src)
    if toks is None:
        return None
    sig = [t for t in toks if t[0] not in ("comment", "doc")]
    pairs = _brackets(sig)
    if pairs is None:
        return None
    docs_by_end = {t[3]: t[2] for t in toks if t[0] == "doc"}
    spans, stack, k = [], [], 0  # stack: (close index, is an item list)
    while k < len(sig):
        if stack and k == stack[-1][0]:
            stack.pop()
        elif sig[k][0] == "punct" and sig[k][1] in "([{":
            in_list = not stack or stack[-1][1]  # hereditary: every enclosing bracket
            stack.append((pairs[k], in_list and sig[k][1] == "{" and _list_body(sig, pairs, k)))
        elif _is(sig, k, "#") and _is(sig, k + 1, "[") and (not stack or stack[-1][1]) and (
                k == 0 or sig[k - 1][1] in ("{", "}", ";", "]")):
            limit = stack[-1][0] if stack else len(sig)
            group, is_test = k, False
            while _is(sig, k, "#") and _is(sig, k + 1, "["):
                close = pairs[k + 1]
                is_test = is_test or cfg_is_test(sig[k + 2:close])
                k = close + 1
            if not is_test:
                continue
            j = k
            while j < limit:
                if sig[j][1] == "pub":
                    j += 1
                    if _is(sig, j, "("):
                        j = pairs[j] + 1
                elif sig[j][1] in _MODIFIERS or (sig[j][1] == "const" and sig[j + 1][1] in ("fn", "unsafe")):
                    j += 1
                else:
                    break
            end = _item_end(sig, pairs, j, limit) if j < limit else None
            if end is None:
                continue
            if any(_is(sig, x, "mod", "word") and _is(sig, x + 2, ";") for x in range(group, end)):
                return None  # `mod x;` pulls another file into the block
            start = sig[group][2]
            while True:  # `///` doc comments directly above belong to the item
                p = start
                while p > 0 and src[p - 1].isspace():
                    p -= 1
                if p not in docs_by_end:
                    break
                start = docs_by_end[p]
            spans.append((start, sig[end][3]))
            k = end + 1
            continue
        k += 1
    starts = [s for s, _ in spans]
    def inside(t):
        i = bisect.bisect_right(starts, t[2]) - 1
        return i >= 0 and t[2] < spans[i][1]
    def key(ts, i):  # operators compare with their spacing: `&&` is not `& &`
        t = ts[i]
        joint = t[0] == "punct" and i + 1 < len(ts) and ts[i + 1][0] == "punct" and ts[i + 1][2] == t[3]
        return (t[0], t[1], joint)
    residue = [key(toks, i) for i, t in enumerate(toks) if not inside(t)]
    code = [key(sig, i) for i, t in enumerate(sig) if inside(t)]
    return residue, code


def test_only_change(old, new):
    """True when old -> new changes real code only inside `#[cfg(test)]` items."""
    if len(old.encode()) > MAX_BYTES or len(new.encode()) > MAX_BYTES:
        return False
    a, b = _split(old), _split(new)
    return a is not None and b is not None and a[0] == b[0] and a[1] != b[1]


def _git(root, *args):
    r = subprocess.run(["git", "-C", root, *args], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def _read(root, rev, path):
    size = _git(root, "cat-file", "-s", rev + ":" + path)  # cap BEFORE loading
    if size is None or int(size) > MAX_BYTES:
        return None
    data = _git(root, "show", rev + ":" + path)
    if data is None:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _changes(root, sha):
    """{path: (status, old mode, new mode)} of a commit, or None if it has a
    rename, copy or type change. A merge lists no paths, so none is provable."""
    out = _git(root, "diff-tree", "-r", "-M", "-C", "--root", "--no-commit-id", "--raw", "-z", sha)
    if out is None:
        return None
    parts, found, i = out.decode("utf-8", "replace").split("\0"), {}, 0
    while i < len(parts) - 1:
        meta = parts[i].lstrip(":").split()
        status = meta[4]
        if status[0] not in "AMD":
            return None  # rename, copy, type change, anything unusual
        found[parts[i + 1]] = (status, meta[0], meta[1])
        i += 2
    return found


def commit_is_test_only(root, sha, paths):
    """True when every path (all `.rs`) is changed only inside cfg(test) items.
    Any exception is a False: the caller treats it as implementation."""
    try:
        changes = _changes(root, sha)
        if changes is None or not paths:
            return False
        for p in paths:
            if p not in changes or not p.endswith(".rs"):
                return False
            st, om, nm = changes[p]
            if {om, nm} & {"120000", "160000"}:
                return False  # symlink or submodule: not source text
            old = "" if st == "A" else _read(root, sha + "^", p)
            new = "" if st == "D" else _read(root, sha, p)
            if old is None or new is None or not test_only_change(old, new):
                return False
        return True
    except Exception:
        return False
