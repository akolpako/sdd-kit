# Jira wiki markup (an issue description, Server / Data Center) to Markdown.
#
# Run as: LC_ALL=C awk -v dl=<file> -f wiki-to-md.awk
#
# Reads the wiki text on stdin, writes Markdown on stdout. Every attachment the
# text shows (!name.png!) or links ([^name.pdf]) becomes a link under
# attachments/ and its name is written to `dl`, once each, in the order it
# first appears.
#
# LC_ALL=C, so awk works on bytes. Every pattern below is ASCII and any other
# byte is copied through untouched, which makes the conversion the same
# everywhere; left to the locale, an awk that decodes UTF-8 can stop on a byte
# it does not recognise and answer with nothing at all.
#
# Order matters. A code block is recognised before anything else is looked at
# and nothing inside one is converted, or a Java generic would become a list
# and an underscore in an identifier would become emphasis.
#
# Three shapes below look like defensive programming and are not. All three
# occur in real issues, and each one breaks a line-by-line replacement written
# against the documented syntax:
#   * a list marker carries a leading space — the line reads " * item", so a
#     ^\* pattern matches none of them;
#   * a heading can sit flush against the paragraph above it, and converted
#     as-is it stops being a heading in Markdown, so a blank line is inserted;
#   * a line can hold a single space, which reads as indentation if left alone.

# Inline conversions are stashed as tokens and put back at the end of the
# line: a converted link must not be searched for emphasis, or a URL holding
# an underscore would come back italicised.
function rep_esc(s) { gsub(/\\/, "\\\\", s); gsub(/&/, "\\&", s); return s }
function stash(s,   k) { NTOK++; k = sprintf("\001%d\002", NTOK); TOK[k] = s; return k }
function unstash(s,   k, i) {
  for (i = 0; i < 6; i++) {
    if (s !~ /\001[0-9]+\002/) break
    for (k in TOK) if (index(s, k) > 0) gsub(k, rep_esc(TOK[k]), s)
  }
  return s
}
function is_word(c) { return c ~ /^[A-Za-z0-9]$/ }
function enc_spaces(s) { gsub(/ /, "%20", s); return s }
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

# An attachment the text refers to, by name: listed for download once, and
# linked under attachments/ however often it appears.
function att(fn) {
  if (!(fn in SEEN)) { SEEN[fn] = 1; if (dl != "") print fn > dl }
  return "attachments/" enc_spaces(fn)
}

# Jira breaks markup up with an empty macro. {*}bold{*} is written where a
# plain *bold* would run into the character next to it, and {{{}mono{}}}
# where the monospace text itself begins or ends with a brace. The empty
# braces render as nothing. Only these shapes are undone: a bare {} anywhere
# else is left alone, or an empty Java block in a sentence would disappear.
function unbrace(s) {
  gsub(/\{\{\{\}/, "{{", s)
  gsub(/\{\}\}\}/, "}}", s)
  gsub(/\{\*\}/, "*", s)
  gsub(/\{_\}/, "_", s)
  return s
}

function conv_mono(s,   out, p, tail, q, inner) {
  out = ""
  while ((p = index(s, "{{")) > 0) {
    tail = substr(s, p + 2)
    q = index(tail, "}}")
    if (q == 0) break
    inner = substr(tail, 1, q - 1)
    out = out substr(s, 1, p - 1) stash("`" inner "`")
    s = substr(tail, q + 2)
  }
  return out s
}

