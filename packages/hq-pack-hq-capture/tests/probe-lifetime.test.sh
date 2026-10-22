#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${CAPTURE_LIFETIME_REPO:-$(cd "$here/../../.." && pwd)}"
python3 -I - "$repo" <<'PY'
import pathlib,tempfile,subprocess,os,signal,time,json
repo=pathlib.Path(__import__('sys').argv[1]); passed=0
with tempfile.TemporaryDirectory(prefix='capture-lifetime-') as td:
 t=pathlib.Path(td);(t/'bin').mkdir()
 fake=t/'bin/xcrun';fake.write_text('#!/usr/bin/env python3\nimport os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nsignal.signal(signal.SIGINT,signal.SIG_IGN)\nopen(os.environ["PROBE_PID"],"w").write(str(os.getpid()))\nmode=os.environ.get("PROBE_EXIT")\nif mode: raise SystemExit(int(mode))\nwhile True: time.sleep(0.05)\n');fake.chmod(0o755)
 def alive(pid):
  try:os.kill(pid,0);return True
  except ProcessLookupError:return False
 for pack in ['hq-pack-hq-capture','hq-pack-screen-recorder']:
  source=(repo/'packages'/pack/'scripts/hq-record-process.sh').read_text(); funcs=[]
  for name in ['swiftc_frontend_args','run_probe_typecheck']:
   a=source.index(name+'() {');b=source.index('\n}',a)+2;funcs.append(source[a:b])
  entry=t/(pack+'.sh');entry.write_text('\n'.join(funcs)+'\nrun_probe_typecheck /synthetic/toolchain /synthetic/probe.swift\n')
  for mode,expected in [('TERM',143),('INT',130),('TIMEOUT',124),('SUCCESS',0),('FAIL',22)]:
   pidfile=t/(pack+mode+'.pid');env={**os.environ,'PATH':str(t/'bin')+':'+os.environ['PATH'],'PROBE_PID':str(pidfile),'HQ_RECORDER_PROBE_TIMEOUT':'1' if mode=='TIMEOUT' else '10'}
   if mode in ['SUCCESS','FAIL']:env['PROBE_EXIT']=str(expected)
   p=subprocess.Popen(['/bin/bash',str(entry)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);child=None
   try:
    deadline=time.monotonic()+4
    while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.01)
    assert pidfile.exists(),'compiler not started';child=int(pidfile.read_text())
    if mode in ['TERM','INT']:p.send_signal(getattr(signal,'SIG'+mode))
    p.wait(timeout=5)
    assert p.returncode==expected,(pack,mode,p.returncode)
    assert not alive(child),(pack,mode,'compiler survived wrapper exit',child)
    passed+=1;print('PASS',pack,mode,'exit',p.returncode,'child reaped',flush=True)
   finally:
    if p.poll() is None:p.kill();p.wait()
    if child and alive(child):
     try:os.killpg(child,signal.SIGKILL)
     except ProcessLookupError:pass
 print(json.dumps({'passed':passed,'syntheticOnly':True,'compilerSignals':'TERM/INT ignored','actualExtractedFunctions':True}),flush=True)
PY
