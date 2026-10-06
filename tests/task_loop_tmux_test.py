#!/usr/bin/env python3
"""Test the real task-loop sidebar in an isolated tmux session.

Run: BONE_BIN=/path/to/bone3 python3 tests/task_loop_tmux_test.py
Uses a scripted local provider; preserves screen captures in its temp config.
"""
from pathlib import Path
import hashlib,json,os,queue,shlex,shutil,socket,subprocess,tempfile,time
root=Path(__file__).resolve().parents[1]
binary=os.environ.get('BONE_BIN') or shutil.which('bone3') or shutil.which('bone')
if not binary: raise SystemExit('set BONE_BIN to a Bone 3 executable')
config=Path(tempfile.mkdtemp(prefix='bone-task-loop-tmux-'))
shutil.copytree(root/'plugins/task_loop',config/'plugins/task_loop')
(config/'core.lua').write_text('''
bone.rpc.register("task_loop_test.run", function(args, ctx)
  local result, err = bone._run_tool("task_loop", args, ctx)
  if not result then error(err) end
  return result
end)
bone.provider.register("task_loop_test", { complete = function(req)
  bone.sleep(300)
  local state = require("task_loop.state").load(req.session_id)
  if state.active and req.messages[#req.messages].role ~= "tool" then
    return { content = "", tool_calls = {
      { id = "advance", name = "task_loop", arguments = { action = "advance" } }
    } }
  end
  return { content = "Verified this session's task." }
end })
bone.config.providers.test = { type = "task_loop_test", model = "local" }
bone.config.provider = "test"
''')
(config/'settings.json').write_text(json.dumps({'setup':{'skipped':True}}))
sockpath=str(config/'bone.sock')
env=dict(os.environ,BONE_CONFIG_DIR=str(config))
errfile=open(config/'server.err','w')
server=subprocess.Popen([binary,'--headless','--listen',sockpath],env=env,stdout=subprocess.DEVNULL,stderr=errfile)
name='bone-task-loop-test-'+str(os.getpid())
client=None
serial=0
events=[]
screens=[]
def tmux(*args):
 return subprocess.check_output(['tmux',*args],text=True)
def wait(predicate, label, timeout=10):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  if predicate():return
  time.sleep(.05)
 raise AssertionError(label+'\n'+screen())
def call(method,params=None):
 global serial
 serial+=1
 client.sendall((json.dumps({'jsonrpc':'2.0','id':serial,'method':method,'params':params or {}})+'\n').encode())
 while True:
  line=reader.readline()
  assert line,'server closed'
  msg=json.loads(line)
  if msg.get('id')==serial:
   assert 'error' not in msg,msg
   return msg['result']
  events.append(msg)
def tool(sid,action,**args):
 return call('lua/call',{'name':'task_loop_test.run','session_id':sid,'args':dict(args,action=action)})
def state(sid):
 return json.loads((config/('state/shared/task_loop.'+hashlib.sha256(sid.encode()).hexdigest()+'.json')).read_text())
def screen():
 return tmux('capture-pane','-p','-N','-t',name+':0.0')
def sidebar():
 return '\n'.join(line[88:] for line in screen().splitlines())
def command(text):
 tmux('send-keys','-t',name+':0.0','-l',text)
 tmux('send-keys','-t',name+':0.0','Enter')
def capture(label):
 s=screen()
 screens.append(label+'\n'+s)
 print(label+'\n'+'\n'.join(line.rstrip() for line in sidebar().splitlines() if line.strip()))
