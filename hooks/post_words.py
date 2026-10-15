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

def alt(items):
    """A regex alternation of literal words."""
    return '|'.join(re.escape(w) for w in items)

def state_line(w):
    """The draft State line: **<label>: <word>** (<why>)."""
    return re.compile(rf'^\*\*{re.escape(w["state"][0])}: {re.escape(w["state"][1])}\*\* \(.*\S.*\)$')
