# Markdown to the Confluence storage format (Data Center): the way back of
# html-to-md.awk, for a page written or edited as Markdown.
#
# Run as: LC_ALL=C awk -v refs=<file> -f md-to-storage.awk < in.md > out.xml
#
# Reads Markdown on stdin, writes the page body as storage-format XHTML on
# stdout. Side facts go to `refs`, one per line, tab-separated:
#   image <path>   a local image the text shows; the body names the attachment
#   file  <path>   a local file the text links; the body names the attachment
#   note  <text>   something that was simplified on the way
# A path is local when it has no scheme; it is %-decoded, and the attachment
# is named by its last segment. Whether the file exists is the caller's
# business.
#
# LC_ALL=C, so awk works on bytes, as html-to-md.awk does: every pattern is
# ASCII and any other byte is copied through. The control characters XML
# forbids are dropped.
#
# The whole input is read first and converted at the end, block by block. A
# block that holds blocks of its own — a list item, a quote — has its lines,
# stripped of the indent or the `>`, appended to the same array L and is
# converted by a recursive call over that range, so no awk needs local arrays.
#
# A line break inside a paragraph is kept as <br/>: that is how
# html-to-md.awk wrote one out. Inside a list item or a table cell, lines are
# joined with a space.

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
# nop is set for the content of a list item or a task: its first paragraph
# is written bare, as Confluence writes a list item, rather than in a <p>.
function blocks(a, b, nop,    i, s, R, x, firstp) {
  R = ""; firstp = nop
  i = a
  while (i <= b) {
    s = L[i]
    if (blank(s)) { i++; continue }
    if (fence_open(s)) {
      x = code_block(i, b); i = NEXT
    } else if (!nop && indent(s) >= 4) {
      x = indented_code(i, b); i = NEXT
    } else if (is_heading(s)) {
      x = heading(s); i++
    } else if (is_hr(s)) {
      x = "<hr/>"; i++
    } else if (is_quote(s)) {
      x = quote_block(i, b); i = NEXT
    } else if (is_item(s)) {
      x = list_block(i, b); i = NEXT
    } else if (is_table(i, b)) {
      x = table_block(i, b); i = NEXT
    } else {
      x = para(i, b, nop); i = NEXT
      if (firstp && R == "") x = x
      else x = "<p>" x "</p>"
    }
    R = R x; firstp = 0
  }
  return R
}

function para(i, b, nop,   R, s, first) {
  R = ""; first = 1
  while (i <= b) {
    s = L[i]
    if (blank(s)) break
    if (!first && (starts_block(s) || is_table(i, b))) break
    s = trim(s); sub(/\\$/, "", s); s = rtrim(s)
    s = inl(s)
    R = first ? s : R (nop ? " " : "<br/>") s
    first = 0; i++
  }
  NEXT = i
  return R
}

function heading(s,   n, t) {
  t = ltrim(s); match(t, /^#+/); n = RLENGTH
  t = trim(substr(t, n + 1))
  sub(/[ \t]+#+$/, "", t); if (t ~ /^#+$/) t = ""
  return "<h" n ">" inl(t) "</h" n ">"
}

function code_block(i, b,   ch, run, ind, info, R, s, k) {
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
  return code_out(info, R)
}

function indented_code(i, b,   R, k, j, last) {
  last = i; j = i
  while (j <= b && (blank(L[j]) || indent(L[j]) >= 4)) { if (!blank(L[j])) last = j; j++ }
  NEXT = last + 1
  R = ""; k = 0
  for (j = i; j <= last; j++) R = (k++ == 0) ? substr(L[j], 5) : R "\n" substr(L[j], 5)
  return code_out("", R)
}

function cdata(s) { gsub(/\]\]>/, "]]]]><![CDATA[>", s); return "<![CDATA[" s "]]>" }

