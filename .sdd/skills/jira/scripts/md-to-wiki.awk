# Markdown to Jira wiki markup (Server / Data Center): the way back of
# wiki-to-md.awk, for a description written or edited as Markdown.
#
# Run as: LC_ALL=C awk -v refs=<file> [-v plain=<file>] -f md-to-wiki.awk < in.md > out.wiki
#
# Reads Markdown on stdin, writes wiki markup on stdout. Side facts go to
# `refs`, one per line, tab-separated:
#   image <path>   a local image the text shows; the markup names it !<name>!
#   file  <path>   a local file the text links; the markup names it [text|^<name>]
#   mention <user> an @user turned into [~user]
#   note  <text>   something that was simplified on the way
# A path is local when it has no scheme; it is %-decoded, and <name> is its
# last segment. Whether the file exists is the caller's business.
#
# `plain`, when given, lists names one per line that are not to become
# mentions — the ones Jira has no user for: @name stays text. \@name is
# always text.
#
# LC_ALL=C, so awk works on bytes, as wiki-to-md.awk does: every pattern is
# ASCII and any other byte is copied through.
#
# The whole input is read first and converted at the end, block by block. A
# block that holds blocks of its own — a list item, a quote — has its lines,
# stripped of the indent or the `>`, appended to the same array L and is
# converted by a recursive call over that range, so no awk needs local arrays.
#
# A line break inside a paragraph is kept as a line break: Jira shows one
# where the wiki text has one, and that is how wiki-to-md.awk wrote it out.
# Inside a list item or a table cell, where a line break would end the item
# or the row, lines are joined with a space.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function blank(s) { return s ~ /^[ \t]*$/ }
function indent(s) { match(s, /^ */); return RLENGTH }
function add(r, x, sep) { return r == "" ? x : r sep x }
function rep(c, n,   r) { r = ""; while (n-- > 0) r = r c; return r }
function note(t) { if (!(t in NOTED)) { NOTED[t] = 1; if (refs != "") print "note\t" t > refs } }

# ── Lines ─────────────────────────────────────────────────────────
# HTML comments are dropped — a template's hints are not for the reader —
# and a line that held nothing else goes with them. A leading tab is four
# spaces. Neither is touched inside a fenced block.
function prep(   i, s, fence, incom, p, q, had) {
  N = 0; fence = 0; incom = 0
  for (i = 1; i <= NRAW; i++) {
    s = RAW[i]
    if (!incom && s ~ /^[ \t]*(```|~~~)/) fence = !fence
    if (fence) { L[++N] = s; continue }
    had = !blank(s)
    while (1) {
      if (incom) {
        q = index(s, "-->")
        if (q == 0) { s = ""; break }
        s = substr(s, q + 3); incom = 0
        continue
      }
      p = index(s, "<!--")
      if (p == 0) break
      q = index(substr(s, p + 4), "-->")
      if (q == 0) { s = substr(s, 1, p - 1); incom = 1; break }
      s = substr(s, 1, p - 1) substr(s, p + 4 + q + 2)
    }
    if (had && blank(s)) continue
    while (match(s, /^ *\t/)) s = substr(s, 1, RLENGTH - 1) "    " substr(s, RLENGTH + 1)
    L[++N] = s
  }
}

# ── Block starts ──────────────────────────────────────────────────
function fence_open(s,   ml) {
  if (!match(s, /^ *(```+|~~~+)/)) return 0
  ml = RLENGTH
  FIND = indent(s); if (FIND > 3) return 0
  FRUN = substr(s, FIND + 1, ml - FIND)
  FCH = substr(FRUN, 1, 1)
  FINFO = trim(substr(s, ml + 1))
  if (FCH == "`" && index(FINFO, "`") > 0) return 0
  return 1
}
function is_heading(s) { return indent(s) <= 3 && s ~ /^ *#+([ \t]|$)/ && match(s, /#+/) && RLENGTH <= 6 }
function is_hr(s,   t) {
  if (indent(s) > 3) return 0
  t = s; gsub(/[ \t]/, "", t)
  return t ~ /^(---+|\*\*\*+|___+)$/
}
function is_quote(s) { return indent(s) <= 3 && s ~ /^ *>/ }
# Sets IM_TYPE (ul or ol), IM_CC (the column the content starts at) and
# IM_TEXT (the content on the marker's line).
function is_item(s,   ind, m, rest, sp, ml) {
  if (is_hr(s)) return 0
  if (!match(s, /^ *([-*+]|[0-9]+[.)])/)) return 0
  ml = RLENGTH
  ind = indent(s); if (ind > 3) return 0
  m = substr(s, ind + 1, ml - ind)
  rest = substr(s, ml + 1)
  if (rest != "" && rest !~ /^[ \t]/) return 0
  IM_TYPE = (m ~ /^[0-9]/) ? "ol" : "ul"
  match(rest, /^ */); sp = RLENGTH
  if (rest == "" || blank(rest)) { IM_CC = ind + length(m) + 1; IM_TEXT = ""; return 1 }
  if (sp > 4) sp = 1
  IM_CC = ind + length(m) + sp
  IM_TEXT = substr(rest, sp + 1)
  return 1
}
function is_delim_row(s,   t) {
  t = trim(s)
  if (t !~ /^[|: -]+$/ || index(t, "-") == 0) return 0
  return index(t, "|") > 0 || t ~ /^:?-+:?$/
}
function is_table(i, b) { return i < b && index(L[i], "|") > 0 && is_delim_row(L[i + 1]) }
function starts_block(s) { return blank(s) || fence_open(s) || is_heading(s) || is_hr(s) || is_quote(s) || is_item(s) }

