# The shape of every table in a body in the storage format, the way
# confluence-publish.sh compares the page it replaces with the file.
#
# Run as: LC_ALL=C awk -f table-shapes.awk < body.xml
#
# One line per table that is not inside another, tab-separated:
#   <rows> <columns> <merged: 0|1> <short rows, as "3, 5", or -> <header>
# A row's width counts the columns a merged cell spans and the cells of the
# rows above that reach down into it; a short row is narrower than the table.
# The header is the text of the first row's cells joined by " | ", cut at 60
# bytes. A table inside a cell is not counted, nor is anything in CDATA — the
# body of a code macro can show a <table> of its own.
#
# The input is cut on "<", as html-to-md.awk cuts it.

BEGIN { RS = "<"; depth = 0; incdata = 0 }

NR == 1 { next }

{
  rec = $0
  if (incdata) { if (index(rec, "]]>") > 0) incdata = 0; next }
  if (substr(rec, 1, 8) == "![CDATA[") { if (index(rec, "]]>") == 0) incdata = 1; next }
  p = index(rec, ">"); if (p == 0) next
  t = substr(rec, 1, p - 1)
  if (match(t, /^\/?[A-Za-z][A-Za-z0-9:-]*/)) {
    isclose = (substr(t, 1, 1) == "/")
    name = tolower(substr(t, RSTART + isclose, RLENGTH - isclose))
    selfclose = (t ~ /\/[ \t\r\n]*$/)
    if (name == "table") {
      if (isclose) { if (depth == 1) table_out(); if (depth > 0) depth-- }
      else if (!selfclose) { if (++depth == 1) { TR = 0; TC = 0; merged = 0; H = ""; incell = 0; delete RSP; delete RF } }
    } else if (depth == 1 && name == "tr") {
      if (isclose) row_close()
      else { TR++; col = 1 }
    } else if (depth == 1 && (name == "td" || name == "th")) {
      if (isclose) incell = 0
      else {
        if (TR == 0) { TR = 1; col = 1 }
        cell_open(t)
        if (selfclose) incell = 0
      }
    }
  }
  if (depth == 1 && incell && TR == 1) H = H substr(rec, p + 1)
}

function attr(t, a,   v) {
  if (match(t, "[ \t\r\n]" a "[ \t\r\n]*=[ \t\r\n]*(\"[^\"]*\"|'[^']*'|[^ \t\r\n\"'=<>`/]+)")) {
    v = substr(t, RSTART, RLENGTH); sub(/^[^=]*=[ \t\r\n]*/, "", v); gsub(/["']/, "", v); return v
  }
  return ""
}

function cell_open(t,   cs, rs, k) {
  while (RSP[col] > 0) { RSP[col]--; col++ }
  cs = attr(t, "colspan") + 0; if (cs < 1) cs = 1
  rs = attr(t, "rowspan") + 0; if (rs < 1) rs = 1
  if (cs > 1 || rs > 1) merged = 1
  if (rs > 1) for (k = 0; k < cs; k++) RSP[col + k] = rs - 1
  if (TR == 1 && col > 1) H = H " | "
  col += cs
  if (col - 1 > TC) TC = col - 1
  incell = 1
}

function row_close(   c, f) {
  if (TR == 0) return
  f = col - 1
  for (c = col; c <= TC; c++) if (RSP[c] > 0) { RSP[c]--; f = c }
  RF[TR] = f
  incell = 0
}

function table_out(   r, list, h) {
  list = ""
  for (r = 1; r <= TR; r++) if ((r in RF) && RF[r] < TC) list = list (list == "" ? "" : ", ") r
  h = H
  gsub(/&nbsp;|&#160;/, " ", h); gsub(/&lt;/, "<", h); gsub(/&gt;/, ">", h)
  gsub(/&quot;/, "\"", h); gsub(/&#39;|&apos;/, "'", h); gsub(/&amp;/, "\\&", h)
  gsub(/[ \t\r\n]+/, " ", h); sub(/^ /, "", h); sub(/ $/, "", h)
  printf "%d\t%d\t%d\t%s\t%s\n", TR, TC, merged, (list == "" ? "-" : list), clip(h, 60)
}

function clip(s, n,   c) {
  if (length(s) <= n) return s
  s = substr(s, 1, n - 3)
  while (s != "") { c = substr(s, length(s), 1); if (c < "\200") break; s = substr(s, 1, length(s) - 1); if (c >= "\300") break }
  return s "..."
}
