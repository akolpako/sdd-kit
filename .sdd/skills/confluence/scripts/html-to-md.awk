# HTML of a Confluence Data Center page (body.export_view) to Markdown.
#
# Run as: LC_ALL=C awk -v origin=<scheme://host[:port]> -v dl=<file> -v notes=<file>
#                     [-v store=<dir> -v npuml=<n> -v nexp=<n>] -f html-to-md.awk
#
# Reads HTML on stdin, writes Markdown on stdout. Every attachment the page
# links or shows is turned into a link under attachments/ and written to `dl`
# as "<download url>\t<local name>", once each; `notes` gets one line for each
# thing the reader should know was simplified. `store` holds what
# storage-macros.awk read from the page's storage format: the sources of the
# PlantUML macros, 1 to `npuml` — the export view has only their rendered
# images, which become the source — and which of the `nexp` expand macros have
# a title of their own.
#
# The input is cut on "<" (RS), so each record is "tag>text" and the page is
# read in one pass however long it is. Simple structure becomes Markdown;
# whatever has no Markdown shape is reduced to its text, never dropped.
#
# LC_ALL=C: every pattern is ASCII and any other byte is copied through, so a
# UTF-8 page comes out byte for byte the same on every awk.

BEGIN {
  npuml += 0; pumlk = 0; nexp += 0; expk = 0; expcap = 0
  if (store != "") for (i = 1; i <= nexp && (getline line < (store "/expand")) > 0; i++) EXPT[i] = (line == "1")
  RS = "<"
  NBSP = sprintf("%c%c", 194, 160)
  init_entities()
  no = 0; nlc = 0; pend = 0
  nps = 0; mk = ""; mkidx = 0
  inli = 0; ld = 0; dd = 0; nas = 0
  pre = 0; prefirst = 0; inh = 0; hmark = ""; pmark = ""
  tdepth = 0; incell = 0; cell = ""; cellbr = 0
  skipdiv = 0; skiptag = ""
  spd = 0; jirask = 0
  incomment = 0
}

NR == 1 { text($0); next }

{
  rec = $0
  if (incomment) {
    p = index(rec, "-->")
    if (p == 0) next
    incomment = 0
    text(substr(rec, p + 3))
    next
  }
  if (substr(rec, 1, 3) == "!--") {
    p = index(substr(rec, 4), "-->")
    if (p == 0) { incomment = 1; next }
    text(substr(rec, p + 6))
    next
  }
  e = tag_end(rec)
  if (e == 0) { text("<" rec); next }
  tag(substr(rec, 1, e - 1))
  text(substr(rec, e + 1))
}

END {
  if (pre) { if (nlc == 0) emit("\n"); emit("```\n") }
  for (i = 1; i <= no; i++) printf "%s", O[i]
  if (no > 0 && lastc() != "\n") printf "\n"
}

# ── Reading tags ──────────────────────────────────────────────────

