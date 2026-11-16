"""Real flock/process races against tiny fixtures; never touches a live worker."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).with_name('scripts') / 'heavy-lease.sh'
script = script.resolve()
with tempfile.TemporaryDirectory(prefix='lease-fixtures-', dir=Path.cwd()) as tmp:
    root = Path(tmp)
    (root / 'work').mkdir()
    (root / 'stores').mkdir()
    ready = root / 'ready'
    env = dict(os.environ, HEAVY_LEASE_STATE=str(root), HEAVY_LEASE_READY=str(ready))

    def run(code, *args, ok=True, extra=None):
        result = subprocess.run(['bash', '-eu', '-c', 'source "$1"; shift; ' + code,
                                 'fixture', str(script), *map(str, args)],
                                env=env | (extra or {}), capture_output=True, text=True, timeout=10)
        assert (result.returncode == 0) == ok, (code, result)
        return result.stdout.strip()

    def tree(name, where='work'):
        p = root / where / name
        (p / 'target').mkdir(parents=True)
        (p / 'trace.jsonl').write_text('precious trace\n')
        return p

    def holder(code, *args, extra=None):
        p = subprocess.Popen(['bash', '-eu', '-c', 'source "$1"; shift; ' + code +
                              '; echo READY; read -r finish', 'fixture', str(script), *map(str, args)],
                             env=env | (extra or {}), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
        assert p.stdout.readline().strip() == 'READY', p.stderr.read() if p.poll() is not None else ''
        return p

    def finish(p):
        out, err = p.communicate('done\n', timeout=5)
        assert p.returncode == 0, (out, err)

    borrowed = tree('borrowed')
    own = tree('own')
    run('lease_retain "$1" owner', borrowed, ok=False)
    ready.touch()
    token = run('lease_retain "$1" connect', borrowed / 'target')
    second = run('lease_retain "$1" another-owner', borrowed)
    p = holder('lease_admit "$1"', own, extra={'CARGO_TARGET_DIR': str(borrowed / 'target'),
                                               'HEAVY_TARGET_LEASE': token})
    run('lease_retire "$1" race', borrowed, ok=False)
    run('lease_retire "$1" own-active', own, ok=False)
    run('lease_release "$1" "$2"', borrowed, token, ok=False)
    finish(p)
    # Gap, a new process, and old timestamps must not expire either owner.
    os.utime(borrowed, (1, 1))
    run('lease_prune_workspaces')
    assert borrowed.exists()
    run('lease_release "$1" "$2"', borrowed, token)
    run('lease_retire "$1" second-owner', borrowed, ok=False)
    run('lease_release "$1" "$2"', borrowed, token, ok=False)
    run('lease_release "$1" "$2"', borrowed, second)
    run('lease_retire "$1" released', borrowed)
    assert not borrowed.exists()
    archived = list((root / 'retired-workspaces').glob('borrowed.*'))
    assert len(archived) == 1 and (archived[0] / 'trace.jsonl').read_text() == 'precious trace\n'
    run('lease_retain "$1" late', borrowed, ok=False)
    print('PASS cross-workspace job + retained validation gap + multiple owners + released lossless cleanup')

    run('lease_admit "$1"', own, extra={'CARGO_TARGET_DIR': str(root / 'work/missing/target')}, ok=False)
    assert not (root / 'work/missing').exists()
    run('lease_admit "$1"', own, extra={'CARGO_TARGET_DIR': str(own / 'new-target')})
    print('PASS missing borrowed target fails; fresh own target allowed')

    store = tree('store', 'stores')
    st = run('lease_retain "$1" connect', store)
    p = holder('lease_hold "$1" "$2"', store, st)
    run('lease_retire "$1" store-race', store, ok=False)
    finish(p)
    run('lease_retire "$1" retained-store', store, ok=False)
    print('PASS persistent store and workspace use same authority')

    # Force the cleaner's exclusive lock to win before a retain/hold. No
    # observer may publish a lease while that lock permits moving the tree.
    raced = tree('raced')
    p = holder('lease_lock "$(lease_resource "$1")" -x', raced)
    run('lease_retain "$1" racer', raced, ok=False)
    run('lease_hold "$1"', raced, ok=False)
    finish(p)
    run('lease_retire "$1" cleaner-won', raced)
    run('lease_retain "$1" racer', raced, ok=False)
    print('PASS cleanup-wins race never leases a removed/recreated target')

    # A killed job releases its kernel lock, not its persisted owner record.
    orphan = tree('orphan')
    ot = run('lease_retain "$1" orphan-owner', orphan)
    p = holder('lease_hold "$1" "$2"', orphan, ot)
    p.kill(); p.communicate(timeout=5)
    run('lease_retire "$1" crash', orphan, ok=False)
    run('lease_release "$1" "$2"', orphan, ot)
    # Replacing an inode does not confer the previous lease on the new tree.
    identity = tree('identity')
    it = run('lease_retain "$1" owner', identity)
    identity.rename(root / 'displaced')
    tree('identity')
    run('lease_hold "$1" "$2"', identity, it, ok=False)
    run('lease_release "$1" "$2"', identity, it, ok=False)
    run('lease_retire "$1" mismatch', identity, ok=False)
    print('PASS killed holder, stale token and replaced inode fail closed')

    partial = tree('partial')
    key = hashlib.sha256(str(partial).encode()).hexdigest()
    (root / 'leases' / key).mkdir()
    (root / 'leases' / key / 'broken.pending').touch()
    run('lease_retire "$1" interrupted-acquire', partial, ok=False)
    print('PASS interrupted publication blocks cleanup')

    # Exercise the actual budget branch without allocating gigabytes: budget
    # -1 selects all tiny fixtures. Retained/in-use ones must still survive.
    budget = tree('budget')
    bt = run('lease_retain "$1" owner', budget)
    run('lease_prune_workspaces', extra={'HEAVY_WORK_BUDGET_GB': '-1'})
    assert budget.exists() and store.exists() and partial.exists()
    run('lease_release "$1" "$2"', budget, bt)
    run('lease_prune_workspaces', extra={'HEAVY_WORK_BUDGET_GB': '-1'})
    assert not budget.exists()
    assert list((root / 'retired-workspaces').glob('budget.*/trace.jsonl'))
    print('PASS real age and budget pruning honor leases and preserve traces')

# Test the actual receipt retention helpers without entering the CLI dispatcher.
with tempfile.TemporaryDirectory(prefix='receipt-fixtures-', dir=Path.cwd()) as tmp:
    root = Path(tmp)
    jobs = root / 'jobs'
    for name in ('done', 'dead'):
        d = jobs / name
        d.mkdir(parents=True)
        (d / 'out').write_text('retained output')
        if name == 'done':
            (d / 'status').write_text('1')
            (d / 'consumed').touch()
        os.utime(d, (1, 1))
    helper = root / 'functions.sh'
    helper.write_text(script.with_name('heavy-detach.sh').read_text().split('case "${1:-}" in')[0])
    result = subprocess.run(['bash', '-u', '-c',
        'source "$1"; jobs=$2; reap; d=$jobs/done; archive_job',
        'fixture', str(helper), str(jobs)],
        env=dict(os.environ, HEAVY_JOB_HISTORY=str(root / 'history')),
        capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result
    assert (jobs / 'dead/out').read_text() == 'retained output'
    assert not (jobs / 'done').exists()
    assert next((root / 'history').glob('done.*/out')).read_text() == 'retained output'
    print('PASS expired/partial job receipts retained; reused receipt archived losslessly')
