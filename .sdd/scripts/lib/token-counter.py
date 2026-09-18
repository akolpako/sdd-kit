#!/usr/bin/env python3
"""Static context-size report for every /sdd-* command.

Reads only the repository: no network, no arguments, changes nothing on
disk. See token-counter.md at the repo root for the full design.
"""
from __future__ import annotations

import hashlib
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

WIDTH = 73

# ── Colour ─────────────────────────────────────────────────────────
# Colour is decoration over a report that has to stay readable without it, so
# every escape goes on *after* the column arithmetic — pad the plain string,
# then wrap it. Off when stdout is not a terminal, so a redirect or a pipe
# still gets the plain fixed-width table, and off when NO_COLOR is set.
# https://no-color.org
COLOR = False


def use_color(stream) -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("TERM") == "dumb":
        return False
    return bool(getattr(stream, "isatty", lambda: False)())


_SGR = {
    "dim": "2",
    "bold": "1",
    "red": "31",
    "green": "32",
    "yellow": "33",
    "blue": "34",
    "magenta": "35",
    "cyan": "36",
    "grey": "90",
}


def paint(text: str, *styles: str) -> str:
    if not COLOR or not styles:
        return text
    codes = ";".join(_SGR[s] for s in styles)
    return f"\033[{codes}m{text}\033[0m"

# ── Tokenizer ──────────────────────────────────────────────────────
# tiktoken is a proxy: Claude's own tokenizer is not published, and on English
# markdown o200k_base normally lands within about 10% of it. Enough to compare
# commands, not enough to predict a hard context limit to the token.
#
# get_encoding downloads and caches the BPE file on first use, so it fails on a
# machine with no network — catch every exception, not just ImportError. The
# divisor of the fallback is measured across the files this tool counts, not
# guessed, but a per-file estimate can still be off by ±20%.
FALLBACK_DIVISOR = 4.26
_ENC = None
try:
    import tiktoken

    _ENC = tiktoken.get_encoding("o200k_base")
    TOKENIZER_LABEL = "tiktoken · o200k_base"
    TOKENIZER_HINT = ""
except Exception:
    TOKENIZER_LABEL = f"characters ÷ {FALLBACK_DIVISOR} (estimate)"
    TOKENIZER_HINT = "  tiktoken is not installed. For a real tokenizer:  pip install tiktoken"


def count_tokens(text: str) -> int:
    # disallowed_special=() matters: without it a document containing the
    # literal <|endoftext|> raises instead of counting.
    if _ENC is not None:
        return len(_ENC.encode(text, disallowed_special=()))
    return round(len(text) / FALLBACK_DIVISOR)


# ── File cache ─────────────────────────────────────────────────────
@dataclass
class FileInfo:
    exists: bool
    tokens: int
    sha: str | None


_CACHE: dict[Path, FileInfo] = {}
MISSING: list[tuple[str, str]] = []  # (display path, source that named it)


def load(path: Path, source: str) -> FileInfo:
    if path in _CACHE:
        info = _CACHE[path]
        if not info.exists:
            MISSING.append((rel(path), source))
        return info
    if path.is_file():
        text = read(path)
        info = FileInfo(True, count_tokens(text), hashlib.sha256(text.encode("utf-8")).hexdigest())
    else:
        info = FileInfo(False, 0, None)
        MISSING.append((rel(path), source))
    _CACHE[path] = info
    return info


ROOT: Path = None  # type: ignore


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


# ── Formatting helpers ─────────────────────────────────────────────
def fmt(n: int) -> str:
    return f"{n:,}".replace(",", " ")


def clip(text: str, width: int, keep: str = "tail") -> str:
    """Fit text into a fixed column.

    A path keeps its `tail`, because the filename is what identifies it; a
    label keeps its `head`, because the name comes before the formula.
    """
    if len(text) <= width:
        return text
    if keep == "head":
        return text[: width - 1] + "…"
    return "…" + text[-(width - 1):]


# One colour per tier, reused by the group row, its file rows, and its bar, so
# a block can be read by colour before any of its numbers are.
TIER_COLOR = {
    "base": "blue",
    "orchestrator": "cyan",
    "role": "green",
    "skills": "magenta",
}