# ── Blocks ────────────────────────────────────────────────────────
# lp is the list prefix of the item the range belongs to ("" at the top):
# inside an item, the first paragraph is the item's own line and everything
# else follows it without a blank line, which in Jira would end the list.
function blocks(a, b, lp,    i, s, R, x, itemed, last_item, sep) {
  R = ""; itemed = 0; last_item = 0
  sep = (lp == "") ? "\n\n" : "\n"
  i = a
  while (i <= b) {
    s = L[i]
    if (blank(s)) { i++; continue }
    if (fence_open(s)) {
      x = code_block(i, b); i = NEXT
    } else if (lp == "" && indent(s) >= 4) {
      x = indented_code(i, b); i = NEXT
    } else if (is_heading(s)) {
      x = heading(s); i++
    } else if (is_hr(s)) {
      x = "----"; i++
    } else if (is_quote(s)) {
      x = quote_block(i, b); i = NEXT
    } else if (is_item(s)) {
      x = list_block(i, b, lp); i = NEXT
      if (lp != "" && !itemed) { R = add(R, lp " ", "\n"); itemed = 1 }
      R = add(R, x, sep); last_item = 0
      continue
    } else if (is_table(i, b)) {
      x = table_block(i, b); i = NEXT
    } else {
      x = para(i, b, lp); i = NEXT
      if (lp != "") {
        if (!itemed) { R = add(R, lp " " x, "\n"); itemed = 1; last_item = 1; continue }
        if (last_item) { R = R " \\\\ " x; continue }
        note("A paragraph that follows a nested list inside a list item was set apart from the list.")
        R = add(R, x, "\n\n"); continue
      }
      R = add(R, x, sep); continue
    }
    if (lp != "") {
      if (!itemed) { R = add(R, lp " ", "\n"); itemed = 1 }
      note("A code block, table, quote or heading inside a list item was placed after the item: Jira lists cannot hold one, and a numbered list starts counting again after it.")
      R = add(R, "\n" x "\n", "\n"); last_item = 0
      continue
    }
    R = add(R, x, sep)
  }
  if (lp != "" && !itemed) R = lp " "
  return R
}

function para(i, b, lp,   R, s, first) {
  R = ""; first = 1
  while (i <= b) {
    s = L[i]
    if (blank(s)) break
    if (!first && (starts_block(s) || is_table(i, b))) break
    s = trim(s); sub(/\\$/, "", s); s = rtrim(s)
    s = guard(inl(s))
    R = first ? s : R ((lp == "") ? "\n" : " ") s
    first = 0; i++
  }
  NEXT = i
  return R
}