function code_out(info, body,   l) {
  # A PlantUML block is the PlantUML macro, as confluence-fetch.sh read it.
  l = tolower(info); sub(/[ \t{].*/, "", l)
  if (l == "plantuml" || l == "puml")
    return "<ac:structured-macro ac:name=\"plantuml\" ac:schema-version=\"1\"><ac:parameter ac:name=\"atlassian-macro-output-type\">INLINE</ac:parameter>" \
      "<ac:plain-text-body>" cdata(body) "</ac:plain-text-body></ac:structured-macro>"
  # Other diagram languages have no macro here: their source is shown as
  # code, which the dry run has to say.
  if (l ~ /^(mermaid|dot|graphviz|d2)$/) { if (!(l in DIAG)) DIAGS = add(DIAGS, l, " "); DIAG[l]++ }
  return "<ac:structured-macro ac:name=\"code\"><ac:parameter ac:name=\"language\">" brush(info) \
    "</ac:parameter><ac:plain-text-body>" cdata(body) "</ac:plain-text-body></ac:structured-macro>"
}

# The name the code macro gives a language; anything it does not know is
# plain text rather than Java, which is what the macro falls back to.
function brush(info,   l) {
  l = tolower(info); sub(/[ \t{].*/, "", l)
  if (l == "javascript" || l == "jsx" || l == "ts" || l == "tsx" || l == "typescript" || l == "json") return "js"
  if (l == "python") return "py"
  if (l == "shell" || l == "sh" || l == "zsh" || l == "console") return "bash"
  if (l == "yaml") return "yml"
  if (l == "html" || l == "xhtml" || l == "svg") return "xml"
  if (l == "c++" || l == "cxx") return "cpp"
  if (l == "csharp" || l == "cs") return "c#"
  if (l == "kotlin" || l == "kt") return "java"
  if (l == "ps1") return "powershell"
  if (l == "erlang") return "erl"
  if (l == "vb" || l == "visualbasic") return "vb"
  if (l ~ /^(actionscript3|applescript|bash|c#|cpp|css|coldfusion|delphi|diff|erl|groovy|java|javafx|js|perl|php|powershell|py|ruby|sass|scala|sql|xml|yml)$/) return l
  return "text"
}

function quote_block(i, b,   a, s, kind, inner, prev, nx, mac) {
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
  inner = blocks(a, N, 0)
  NEXT = nx
  if (kind == "") return "<blockquote>" inner "</blockquote>"
  mac = "info"
  if (kind == "TIP") mac = "tip"
  else if (kind == "WARNING") mac = "note"
  else if (kind == "CAUTION") mac = "warning"
  return "<ac:structured-macro ac:name=\"" mac "\"><ac:rich-text-body>" inner "</ac:rich-text-body></ac:structured-macro>"
}

# The items are collected first — each one's lines appended to L — and only
# then converted, because a list whose every item starts with [ ] or [x] is a
# task list. Their ranges sit on a stack (IA, IB above SP), as the items'
# own nested lists use it too.
function list_block(i, b,   type, cc, a, j, k, t, base, n, z, R, tasks, done, body, tag) {
  is_item(L[i]); type = IM_TYPE
  base = SP; n = 0; tasks = 1
  while (1) {
    cc = IM_CC
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
    n++; IA[base + n] = a; IB[base + n] = N
    if (L[a] !~ /^\[[ xX]\]([ \t]|$)/) tasks = 0
    i = j
    k = i; while (k <= b && blank(L[k])) k++
    if (k <= b && is_item(L[k]) && IM_TYPE == type) { i = k; continue }
    break
  }
  SP = base + n
  if (type != "ul") tasks = 0
  R = ""
  for (z = base + 1; z <= base + n; z++) {
    a = IA[z]
    if (tasks) {
      done = (L[a] ~ /^\[[xX]\]/)
      L[a] = substr(L[a], 4); sub(/^[ \t]+/, "", L[a])
      body = blocks(a, IB[z], 1)
      R = R "<ac:task><ac:task-id>" (++TASKID) "</ac:task-id><ac:task-status>" (done ? "complete" : "incomplete") \
        "</ac:task-status><ac:task-body>" body "</ac:task-body></ac:task>"
    } else {
      R = R "<li>" blocks(a, IB[z], 1) "</li>"
    }
  }
  SP = base
  NEXT = i
  if (tasks) return "<ac:task-list>" R "</ac:task-list>"
  tag = type
  return "<" tag ">" R "</" tag ">"
}

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


function table_block(i, b,   H, C, nh, nc, k, R, row) {
  nh = split_cells(L[i], H)
  row = "<tr>"
  for (k = 1; k <= nh; k++) row = row "<th>" inl(H[k]) "</th>"
  R = "<table><tbody>" row "</tr>"
  i += 2
  while (i <= b && !blank(L[i]) && !starts_block(L[i])) {
    nc = split_cells(L[i], C)
    row = "<tr>"
    for (k = 1; k <= nh; k++) row = row "<td>" ((k <= nc) ? inl(C[k]) : "") "</td>"
    if (nc > nh) note("A table row has more cells than its header; the extra cells were dropped.")
    R = R row "</tr>"
    delete C
    i++
  }
  NEXT = i
  return R "</tbody></table>"
}

# ── Inline ────────────────────────────────────────────────────────
function is_word(c) { return c ~ /^[A-Za-z0-9]$/ }
function is_space(c) { return c == "" || c == " " || c == "\t" }
function is_punct(c) { return c != "" && index(PUNCT, c) > 0 }
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

# Text is XML: & < > and " are escaped wherever they stand. A numeric
# character reference is kept as it is, since it is one already.
function xa(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
function lit(c) {
  if (c == "&") return "&amp;"
  if (c == "<") return "&lt;"
  if (c == ">") return "&gt;"
  if (c == "\"") return "&quot;"
  return c
}

function img(u, alt,   name) {
  if (u == "") return ""
  if (is_remote(u)) return "<ac:image><ri:url ri:value=\"" xa(u) "\"/></ac:image>"
  name = ref("image", u)
  return "<ac:image" (alt != "" ? " ac:alt=\"" xa(alt) "\"" : "") "><ri:attachment ri:filename=\"" xa(name) "\"/></ac:image>"
}
function link(t, u,   name, x) {
  x = inl(t)
  if (u == "") return x
  if (u ~ /^#/ || is_remote(u)) return "<a href=\"" xa(u) "\">" (x == "" ? xa(u) : x) "</a>"
  name = ref("file", u)
  return "<ac:link><ri:attachment ri:filename=\"" xa(name) "\"/>" (x == "" ? "" : "<ac:link-body>" x "</ac:link-body>") "</ac:link>"
}

function inl(s,   out, n, i, c, p, q, j, e, inner, d, u) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    p = (i > 1) ? substr(s, i - 1, 1) : ""
    q = (i < n) ? substr(s, i + 1, 1) : ""

    if (c == "\\") {
      if (is_punct(q)) { out = out lit(q); i += 2; continue }
      out = out c; i++; continue
    }

    if (c == "&" && match(substr(s, i), /^&#([0-9]+|[xX][0-9a-fA-F]+);/)) {
      out = out substr(s, i, RLENGTH); i += RLENGTH; continue
    }

    if (c == "`") {
      e = code_end(s, i)
      if (e > 0) {
        inner = substr(s, i + CRUN, e - i - CRUN)
        if (inner ~ /^ .*[^ ].* $/) inner = substr(inner, 2, length(inner) - 2)
        if (inner != "") { out = out "<code>" xa(inner) "</code>"; i = e + CRUN; continue }
      }
      out = out rep("`", CRUN); i += CRUN; continue
    }

    if ((c == "!" && q == "[") || c == "[") {
      j = (c == "!") ? i + 1 : i
      if (parse_link(s, j)) {
        out = out ((c == "!") ? img(LU, LT) : link(LT, LU))
        i = LEND; continue
      }
    }

    if (c == "<") {
      if (match(substr(s, i), /^<[A-Za-z][A-Za-z0-9+.-]*:[^ <>]*>/)) {
        u = substr(s, i + 1, RLENGTH - 2); out = out "<a href=\"" xa(u) "\">" xa(u) "</a>"; i += RLENGTH; continue
      }
      if (match(substr(s, i), /^<[^ <>@]+@[^ <>@]+\.[^ <>@]+>/)) {
        u = substr(s, i + 1, RLENGTH - 2); out = out "<a href=\"mailto:" xa(u) "\">" xa(u) "</a>"; i += RLENGTH; continue
      }
      if (match(substr(s, i), /^<[Bb][Rr] *\/?>/)) { out = out "<br/>"; i += RLENGTH; continue }
    }

    if ((c == "h" || c == "f") && !is_word(p) && match(substr(s, i), /^(https?|ftp):\/\/[^ \t<>]+/)) {
      u = substr(s, i, RLENGTH); sub(/[.,;:!?'"]+$/, "", u)
      if (u ~ /\)$/ && index(u, "(") == 0) sub(/\)+$/, "", u)
      out = out "<a href=\"" xa(u) "\">" xa(u) "</a>"; i += length(u); continue
    }

    if ((c == "*" || c == "_") && q == c && !is_space(substr(s, i + 2, 1)) && !(c == "_" && is_word(p))) {
      d = c c
      j = find_close(s, i + 2, d)
      if (j > 0) { out = out "<strong>" inl(substr(s, i + 2, j - i - 2)) "</strong>"; i = j + 2; continue }
    }
    if ((c == "*" || c == "_") && q != c && !is_space(q) && !(c == "_" && is_word(p))) {
      j = find_close(s, i + 1, c)
      if (j > 0) { out = out "<em>" inl(substr(s, i + 1, j - i - 1)) "</em>"; i = j + 1; continue }
    }
    if (c == "~" && q == "~" && !is_space(substr(s, i + 2, 1))) {
      j = find_close(s, i + 2, "~~")
      if (j > 0) { out = out "<del>" inl(substr(s, i + 2, j - i - 2)) "</del>"; i = j + 2; continue }
    }

    out = out lit(c); i++
  }
  return out
}

function diagram_notes(   n, i, D, l, w) {
  n = split(DIAGS, D, " ")
  for (i = 1; i <= n; i++) {
    l = D[i]; w = DIAG[l] == 1 ? "1 ```" l " block is" : DIAG[l] " ```" l " blocks are"
    note(w " published as code, not drawn: Confluence shows the diagram's source as text. Only ```plantuml becomes a diagram; rewrite it as PlantUML to have it drawn.")
  }
}

BEGIN {
  PUNCT = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"; NRAW = 0; SP = 0; TASKID = 0
  CTRL = "[" sprintf("%c", 1) "-" sprintf("%c", 8) sprintf("%c", 11) sprintf("%c", 12) sprintf("%c", 14) "-" sprintf("%c", 31) "]"
}
{
  sub(/\r$/, "")
  if (gsub(CTRL, "")) note("Control characters, which a page cannot hold, were dropped.")
  RAW[++NRAW] = $0
}
END {
  prep()
  out = blocks(1, N, 0)
  diagram_notes()
  if (out != "") printf "%s\n", out
}