# !name.png!, !name.png|thumbnail! and !name.png|width=300! are the same
# link: the options are a rendering hint Markdown has no place for. The file
# name is required to carry an extension and to start right after the mark,
# so a bare pair of exclamation marks around a sentence is left alone; a space
# inside the name is fine, Jira allows one. An image given by its URL is
# linked where it is and not downloaded.
function conv_images(s,   out, rest, m, tok, bar, fn) {
  out = ""; rest = s
  while (match(rest, /![^!|[:space:]][^!|]*\.[A-Za-z0-9]+(\|[^!]*)?!/)) {
    m = substr(rest, RSTART, RLENGTH)
    tok = substr(m, 2, length(m) - 2)
    bar = index(tok, "|")
    fn = (bar > 0) ? substr(tok, 1, bar - 1) : tok
    out = out substr(rest, 1, RSTART - 1)
    if (fn ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) out = out stash("![](" fn ")")
    else out = out stash("![" fn "](" att(fn) ")")
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out rest
}

# [text|url], [url], [^attachment], [text|^attachment] and [~user].
function conv_links(s,   out, rest, m, inner, bar, text, url) {
  out = ""; rest = s
  while (match(rest, /\[[^][]*\]/)) {
    m = substr(rest, RSTART, RLENGTH)
    inner = substr(m, 2, length(m) - 2)
    bar = index(inner, "|")
    out = out substr(rest, 1, RSTART - 1)
    text = (bar > 0) ? substr(inner, 1, bar - 1) : ""
    url = (bar > 0) ? substr(inner, bar + 1) : inner
    if (url ~ /^\^./) {
      url = substr(url, 2)
      out = out stash("[" (text != "" ? text : url) "](" att(url) ")")
    } else if (bar == 0 && url ~ /^~[^[:space:]]+$/) {
      out = out stash("@" substr(url, 2))
    } else if (bar > 0) {
      out = out stash("[" text "](" url ")")
    } else if (url ~ /^(https?|ftp|mailto):/) {
      out = out stash("<" url ">")
    } else {
      out = out stash(m)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out rest
}

# A delimiter only opens emphasis where a word does not already run into it.
# That single test is what keeps SOME_CONST_NAME out of italics without
# escaping the underscore: escaping corrupts the identifier for anyone who
# copies it back out.
function conv_emph(s, d, wrap,   out, rest, p, before, pre, prevc, tail, q, inner, nextc) {
  out = ""; rest = s
  while ((p = index(rest, d)) > 0) {
    before = substr(rest, 1, p - 1)
    pre = out before
    prevc = (pre == "") ? "" : substr(pre, length(pre), 1)
    tail = substr(rest, p + 1)
    q = index(tail, d)
    inner = (q > 1) ? substr(tail, 1, q - 1) : ""
    nextc = (q > 1) ? substr(tail, q + 1, 1) : ""
    if (q > 1 && !is_word(prevc) && prevc != d && nextc != d && !is_word(nextc) &&
        inner !~ /^[[:space:]]/ && inner !~ /[[:space:]]$/) {
      out = pre stash(wrap inner wrap)
      rest = substr(tail, q + 1)
    } else {
      out = pre d
      rest = tail
    }
  }
  return out rest
}

# A wrapper that carries no meaning outside Jira: the text it holds stays,
# the wrapper goes.
function drop_wrappers(s) {
  gsub(/\{color:[^}]*\}/, "", s)
  gsub(/\{color\}/, "", s)
  gsub(/\{panel:[^}]*\}/, "", s)
  gsub(/\{panel\}/, "", s)
  gsub(/\{anchor:[^}]*\}/, "", s)
  return s
}

function conv_inline(s) {
  s = drop_wrappers(s)
  s = unbrace(s)
  s = conv_mono(s)
  s = conv_images(s)
  s = conv_links(s)
  s = conv_emph(s, "*", "**")
  s = conv_emph(s, "_", "*")
  return unstash(s)
}

function out_line(l) { NL++; LINES[NL] = l }
function emit(l) { out_line(inquote ? "> " l : l) }
function need_blank() { if (NL > 0 && LINES[NL] != "") out_line("") }

BEGIN {
  NL = 0; NTOK = 0; incode = 0; inquote = 0; waslist = 0; intable = 0
  NBSP = sprintf("%c%c", 194, 160)
}