# Where the tag ends: the first ">" outside a quoted attribute value.
function tag_end(r,   p, i, n, c, q) {
  p = index(r, ">")
  if (p == 0) return 0
  if (substr(r, 1, p) !~ /["']/) return p
  n = length(r); q = ""
  for (i = 1; i <= n; i++) {
    c = substr(r, i, 1)
    if (q != "") { if (c == q) q = "" }
    else if (c == "\"" || c == "'") q = c
    else if (c == ">") return i
  }
  return 0
}

function attr(t, a,   v) {
  if (match(t, "[ \t\r\n]" a "[ \t\r\n]*=[ \t\r\n]*\"[^\"]*\"")) {
    v = substr(t, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); return ent(v)
  }
  if (match(t, "[ \t\r\n]" a "[ \t\r\n]*=[ \t\r\n]*'[^']*'")) {
    v = substr(t, RSTART, RLENGTH); sub(/^[^']*'/, "", v); sub(/'$/, "", v); return ent(v)
  }
  if (match(t, "[ \t\r\n]" a "[ \t\r\n]*=[ \t\r\n]*[^ \t\r\n\"'=<>`/]+")) {
    v = substr(t, RSTART, RLENGTH); sub(/^[^=]*=[ \t\r\n]*/, "", v); return ent(v)
  }
  return ""
}

function hasclass(t, c) { return index(" " attr(t, "class") " ", " " c " ") > 0 }

# ── Output ────────────────────────────────────────────────────────
# The Markdown is kept as a list of chunks, joined once at the end: a link's
# text has to be looked at again when the link closes, and a string grown by
# concatenation would be copied whole on every append.

function emit(s) { if (s != "") O[++no] = s }
function lastc() { return no ? substr(O[no], length(O[no])) : "" }
function at_bol() { return no == 0 || nlc > 0 }

# What starts a line: one entry per open list item ("  ") or quote ("> ").
# The first line of a list item carries its marker instead of the indent.
function prefix(blank,   i, s) {
  s = ""
  for (i = 1; i <= nps; i++) s = s ((i == mkidx && mk != "" && !blank) ? mk : PS[i])
  if (blank) sub(/ +$/, "", s)
  else if (mk != "" && mkidx <= nps) { mk = ""; mkidx = 0 }
  return s
}

# A request for n line ends before the next text: 1 ends the line, 2 leaves a
# blank one. Inside a list item a paragraph ends the line only, so the list
# stays one list.
function brk(n) {
  if (incell) { if (cell != "") cellbr = 1; return }
  if (inh) return
  if (inli && n > 1) n = 1
  if (n > pend) pend = n
}

function flush(   p) {
  if (pend == 0) return
  if (no == 0) { pend = 0; return }
  while (nlc < pend) {
    if (nlc >= 1) { p = prefix(1); emit(p) }
    emit("\n"); nlc++
  }
  pend = 0
}

function line_start() { flush(); if (at_bol()) { emit(prefix(0)); emit(hmark); hmark = ""; nlc = 0 } }

# A whole line, for a fence, a rule or a table row.
function out_line(s) { flush(); if (at_bol()) emit(prefix(0)); emit(s "\n"); nlc = 1 }

# Inline text, whitespace already collapsed. Emphasis opened just before is
# written only now, after any leading space, so "<b> x</b>" is " **x**".
function put(s,   lead) {
  if (s == "") return
  if (incell) { put_cell(s); return }
  if (s ~ /^ +$/) {
    if (at_bol() || pend > 0 || lastc() == " ") return
    emit(" "); return
  }
  if (pend > 0 || at_bol()) { sub(/^ +/, "", s); line_start() }
  else if (lastc() == " ") sub(/^ +/, "", s)
  if (pmark != "") {
    match(s, /^ */); lead = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
    emit(lead); emit(pmark); pmark = ""
  }
  emit(s); nlc = 0
}

function put_cell(s,   lead) {
  if (cellbr) { if (cell != "") cell = cell "<br>"; cellbr = 0; sub(/^ +/, "", s) }
  if (cell == "" || cell ~ / $/ || cell ~ /<br>$/) sub(/^ +/, "", s)
  if (s == "") return
  if (pmark != "") {
    match(s, /^ */); lead = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
    cell = cell lead pmark; pmark = ""
  }
  cell = cell s
}

# Preformatted text: line ends kept, every line given the current prefix.
function put_pre(s,   n, L, i) {
  n = split(s, L, "\n")
  for (i = 1; i <= n; i++) {
    if (L[i] != "") { flush(); if (at_bol()) emit(prefix(0)); emit(L[i]); nlc = 0 }
    if (i < n) { emit("\n"); nlc++ }
  }
}

function text(s) {
  if (s == "" || skipdiv || skiptag != "") return
  if (expcap) { expbuf = expbuf s; return }
  # A Jira issue the browser fills in later: only its key link is real.
  if (jirask && nas == 0) return
  s = ent(s)
  gsub(NBSP, " ", s)
  if (pre) {
    gsub(/\r/, "", s)
    if (prefirst) { sub(/^\n/, "", s); prefirst = 0 }
    if (incell) { gsub(/\|/, "\\|", s); gsub(/\n/, "<br>", s); put_cell(s) }
    else put_pre(s)
    return
  }
  gsub(/[ \t\r\n]+/, " ", s)
  if (tdepth > 0 && !incell) return
  if (incell) gsub(/\|/, "\\|", s)
  put(s)
}

# ── Emphasis and links ────────────────────────────────────────────

function mark_open(m) { if (!pre) pmark = pmark m }

function mark_close(m,   n, tr) {
  if (pre) return
  n = length(pmark) - length(m)
  if (n >= 0 && substr(pmark, n + 1) == m) { pmark = substr(pmark, 1, n); return }
  if (incell) {
    if (cell ~ / $/) { sub(/ $/, "", cell); tr = 1 }
    cell = cell m (tr ? " " : ""); return
  }
  if (lastc() == " ") { O[no] = substr(O[no], 1, length(O[no]) - 1); tr = 1 }
  emit(m); if (tr) emit(" ")
}

function pos() { return incell ? length(cell) : no }

function since(p,   i, s) {
  if (incell) return substr(cell, p + 1)
  s = ""
  for (i = p + 1; i <= no; i++) s = s O[i]
  return s
}

# Cuts back to just before the "[" that opened the link at p.
function cut(p) {
  if (incell) cell = substr(cell, 1, p - 1)
  else { no = p - 1; if (no > 0 && lastc() == "\n") nlc = 1 }
}

function link_open(t,   h) {
  h = attr(t, "href")
  nas++
  if (h == "" || pre) { AU[nas] = ""; return }
  if (hasclass(t, "confluence-userlink") || hasclass(t, "user-mention")) {
    AU[nas] = ""; put("@"); return
  }
  AU[nas] = resolve(h, "")
  put("[")
  AP[nas] = pos()
}

function link_close(   u, p, s) {
  if (nas == 0) return
  u = AU[nas]; p = AP[nas]; nas--
  if (u == "") return
  if (pmark != "") pmark = ""
  s = since(p)
  gsub(/^ +| +$/, "", s)
  if (s == "") { cut(p); return }
  if (s == u) { cut(p); put("<" u ">"); return }
  # A thumbnail that links to its own full-size image is the image.
  if (index(s, "![") == 1 && substr(s, length(s) - length(u) - 1) == "(" u ")") { cut(p); put(s); return }
  if (incell) cell = cell "](" u ")"
  else emit("](" u ")")
}

function image(t,   cls, alt, src, alias, r) {
  alt = attr(t, "alt")
  if (hasclass(t, "emoticon")) { if (alt != "") put(alt); return }
  src = attr(t, "data-image-src")
  if (src == "") src = attr(t, "src")
  if (src == "" || hasclass(t, "icon") || hasclass(t, "userLogo") || src ~ /\/images\/icons\//) return
  if (src ~ /\/rest\/plantuml\// && plantuml()) return
  if (match(src, /\/rest\/[A-Za-z0-9_.-]+\//) && src !~ /\/rest\/plantuml\//)
    note("An image drawn by a macro (" substr(src, RSTART, RLENGTH) "…) was kept as a link to its rendering, which may not last; the macro's own content is not in the file.")
  alias = attr(t, "data-linked-resource-default-alias")
  r = resolve(src, alias)
  if (alt == "") alt = (alias != "") ? alias : LASTNAME
  gsub(/[][]/, "", alt)
  put("![" alt "](" r ")")
}

# The next PlantUML macro, as a fenced block of its source. 0 when there is
# no source to give, and the image stands instead.
function plantuml(   f, line, src, k) {
  if (++pumlk > npuml) {
    note("A PlantUML diagram's source was not found; its image link was kept, and it works only for a few minutes.")
    return 0
  }
  # The page is read cut on "<"; the source is read by lines.
  f = store "/plantuml." pumlk; src = ""; k = 0; RS = "\n"
  while ((getline line < f) > 0) src = (k++ == 0) ? line : src "\n" line
  close(f); RS = "<"
  gsub(/\r/, "", src)
  if (src !~ /[^ \t\n]/) {
    note("A PlantUML macro draws an attachment, not a source of its own; its image link was kept.")
    return 0
  }
  if (incell) { gsub(/\|/, "\\|", src); gsub(/\n/, "<br>", src); put_cell(src); return 1 }
  brk(2); flush()
  out_line("```plantuml")
  put_pre(src)
  if (nlc == 0) { emit("\n"); nlc = 1 }
  out_line("```"); brk(2)
  return 1
}

# The title an expand macro shows on its collapsed section, as a bold line —
# unless the macro has none, and the text is Confluence's default ("Click here
# to expand...", in the reader's language). Without the storage format to say,
# only the English default is known.
function expand_title(   k, titled) {
  expcap = 0
  k = ++expk
  expbuf = ent(expbuf); gsub(NBSP, " ", expbuf); gsub(/[ \t\r\n]+/, " ", expbuf)
  sub(/^ /, "", expbuf); sub(/ $/, "", expbuf)
  titled = (k <= nexp) ? EXPT[k] : (expbuf !~ /^Click here to expand/)
  if (!titled || expbuf == "") return
  brk(2); put("**" expbuf "**"); brk(2)
}

# A link as the page wrote it, made into one that works outside the page: an
# attachment becomes its local copy, a path on the instance becomes absolute,
# anything else is kept.
function resolve(h, alias,   path, seg, id, name, ctx, url, lname, rest) {
  LASTNAME = ""
  if (h ~ /^#/ || h ~ /^(mailto|tel):/) return h
  if (h ~ /^\/\//) h = substr(origin, 1, index(origin, ":")) h
  if (h ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) {
    if (origin == "" || (index(h, origin "/") != 1 && h != origin)) return h
    path = substr(h, length(origin) + 1)
  } else if (h ~ /^\//) path = h
  else return h
  if (match(path, /\/download\/(attachments|thumbnails)\/[0-9]+\/[^?#]+/)) {
    ctx = substr(path, 1, RSTART - 1)
    seg = substr(path, RSTART, RLENGTH)
    sub(/^\/download\/[a-z]+\//, "", seg)
    id = seg; sub(/\/.*/, "", id)
    name = seg; sub(/^[0-9]+\//, "", name)
    url = origin ctx "/download/attachments/" id "/" name
    lname = (alias != "") ? alias : urldec(name)
    LASTNAME = lname
    return "attachments/" register(url, safe(lname), id)
  }
  # Confluence 9 names an image by the page it is embedded in, not by an id.
  if (match(path, /\/download\/(attachments|thumbnails)\/embedded-page\/[^?#]+/)) {
    ctx = substr(path, 1, RSTART - 1)
    seg = substr(path, RSTART, RLENGTH)
    rest = substr(path, RSTART + RLENGTH); sub(/#.*/, "", rest)
    sub(/^\/download\/[a-z]+\//, "", seg)
    name = seg; sub(/.*\//, "", name)
    url = origin ctx "/download/attachments/" seg rest
    lname = (alias != "") ? alias : urldec(name)
    LASTNAME = lname
    return "attachments/" register(url, safe(lname), "page")
  }
  return origin path
}

function register(url, lname, id) {
  if (url in DLNAME) return enc(DLNAME[url])
  if ((lname in TAKEN) && TAKEN[lname] != url) lname = id "-" lname
  TAKEN[lname] = url; DLNAME[url] = lname
  if (dl != "") print url "\t" lname > dl
  return enc(lname)
}

# A name is a name, never a path.
function safe(n) {
  gsub(/[\/\\]/, "_", n)
  gsub(/[\001-\037]/, "", n)
  sub(/^\.+/, "_", n)
  return n == "" ? "file" : n
}

function enc(n) { gsub(/%/, "%25", n); gsub(/ /, "%20", n); gsub(/\(/, "%28", n); gsub(/\)/, "%29", n); return n }

function urldec(s,   out, p, h) {
  out = ""
  while ((p = index(s, "%")) > 0) {
    h = substr(s, p + 1, 2)
    if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) { out = out substr(s, 1, p - 1) sprintf("%c", hex(h)); s = substr(s, p + 3) }
    else { out = out substr(s, 1, p); s = substr(s, p + 1) }
  }
  return out s
}

# ── Tables ────────────────────────────────────────────────────────
# Each cell's text is collected on its own; the table is written when it
# closes, the first row as the header. A merged cell is split back into plain
# ones, the extra ones left empty. A table inside a cell becomes its text.
#
# A row narrower than the table — fewer cells than the widest row, merged
# ones and the ones a cell above reaches into counted — is filled up with
# empty cells at its end and named under NOTES:. On the page such a row may
# be meant that way, or its cells may have been shifted when cells were
# merged or split; Markdown puts every cell after the gap a column too far
# left, and a file published back makes that permanent.

function table_open() {
  if (tdepth++ > 0) { put(" "); return }
  brk(2)
  TR = 0; TC = 0; col = 1; tspan = 0
  delete TV; delete RSP; delete RF
}

function row_open() {
  if (tdepth > 1) { brk(1); return }
  if (tdepth == 1) { TR++; col = 1 }
}

function row_close(   c, f) {
  if (tdepth != 1 || TR == 0) return
  f = col - 1
  for (c = col; c <= TC; c++) if (RSP[c] > 0) { RSP[c]--; f = c }
  RF[TR] = f
}

function cell_open(t) {
  if (tdepth > 1) { put(" "); return }
  if (tdepth != 1) { brk(1); return }
  if (TR == 0) { TR = 1; col = 1 }
  while (RSP[col] > 0) { RSP[col]--; TV[TR, col] = ""; col++ }
  CS = attr(t, "colspan") + 0; if (CS < 1) CS = 1
  RS_ = attr(t, "rowspan") + 0; if (RS_ < 1) RS_ = 1
  incell = 1; cell = ""; cellbr = 0; pmark = ""
}

function cell_close(   k, s) {
  if (tdepth != 1 || !incell) return
  s = cell; gsub(/^ +| +$/, "", s); sub(/(<br>)+$/, "", s)
  TV[TR, col] = s
  for (k = 1; k < CS; k++) TV[TR, col + k] = ""
  if (RS_ > 1) for (k = 0; k < CS; k++) RSP[col + k] = RS_ - 1
  if (CS > 1 || RS_ > 1) tspan = 1
  col += CS
  if (col - 1 > TC) TC = col - 1
  incell = 0; cell = ""; pmark = ""
}

function table_close(   r, c, s) {
  if (tdepth == 1 && incell) cell_close()
  if (--tdepth > 0) return
  if (TR == 0 || TC == 0) return
  for (r = 1; r <= TR; r++) {
    s = "|"
    for (c = 1; c <= TC; c++) s = s " " TV[r, c] " |"
    out_line(s)
    if (r == 1) { s = "|"; for (c = 1; c <= TC; c++) s = s " --- |"; out_line(s) }
  }
  brk(2)
  if (tspan && !NOTED["span"]) { NOTED["span"] = 1; note("A table has merged cells; they were split and the extra cells left empty.") }
  short_rows()
}

# At most n bytes of s, cut short with "...". A UTF-8 character the cut
# went through is dropped whole.
function clip(s, n,   c) {
  if (length(s) <= n) return s
  s = substr(s, 1, n - 3)
  while (s != "") { c = substr(s, length(s), 1); if (c < "") break; s = substr(s, 1, length(s) - 1); if (c >= "À") break }
  return s "..."
}

function short_rows(   r, n, list, h, c) {
  n = 0; list = ""
  for (r = 1; r <= TR; r++) if ((r in RF) && RF[r] < TC) { n++; list = list (list == "" ? "" : ", ") r }
  if (n == 0) return
  h = ""
  for (c = 1; c <= TC; c++) h = h (c > 1 ? " | " : "") TV[1, c]
  h = clip(h, 60)
  note("The table \"" h "\" has " (n == 1 ? "a row" : n " rows") " with fewer cells than the table is wide: " (n == 1 ? "row " : "rows ") list ", the header being row 1. The missing cells were added empty at the end of the row, so its cells may sit a column further left than on the page. Check the table on the page before this file is published back.")
}

function note(s) { if (notes != "" && !(s in NOTEONCE)) { NOTEONCE[s] = 1; print s > notes } }

# ── Tags ──────────────────────────────────────────────────────────

function tag(t,   isclose, name, n, m, lang, a) {
  if (t ~ /^[!?]/) return
  isclose = (substr(t, 1, 1) == "/")
  if (!match(t, /^\/?[A-Za-z][A-Za-z0-9:-]*/)) { text("<" t ">"); return }
  name = tolower(substr(t, RSTART + isclose, RLENGTH - isclose))

  if (skiptag != "") { if (isclose && name == skiptag) skiptag = ""; return }
  if (skipdiv) {
    if (name == "div") {
      if (isclose) { if (--skipdiv == 0) brk(2) }
      else if (t !~ /\/[ \t\r\n]*$/) skipdiv++
    }
    return
  }

  if (name == "script" || name == "style" || name == "noscript" || name == "template") {
    if (!isclose && t !~ /\/[ \t\r\n]*$/) skiptag = name
    return
  }

  if (pre && name != "pre" && name != "br") return

  if (name == "span") {
    if (isclose) {
      if (expcap && spd == expcap) expand_title()
      if (jirask && spd == jirask) jirask = 0; if (spd > 0) spd--; return
    }
    if (t ~ /\/[ \t\r\n]*$/) return
    spd++
    if (!expcap && hasclass(t, "expand-control-text")) { expcap = spd; expbuf = ""; return }
    if (!jirask && hasclass(t, "jira-issue") && attr(t, "data-client-id") != "") jirask = spd
    if (hasclass(t, "plantuml-svg-image")) plantuml()
    return
  }

  if (name ~ /^h[1-6]$/) {
    if (incell) { if (isclose) mark_close("**"); else mark_open("**"); return }
    if (isclose) { inh = 0; hmark = ""; brk(2); return }
    brk(2); n = substr(name, 2) + 0
    hmark = substr("###### ", 7 - n); inh = 1
    return
  }

  if (name == "p" || name == "section" || name == "article" || name == "header" || name == "footer" \
      || name == "figure" || name == "figcaption" || name == "address" || name == "center" || name == "dl") { brk(2); return }
  if (name == "dt" || name == "dd" || name == "caption") { brk(1); return }

  if (name == "div") {
    if (isclose) {
      if (dd == 0) { brk(2); return }
      a = DA[dd]; if (a == "q") nps = DN[dd]
      dd--; brk(2); return
    }
    if (t ~ /\/[ \t\r\n]*$/) return
    if (hasclass(t, "toc-macro") || hasclass(t, "client-side-toc-macro")) { skipdiv = 1; return }
    dd++; DA[dd] = ""; DN[dd] = nps
    brk(2)
    m = admonition(t)
    if (m != "" || (hasclass(t, "panel") && !hasclass(t, "code") && !hasclass(t, "preformatted"))) {
      flush(); DA[dd] = "q"; PS[++nps] = "> "
      if (m != "") { put("[!" m "]"); brk(1) }
    }
    return
  }

  if (name == "blockquote") {
    if (isclose) { if (dd > 0) { nps = DN[dd]; dd-- }; brk(2); return }
    brk(2); flush(); dd++; DA[dd] = "q"; DN[dd] = nps; PS[++nps] = "> "
    return
  }

  if (name == "ul" || name == "ol") {
    if (isclose) { if (ld > 0) ld--; brk(inli ? 1 : 2); return }
    brk(inli ? 1 : 2)
    ld++; LT[ld] = name; LN[ld] = 0; LK[ld] = hasclass(t, "inline-task-list")
    return
  }

  if (name == "li") {
    if (incell) { if (!isclose) { brk(1); put("• ") } ; return }
    if (isclose) {
      if (inli == 0) return
      nps = LI[inli] - 1; inli--
      if (mkidx > nps) { mk = ""; mkidx = 0 }
      brk(1); return
    }
    brk(1)
    if (ld == 0) { ld = 1; LT[ld] = "ul"; LN[ld] = 0; LK[ld] = 0 }
    LN[ld]++
    m = (LT[ld] == "ol") ? LN[ld] ". " : "- "
    PS[++nps] = sprintf("%" length(m) "s", "")
    if (LK[ld]) m = m (hasclass(t, "checked") ? "[x] " : "[ ] ")
    mk = m; mkidx = nps
    inli++; LI[inli] = nps
    return
  }

  if (name == "pre") {
    if (isclose) {
      if (!pre) return
      pre = 0
      if (incell) return
      if (since(PRE1) !~ /[^[:space:]]/) { no = PRE0; nlc = PRENLC; brk(2); return }
      if (nlc == 0) { emit("\n"); nlc = 1 }
      out_line("```"); brk(2); return
    }
    pre = 1; prefirst = 1
    if (incell) return
    lang = attr(t, "data-syntaxhighlighter-params")
    if (match(lang, /brush: *[A-Za-z0-9+#-]+/)) { lang = substr(lang, RSTART, RLENGTH); sub(/brush: */, "", lang) } else lang = ""
    if (lang == "" && match(attr(t, "class"), /language-[A-Za-z0-9+#-]+/)) lang = substr(attr(t, "class"), RSTART + 9, RLENGTH - 9)
    lang = brush(lang)
    brk(2); flush(); PRE0 = no; PRENLC = nlc
    out_line("```" lang); PRE1 = no
    return
  }

  if (name == "br") {
    if (pre) { if (incell) put_cell("<br>"); else { emit("\n"); nlc++ }; return }
    if (incell) { cellbr = 1; return }
    if (inh) { put(" "); return }
    brk(1); return
  }

  if (name == "hr") { brk(2); out_line("---"); brk(2); return }

  if (name == "table") { if (isclose) table_close(); else table_open(); return }
  if (name == "tr") { if (isclose) row_close(); else row_open(); return }
  if (name == "td" || name == "th") {
    if (isclose) { if (tdepth == 1) cell_close(); return }
    cell_open(t); return
  }

  if (name == "a") { if (isclose) link_close(); else link_open(t); return }
  if (name == "img") { if (!isclose) image(t); return }

  if (name == "strong" || name == "b") { if (isclose) mark_close("**"); else mark_open("**"); return }
  if (name == "em" || name == "i" || name == "cite" || name == "var") { if (isclose) mark_close("*"); else mark_open("*"); return }
  if (name == "del" || name == "s" || name == "strike") { if (isclose) mark_close("~~"); else mark_open("~~"); return }
  if (name == "code" || name == "tt" || name == "kbd" || name == "samp") { if (isclose) mark_close("`"); else mark_open("`"); return }
  if (name == "q") { put("\""); return }
}

# An info, tip, note or warning macro, as a GitHub alert.
function admonition(t) {
  if (hasclass(t, "confluence-information-macro-information")) return "NOTE"
  if (hasclass(t, "confluence-information-macro-tip")) return "TIP"
  if (hasclass(t, "confluence-information-macro-note")) return "WARNING"
  if (hasclass(t, "confluence-information-macro-warning")) return "CAUTION"
  return ""
}

# The name the code macro gives a language, as a Markdown fence names it.
function brush(b) {
  b = tolower(b)
  if (b == "js" || b == "jscript") return "javascript"
  if (b == "py") return "python"
  if (b == "ps" || b == "powershell") return "powershell"
  if (b == "shell" || b == "sh") return "bash"
  if (b == "csharp" || b == "c#") return "csharp"
  if (b == "cpp" || b == "c++") return "cpp"
  if (b == "plain" || b == "text" || b == "none") return ""
  if (b == "yml") return "yaml"
  if (b == "html" || b == "xhtml") return "html"
  return b
}

# ── Entities ──────────────────────────────────────────────────────

function ent(s,   out, p, e, cp) {
  if (index(s, "&") == 0) return s
  out = ""
  while ((p = index(s, "&")) > 0) {
    out = out substr(s, 1, p - 1)
    s = substr(s, p)
    if (match(s, /^&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/)) {
      e = substr(s, 2, RLENGTH - 2)
      if (e ~ /^#[xX]/) cp = hex(substr(e, 3))
      else if (e ~ /^#/) cp = substr(e, 2) + 0
      else if (e in NAMED) cp = NAMED[e]
      else cp = -1
      if (cp == 160) cp = 32
      if (cp > 0) out = out utf8(cp)
      else if (cp < 0) out = out substr(s, 1, RLENGTH)
      s = substr(s, RLENGTH + 1)
    } else { out = out "&"; s = substr(s, 2) }
  }
  return out s
}

function hex(h,   i, v) {
  v = 0; h = tolower(h)
  for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return v
}

function utf8(c) {
  if (c < 128) return sprintf("%c", c)
  if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
  if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
  return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64, 128 + int(c / 64) % 64, 128 + c % 64)
}

function init_entities(   list, n, i, kv) {
  list = "amp=38 lt=60 gt=62 quot=34 apos=39 nbsp=32 shy=0 ndash=8211 mdash=8212 hellip=8230 " \
         "lsquo=8216 rsquo=8217 sbquo=8218 ldquo=8220 rdquo=8221 bdquo=8222 laquo=171 raquo=187 " \
         "bull=8226 middot=183 copy=169 reg=174 trade=8482 deg=176 plusmn=177 times=215 divide=247 " \
         "le=8804 ge=8805 ne=8800 asymp=8776 larr=8592 rarr=8594 uarr=8593 darr=8595 harr=8596 " \
         "lArr=8656 rArr=8658 hArr=8660 euro=8364 pound=163 yen=165 cent=162 sect=167 para=182 " \
         "iexcl=161 iquest=191 frac12=189 frac14=188 frac34=190 sup2=178 sup3=179 micro=181 " \
         "check=10003 zwj=8205 zwnj=8204 thinsp=32 ensp=32 emsp=32"
  n = split(list, kv, " ")
  for (i = 1; i <= n; i++) { split(kv[i], P, "="); NAMED[P[1]] = P[2] + 0 }
}
