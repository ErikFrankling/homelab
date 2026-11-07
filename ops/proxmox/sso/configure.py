#!/usr/bin/env python3
"""Run on Proxmox; read the OIDC client secret from stdin, never log it."""
import json,os,subprocess,sys
from pathlib import Path
from datetime import datetime,timezone
secret=sys.stdin.read().strip()
assert len(secret)>32
backup=Path('/root/homelab-sso-backups')/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup.mkdir(parents=True,mode=0o700)
for name in ['domains.cfg','user.cfg']:
    p=Path('/etc/pve')/name
    if p.exists():
        dest=backup/name;dest.write_bytes(p.read_bytes());dest.chmod(0o600)
realms=json.loads(subprocess.check_output(['pveum','realm','list','--output-format','json']))
action='modify' if any(x['realm']=='homelab' for x in realms) else 'add'
args=['pveum','realm',action,'homelab']
if action=='add': args+=['--type','openid']
args+=['--issuer-url','https://auth.erikfrankling.duckdns.org/application/o/proxmox/',
       '--client-id','homelab-proxmox','--client-key',secret,'--username-claim','preferred_username',
       '--autocreate','0','--default','1','--scopes','email profile']
subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
users=json.loads(subprocess.check_output(['pveum','user','list','--output-format','json']))
if not any(x['userid']=='akadmin@homelab' for x in users):
    subprocess.run(['pveum','user','add','akadmin@homelab','--email','erik.frankling@frankling.se'],check=True)
subprocess.run(['pveum','acl','modify','/','--users','akadmin@homelab','--roles','Administrator'],check=True)
print('Native OIDC realm configured; recovery config backed up to',backup)
