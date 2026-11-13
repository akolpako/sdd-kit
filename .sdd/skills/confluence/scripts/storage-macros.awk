# What the export view of a page loses about its macros, read from the page's
# storage format (body.storage).
#
# Run as: LC_ALL=C awk -v dir=<directory> -f storage-macros.awk < storage.xml
#
# Writes, in the order the macros stand on the page — the order their output
# stands in the export view:
#   <dir>/plantuml.<n>  the source of the n-th macro whose name starts with
#                       "plantuml"; empty for one that draws an attachment, so
#                       the count stays in step with the images
#   <dir>/expand        one line per expand macro: 1 when it has a title of its
#                       own, 0 when Confluence shows its default text instead
#   <dir>/macros        the name of every macro, one per line
# Prints "<plantuml count> <expand count>".

{ s = s $0 "\n" }

END {
  all = s; np = 0; ne = 0
  printf "" > (dir "/expand"); printf "" > (dir "/macros")
  while ((p = index(s, "<ac:structured-macro")) > 0) {
    s = substr(s, p)
    e = index(s, ">")
    if (e == 0) break
    t = substr(s, 1, e)
    s = substr(s, e + 1)
    name = ""
    if (match(t, /ac:name="[^"]*"/)) name = tolower(substr(t, RSTART + 9, RLENGTH - 10))
    if (name != "") print name > (dir "/macros")
    # Up to the end of this macro, or into the next one: its own parameters
    # and plain body stand before either.
    q = index(s, "</ac:structured-macro>")
    seg = (q > 0) ? substr(s, 1, q - 1) : s
    q = index(seg, "<ac:structured-macro")
    if (q > 0) seg = substr(seg, 1, q - 1)

    if (name == "expand") {
      ne++
      titled = 0
      b = index(seg, "<ac:parameter ac:name=\"title\">")
      if (b > 0) {
        v = substr(seg, b + 30)
        c = index(v, "</ac:parameter>")
        if (c > 0) v = substr(v, 1, c - 1)
        titled = (unesc(v) ~ /[^ \t\r\n]/)
      }
      print titled > (dir "/expand")
      continue
    }

    if (name !~ /^plantuml/) continue
    body = ""
    b = index(seg, "<ac:plain-text-body>")
    if (b > 0) {
      seg = substr(seg, b + 20)
      c = index(seg, "</ac:plain-text-body>")
      if (c > 0) seg = substr(seg, 1, c - 1)
      body = text(seg)
    }
    file = dir "/plantuml." (++np)
    printf "%s", body > file
    close(file)
  }
  # An older page may still use the macro element of the first storage format.
  s = all
  while ((p = index(s, "<ac:macro ")) > 0) {
    s = substr(s, p + 10)
    if (match(s, /^[^>]*ac:name="[^"]*"/)) {
      t = substr(s, 1, RLENGTH); sub(/.*ac:name="/, "", t); sub(/"$/, "", t)
      print tolower(t) > (dir "/macros")
    }
  }
  close(dir "/expand"); close(dir "/macros")
  print np, ne
}

# The text of a plain-text body: CDATA sections as they are — a body holding
# "]]>" is split over two of them — and what stands outside one unescaped.
function text(seg,   out, p, c) {
  out = ""
  while ((p = index(seg, "<![CDATA[")) > 0) {
    out = out unesc(substr(seg, 1, p - 1))
    seg = substr(seg, p + 9)
    c = index(seg, "]]>")
    if (c == 0) { out = out seg; seg = ""; break }
    out = out substr(seg, 1, c - 1)
    seg = substr(seg, c + 3)
  }
  return out unesc(seg)
}

function unesc(x) {
  gsub(/&lt;/, "<", x); gsub(/&gt;/, ">", x); gsub(/&quot;/, "\"", x); gsub(/&apos;/, "'", x)
  gsub(/&#39;/, "'", x); gsub(/&amp;/, "\\&", x)
  return x
}