def tier_color(label: str) -> str:
    return TIER_COLOR.get(label.split(" ·")[0], "cyan")


def heat(ratio: float) -> str:
    """Green through yellow to red, by how close a value is to the largest."""
    if ratio >= 0.8:
        return "red"
    if ratio >= 0.5:
        return "yellow"
    return "green"


def paint_path(display: str) -> str:
    """Dim the directories, leave the filename at full strength."""
    if not COLOR or "/" not in display:
        return display
    head, _, tail = display.rpartition("/")
    return paint(head + "/", "dim") + tail


def bar(value: int, scale: int, width: int) -> str:
    if scale <= 0:
        return ""
    units = value / scale * width
    full = int(units)
    eighths = round((units - full) * 8)
    if eighths == 8:
        full, eighths = full + 1, 0
    drawn = "█" * full + ("▏▎▍▌▋▊▉"[eighths - 1] if eighths else "")
    return drawn or ("▏" if value > 0 else "")


# ── Interactive picker ─────────────────────────────────────────────
# The menu draws on stderr, not stdout, so `token-counter.sh > report.txt`
# still gets to ask which command it should write. Keys come from the
# terminal itself rather than from stdin, for the same reason.
UP, DOWN, ENTER, CANCEL, OTHER = "up", "down", "enter", "cancel", "other"

_KEYS = {
    "\x1b[A": UP, "\x1bOA": UP, "k": UP,
    "\x1b[B": DOWN, "\x1bOB": DOWN, "j": DOWN,
    "\r": ENTER, "\n": ENTER, " ": ENTER,
    "\x1b": CANCEL, "\x03": CANCEL, "\x04": CANCEL, "q": CANCEL,
}


def read_key(fd) -> str:
    """One keypress, with the arrow keys' escape sequences folded in.

    A bare Esc and the start of an arrow key are the same first byte. They
    are told apart by waiting a moment: a terminal sends the rest of an
    escape sequence at once, a human pressing Esc sends nothing more.
    """
    import select as _select

    ch = os.read(fd, 1).decode("utf-8", "replace")
    if ch == "\x1b":
        ready, _, _ = _select.select([fd], [], [], 0.05)
        if ready:
            ch += os.read(fd, 2).decode("utf-8", "replace")
    return _KEYS.get(ch, OTHER)


def pick(options: list[str], prompt: str) -> str | None:
    """Arrow-key menu on the terminal. Returns None if the user cancels."""
    import termios
    import tty

    try:
        tty_in = open("/dev/tty", "rb", buffering=0)
        tty_out = open("/dev/tty", "w")
    except OSError:
        return None

    fd = tty_in.fileno()
    saved = termios.tcgetattr(fd)
    cursor = 0

    def draw(first: bool) -> None:
        if not first:
            tty_out.write(f"\033[{len(options)}A")
        for i, opt in enumerate(options):
            marker = "❯ " if i == cursor else "  "
            row = f"{marker}{opt}"
            if i == cursor:
                row = paint(row, "bold", "cyan")
            # Raw mode turns off the newline-to-carriage-return translation,
            # so the carriage return has to be written by hand or the menu
            # walks off to the right.
            tty_out.write("\033[2K" + row + "\r\n")
        tty_out.flush()

    try:
        tty_out.write(paint(prompt, "dim") + "\r\n")
        tty_out.write("\033[?25l")  # hide the cursor while the menu owns the screen
        tty_out.flush()
        # TCSADRAIN, not the TCSAFLUSH that tty.setraw defaults to: a key
        # pressed while tiktoken was still loading is typeahead, not noise,
        # and flushing it would swallow it.
        tty.setraw(fd, termios.TCSADRAIN)
        draw(first=True)
        while True:
            key = read_key(fd)
            if key == UP:
                cursor = (cursor - 1) % len(options)
            elif key == DOWN:
                cursor = (cursor + 1) % len(options)
            elif key == ENTER:
                return options[cursor]
            elif key == CANCEL:
                return None
            else:
                continue
            draw(first=False)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        # Wipe the menu so the report starts at the top of a clean screen.
        tty_out.write(f"\033[{len(options) + 1}A" + "\033[J" + "\033[?25h")
        tty_out.flush()
        tty_out.close()
        tty_in.close()


