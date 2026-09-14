"""Install the local app and a per-user login agent without elevated privileges."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

mode, source, destination = sys.argv[1:]
app = pathlib.Path(destination) / 'Codex Numbers.app'
agent = pathlib.Path.home() / 'Library/LaunchAgents/local.codex-numbers.plist'
service = f'gui/{os.getuid()}'
subprocess.run(['launchctl', 'bootout', f'{service}/local.codex-numbers'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if mode == 'install':
    app.parent.mkdir(parents=True, exist_ok=True)
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(source, app)
    agent.parent.mkdir(parents=True, exist_ok=True)
    config = {'Label': 'local.codex-numbers', 'ProgramArguments': [str(app / 'Contents/MacOS/CodexNumbers')], 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10}
    if os.environ.get('CODEX_HOME'):
        config['EnvironmentVariables'] = {'CODEX_HOME': os.environ['CODEX_HOME']}
    agent.write_bytes(plistlib.dumps(config))
    subprocess.run(['launchctl', 'bootstrap', service, str(agent)], check=True)
    print(f'Установлено: {app}\nАвтозапуск: {agent}')
else:
    agent.unlink(missing_ok=True)
    if app.exists():
        shutil.rmtree(app)
    print('Приложение и автозапуск удалены; журналы Codex сохранены.')
