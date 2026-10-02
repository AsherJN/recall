#!/usr/bin/env python3
"""Real macOS process/mapping isolation and 25-second closer, with owned fixtures.

No game or Wine process is signalled. Fixtures model executable names and mapped
engine/prefix files, including foreign prefixes/engines and an update Agent.
"""
import argparse,json,os,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--worker',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();worker=a.worker.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
with tempfile.TemporaryDirectory(prefix='ow2-session-fixture-') as temp:
    base=Path(temp).resolve();root=base/'Owned Installation';other=base/'Foreign Installation'
    def call(command):
        r=subprocess.run([str(worker),command,'--root',str(root)],capture_output=True,text=True,timeout=20);r.check_returncode();(out/(command+'.jsonl')).write_text(r.stdout);return [json.loads(x) for x in r.stdout.splitlines()]
    call('status')
    engine=root/'runtimes/v1';engine.mkdir();(engine/'runtime.json').write_text('{}');(root/'state.json').write_text('{"active_runtime":"v1","schema":1}')
    prefix=root/'environment';prefix.mkdir();foreign=other/'environment';foreign.mkdir(parents=True)
    source=base/'fixture.c';source.write_text('#include <dlfcn.h>\n#include <unistd.h>\n#include <fcntl.h>\nint main(int argc,char **argv){if(argc!=3||!dlopen(argv[1],RTLD_NOW))return 2;int fd=open(argv[2],O_CREAT|O_WRONLY,0600);if(fd<0)return 3;close(fd);for(;;)pause();}\n')
    libsrc=base/'library.c';libsrc.write_text('int fixture_library(void){return 1;}\n')
    binary=base/'fixture';library=engine/'fixture.dylib';foreignlib=other/'fixture.dylib'
    subprocess.run(['clang',str(source),'-o',str(binary)],check=True)
    subprocess.run(['clang','-dynamiclib',str(libsrc),'-o',str(library)],check=True)
    subprocess.run(['/bin/cp',str(library),str(foreignlib)],check=True)
    processes=[]
    def start(directory,name,lib):
        path=directory/name;subprocess.run(['/bin/cp',str(binary),str(path)],check=True)
        ready=base/('ready-'+str(len(processes)))
        proc=subprocess.Popen([str(path),str(lib),str(ready)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);processes.append(proc)
        deadline=time.monotonic()+15
        while not ready.exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.05)
        assert ready.exists() and proc.poll() is None,'Fixture never mapped its library'
        return proc
    try:
        client=start(prefix,'C:\\Program Files\\Battle.net.exe',library)
        game=start(prefix,'Overwatch.exe',library)
        agent=start(prefix,'Agent.exe',library)
        foreignClient=start(foreign,'C:\\Program Files\\Battle.net.exe',library)
        foreignEngine=start(prefix,'D:\\Battle.net.exe',foreignlib)
        rows=call('session')[-1]['processes'];
        if not rows:
            table=subprocess.check_output(['ps','-axo','pid=,lstart=,comm='],text=True)
            (out/'fixture-identity.log').write_text('\n'.join(line for line in table.splitlines() if line.strip().split()[0] in {str(x.pid) for x in processes})+'\n'+subprocess.check_output(['lsof','-a','-p',str(client.pid),'-d','txt','-Fn'],text=True))
        assert {r['pid'] for r in rows}=={client.pid,game.pid},rows
        blocked=subprocess.run([str(worker),'display','--root',str(root),'--height','1080'],capture_output=True,text=True)
        assert blocked.returncode and json.loads(blocked.stdout)['code']=='close_game_before_maintenance'
        registry=prefix/'user.reg';registry.write_text('WINE REGISTRY Version 2\n')
        blocked=subprocess.run([str(worker),'repair-retina','--root',str(root)],capture_output=True,text=True)
        assert blocked.returncode and json.loads(blocked.stdout)['code']=='close_game_before_setup'
        assert registry.read_text()=='WINE REGISTRY Version 2\n'
        assert all(p.poll() is None for p in processes),'Retina migration disturbed a running process'
        monitor=subprocess.Popen([str(worker),'watch','--root',str(root)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True);processes.append(monitor)
        time.sleep(5);assert client.poll() is None,'Client closed before grace period'
        report,_=monitor.communicate(timeout=40)
        assert monitor.returncode==0,report
        client.wait(timeout=5);assert client.returncode==-15,client.returncode
        assert all(p.poll() is None for p in [game,agent,foreignClient,foreignEngine]),'Unrelated process was signalled'
        (out/'result.json').write_text(json.dumps({'scoped_membership':True,'grace_period_preserved':True,'client_sigterm':True,'game_agent_foreign_prefix_foreign_engine_preserved':True,'monitor_exited_after_close':True,'display_change_rejected_during_game':True},indent=2)+'\n')
        print('PASS: exact prefix/engine membership, 25-second grace, scoped close and monitor exit')
    finally:
        for proc in processes:
            if proc.poll() is None:proc.terminate()
        for proc in processes:
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