def interactive() -> bool:
    return sys.stdin.isatty() and sys.stderr.isatty()


# ── Repo structure ─────────────────────────────────────────────────
SLASH_TOKEN_MAP = {
    "sdd-spec-review": "review",
    "sdd-next-story": "new",
}

BACKTICK_PATH_RE = re.compile(r"`(\.sdd/[^`]*\.md)`")
AT_INCLUDE_RE = re.compile(r"^@(\S+)\s*$", re.MULTILINE)
FENCE_RE = re.compile(r"^```.*?^```", re.MULTILINE | re.DOTALL)


def prose(text: str) -> str:
    """The parts of a markdown file that name a path for real.

    A path inside a fenced code block is an example of what a file may
    contain, not a file this one pulls in, so the fences come out first.
    """
    return FENCE_RE.sub("", text)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def command_token(slash_name: str) -> str:
    if slash_name in SLASH_TOKEN_MAP:
        return SLASH_TOKEN_MAP[slash_name]
    return slash_name[len("sdd-"):] if slash_name.startswith("sdd-") else slash_name


def walk(seed: Path, seed_source: str, refs, depth: int) -> list[tuple[Path, str]]:
    """Breadth-first closure of a file and the paths it names, `depth` hops out.

    `seen` keeps a cycle from looping and keeps a file from being counted
    twice. `depth` is what separates the two tiers: an `@include` is expanded
    by the runtime, and an expanded file's own includes are expanded in turn,
    so the base tier follows the chain as far as it goes. A path merely named
    in prose is read at the model's discretion; one hop from the command file
    is a reference, but a path named by a file that was itself only referenced
    is a guess, so the orchestrator tier stops at one.
    """
    ordered: list[tuple[Path, str]] = []
    seen: set[Path] = set()
    queue: list[tuple[Path, str, int]] = [(seed, seed_source, 0)]
    while queue:
        path, source, hops = queue.pop(0)
        if path in seen:
            continue
        seen.add(path)
        ordered.append((path, source))
        if hops >= depth or not path.is_file():
            continue
        for ref in refs(prose(read(path))):
            child = ROOT / ref
            if child not in seen:
                queue.append((child, rel(path), hops + 1))
    return ordered


def _at_refs(text: str) -> list[str]:
    return [m.group(1) for m in AT_INCLUDE_RE.finditer(text)]


def _backtick_refs(text: str) -> list[str]:
    return [m.group(1) for m in BACKTICK_PATH_RE.finditer(text)]


def base_tier() -> list[tuple[Path, str]]:
    """`CLAUDE.md` and the chain of files it pulls in with `@path`."""
    return walk(ROOT / "CLAUDE.md", "the repository root", _at_refs, depth=64)


def orchestrator_tier(cmd_file: Path) -> list[tuple[Path, str]]:
    """The command file itself, plus every `.sdd/**.md` path its prose names."""
    return walk(cmd_file, "the command list", _backtick_refs, depth=1)


@dataclass
class SpawnRecord:
    role: str
    protocols: list[str]
    scope: str


def parse_spawn_table(gate_sh: Path) -> dict[str, list[SpawnRecord]]:
    text = read(gate_sh)
    m = re.search(r"^if \[\[ \$SPAWNING -eq 1 \]\]; then$", text, re.MULTILINE)
    if not m:
        return {}
    start = m.end()
    end_m = re.search(r"^fi$", text[start:], re.MULTILINE)
    block = text[start:start + end_m.start()] if end_m else text[start:]

    label_re = re.compile(r"^ {4}([a-z][a-z-]*)\)$")
    printf_re = re.compile(r"printf\s+'([^']*)'")

    table: dict[str, list[SpawnRecord]] = {}
    current: str | None = None
    for line in block.splitlines():
        lm = label_re.match(line)
        if lm:
            current = lm.group(1)
            table.setdefault(current, [])
            continue
        pm = printf_re.search(line)
        if pm and current is not None:
            fstr = pm.group(1).replace("%s", ".sdd/protocols")
            if fstr.endswith("\\n"):
                fstr = fstr[:-2]
            parts = fstr.split("|")
            if len(parts) != 3:
                continue
            role, protocols_csv, scope = parts
            protocols = [p for p in protocols_csv.split(",") if p]
            table[current].append(SpawnRecord(role, protocols, scope))
    return table


