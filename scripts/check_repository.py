"""Check V1 repository structure and local Markdown links; not RTL acceptance."""
from pathlib import Path
import re, sys, subprocess

root = Path(__file__).resolve().parents[1]
errors = []
required = ['README.md','PROJECT_GOVERNANCE.md','AGENTS.md','CLAUDE.md',
            'docs/plans/PROJECT_PLAN.md','docs/architecture/TECHNICAL_BASELINE.md','docs/REVIEW.md','docs/AI_CONTEXT.md',
            'docs/requirements/OFFICIAL_REQUIREMENTS.md','templates/SKILL_STANDARD.md']
required += ['governance/PROJECT_GOVERNANCE.md','governance/SOURCE_POLICY.md','governance/REVIEW_POLICY.md','governance/SKILL_STANDARD.md','docs/plans/TEACHER_PROJECT_PLAN.md','docs/architecture/ARCHITECTURE_OVERVIEW.md','docs/plans/ROADMAP.md','tasks/templates/TASK_TEMPLATE.md','lessons/LESSON_TEMPLATE.md','lessons/ERROR_TEMPLATE.md']
for name in required:
    if not (root/name).is_file(): errors.append('missing: '+name)
count = 0
# In a checkout, ignore local reference/build caches just as Git does.
if (root/'.git').exists():
    listing = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root)
    markdown_files = [root/name for name in listing.decode('utf-8').split('\0')
                      if name.endswith('.md') and (root/name).is_file()]
else:
    markdown_files = list(root.rglob('*.md'))  # Exported source package.
for p in markdown_files:
    count += 1
    content=p.read_text(encoding='utf-8')
    if content.count('```') % 2: errors.append('unclosed code fence: '+str(p.relative_to(root)))
    for link in re.findall(r'\[[^\]]*\]\(([^)]+)\)',content):
        if '://' in link or link.startswith('#'): continue
        path=link.split('#',1)[0]
        if path and not (p.parent/path).exists(): errors.append(f'broken link: {p.relative_to(root)} -> {link}')
allowed={'backlog','ready','doing','review','done','blocked','cancelled'}
task_files=list((root/'tasks').rglob('TASK-*.md'))
for p in task_files:
    s=p.read_text(encoding='utf-8')
    fields=dict(re.findall(r'^(status|owner|reviewer|backup|depends_on):\s*(.+)$',s,re.M))
    if fields.get('status') not in allowed: errors.append('invalid status: '+p.name)
    if fields.get('status') in {'ready','doing','review','done'}:
        if any(fields.get(k,'UNASSIGNED')=='UNASSIGNED' for k in ['owner','reviewer','backup']): errors.append('unassigned active task: '+p.name)
        if fields.get('owner')==fields.get('reviewer'): errors.append('self review: '+p.name)
    for dep in re.findall(r'TASK-\d+',fields.get('depends_on','')):
        if not any(q.stem == dep for q in task_files): errors.append('missing dependency: '+dep)
if (root/'AGENTS.md').read_text(encoding='utf-8')!=(root/'CLAUDE.md').read_text(encoding='utf-8'):
    errors.append('adapter drift: AGENTS/CLAUDE')
external_check = root/'tools/bootstrap/check_external.py'
if external_check.is_file() and subprocess.run([sys.executable, str(external_check)]).returncode != 0:
    errors.append('external source registration failed')
for e in errors: print('FAIL:',e)
print(f'{"FAIL" if errors else "PASS"}: {count} Markdown files; {len(task_files)} tasks; structure/links only; hardware NOT_RUN')
sys.exit(1 if errors else 0)
