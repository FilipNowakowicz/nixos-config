"""Regression checks for isolated shell state and safe process signalling."""
import ast
import importlib.util
import os
from pathlib import Path
import signal
import sys
import tempfile
import types
from unittest.mock import Mock, patch

source = Path(sys.argv[1])
package = types.ModuleType('control_center')
package.__path__ = [str(source)]
sys.modules['control_center'] = package


def load(name):
    full = f'control_center.{name}'
    spec = importlib.util.spec_from_file_location(full, source / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[full] = module
    spec.loader.exec_module(module)
    return module


with tempfile.TemporaryDirectory() as runtime:
    with patch.dict(os.environ, XDG_RUNTIME_DIR=runtime, WAYLAND_DISPLAY='test-a'):
        constants = load('constants')
        first_path = constants.STATE_PATH
        state = load('state_file')
    with patch.dict(os.environ, XDG_RUNTIME_DIR=runtime, WAYLAND_DISPLAY='test-b'):
        assert load('constants').STATE_PATH != first_path
    state.acquire_lock()
    state.write_state(os.getpid(), 'wifi', True)
    saved = state.read_state()
    assert state.process_alive(os.getpid(), saved['start_time'])
    assert not state.process_alive(os.getpid(), 'stale-start-time')
    assert not state.process_alive(None, None)
    assert not state.process_alive(-1, None)
    with patch.object(signal, 'pidfd_send_signal', create=True) as send:
        assert state.signal_instance(saved, signal.SIGCONT)
        send.assert_called_once()
        send.reset_mock()
        assert not state.signal_instance({**saved, 'start_time': 'stale'}, signal.SIGCONT)
        send.assert_not_called()
        assert not state.signal_instance({'pid': -1}, signal.SIGCONT)
    # A remote update must preserve its observed identity even if the PID changes.
    with patch.object(state, 'process_start_time', return_value='reused'):
        state.write_state(os.getpid(), 'home', False, saved['start_time'])
        assert state.read_state()['start_time'] == saved['start_time']
    state.clear_state(os.getpid() + 1)
    assert state.read_state()
    state.clear_state(os.getpid())
    assert state.read_state() == {}
    state.release_lock()

# Extract launcher submission logic without requiring GTK for a unit check.
launcher = ast.parse(Path(sys.argv[2]).read_text())
klass = next(n for n in launcher.body if isinstance(n, ast.ClassDef) and n.name == 'Launcher')
launch = next(n for n in klass.body if isinstance(n, ast.FunctionDef) and n.name == '_launch')
import shlex
spawn = Mock()
namespace = {'subprocess': types.SimpleNamespace(Popen=spawn, DEVNULL=-3), 'shlex': shlex, 'sys': sys}
exec(compile(ast.Module(body=[launch], type_ignores=[]), '<launcher submission>', 'exec'), namespace)
app = types.SimpleNamespace(typed='foot', quit=Mock())
namespace['_launch'](app)
assert spawn.call_args.args[0] == ['foot']
app.typed = 'printf "two words"'
namespace['_launch'](app)
assert spawn.call_args.args[0] == ['printf', 'two words']
app.quit.reset_mock()
app._set_error = Mock()
app.typed = 'missing-command'
spawn.side_effect = FileNotFoundError()
namespace['_launch'](app)
assert app.typed == 'missing-command'
app._set_error.assert_called_once()
app.quit.assert_not_called()
print('Desktop shell state and launcher regression checks passed')

actions = ast.parse((source / 'actions.py').read_text())
dnd = next(n for n in actions.body if isinstance(n, ast.FunctionDef) and n.name == 'act_set_dnd_mode')
fire = Mock()
action_namespace = {'_fire': fire}
exec(compile(ast.Module(body=[dnd], type_ignores=[]), '<DND action>', 'exec'), action_namespace)
action_namespace['act_set_dnd_mode']('do-not-disturb')
assert fire.call_args.args[0] == ['makoctl', 'mode', '-a', 'do-not-disturb']
action_namespace['act_set_dnd_mode']('default')
assert fire.call_args.args[0] == ['makoctl', 'mode', '-r', 'do-not-disturb']
print('DND preserves unrelated mako modes')

launch_helpers = [n for n in actions.body if isinstance(n, ast.FunctionDef)
                  and n.name in ('_fire', '_fire_if_found', 'act_open_bluetooth_settings', 'act_open_sound_settings')]
spawn = Mock()
launch_namespace = {'subprocess': types.SimpleNamespace(Popen=spawn, DEVNULL=-3),
                    'shutil': types.SimpleNamespace(which=Mock(return_value='/private/blueman-manager'))}
exec(compile(ast.Module(body=launch_helpers, type_ignores=[]), '<settings launch>', 'exec'), launch_namespace)
assert launch_namespace['act_open_bluetooth_settings']()
assert spawn.call_args.args[0] == ['/private/blueman-manager']
spawn.reset_mock()
launch_namespace['shutil'].which.return_value = None
assert not launch_namespace['act_open_bluetooth_settings']()
spawn.assert_not_called()
launch_namespace['shutil'].which.return_value = '/private/blueman-manager'
spawn.side_effect = FileNotFoundError()
assert not launch_namespace['act_open_bluetooth_settings']()
spawn.side_effect = None
launch_namespace['shutil'].which.return_value = '/private/pavucontrol'
assert launch_namespace['act_open_sound_settings']()
assert spawn.call_args.args[0] == ['/private/pavucontrol']
spawn.reset_mock()
launch_namespace['shutil'].which.return_value = None
assert not launch_namespace['act_open_sound_settings']()
spawn.assert_not_called()
launch_namespace['shutil'].which.return_value = '/private/pavucontrol'
spawn.side_effect = OSError('settings process cannot start')
assert not launch_namespace['act_open_sound_settings']()
print('Settings handoff distinguishes missing tools and failed process startup')
