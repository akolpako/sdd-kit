# shellcheck shell=bash
# The reader of `.sdd/sdd.conf`, in one place.
#
# Sourced, never run. lib/log.sh sources it before anything else and must not
# fail a script, so it is sourced behind a readability test and called only when
# defined.
#
#   sdd_conf_read <file> <ERE> [n]
#       one `KEY=value` line per line of the file whose key matches <ERE>, in
#       file order — a key set twice comes out twice, and the reader takes the
#       last, as a shell would. With `n`, each line is prefixed `<line>|`: the
#       line number that `spec-edit.sh conf-set` rewrites.
#
# The file is parsed, never sourced: `. .sdd/sdd.conf` is one line shorter and
# would execute whatever the file holds on every run of every script — and it
# may hold a token. A line is `KEY=value` with blanks allowed around both;
# comment lines and blank lines are skipped, a line without `=` is ignored. A
# value wrapped whole in one kind of quote loses that pair and nothing else:
# `-Dgroups="fast"` ends in a quote that belongs to the command.
#
# The pattern reaches awk through the environment, never through `-v`, which
# runs escape processing over it.

sdd_conf_read() {
  [[ -r "$1" ]] || return 0
  SDD_CONF_KEYS="$2" awk -v numbered="${3:-}" '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      p = index(line, "=")
      if (p < 2) next
      key = substr(line, 1, p - 1)
      val = substr(line, p + 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", val)
      if (key !~ ENVIRON["SDD_CONF_KEYS"]) next
      q = substr(val, 1, 1)
      if (length(val) >= 2 && (q == "\"" || q == "\047") && substr(val, length(val), 1) == q)
        val = substr(val, 2, length(val) - 2)
      print (numbered != "" ? NR "|" : "") key "=" val
    }
  ' "$1" 2>/dev/null
  return 0
}