SKILLS_RE = re.compile(r"^skills:\s*$", re.MULTILINE)
SKILL_ITEM_RE = re.compile(r"^\s*-\s*(\S+)\s*$")

def agent_skills(agent_path: Path) -> list[str]:
    if not agent_path.is_file():
        return []
    text = read(agent_path)
    if not text.startswith("---"):
        return []
    end = text.find("\n---", 3)
    front = text[3:end] if end != -1 else text
    lines = front.splitlines()
    skills: list[str] = []
    in_skills = False
    for line in lines:
        if SKILLS_RE.match(line):
            in_skills = True
            continue
        if in_skills:
            im = SKILL_ITEM_RE.match(line)
            if im:
                skills.append(im.group(1))
            else:
                break
    return skills


# ── Assignment / command model ──────────────────────────────────────
@dataclass
class Group:
    label: str
    files: list[tuple[str, Path, int]] = field(default_factory=list)  # (display, path, tokens)

    @property
    def total(self) -> int:
        return sum(t for _, _, t in self.files)


@dataclass
class Assignment:
    role: str
    scope: str
    role_group: Group
    skills_group: Group
    references_total: int

    @property
    def total(self) -> int:
        return self.role_group.total + self.skills_group.total


@dataclass
class CommandReport:
    slash_name: str
    base: Group
    orchestrator: Group
    assignments: list[Assignment]

    @property
    def heaviest(self) -> Assignment | None:
        if not self.assignments:
            return None
        return max(self.assignments, key=lambda a: a.total)

    @property
    def total(self) -> int:
        """Everything read once during a run, across both context windows."""
        h = self.heaviest
        return self.base.total + self.orchestrator.total + (h.total if h else 0)

    @property
    def orch_window(self) -> int:
        """What the orchestrator's own window carries."""
        return self.base.total + self.orchestrator.total

    @property
    def role_window(self) -> int:
        """What the heaviest spawned role's window carries. It gets `base` too."""
        h = self.heaviest
        return self.base.total + h.total if h else 0

    @property
    def peak_window(self) -> int:
        return max(self.orch_window, self.role_window)


def build_report(sdd: Path, cmd_file: Path, spawn_table: dict[str, list[SpawnRecord]]) -> CommandReport:
    slash_name = cmd_file.stem
    token = command_token(slash_name)

    base_group = Group("base")
    for p, source in base_tier():
        info = load(p, source)
        base_group.files.append((rel(p), p, info.tokens))
    base_group.files.sort(key=lambda x: x[2], reverse=True)

    orch_group = Group("orchestrator")
    for p, source in orchestrator_tier(cmd_file):
        info = load(p, source)
        orch_group.files.append((rel(p), p, info.tokens))
    orch_group.files.sort(key=lambda x: x[2], reverse=True)

    assignments: list[Assignment] = []
    for rec in spawn_table.get(token, []):
        prompt_path = sdd / "prompts" / f"{token}-{rec.scope}.md"
        agent_path = sdd / "agents" / f"{rec.role}.md"
        role_group = Group(f"role · {rec.scope}")
        p_info = load(prompt_path, f"agents/{rec.role}.md")
        role_group.files.append((rel(prompt_path), prompt_path, p_info.tokens))
        a_info = load(agent_path, f"agents/{rec.role}.md")
        role_group.files.append((rel(agent_path), agent_path, a_info.tokens))
        for proto in rec.protocols:
            proto_path = ROOT / proto
            pr_info = load(proto_path, f"agents/{rec.role}.md")
            role_group.files.append((rel(proto_path), proto_path, pr_info.tokens))
        role_group.files.sort(key=lambda x: x[2], reverse=True)

        skill_names = agent_skills(agent_path)
        skills_group = Group(f"skills · {rec.scope}")
        refs_total = 0
        for name in skill_names:
            skill_md = sdd / "skills" / name / "SKILL.md"
            s_info = load(skill_md, f"agents/{rec.role}.md")
            display = rel(skill_md)
            if display.startswith(".sdd/skills/"):
                display = display[len(".sdd/skills/"):]
            skills_group.files.append((display, skill_md, s_info.tokens))
            refs_dir = sdd / "skills" / name / "references"
            if refs_dir.is_dir():
                for f in sorted(refs_dir.glob("*.md")):
                    r_info = load(f, f"skills/{name}/SKILL.md")
                    refs_total += r_info.tokens
        skills_group.files.sort(key=lambda x: x[2], reverse=True)

        assignments.append(Assignment(rec.role, rec.scope, role_group, skills_group, refs_total))

    return CommandReport(slash_name, base_group, orch_group, assignments)


