import resource
import subprocess
import sys
import time

cmd = sys.argv[1:]
start = time.perf_counter()
proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
elapsed = time.perf_counter() - start
usage = resource.getrusage(resource.RUSAGE_CHILDREN)
print(proc.stdout, end="")
if proc.stderr:
    print(proc.stderr, file=sys.stderr, end="")
print(f"ELAPSED_SEC={elapsed:.3f}")
print(f"MAX_RSS_KB={usage.ru_maxrss}")
sys.exit(proc.returncode)