# A line whose text begins like a list marker or a block macro would turn
# into one in Jira.
function guard(x) {
  if (x ~ /^([*#-]+ |h[1-6]\. |bq\. )/) return "\\" x
  return x
}

function heading(s,   n, t) {
  t = ltrim(s); match(t, /^#+/); n = RLENGTH
  t = trim(substr(t, n + 1))
  sub(/[ \t]+#+$/, "", t); if (t ~ /^#+$/) t = ""
  return "h" n ". " inl(t)
}

function code_block(i, b,   ch, run, ind, info, R, s, lang, k) {
  fence_open(L[i]); ch = FCH; run = length(FRUN); ind = FIND; info = FINFO
  R = ""; k = 0; i++
  while (i <= b) {
    s = L[i]
    if (indent(s) <= 3 && match(s, "^ *" (ch == "`" ? "```" : "~~~") "+[ \t]*$")) {
      if (length(trim(s)) >= run) { i++; break }
    }
    match(s, /^ */); s = substr(s, (RLENGTH < ind ? RLENGTH : ind) + 1)
    R = (k++ == 0) ? s : R "\n" s
    i++
  }
  NEXT = i
  return code_out(info, R, k)
}

function indented_code(i, b,   R, k, j, last) {
  last = i; j = i
  while (j <= b && (blank(L[j]) || indent(L[j]) >= 4)) { if (!blank(L[j])) last = j; j++ }
  NEXT = last + 1
  R = ""; k = 0
  for (j = i; j <= last; j++) R = (k++ == 0) ? substr(L[j], 5) : R "\n" substr(L[j], 5)
  return code_out("", R, k)
}

function code_out(info, body, k,   lang, open, cls) {
  lang = jira_lang(info)
  if (index(body, "{code") > 0 || index(body, "{noformat") > 0)
    note("A code block holds {code} or {noformat}; Jira may end the block there.")
  if (lang != "") { open = "{code:" lang "}"; cls = "{code}" }
  else { open = "{noformat}"; cls = "{noformat}" }
  return k == 0 ? open "\n" cls : open "\n" body "\n" cls
}

# The language names Jira's code macro knows; anything else is shown as
# plain text rather than as Java, which is what the macro falls back to.
function jira_lang(info,   l) {
  l = tolower(info); sub(/[ \t{].*/, "", l)
  if (l == "") return ""
  if (l == "shell" || l == "sh" || l == "zsh" || l == "console") return "bash"
  if (l == "js" || l == "jsx" || l == "ts" || l == "tsx" || l == "typescript") return "javascript"
  if (l == "py") return "python"
  if (l == "yml") return "yaml"
  if (l == "csharp" || l == "cs") return "c#"
  if (l == "cpp" || l == "cxx") return "c++"
  if (l == "kotlin" || l == "kt") return "java"
  if (l == "golang") return "go"
  if (l == "html" || l == "xhtml" || l == "svg") return "xml"
  if (l ~ /^(actionscript|ada|applescript|bash|c|c#|c\+\+|css|erlang|go|groovy|haskell|java|javascript|json|lua|objc|perl|php|python|r|ruby|scala|sql|swift|visualbasic|xml|yaml)$/) return l
  return ""
}

function quote_block(i, b,   a, s, kind, inner, open, cls, prev, nx) {
  a = N + 1; prev = ""
  while (i <= b) {
    s = L[i]
    if (is_quote(s)) {
      s = ltrim(s); s = substr(s, 2); sub(/^ /, "", s)
    } else if (!blank(s) && !blank(prev) && !starts_block(s)) {
      s = s
    } else break
    L[++N] = s; prev = s; i++
  }
  nx = i
  kind = ""
  if (a <= N && match(L[a], /^ *\[![A-Za-z]+\][ \t]*$/)) {
    kind = toupper(trim(L[a])); gsub(/[^A-Z]/, "", kind)
    if (kind ~ /^(NOTE|TIP|IMPORTANT|WARNING|CAUTION)$/) L[a] = ""
    else kind = ""
  }
  inner = blocks(a, N, "")
  NEXT = nx
  open = "{quote}"
  if (kind == "NOTE" || kind == "IMPORTANT") open = "{info}"
  else if (kind == "TIP") open = "{tip}"
  else if (kind == "WARNING") open = "{note}"
  else if (kind == "CAUTION") open = "{warning}"
  cls = open
  return inner == "" ? open "\n" cls : open "\n" inner "\n" cls
}

function list_block(i, b, lp,   type, cc, mark, a, j, k, t, R, x) {
  is_item(L[i]); type = IM_TYPE
  R = ""
  while (1) {
    cc = IM_CC; mark = (type == "ul") ? "*" : "#"
    a = N + 1; L[++N] = IM_TEXT
    j = i + 1
    while (j <= b) {
      t = L[j]
      if (blank(t)) {
        k = j + 1; while (k <= b && blank(L[k])) k++
        if (k <= b && indent(L[k]) >= cc) { while (j < k) { L[++N] = ""; j++ }; continue }
        break
      }
      if (indent(t) >= cc) { L[++N] = substr(t, cc + 1); j++; continue }
      if (starts_block(t)) break
      if (!blank(L[N])) { L[++N] = ltrim(t); j++; continue }
      break
    }
    x = blocks(a, N, lp mark)
    R = add(R, x, "\n")
    i = j
    k = i; while (k <= b && blank(L[k])) k++
    if (k <= b && is_item(L[k]) && IM_TYPE == type) { i = k; continue }
    break
  }
  NEXT = i
  return R
}

# Cells are split on a pipe that is neither escaped nor inside a code span.
function split_cells(s, C,   n, i, c, cell, run, j) {
  s = trim(s); sub(/^\|/, "", s)
  if (s ~ /[^\\]\|$/ || s == "|") s = substr(s, 1, length(s) - 1)
  n = 0; cell = ""; i = 1
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\\" && i < length(s)) { cell = cell substr(s, i, 2); i += 2; continue }
    if (c == "`") {
      match(substr(s, i), /^`+/); run = RLENGTH
      j = index(substr(s, i + run), substr(s, i, run))
      if (j > 0) { cell = cell substr(s, i, run + j - 1 + run); i += run + j - 1 + run; continue }
      cell = cell substr(s, i, run); i += run; continue
    }
    if (c == "|") { C[++n] = trim(cell); cell = ""; i++; continue }
    cell = cell c; i++
  }
  C[++n] = trim(cell)
  return n
}

function table_block(i, b,   H, C, nh, nc, k, R, row, x) {
  nh = split_cells(L[i], H)
  row = "||"
  for (k = 1; k <= nh; k++) { x = cell_out(H[k]); row = row x "||" }
  R = row
  i += 2
  while (i <= b && !blank(L[i]) && !starts_block(L[i])) {
    nc = split_cells(L[i], C)
    row = "|"
    for (k = 1; k <= nh; k++) { x = (k <= nc) ? cell_out(C[k]) : " "; row = row x "|" }
    if (nc > nh) note("A table row has more cells than its header; the extra cells were dropped.")
    R = R "\n" row
    delete C
    i++
  }
  NEXT = i
  return R
}
function cell_out(s,   x) { x = inl(s); return x == "" ? " " : x }

# ── Inline ────────────────────────────────────────────────────────
function is_word(c) { return c ~ /^[A-Za-z0-9]$/ }
function is_space(c) { return c == "" || c == " " || c == "\t" }
function is_punct(c) { return c != "" && index(PUNCT, c) > 0 }

# A character that is only text. Jira reads markup into a good deal of
# punctuation, so whatever could open or cls something is escaped: a
# brace, a bracket and a pipe always, an exclamation mark that could start
# an image, and *_^~-+ where they touch a word on one side only. A word
# such as SOME_CONST_NAME or 3-D is left alone.
function lit(c, p, q,   open, cls) {
  if (c == "{" || c == "[" || c == "|") return "\\" c
  if (c == "\\") return "&#92;"
  if (c == "!") return is_space(q) ? c : "\\!"
  if (index("*_^~-+", c) > 0) {
    open = (p == "" || is_space(p) || is_punct(p)) && !is_space(q)
    cls = !is_space(p) && (is_space(q) || is_punct(q))
    if (open || cls) return "\\" c
  }
  return c
}

# Text inside {{…}} is still read for markup by Jira, and a brace there
# would end it early.
function mono(s,   i, n, c, r) {
  r = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "}") r = r "\\}"
    else r = r lit(c, i > 1 ? substr(s, i - 1, 1) : "", i < n ? substr(s, i + 1, 1) : "")
  }
  return r
}

function pct_decode(s,   out, p, h, v) {
  out = ""
  while ((p = index(s, "%")) > 0) {
    h = tolower(substr(s, p + 1, 2))
    if (h ~ /^[0-9a-f][0-9a-f]$/) {
      v = (index("0123456789abcdef", substr(h, 1, 1)) - 1) * 16 + index("0123456789abcdef", substr(h, 2, 1)) - 1
      out = out substr(s, 1, p - 1) sprintf("%c", v); s = substr(s, p + 3)
    } else { out = out substr(s, 1, p); s = substr(s, p + 1) }
  }
  return out s
}
function is_remote(u) { return u ~ /^[A-Za-z][A-Za-z0-9+.-]*:/ || u ~ /^\/\// }
function ref(kind, u,   d, name) {
  d = pct_decode(u)
  if (refs != "") print kind "\t" d > refs
  name = d; sub(/\/+$/, "", name); sub(/.*\//, "", name)
  return name
}

# The end of a code span that opens at i, or 0. Sets CRUN.
function code_end(s, i,   run, j) {
  match(substr(s, i), /^`+/); run = RLENGTH; CRUN = run
  j = i + run
  while (j <= length(s)) {
    if (substr(s, j, 1) == "`") {
      match(substr(s, j), /^`+/)
      if (RLENGTH == run) return j
      j += RLENGTH; continue
    }
    j++
  }
  return 0
}

# Where the closing delimiter d of an emphasis opened before `from` sits, or
# 0. Escapes and code spans are stepped over.
function find_close(s, from, d,   n, dl, j, c, pc, nc, ok, e) {
  n = length(s); dl = length(d); j = from
  while (j <= n - dl + 1) {
    c = substr(s, j, 1)
    if (c == "\\") { j += 2; continue }
    if (c == "`") { e = code_end(s, j); j = (e > 0) ? e + CRUN : j + CRUN; continue }
    if (substr(s, j, dl) == d) {
      pc = substr(s, j - 1, 1); nc = substr(s, j + dl, 1)
      ok = (j > from) && !is_space(pc)
      if (dl == 1 && (nc == d || pc == d)) ok = 0
      if (substr(d, 1, 1) == "_" && is_word(nc)) ok = 0
      if (ok) return j
      if (dl == 1 && nc == d) { j += 2; continue }
    }
    j++
  }
  return 0
}

# Parses [text](dest) with `[` at k. Sets LT, LU and LEND, the index after it.
function parse_link(s, k,   n, j, depth, c, e, cls, raw) {
  n = length(s); depth = 0; cls = 0; j = k
  while (j <= n) {
    c = substr(s, j, 1)
    if (c == "\\") { j += 2; continue }
    if (c == "`") { e = code_end(s, j); j = (e > 0) ? e + CRUN : j + CRUN; continue }
    if (c == "[") depth++
    else if (c == "]") { depth--; if (depth == 0) { cls = j; break } }
    j++
  }
  if (!cls || substr(s, cls + 1, 1) != "(") return 0
  LT = substr(s, k + 1, cls - k - 1)
  j = cls + 2
  while (substr(s, j, 1) == " ") j++
  if (substr(s, j, 1) == "<") {
    e = index(substr(s, j + 1), ">"); if (e == 0) return 0
    LU = substr(s, j + 1, e - 1); j = j + e + 1
    while (substr(s, j, 1) == " ") j++
    if (substr(s, j, 1) == "\"") { e = index(substr(s, j + 1), "\""); if (e == 0) return 0; j = j + e + 1 }
    while (substr(s, j, 1) == " ") j++
    if (substr(s, j, 1) != ")") return 0
    LEND = j + 1; return 1
  }
  depth = 0; raw = ""
  while (j <= n) {
    c = substr(s, j, 1)
    if (c == "\\" && j < n) { raw = raw substr(s, j + 1, 1); j += 2; continue }
    if (c == "(") depth++
    else if (c == ")") { if (depth == 0) break; depth-- }
    raw = raw c; j++
  }
  if (j > n) return 0
  sub(/[ \t]+"[^"]*"$/, "", raw); sub(/[ \t]+'[^']*'$/, "", raw)
  LU = trim(raw); LEND = j + 1
  return 1
}

function wrap(m, x, before, after) {
  if (is_word(before) || is_word(after)) return "{" m "}" x "{" m "}"
  return m x m
}

function img(u,   name) {
  if (u == "") return ""
  if (is_remote(u)) return "!" u "!"
  name = ref("image", u)
  return "!" name "!"
}
function link(t, u,   name, x) {
  x = inl(t)
  if (u == "") return x
  if (u ~ /^#/) return "[" (x == "" ? u : x "|" u) "]"
  if (is_remote(u)) return (t == "" || t == u) ? "[" u "]" : "[" x "|" u "]"
  name = ref("file", u)
  return "[" (x == "" ? "^" name : x "|^" name) "]"
}

function inl(s,   out, n, i, c, p, q, j, e, inner, d, u, m, after) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    p = (i > 1) ? substr(s, i - 1, 1) : ""
    q = (i < n) ? substr(s, i + 1, 1) : ""

    if (c == "\\") {
      if (is_punct(q)) { out = out lit(q, p, substr(s, i + 2, 1)); i += 2; continue }
      out = out "&#92;"; i++; continue
    }

    if (c == "`") {
      e = code_end(s, i)
      if (e > 0) {
        inner = substr(s, i + CRUN, e - i - CRUN)
        if (inner ~ /^ .*[^ ].* $/) inner = substr(inner, 2, length(inner) - 2)
        if (inner != "") { out = out "{{" mono(inner) "}}"; i = e + CRUN; continue }
      }
      out = out rep("`", CRUN); i += CRUN; continue
    }

    if ((c == "!" && q == "[") || c == "[") {
      j = (c == "!") ? i + 1 : i
      if (parse_link(s, j)) {
        out = out ((c == "!") ? img(LU) : link(LT, LU))
        i = LEND; continue
      }
    }

    if (c == "<") {
      if (match(substr(s, i), /^<[A-Za-z][A-Za-z0-9+.-]*:[^ <>]*>/)) {
        u = substr(s, i + 1, RLENGTH - 2); out = out "[" u "]"; i += RLENGTH; continue
      }
      if (match(substr(s, i), /^<[^ <>@]+@[^ <>@]+\.[^ <>@]+>/)) {
        u = substr(s, i + 1, RLENGTH - 2); out = out "[mailto:" u "]"; i += RLENGTH; continue
      }
      if (match(substr(s, i), /^<[Bb][Rr] *\/?>/)) { out = out " \\\\ "; i += RLENGTH; continue }
    }

    if ((c == "h" || c == "f") && !is_word(p) && match(substr(s, i), /^(https?|ftp):\/\/[^ \t<>]+/)) {
      u = substr(s, i, RLENGTH); sub(/[.,;:!?'"]+$/, "", u)
      if (u ~ /\)$/ && index(u, "(") == 0) sub(/\)+$/, "", u)
      out = out u; i += length(u); continue
    }

    if ((c == "*" || c == "_") && q == c && !is_space(substr(s, i + 2, 1)) && !(c == "_" && is_word(p))) {
      d = c c
      j = find_close(s, i + 2, d)
      if (j > 0) {
        after = substr(s, j + 2, 1)
        out = out wrap("*", inl(substr(s, i + 2, j - i - 2)), p, after)
        i = j + 2; continue
      }
    }
    if ((c == "*" || c == "_") && q != c && !is_space(q) && !(c == "_" && is_word(p))) {
      j = find_close(s, i + 1, c)
      if (j > 0) {
        after = substr(s, j + 1, 1)
        out = out wrap("_", inl(substr(s, i + 1, j - i - 1)), p, after)
        i = j + 1; continue
      }
    }
    if (c == "~" && q == "~" && !is_space(substr(s, i + 2, 1))) {
      j = find_close(s, i + 2, "~~")
      if (j > 0) {
        after = substr(s, j + 2, 1)
        out = out wrap("-", inl(substr(s, i + 2, j - i - 2)), p, after)
        i = j + 2; continue
      }
    }

    if (c == "@" && (p == "" || is_space(p) || p == "(") && match(substr(s, i + 1), /^[A-Za-z0-9][A-Za-z0-9._-]*/)) {
      m = substr(s, i + 1, RLENGTH); sub(/[._-]+$/, "", m)
      if (!(m in PLAIN)) {
        if (refs != "") print "mention\t" m > refs
        out = out "[~" m "]"; i += 1 + length(m); continue
      }
    }

    out = out lit(c, p, q); i++
  }
  return out
}

BEGIN {
  PUNCT = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"; NRAW = 0
  if (plain != "") while ((getline nm < plain) > 0) if (nm != "") PLAIN[nm] = 1
}
{ sub(/\r$/, ""); RAW[++NRAW] = $0 }
END {
  prep()
  out = blocks(1, N, "")
  if (out != "") printf "%s\n", out
}