# ── Duplicate detection ──────────────────────────────────────────────
def mark_duplicates(rows: list[tuple[str, Path, int, frozenset[str]]]) -> tuple[set[int], list[str]]:
    """Flag identical content counted more than once in a single run.

    Each row carries the set of context windows it lands in. Two identical
    files that share a window are paid for twice inside one context; two
    that do not are paid for once in each of two contexts. Both are waste,
    but only the first crowds a single window, so they are worded apart.
    """
    seen: dict[str, int] = {}
    marked: set[int] = set()
    footnotes: list[str] = []
    for i, (display, path, tokens, windows) in enumerate(rows):
        info = _CACHE.get(path)
        if info is None or info.sha is None:
            continue
        if info.sha in seen:
            first_idx = seen[info.sha]
            marked.add(i)
            first_display, _, _, first_windows = rows[first_idx]
            shared = windows & first_windows
            if shared:
                where = " and ".join(sorted(shared))
                cost = f"{fmt(tokens)} tokens are read twice inside the {where} window"
            else:
                cost = f"{fmt(tokens)} tokens are read once in each of two separate windows"
            if display == first_display:
                glyph = paint(" ⧉", "bold", "yellow")
                footnotes.append(
                    f"{glyph}  {paint_path(display)} is counted in two tiers\n"
                    f"    {paint(cost + '.', 'dim')}"
                )
            else:
                glyph = paint(" ⧉", "bold", "yellow")
                footnotes.append(
                    f"{glyph}  {paint_path(display)} is byte-for-byte identical to\n"
                    f"    {paint_path(first_display)}\n    {paint(cost + '.', 'dim')}"
                )
        else:
            seen[info.sha] = i
    return marked, footnotes


# ── Rendering ────────────────────────────────────────────────────────
def render_summary(reports: list[CommandReport]) -> str:
    rows = sorted(reports, key=lambda r: r.total, reverse=True)
    max_total = max((r.total for r in rows), default=0)
    rule = paint("─" * WIDTH, "grey")
    lines = []
    lines.append(paint(
        f"  {'COMMAND':<16}{'BASE':>6}{'ORCH':>8}{'ROLE':>8}"
        f"{'SKILLS':>8}{'TOTAL':>8}{'PEAK':>8}",
        "bold",
    ))
    lines.append(rule)
    for r in rows:
        h = r.heaviest
        dash = paint("—".rjust(8), "grey")
        role_s = paint(fmt(h.role_group.total).rjust(8), "green") if h else dash
        skills_s = paint(fmt(h.skills_group.total).rjust(8), "magenta") if h else dash
        ratio = r.total / max_total if max_total else 0
        lines.append(
            "  "
            + paint(f"{r.slash_name:<16}", "bold", "cyan")
            + paint(f"{fmt(r.base.total):>6}", "blue")
            + paint(f"{fmt(r.orchestrator.total):>8}", "cyan")
            + role_s
            + skills_s
            + paint(f"{fmt(r.total):>8}", "bold")
            + paint(f"{fmt(r.peak_window):>8}", "bold", "yellow")
            + "  "
            + paint(bar(r.total, max_total, 8), heat(ratio))
        )
    lines.append(rule)
    heaviest_run = max((r.total for r in rows), default=0)
    peak_window = max((r.peak_window for r in rows), default=0)
    lines.append(
        paint(f"{'heaviest run':<{WIDTH - 9}}", "dim") + paint(f"{fmt(heaviest_run):>9}", "bold")
    )
    lines.append(
        paint(f"{'largest single window':<{WIDTH - 9}}", "dim")
        + paint(f"{fmt(peak_window):>9}", "bold", "yellow")
    )
    lines.append("")
    for note in (
        "TOTAL = BASE + ORCH + the heaviest ROLE and its SKILLS: every",
        "token read during one run. Two roles never share a context window,",
        "so the heaviest one is taken, not the sum.",
        "PEAK is the largest single window of that run. The orchestrator's",
        "window is BASE + ORCH; a role's window is BASE + ROLE + SKILLS,",
        "because a role is handed BASE too. The two never coexist, so the",
        "largest window is PEAK, not TOTAL.",
        "Not counted: the system prompt, the tool definitions, the gate",
        "output, and the spec files a role opens for itself.",
    ):
        lines.append(paint(note, "dim"))
    return "\n".join(lines)


