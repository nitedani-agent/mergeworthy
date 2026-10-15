"""The words a post's checks look for, per language (post-lint, pre-bash-guard). A repo's language is the `Language: <code>` line of
its project file (~/.mergeworthy/projects/<owner>/<repo>.md); without one, or with a code not listed here, it is English."""
import os, re

WORDS = {
    'en': {
        'state': ('State', 'draft'),  # **State: draft** (<why>)
        'effort': ('low', 'medium', 'high', 'xhigh', 'max', 'ultra'), 'effort_word': 'effort',
        'blocks': ('Approach', 'Loop A', 'Loop B', 'Refactor pass', 'Fresh read', 'Gates'),  # converge §Evidence blocks
        'note': ('Note', 'Remark'),
        'notes': ('Note', 'Kind', 'Blocks merge', 'Next'), 'kinds': ('bug', 'limitation', 'not a regression'),
        'imposed': 'imposed by',
        'decision': 'Decision', 'picked': ('I picked (x) because …', r'\bI picked \([a-z]\)'),
        'see': 'What you should see',  # pull-request §Body
        'tracker': ('Tracking: ', 'Decisions', ('Process and requirements', 'Agreed', 'Open')),  # task §Umbrella: title, Decisions comment, its sections
        'recommend': "I recommend|recommend|I'd|I would|I propose|I suggest|I'll go with|I picked",  # a question carries our pick
    },
    'hu': {
        'state': ('Állapot', 'piszkozat'),
        'effort': ('alacsony', 'közepes', 'magas', 'nagyon magas', 'maximális', 'ultra'), 'effort_word': 'erőfeszítés',
        'blocks': ('Megközelítés', 'Loop A', 'Loop B', 'Refaktorálás', 'Friss olvasás', 'Ellenőrzések'),
        'note': ('Megjegyzés',),
        'notes': ('Megjegyzés', 'Fajta', 'Blokkolja a beolvasztást', 'Következő'), 'kinds': ('hiba', 'korlát', 'nem regresszió'),
        'imposed': 'szabja meg',
        'decision': 'Döntés', 'picked': ('Az (x) lehetőséget választottam, mert …', r'\([a-z]\)[^\n]*\bválasztottam\b'),
        'see': 'Amit látni fogsz',
        'tracker': ('Követés: ', 'Döntések', ('Folyamat és követelmények', 'Elfogadva', 'Nyitott')),
        'recommend': 'javaslom|javasolnám|választanám|választottam',
    },
}

def language(repo):
    """The language code of a repo (owner/repo, or gitlab.com/<namespace>/<project>)."""
    p = os.path.expanduser(f"~/.mergeworthy/projects/{re.sub(r'^gitlab[.]com/', '', repo or '')}.md")
    try: m = re.search(r'^\s*(?:[-*]\s+)?Language:\s*(\w+)', open(p).read(), re.M) if repo else None
    except OSError: m = None
    return m[1] if m and m[1] in WORDS else 'en'

def words(repo):
    return WORDS[language(repo)]

def draft_repo(path):
    """(repo, why not) for a draft linted without --repo: its watch dir's repo (the first folder above the draft holding repos.txt; when
    that lists several, the one threads.txt names), else the git origin of the cwd."""
    d = os.path.dirname(os.path.abspath(path))
    while True:
        f = os.path.join(d, 'repos.txt')
        if os.path.isfile(f):
            repos = list(dict.fromkeys(l.split()[0] for l in open(f, errors='replace') if l.strip()))
            if len(repos) > 1:
                t = os.path.join(d, 'threads.txt')
                named = {l.split()[0] for l in open(t, errors='replace') if l.strip()} if os.path.isfile(t) else set()
                repos = [r for r in repos if r in named] or repos
            if len(repos) > 1:
                return None, f"{f} lists {', '.join(repos)} and threads.txt doesn't single one out: pass --repo <owner/repo>, so the checks use its language"
            if repos: return repos[0], None
            break
        if os.path.dirname(d) == d: break
        d = os.path.dirname(d)
    import subprocess
    url = subprocess.run(['git', 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
    m = re.search(r'(gitlab\.com)[:/](.+?)(?:\.git)?$|github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$', url)
    return (m and ('gitlab.com/' + m[2] if m[1] else m[3])), None

def alt(items):
    """A regex alternation of literal words."""
    return '|'.join(re.escape(w) for w in items)

def state_line(w):
    """The draft State line: **<label>: <word>** (<why>)."""
    return re.compile(rf'^\*\*{re.escape(w["state"][0])}: {re.escape(w["state"][1])}\*\* \(.*\S.*\)$')
