import subprocess, sys, time, pathlib
cmd = sys.argv[1:]
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
peak = 0
status = pathlib.Path(f'/proc/{proc.pid}/status')
start = time.perf_counter()
while proc.poll() is None:
    try:
        text = status.read_text()
        for line in text.splitlines():
            if line.startswith('VmRSS:'):
                rss = int(line.split()[1])
                peak = max(peak, rss)
                break
    except FileNotFoundError:
        pass
    time.sleep(0.001)
out, err = proc.communicate()
elapsed = time.perf_counter() - start
print(out, end='')
if err:
    print(err, end='', file=sys.stderr)
print(f'ELAPSED_SEC={elapsed:.3f}')
print(f'PEAK_RSS_KB={peak}')
sys.exit(proc.returncode)