{
  line = $0
  sub(/\r$/, "", line)

  # A non-breaking space is a space in everything this converter decides, and
  # Jira issues are full of them: they arrive with pasted text. Reading bytes,
  # nothing here would recognise one — a list marker followed by one would
  # keep it as the first character of the item, and a line holding nothing
  # else would read as indentation rather than as the blank line it looks
  # like. The character itself is not worth preserving; how it renders is.
  gsub(NBSP, " ", line)

  if (incode) {
    if (line ~ /^[[:space:]]*\{(code|noformat)\}[[:space:]]*$/) {
      out_line("```"); out_line(""); incode = 0
    } else out_line(line)
    next
  }

  if (line ~ /^[[:space:]]*\{(code|noformat)(:[^}]*)?\}[[:space:]]*$/) {
    lang = ""
    if (match(line, /\{code:[^}]*\}/)) {
      spec = substr(line, RSTART + 6, RLENGTH - 7)
      n = split(spec, parts, "|")
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^language=/) lang = substr(parts[i], 10)
        else if (index(parts[i], "=") == 0 && lang == "") lang = parts[i]
      }
    }
    need_blank()
    out_line("```" lang)
    incode = 1; waslist = 0; intable = 0
    next
  }

  if (line ~ /^[[:space:]]*\{quote\}[[:space:]]*$/) {
    inquote = !inquote; need_blank(); waslist = 0; intable = 0
    next
  }

  if (line ~ /^[[:space:]]*$/) { out_line(""); waslist = 0; intable = 0; next }

  if (line ~ /^[[:space:]]*h[1-6]\./) {
    t = trim(line)
    lvl = substr(t, 2, 1) + 0
    text = substr(t, 4); sub(/^[[:space:]]+/, "", text)
    hashes = ""
    for (i = 0; i < lvl; i++) hashes = hashes "#"
    need_blank()
    emit(hashes " " conv_inline(text))
    out_line("")
    waslist = 0; intable = 0
    next
  }

  # One branch for both kinds of list, because Jira mixes them: "#*" is a
  # bullet inside a numbered item. The marker does not always spell the whole
  # path, though — a nested bullet under a numbered item is often written
  # "**" — so the kind of each level is remembered from the line that opened
  # it. The indent has to clear the marker of the parent: three columns under
  # "1. ", two under "- ". Two under a numbered parent and Markdown reads the
  # nested item as a paragraph of its own and the nesting is lost.
  if (match(line, /^[[:space:]]*[*#]+[[:space:]]+/)) {
    marks = substr(line, RSTART, RLENGTH); gsub(/[^*#]/, "", marks)
    text = substr(line, RSTART + RLENGTH)
    if (!waslist) { split("", LTYPE); need_blank() }
    depth = length(marks)
    ind = ""
    for (i = 1; i < depth; i++) {
      if (!(i in LTYPE)) LTYPE[i] = substr(marks, i, 1)
      ind = ind (LTYPE[i] == "#" ? "   " : "  ")
    }
    LTYPE[depth] = substr(marks, depth, 1)
    emit(ind (LTYPE[depth] == "#" ? "1. " : "- ") conv_inline(text))
    waslist = 1; intable = 0
    next
  }

  # The header row of a table brings the alignment row with it: Markdown has
  # no table without one, and Jira has no row that says where it goes.
  if (line ~ /^[[:space:]]*\|\|/) {
    row = trim(line); sub(/^\|\|/, "", row); sub(/\|\|$/, "", row)
    n = split(row, cells, /\|\|/)
    o = "|"; sep = "|"
    for (i = 1; i <= n; i++) { o = o " " conv_inline(trim(cells[i])) " |"; sep = sep " --- |" }
    if (!intable) need_blank()
    emit(o); emit(sep)
    intable = 1; waslist = 0
    next
  }

  if (line ~ /^[[:space:]]*\|/) {
    row = trim(line); sub(/^\|/, "", row); sub(/\|$/, "", row)
    n = split(row, cells, /\|/)
    o = "|"
    for (i = 1; i <= n; i++) o = o " " conv_inline(trim(cells[i])) " |"
    if (!intable) need_blank()
    emit(o)
    intable = 1; waslist = 0
    next
  }

  emit(conv_inline(line))
  waslist = 0; intable = 0
}

END { for (i = 1; i <= NL; i++) print LINES[i] }
