"""Explicit local setup and approval console. No service, listener or keys on import."""
import argparse
import asyncio
import inspect
import json
import os
from pathlib import Path
import re
import select
import sys
import uuid
from . import paired_identity as identity_store
from . import paired_protocol as wire
from .autonomy import DEFAULT_LIMITS
from .core import check_links
from .paired_host import PairedHost

CONFIG_FILE='host-config.json'
HELP='Commands: projects, invite PROJECT_ID, pending, devices, approve DEVICE_ID SAFETY_CODE, revoke DEVICE_ID, quit. No shell commands.'

def require_runtime():
    if sys.version_info[:2]<(3,11):raise wire.ProtocolError('python_3_11_required')

def configure(state_dir,origin,workspace,label,model,*,approve):
    require_runtime();identity_store.parse_origin(origin)
    state=Path(os.path.abspath(state_dir));work=Path(os.path.abspath(workspace))
    identity_store.require_non_repository_state(state);check_links(state.parent);check_links(work)
    if state.exists() or state.is_symlink() or not work.is_dir() or state==work or state in work.parents or work in state.parents:raise wire.ProtocolError('invalid_setup')
    wire.text(label,256,scalars=64);wire.text(model,128)
    if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.:-]*',model) or 'cloud' in model.lower():raise wire.ProtocolError('invalid_setup')
    preview=(f'Create a persistent private host identity for {origin}?\nProject: {label}\nRead-only workspace: {work}\nTrusted installed local model: {model}\nPrivate state: {state}\n'
             'Keep private state outside ALL Git worktrees, cloud-synced and shared folders. Cloud-sync status is not detected. '
             'Phones you approve separately can submit bounded read-only jobs and receive file-derived results. '
             'The selected local model receives the goal and bounded file observations. Existing notes are not shared. '
             'This does not start a listener, install a service/model or change any firewall. '
             'Revoke devices in the foreground console. The identity persists until deliberately removed.')
    if approve(preview) is not True:return None
    identity_store.create_private_state_directory(state,approved=True)
    identity=identity_store.initialize_identity(state,origin,approved=True)
    project=dict(project_id=str(uuid.uuid4()),label=label,workspace=str(work),permission_revision=1,model=model,trust_local_model=True,limits=dict(DEFAULT_LIMITS))
    host=PairedHost(state,identity['host_id'],[project],create=True);host.close()
    identity_store.create_private_file(state,CONFIG_FILE,json.dumps(dict(v=1,projects=[project]),separators=(',',':')).encode())
    return identity

def open_host(state_dir):
    require_runtime();identity=identity_store.load_identity(state_dir)
    configuration=wire.load_object(identity_store.read_private_file(state_dir,CONFIG_FILE,65536),65536)
    wire.exact(configuration,('v','projects'));wire.version(configuration['v'])
    return PairedHost(state_dir,identity['host_id'],configuration['projects']),identity

async def decision(confirm,message):
    result=confirm(message)
    if inspect.isawaitable(result):result=await result
    return result is True

async def local_command(host,identity,line,*,confirm,display):
    parts=line.strip().split()
    if not parts:return True
    if len(line)>512:display('Invalid command.');return True
    command=parts[0]
    try:
        if command=='quit' and len(parts)==1:return False
        if command=='help' and len(parts)==1:display(HELP);return True
        if command=='projects' and len(parts)==1:
            for project in host._projects.values():display(f"{project['project_id']}  {project['label']}  read-only  {project['workspace']}")
            return True
        if command=='invite' and len(parts)==2:
            invitation=host.create_invitation([wire.identifier(parts[1])])
            descriptor=dict(invitation,origin=identity['origin'],tls_leaf_sha256=identity['tls_leaf_sha256'])
            display('Paste this private ten-minute invitation only into your own iPhone pairing review. Do not save or share it elsewhere.')
            display(json.dumps(descriptor,separators=(',',':')));return True
        if command in ('pending','devices') and len(parts)==1:
            with host.transaction() as db:rows=[dict(row) for row in db.execute('SELECT device_id,name,state,safety_code,grants FROM devices')]
            for row in rows:
                if command=='pending' and row['state']!='pending':continue
                display(f"{row['device_id']}  {row['name']}  {row['state']}"+(f"  safety code {row['safety_code']}" if row['state']=='pending' else ''))
                for grant in json.loads(row['grants']):display(f"  {grant['project_id']}  {grant['label']}  jobs.read_only")
            if not rows:display('No devices enrolled.')
            return True
        if command in ('approve','revoke') and len(parts)==(3 if command=='approve' else 2):
            device=wire.identifier(parts[1])
            with host.transaction() as db:row=db.execute('SELECT name,state,grants FROM devices WHERE device_id=?',(device,)).fetchone()
            if not row:display('Invalid device.');return True
            scopes=[]
            for grant in json.loads(row['grants']):
                project=host._projects.get(grant['project_id'])
                if project is None:raise wire.ProtocolError()
                scopes.append(f"{grant['label']} ({grant['project_id']}): bounded read-only jobs and file-derived results\n  Workspace: {project['workspace']}\n  Trusted local model: {project['model']}\n  Limits: {json.dumps(project['limits'],sort_keys=True)}")
            if command=='approve':
                prompt=f"Approve persistent access for {row['name']} ({device})?\n"+'\n'.join(scopes)+'\nCompare the safety code on both devices. No existing notes or workspace writes are authorized. You can revoke future access here; received information cannot be recalled. Type APPROVE to continue: '
                if await decision(confirm,prompt):host.approve_device(device,parts[2]);display('Device approved.')
                else:display('Approval cancelled.')
            else:
                if await decision(confirm,f"Revoke {row['name']} ({device})? New requests will be denied; running work stops cooperatively. Type APPROVE to continue: "):host.revoke_device(device);display('Device revoked. Already received results cannot be recalled.')
                else:display('Revocation cancelled.')
            return True
        display('Command not available. Type help for fixed commands.')
    except (ValueError,KeyError,TypeError):display('Invalid request or unavailable private state. No permission was expanded.')
    return True

