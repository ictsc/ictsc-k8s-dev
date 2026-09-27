#!/usr/bin/env python3
"""Install Omni backup files using credentials held in Sakura Secret Manager."""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REMOTE = r'''
import base64,json,os,pathlib,subprocess,sys
payload=json.load(sys.stdin)
for path, item in payload['files'].items():
    target=pathlib.Path(path)
    data=base64.b64decode(item['content'])
    if item.get('preserve') and target.exists() and target.read_bytes()!=data:
        raise SystemExit('Existing Omni backup credential differs; preserved')
for path, item in payload['files'].items():
    target=pathlib.Path(path)
    temporary=target.with_name(target.name+'.install-new')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,item['mode'])
    with os.fdopen(fd,'wb') as stream:
        stream.write(base64.b64decode(item['content']))
    os.replace(temporary,target)
subprocess.run(['systemctl','daemon-reload'],check=True)
print('Installed backup scripts and root-only credentials; timer not enabled')
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    spec = importlib.util.spec_from_file_location('recovery', ROOT / 'scripts/recovery-secrets.py')
    recovery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recovery)
    secret = json.loads(recovery.Vault().get('omni-restic'))
    env = {'RESTIC_REPOSITORY': secret['repository'], 'RESTIC_PASSWORD_FILE': '/etc/omni-backup.password',
           'AWS_ACCESS_KEY_ID': secret['credentials']['ACCESS_KEY_ID'],
           'AWS_SECRET_ACCESS_KEY': secret['credentials']['ACCESS_SECRET_KEY'],
           'AWS_DEFAULT_REGION': secret['region'], 'AWS_REGION': secret['region']}
    payload = {'files': {}}

    def add(path, content, mode, preserve=False):
        payload['files'][path] = {'content': base64.b64encode(content).decode(), 'mode': mode, 'preserve': preserve}

    add('/etc/omni-backup.env', ''.join(k + '=' + shlex.quote(v) + '\n' for k, v in env.items()).encode(), 0o600, True)
    add('/etc/omni-backup.password', (secret['password'] + '\n').encode(), 0o600, True)
    for name, target in [('backup.sh', 'omni-backup'), ('verify-backup.sh', 'omni-verify-backup')]:
        add('/usr/local/sbin/' + target, (ROOT / 'omni/scripts' / name).read_bytes(), 0o750)
    for name in ('omni-backup.service', 'omni-backup.timer'):
        add('/etc/systemd/system/' + name, (ROOT / 'omni/backup' / name).read_bytes(), 0o644)
    # Existing Terraform credentials are transferred over SSH stdin only.
    outputs = recovery.run_json(['terraform', '-chdir=' + str(ROOT / 'omni/terraform'), 'output', '-json'])
    host = outputs['omni_ip']['value']
    password = outputs['console_password']['value']
    command = 'sudo -k -S -p "" python3 -c ' + shlex.quote(REMOTE)
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', 'ubuntu@' + host, command],
                            input=password + '\n' + json.dumps(payload), text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Omni backup installation failed; output suppressed to protect credentials')
    print('Installed Omni backup files; timer requires successful restore verification before enabling')


if __name__ == '__main__':
    main()