try:
 wait(lambda:Path(sockpath).exists(),'socket startup')
 client=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
 client.settimeout(10)
 client.connect(sockpath)
 reader=client.makefile('rb')
 call('initialize',{'protocol_version':0,'client_name':'task-loop-tmux-test'})
 a=call('session/create')['session_id'];b=call('session/create')['session_id']
 call('session/rename',{'session_id':a,'title':'Session A'})
 call('session/rename',{'session_id':b,'title':'Session B'})
 (config/'tui.lua').write_text('''
bone.cmd.create("test_a", function() bone.api.open_session(%s) end)
bone.cmd.create("test_b", function() bone.api.open_session(%s) end)
'''%(json.dumps(a),json.dumps(b)))
 launch=shlex.join(['env','BONE_CONFIG_DIR='+str(config),binary,'--connect',sockpath,'--resume',a])
 tmux('new-session','-d','-s',name,'-x','120','-y','40','-c',str(config),launch)
 wait(lambda:'Message bone' in screen(),'TUI startup')
 command('/task A manual')
 wait(lambda:'A manual' in sidebar(),'A sidebar')
 assert 'Tasks 1/1' in sidebar(),sidebar()
 capture('A: manual task')
 command('/test_b')
 wait(lambda:'nothing to do' in sidebar(),'B empty sidebar')
 assert 'A manual' not in sidebar()
 capture('B: empty list after switch')
 command('/task B manual')
 wait(lambda:'B manual' in sidebar(),'B task')
 assert state(a)['tasks'][0]['text']=='A manual'
 assert state(b)['tasks'][0]['text']=='B manual'
 capture('B: independent manual task')
 command('/test_a')
 wait(lambda:'A manual' in sidebar() and 'B manual' not in sidebar(),'return to A')
 command('/task')
 time.sleep(.1)
 tmux('send-keys','-t',name+':0.0','Enter')
 wait(lambda:state(a)['tasks'][0]['done'],'toggle A')
 assert not state(b)['tasks'][0]['done']
 tmux('send-keys','-t',name+':0.0','Escape')
 capture('A: checkbox toggle leaves B untouched')
 tool(a,'write',tasks=['A auto 1','A auto 2'])
 tool(b,'write',tasks=['B auto 1','B auto 2'])
 call('turn/start',{'session_id':b,'text':'Run B checklist'})
 command('Run A checklist')
 wait(lambda:all(t['done'] for t in state(a)['tasks']) and all(t['done'] for t in state(b)['tasks']),'both automatic loops')
 wait(lambda:'Tasks 0/2' in sidebar() and 'A auto 2' in sidebar(),'foreground finish refresh')
 assert 'B auto' not in sidebar()
 assert not state(a)['active'] and not state(b)['active']
 capture('A: concurrent loops completed, sidebar stays on A')
 command('/test_b')
 wait(lambda:'Tasks 0/2' in sidebar() and 'B auto 2' in sidebar(),'B completed sidebar')
 assert 'A auto' not in sidebar()
 capture('B: completed list after switch')
 command('/new')
 wait(lambda:'nothing to do' in sidebar(),'new chat empty sidebar')
 assert 'A auto' not in sidebar() and 'B auto' not in sidebar()
 command('/task unowned')
 wait(lambda:'create this session before adding tasks' in screen(),'unsaved chat guard')
 assert len(state(a)['tasks'])==2 and len(state(b)['tasks'])==2
 capture('New chat: empty and cannot modify saved sessions')
 assert 'Lua error' not in screen(),screen()
 # Reload the TUI while B is selected and confirm persisted sidebar state.
 command('/test_b')
 wait(lambda:'B auto 2' in sidebar(),'B before reload')
 command('/plugins reload task_loop')
 wait(lambda:'B auto 2' in sidebar() and 'Tasks 0/2' in sidebar(),'sidebar after reload')
 time.sleep(.2)
 assert 'Lua error' not in screen(),screen()
 capture('B: persisted sidebar after plugin reload')
 print('PASS: real tmux sidebar, selection/toggle, switching, concurrent automatic loops, new chat guard and reload')
finally:
 (config/'tmux-screens.txt').write_text('\n\n'.join(screens))
 print('Artifacts:',config)
 subprocess.run(['tmux','kill-session','-t',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 if client:
  try:call('shutdown')
  except Exception:pass
  client.close()
 try:server.wait(timeout=5)
 except subprocess.TimeoutExpired:server.kill();server.wait()
 errfile.close()