async def console_line():
    if os.name=='nt':
        import msvcrt
        value=''
        while True:
            if msvcrt.kbhit():
                char=msvcrt.getwch()
                if char in ('\x00','\xe0'):msvcrt.getwch();continue
                if char=='\x03':raise KeyboardInterrupt
                if char in ('\r','\n'):print();return value
                if char=='\x1a':return None
                if char=='\b':
                    if value:value=value[:-1];print('\b \b',end='',flush=True)
                elif char.isprintable() and len(value)<512:value+=char;print(char,end='',flush=True)
            await asyncio.sleep(.05)
    while True:
        if select.select([sys.stdin],[],[],0)[0]:
            value=sys.stdin.readline(514);return None if value=='' else value.rstrip('\r\n')
        await asyncio.sleep(.05)

async def serve(state_dir):
    from .paired_https import PairedHTTPSService
    host,identity=open_host(state_dir);service=None
    try:
        context=identity_store.server_ssl_context(state_dir);service=PairedHTTPSService(host,identity);await service.start(context)
        print(f"Foreground host listening only at {identity['origin']}. Closing it stops connectivity. No firewall rules were changed.");print(HELP)
        async def confirm(message):print(message,end='',flush=True);return await console_line()=='APPROVE'
        while True:
            if service.dispatch_failed:print('Job dispatcher unavailable. No new jobs are accepted. Stop and inspect private state.');break
            print('veyra> ',end='',flush=True);line=await console_line()
            if line is None or not await local_command(host,identity,line,confirm=confirm,display=print):break
    finally:
        try:
            if service:await service.close()
        finally:host.close()

def main(argv=None):
    parser=argparse.ArgumentParser(description='Reviewed foreground paired read-only host');commands=parser.add_subparsers(dest='command',required=True)
    setup=commands.add_parser('setup',help='Review and initialize a new protected identity; never listen')
    for name in ('state','origin','workspace','label','model'):setup.add_argument('--'+name,required=True)
    run=commands.add_parser('serve',help='Review and launch configured foreground host');run.add_argument('--state',required=True);args=parser.parse_args(argv)
    if not sys.stdin.isatty() or not sys.stdout.isatty():print('An interactive private terminal is required; invitations must not be redirected to files.',file=sys.stderr);return 2
    try:
        require_runtime()
        if args.command=='setup':
            def approve(preview):print(preview);return input('Type SET UP to create this persistent identity: ')=='SET UP'
            result=configure(args.state,args.origin,args.workspace,args.label,args.model,approve=approve);print('Setup complete. No listener was started.' if result else 'Setup cancelled. No identity created.')
        else:
            identity=identity_store.load_identity(args.state);print(f"Start foreground HTTPS only at {identity['origin']}? Devices allowed by your existing network/firewall may reach it. No settings will be changed.")
            if input('Type START to continue: ')!='START':print('Launch cancelled.');return 0
            asyncio.run(serve(args.state))
        return 0
    except KeyboardInterrupt:print('\nForeground host stopped.');return 0
    except (OSError,ValueError,KeyError,TypeError) as error:
        code=error.code if isinstance(error,(wire.ProtocolError,identity_store.IdentityError)) else 'state_unavailable'
        print('Host unavailable: '+code+'. Existing state was not reset.',file=sys.stderr);return 1

if __name__=='__main__':raise SystemExit(main())