def render_detail(r: CommandReport) -> str:
    NAME = 41  # width of the file-name column; longer paths are clipped
    lines = []
    lines.append(paint("═" * WIDTH, "grey"))
    lines.append(
        " "
        + paint(f"{r.slash_name:<45}", "bold", "cyan")
        + paint(f"{fmt(r.total):>9}", "bold")
        + paint(" tokens", "dim")
    )
    lines.append(paint("═" * WIDTH, "grey"))
    lines.append("")
    lines.append(paint(f" {'FILE':<45}{'TOKENS':>7} {'SHARE':>6}", "bold"))
    lines.append(" " + paint("─" * (WIDTH - 1), "grey"))

    h = r.heaviest
    groups: list[Group] = [r.base, r.orchestrator]
    if h:
        groups += [h.role_group, h.skills_group]

    group_scale = max((g.total for g in groups), default=0)

    # Which context window each group lands in. `base` is handed to the
    # orchestrator and to every role it spawns, so it lands in both.
    windows: dict[int, frozenset[str]] = {
        id(r.base): frozenset({"orchestrator", "role"}) if h else frozenset({"orchestrator"}),
        id(r.orchestrator): frozenset({"orchestrator"}),
    }
    if h:
        windows[id(h.role_group)] = frozenset({"role"})
        windows[id(h.skills_group)] = frozenset({"role"})

    # Combined, ordered rows for duplicate detection across this one run.
    combined: list[tuple[str, Path, int, frozenset[str]]] = []
    for g in groups:
        combined.extend((d, path, t, windows[id(g)]) for d, path, t in g.files)
    marked, footnotes = mark_duplicates(combined)

    idx = 0
    for g in groups:
        colour = tier_color(g.label)
        pct = round(g.total / r.total * 100) if r.total else 0
        lines.append(
            " "
            + paint("▸ ", colour)
            + paint(f"{g.label:<43}", "bold", colour)
            + paint(f"{fmt(g.total):>7}", "bold")
            + paint(f"{pct:>5}%", "dim")
            + "  "
            + paint(bar(g.total, group_scale, 20), colour)
        )
        for display, path, tokens in g.files:
            fpct = round(tokens / r.total * 100) if r.total else 0
            name = clip(display, NAME)
            pad = " " * (NAME - len(name))
            mark = paint(" ⧉", "bold", "yellow") if idx in marked else ""
            lines.append(
                "     "
                + paint_path(name)
                + pad
                + f"{fmt(tokens):>7}"
                + paint(f"{fpct:>5}%", "dim")
                + "  "
                + paint(bar(tokens, group_scale, 20), "dim", colour)
                + mark
            )
            idx += 1
        lines.append("")

    lines.append(" " + paint("─" * (WIDTH - 1), "grey"))
    lines.append(
        " "
        + paint(f"{'TOTAL read per run':<45}", "bold")
        + paint(f"{fmt(r.total):>7}", "bold")
        + paint("  100%", "dim")
    )

    if h:
        lines.append("")
        lines.append(paint(" Split across the two windows of this run, which never coexist:", "dim"))
        LABEL = 44
        rows = (
            ("orchestrator — base+orchestrator", r.orch_window, "cyan"),
            (f"role · {h.scope} — base+role+skills", r.role_window, "green"),
            ("PEAK", r.peak_window, "yellow"),
        )
        for label, value, colour in rows:
            text = clip(label, LABEL, keep="head")
            bold = ("bold",) if label == "PEAK" else ()
            lines.append(
                "    "
                + paint(f"{text:<{LABEL}}", colour, *bold)
                + paint(f"{fmt(value):>{WIDTH - 4 - LABEL}}", "bold", *( (colour,) if bold else () ))
            )

    if footnotes:
        lines.append("")
        lines.extend(footnotes)

    if h and len(r.assignments) > 1:
        lines.append("")
        lines.append(paint(
            " Other assignments of this command, each in its own window, not added in:", "dim"
        ))
        for a in r.assignments:
            if a is h:
                continue
            lines.append(
                "    "
                + paint(f"{a.scope:<20}", "cyan")
                + paint(" role ", "dim")
                + paint(f"{fmt(a.role_group.total):>6}", "green")
                + paint("  +  skills ", "dim")
                + paint(f"{fmt(a.skills_group.total):>6}", "magenta")
                + paint("  =  ", "dim")
                + paint(f"{fmt(a.total):>6}", "bold")
            )

    if r.assignments:
        lines.append(paint(" Loaded on demand, not up front:", "dim"))
        for a in r.assignments:
            lines.append(
                "    "
                + paint(f"references · {a.scope}", "dim")
                + "  "
                + paint(fmt(a.references_total), "yellow")
            )
    elif not h:
        lines.append("")
        lines.append(paint(" Spawns no role — the whole context sits with the orchestrator.", "dim"))

    return "\n".join(lines)


