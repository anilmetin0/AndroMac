#!/usr/bin/env python3
"""Exercise the actual workflow shell with a fake gh; never contact GitHub or merge."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHA = 'a' * 40
REPO = 'owner/repo'


def workflow_script(name):
    source = (ROOT / '.github/workflows' / name).read_text()
    # These workflows deliberately have one inline shell step and no PR checkout.
    before, script = source.split('        run: |\n')
    if '        run: |\n' in script:
        raise AssertionError('Update the test extractor for multiple shell steps')
    return textwrap.dedent(script)


def eligible():
    return {
        'pr': {'author': {'login': 'app/dependabot'},
               'headRepository': {'nameWithOwner': REPO},
               'headRefName': 'dependabot/actions/example', 'headRefOid': SHA,
               'baseRefName': 'main', 'isDraft': False, 'mergeStateStatus': 'CLEAN'},
        'files': '.github/workflows/build.yml',
        'checks': [{'name': name, 'bucket': 'pass'} for name in
                   ['version', 'Android · APK', 'macOS · verify + .app', 'CodeRabbit', 'analyze']],
        'reviews': [[{'id': 1, 'user': {'login': 'coderabbitai[bot]', 'type': 'Bot'},
                      'commit_id': SHA, 'state': 'APPROVED'}]],
        'threads': {'data': {'repository': {'pullRequest': {'headRefOid': SHA,
                    'reviewThreads': {'nodes': [], 'pageInfo': {'hasNextPage': False}}}}}},
    }


FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
f = json.loads(Path(os.environ['FIXTURE']).read_text())
with Path(os.environ['CALLS']).open('a') as out:
    out.write(json.dumps(args) + '\n')
if args[:2] == ['pr', 'list']:
    print('\n'.join(f['prs']))
    sys.exit()
if args[:2] == ['pr', 'merge']:
    sys.exit(1 if f.get('merge_fail') else 0)
if args[:2] == ['workflow', 'run']:
    sys.exit()
if args[:2] == ['pr', 'comment']:
    sys.exit()
if args[0] == 'api' and any('/comments' in x for x in args):
    c = f.get('comments', '')
    print(c if isinstance(c, str) else json.dumps(c))
    sys.exit()
number = args[2] if args[0] == 'pr' else (
    next((x.split('/')[-2] for x in args if '/reviews' in x), None)
    or next((x.split('=')[1] for x in args if x.startswith('number=')), '1'))
p = f.get('items', {}).get(number, {})
kind = {'view': 'pr', 'diff': 'files', 'checks': 'checks'}.get(args[1]) if args[0] == 'pr' else (
    'threads' if 'graphql' in args else 'reviews')
if p.get('fail') == kind:
    sys.exit(1)
value = p[kind]
print(value if isinstance(value, str) else json.dumps(value))
'''


class Workflows(unittest.TestCase):
    def run_workflow(self, filename, items=None, comments='', dry_run=False, merge_fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            gh = folder / 'gh'
            gh.write_text(FAKE_GH)
            gh.chmod(0o755)
            fixture, calls = folder / 'fixture.json', folder / 'calls.jsonl'
            fixture.write_text(json.dumps({'prs': list(items or {}), 'items': items or {},
                                           'comments': comments, 'merge_fail': merge_fail}))
            env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'],
                       FIXTURE=str(fixture), CALLS=str(calls), GH_REPO=REPO,
                       HEAD_SHA=SHA, PR_NUMBER='1', RUNNER_TEMP=tmp,
                       DRY_RUN=str(dry_run).lower(), GH_TOKEN='test-token')
            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', workflow_script(filename)],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1 if merge_fail else 0, result.stderr)
            return [json.loads(line) for line in calls.read_text().splitlines()], result.stdout

    def assert_merge(self, item, expected):
        calls, _ = self.run_workflow('dependabot.yml', {'1': item})
        merges = [call for call in calls if call[:2] == ['pr', 'merge']]
        self.assertEqual(bool(merges), expected)
        if merges:
            self.assertEqual(merges[0][-2:], ['--match-head-commit', SHA])
            self.assertIn(['workflow', 'run', 'build.yml', '--ref', 'main', '--field', 'channel=nightly'], calls)
        else:
            self.assertFalse(any(c[:2] == ['workflow', 'run'] for c in calls))

    def test_eligible_and_skipped_release(self):
        item = eligible()
        item['checks'].append({'name': 'GitHub Release', 'bucket': 'skipping'})
        self.assert_merge(item, True)

    def test_metadata_rejections(self):
        for field, value in [('author', {'login': 'someone'}),
                             ('headRepository', {'nameWithOwner': 'fork/repo'}),
                             ('headRefName', 'feature/example'), ('baseRefName', 'other'),
                             ('isDraft', True), ('mergeStateStatus', 'UNSTABLE')]:
            with self.subTest(field=field):
                item = eligible()
                item['pr'][field] = value
                self.assert_merge(item, False)

    def test_check_failures_and_missing_checks(self):
        for bucket in ['fail', 'pending', 'cancel', 'skipping']:
            with self.subTest(bucket=bucket):
                item = eligible()
                item['checks'][0]['bucket'] = bucket
                self.assert_merge(item, False)
        for name in ['version', 'Android · APK', 'macOS · verify + .app', 'CodeRabbit', 'analyze']:
            with self.subTest(missing=name):
                item = eligible()
                item['checks'] = [c for c in item['checks'] if c['name'] != name]
                self.assert_merge(item, False)
        item = eligible()
        item['files'] = 'android/build.gradle.kts'
        item['checks'] = [c for c in item['checks'] if c['name'] != 'analyze']
        self.assert_merge(item, True)

    def test_review_decisions(self):
        for state in ['CHANGES_REQUESTED', 'DISMISSED', 'COMMENTED']:
            with self.subTest(state=state):
                item = eligible()
                item['reviews'][0][0]['state'] = state
                self.assert_merge(item, False)
        item = eligible()
        item['reviews'][0][0]['commit_id'] = 'b' * 40
        self.assert_merge(item, False)
        item = eligible()
        comment = copy.deepcopy(item['reviews'][0][0])
        comment.update(id=2, state='COMMENTED')
        item['reviews'][0].append(comment)
        self.assert_merge(item, True)
        for reviewer_type in ['User', 'Bot']:
            item = eligible()
            login = 'reviewer' if reviewer_type == 'User' else 'coderabbitai[bot]'
            item['reviews'][0].append({'id': 2, 'user': {'login': login, 'type': reviewer_type},
                                       'state': 'CHANGES_REQUESTED', 'commit_id': SHA})
            self.assert_merge(item, False)

    def test_threads_and_head_race(self):
        for case in ['unresolved', 'pagination', 'changed-head', 'graphql-error']:
            with self.subTest(case=case):
                item = eligible()
                pr = item['threads']['data']['repository']['pullRequest']
                if case == 'unresolved':
                    pr['reviewThreads']['nodes'] = [{'isResolved': False}]
                elif case == 'pagination':
                    pr['reviewThreads']['pageInfo']['hasNextPage'] = True
                elif case == 'changed-head':
                    pr['headRefOid'] = 'b' * 40
                else:
                    item['threads']['errors'] = [{'message': 'Unavailable'}]
                self.assert_merge(item, False)

    def test_api_failure_skips_only_affected_pr(self):
        for kind in ['pr', 'files', 'checks', 'reviews', 'threads']:
            with self.subTest(kind=kind):
                broken = eligible()
                broken['fail'] = kind
                calls, _ = self.run_workflow('dependabot.yml', {'1': broken, '2': eligible()})
                merges = [call for call in calls if call[:2] == ['pr', 'merge']]
                self.assertEqual([call[2] for call in merges], ['2'])

    def test_only_one_merge_per_run(self):
        calls, _ = self.run_workflow('dependabot.yml', {'1': eligible(), '2': eligible()})
        self.assertEqual(sum(c[:2] == ['pr', 'merge'] for c in calls), 1)

    def test_dry_run_never_merges(self):
        calls, output = self.run_workflow('dependabot.yml', {'1': eligible()}, dry_run=True)
        self.assertFalse(any(c[:2] == ['pr', 'merge'] for c in calls))
        self.assertFalse(any(c[:2] == ['workflow', 'run'] for c in calls))
        self.assertIn('eligible; dry run, no merge performed', output)

    def test_dispatches_only_after_successful_merge(self):
        calls, _ = self.run_workflow('dependabot.yml', {'1': eligible()})
        self.assertIn(['workflow', 'run', 'codeql.yml', '--ref', 'main'], calls)
        item = eligible()
        item['files'] = 'android/build.gradle.kts'
        calls, _ = self.run_workflow('dependabot.yml', {'1': item})
        self.assertNotIn(['workflow', 'run', 'codeql.yml', '--ref', 'main'], calls)
        calls, _ = self.run_workflow('dependabot.yml', {'1': eligible()}, merge_fail=True)
        self.assertFalse(any(c[:2] == ['workflow', 'run'] for c in calls))

    def test_review_request_idempotency(self):
        marker = '<!-- coderabbit-dependency-review:' + SHA + ' -->'

        def comment(login, body, at):
            return {'user': {'login': login}, 'body': body, 'created_at': at}

        request = comment('github-actions[bot]', marker, '2026-01-01T00:00:00Z')
        declined = comment('coderabbitai[bot]', 'Action not completed. Review skipped.', '2026-01-01T00:01:00Z')
        done = comment('coderabbitai[bot]', 'Action performed. Review finished.', '2026-01-01T00:01:00Z')
        old = comment('github-actions[bot]', '<!-- coderabbit-dependency-review:old -->', '2026-01-01T00:00:00Z')
        cases = [
            ([], [], True),                              # first request
            ([request], [], False),                      # requested, no answer yet
            ([request, done], [], False),                # accepted
            ([request, declined], [], True),             # declined: retry on the next event
            ([request, request, request, declined], [], False),   # bounded at three requests
            ([old], [], True),                           # a marker for another commit
            ([], [{'user': {'login': 'coderabbitai[bot]'}, 'commit_id': SHA}], False),  # reviewed
        ]
        for comments, reviews, expected in cases:
            with self.subTest(comments=comments, reviews=reviews):
                items = {'1': {'reviews': [reviews]}}
                calls, _ = self.run_workflow('coderabbit.yml', items, comments=[comments])
                self.assertEqual(any(c[:2] == ['pr', 'comment'] for c in calls), expected)

if __name__ == '__main__':
    unittest.main(verbosity=2)
