"""Internal worker: cap sampler output before exec, without preexec_fn in threads."""
import os
import resource
import sys

if __name__ == '__main__':
    if len(sys.argv) != 3 or not sys.argv[1].isdigit():
        raise SystemExit('Expected PID and private output path')
    resource.setrlimit(resource.RLIMIT_FSIZE, (16*1024*1024, 16*1024*1024))
    os.execv('/usr/bin/sample', ['sample',sys.argv[1],'1','10','-mayDie','-file',sys.argv[2]])
