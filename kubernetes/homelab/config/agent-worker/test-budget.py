"""Tiny local fixtures only. Fake cgroup kill file; no worker runtime submission."""
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).with_name('scripts').joinpath('heavy-budget.sh').resolve()
with tempfile.TemporaryDirectory(prefix='budget-test-', dir=Path.cwd()) as temp:
    root = Path(temp)
    def test(name, code):
        p = subprocess.run(['bash', '-u', '-c', 'source "$1"; run=$2; budget_receipt=$run/receipt; '+code,
                            'test', str(script), str(root)], capture_output=True, text=True, timeout=10)
        assert p.returncode == 0, (name, p.returncode, p.stdout, p.stderr)
        print('PASS', name)
    test('admission boundaries, lease failure and one writer', r''' 
        mkdir -p "$run/store/target" "$run/leases" "$run/job"
        HEAVY_DISK_STOP=1 HEAVY_LONG=0 HEAVY_WALL_CAP=2700 HEAVY_WALL_GRACE=30
        HEAVY_JOB_KEY=1234567890abcdef12345678 HEAVY_JOB_DIR=$run/job
        store=$run/store CARGO_TARGET_DIR=$run/store/target HEAVY_TARGET_LEASE=test
        shared= ws=$run/ws class=small lease_dir=$run/leases
        realpath() { if [[ $* == */work/.jobs/* ]]; then echo "$run/job"; else command realpath "$@"; fi; }
        lease_resource() { echo "$store"; }
        lease_hold() { return 0; }
        budget_measure() { budget_used=$used; budget_free=$free; }
        used=0 free=188978561023
        ( ! budget_prepare ) || exit 1
        free=188978561024
        ( budget_prepare ) || exit 2
        used=17179869184
        ( ! budget_prepare ) || exit 3
        used=0
        ( lease_hold() { return 1; }; ! budget_prepare ) || exit 4
        exec {other}>"$lease_dir/bounded-writer.lock"; flock -x "$other"
        ( ! budget_prepare ) || exit 5
        exec {other}>&-
    ''')
    test('real bounded measurement + changed store identity', '''
        budget_store=$run; budget_store_id=$(budget_identity "$run")
        budget_measure || exit 1
        [[ $budget_used =~ ^[0-9]+$ && $budget_free =~ ^[0-9]+$ ]] || exit 2
        budget_store_id=wrong; ! budget_measure
    ''')
    test('threshold, floor, failed measurement and receipt', '''
        budget_cgref=$run; budget_cg_id=$(budget_identity "$run")
        budget_limit=17179869184; budget_floor=166429982720
        budget_measure() { budget_used=$used; budget_free=$free; }
        used=17179869183; free=166429982720; budget_check || exit 1
        used=17179869184; ! budget_check && [ "$budget_reason" = store-16GiB ] || exit 2
        used=0; free=166429982719; ! budget_check && [ "$budget_reason" = node-below-155GiB ] || exit 3
        budget_measure() { return 124; }
        ! budget_check && [ "$budget_reason" = measurement-failed ] || exit 4
        budget_measure() { budget_used=0; budget_free=188978561024; }
        budget_receipt=$run/missing/path
        ! budget_check && [ "$budget_reason" = receipt-write-failed ]
    ''')
    test('held directory identity survives path replacement; no broad kill', '''
        budget_enabled=1; cgroot=$run/cg; jobcg=$cgroot/jobs/job-$$
        mkdir -p "$jobcg"; touch "$jobcg/cgroup.kill"
        budget_capture_cgroup || exit 1
        mv "$jobcg" "$jobcg.old"; mkdir "$jobcg"; echo innocent > "$jobcg/cgroup.kill"
        budget_kill || exit 2
        [ "$(cat "$jobcg.old/cgroup.kill")" = 1 ] && [ "$(cat "$jobcg/cgroup.kill")" = innocent ] || exit 3
        budget_cg_id=wrong; ! budget_kill
    ''')
    test('reject shared cgroup', '''
        budget_enabled=1; cgroot=$run/cg; jobcg=$cgroot/jobs
        ! budget_capture_cgroup
    ''')
    # Use real child wait/exit/signal races; only kernel cgroup.kill is mocked,
    # and mock signals exclusively this fixture's known child PID.
    for mode in ('exit0', 'exit7', 'sigkill', 'during-stop', 'normal'):
        test('supervisor '+mode, '''
            rm -f "$run/budget-failed" "$run/kill-called"
            mode='''+mode+'''
            budget_kill() { echo yes >> "$run/kill-called"; kill -KILL "$job" 2>/dev/null || true; }
            sleep() { :; } # skip ONLY the 30-second grace in unit fixtures
            if [ "$mode" = normal ]; then (command sleep .05; exit 23) &
            else (exec command_placeholder) & fi
        '''.replace('(exec command_placeholder)', '(exec /usr/bin/env sleep 5)')+'''
            job=$!; budget_job_start=$(budget_process_start "$job")
            case "$mode" in
              exit0) (command sleep .05; exit 0) & ;;
              exit7) (command sleep .05; exit 7) & ;;
              sigkill) (command sleep 5) & ;;
              during-stop) (: > "$run/budget-failed"; command sleep .05; exit 9) & ;;
              normal) (command sleep 5) & ;;
            esac
            monitor=$!
            [ "$mode" != sigkill ] || kill -KILL "$monitor"
            budget_supervise
            kill "$monitor" 2>/dev/null || true; wait "$monitor" 2>/dev/null || true
            [ -s "$run/kill-called" ] || exit 1
            if [ "$mode" = normal ]; then [ "$rc" = 23 ]; else [ -e "$run/budget-failed" ]; fi
        ''')
    test('disabled mode is inert; incompatible policy refused', '''
        budget_prepare && [ "$budget_enabled" = 0 ] || exit 1
        HEAVY_DISK_STOP=1 HEAVY_LONG=1 HEAVY_WALL_CAP=2700 HEAVY_WALL_GRACE=30
        ! budget_prepare
    ''')
print('Kernel cgroup.kill integration is not simulated as a passing live-worker test.')