def render_missing() -> str:
    if not MISSING:
        return ""
    seen = []
    lines = [paint("Missing, counted as 0:", "bold", "red")]
    for display, source in MISSING:
        key = (display, source)
        if key in seen:
            continue
        seen.append(key)
        lines.append(f"  {paint_path(display)}   {paint('(named by ' + source + ')', 'dim')}")
    return "\n".join(lines)


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("ERROR=usage: token-counter.py <repo-root> <all|slash-name>", file=sys.stderr)
        return 1
    repo_root = Path(args[0]).resolve()
    selection = args[1] if len(args) > 1 else ""
    if args[2:]:
        print("ERROR=usage: token-counter.sh [all|<slash-name>]", file=sys.stderr)
        return 1

    global ROOT, COLOR
    ROOT = repo_root
    # The report is coloured only for a terminal; the menu draws on stderr and
    # needs its own answer, so a redirected report still gets a coloured menu.
    COLOR = use_color(sys.stdout) or (not selection and use_color(sys.stderr))
    sdd = repo_root / ".sdd"
    gate_sh = sdd / "scripts" / "gate.sh"
    if not sdd.is_dir():
        print(f"ERROR=.sdd not found under {repo_root}", file=sys.stderr)
        return 1
    if not gate_sh.is_file():
        print(f"ERROR=missing: {gate_sh}", file=sys.stderr)
        return 1

    spawn_table = parse_spawn_table(gate_sh)
    if not spawn_table:
        print("WARN=gate.sh's SPAWN table yielded no records", file=sys.stderr)

    commands_dir = sdd / "commands"
    cmd_files = sorted(commands_dir.glob("sdd-*.md"))

    if not selection:
        if interactive() and cmd_files:
            choice = pick(
                ["all"] + [f.stem for f in cmd_files],
                "Which command? ↑/↓ to move, Enter to choose, Esc to cancel.",
            )
            if choice is None:
                return 130
            selection = choice
        else:
            selection = "all"

    # The menu is gone by now; whether the report itself is coloured is only
    # ever about stdout.
    COLOR = use_color(sys.stdout)

    if selection != "all":
        cmd_files = [f for f in cmd_files if f.stem == selection]
        if not cmd_files:
            names = ", ".join(sorted(p.stem for p in sorted(commands_dir.glob("sdd-*.md"))))
            print(f"ERROR=unknown command: {selection} — one of: {names}", file=sys.stderr)
            return 1

    reports = [build_report(sdd, f, spawn_table) for f in cmd_files]

    out = []
    header = f"Tokenizer: {TOKENIZER_LABEL}"
    today = date.today().isoformat()
    out.append(paint(f"{header}{today:>{WIDTH - len(header)}}", "dim"))
    if TOKENIZER_HINT:
        out.append(paint(TOKENIZER_HINT, "yellow"))
    out.append("")
    out.append(render_summary(reports))
    out.append("")
    for r in reports:
        out.append(render_detail(r))
        out.append("")

    missing = render_missing()
    if missing:
        out.append(missing)

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
