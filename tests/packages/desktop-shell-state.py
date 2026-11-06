"""Regression checks for isolated shell state and safe process signalling."""
import ast
import importlib.util
import os
from pathlib import Path
import signal
import sys
import tempfile
import types
import socket
import re
import json
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
app = types.SimpleNamespace(typed='foot', mode='command', quit=Mock())
namespace['_launch'](app)
assert spawn.call_args.args[0] == ['foot']
app.typed = 'printf "two words"'
namespace['_launch'](app)
assert spawn.call_args.args[0] == ['printf', 'two words']
app.mode = 'apps'
app.typed = '> printf "two words"'
namespace['_launch'](app)
assert spawn.call_args.args[0] == ['printf', 'two words']
app.mode = 'command'
app.quit.reset_mock()
app._set_error = Mock()
app.typed = 'missing-command'
spawn.side_effect = FileNotFoundError()
namespace['_launch'](app)
assert app.typed == 'missing-command'
app._set_error.assert_called_once()
app.quit.assert_not_called()
print('Desktop shell state and launcher regression checks passed')

import unicodedata
ranking = {'unicodedata': unicodedata}
helpers = [n for n in launcher.body if isinstance(n, ast.FunctionDef)
           and n.name in ('search_text', 'find_applications')]
exec(compile(ast.Module(body=helpers, type_ignores=[]), '<application search>', 'exec'), ranking)
apps = [
    {'id': 'browser', 'name': 'Firefox', 'executable': 'firefox', 'keywords': ['web', 'browser']},
    {'id': 'terminal', 'name': 'Terminal', 'executable': 'foot', 'keywords': ['shell']},
    {'id': 'longer', 'name': 'Footclient', 'executable': 'footclient', 'keywords': []},
    {'id': 'cafe', 'name': 'Café Editor', 'executable': 'cafe', 'keywords': ['text']},
]
find_apps = ranking['find_applications']
assert find_apps(apps, 'foot')[0]['id'] == 'terminal'
assert find_apps(apps, 'FIREFOX')[0]['id'] == 'browser'
assert find_apps(apps, 'web browser')[0]['id'] == 'browser'
assert find_apps(apps, 'cafe')[0]['id'] == 'cafe'
assert find_apps(apps, 'absent') == []
assert len(find_apps(apps, '', limit=2)) == 2
print('Application ranking and explicit command mode checks passed')

window_helpers = [n for n in launcher.body if isinstance(n, ast.FunctionDef)
                  and n.name in ('window_records', 'hypr_target', 'hypr_query', 'contains_launcher_layer', 'switch_window')]
window_namespace = {'re': re, 'os': os, 'Path': Path, 'json': json, 'subprocess': __import__('subprocess')}
exec(compile(ast.Module(body=window_helpers, type_ignores=[]), '<window identity>', 'exec'), window_namespace)
records = window_namespace['window_records']([
    {'stableId': 'aa', 'address': 'same-address', 'title': 'Current', 'focusHistoryID': 0},
    {'stableId': 'bb', 'address': 'same-address', 'title': 'Previous', 'focusHistoryID': 1},
    {'address': 'cached-address-only'}, {'stableId': 'cc', 'mapped': False},
    {'stableId': 'unsafe"; code()'},
])
assert len(records) == 2
assert find_apps(records, '')[0]['id'] == 'bb'
assert {r['id'] for r in records} == {'aa', 'bb'}

with tempfile.TemporaryDirectory() as runtime:
    with patch.dict(os.environ, XDG_RUNTIME_DIR=runtime, HYPRLAND_INSTANCE_SIGNATURE='private_test'):
        try:
            window_namespace['hypr_target']()
            raise AssertionError('Missing explicit socket was accepted')
        except OSError:
            pass
        socket_path = Path(runtime) / 'hypr/private_test/.socket.sock'
        socket_path.parent.mkdir(parents=True)
        with socket.socket(socket.AF_UNIX) as ipc:
            ipc.bind(str(socket_path))
            assert window_namespace['hypr_target']() == ('private_test', runtime)
        with patch.dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE='../host'):
            try:
                window_namespace['hypr_target']()
                raise AssertionError('Unsafe compositor selector was accepted')
            except OSError:
                pass

assert window_namespace['contains_launcher_layer']({'HEADLESS-1': {'levels': {'3': [{'namespace': 'launcher'}]}}})
assert not window_namespace['contains_launcher_layer']({'HEADLESS-1': {'levels': {'3': [{'namespace': 'mako'}]}}})
query = Mock(side_effect=['{}', 'ok', json.dumps({'stableId': 'bb'})])
window_namespace['hypr_query'] = query
window_namespace['time'] = types.SimpleNamespace(monotonic=Mock(side_effect=[10, 10.1, 10.2]), sleep=Mock())
assert window_namespace['switch_window']('bb', ('private_test', '/private')) == 'confirmed'
assert 'w.stable_id == "bb"' in query.call_args_list[1].args[0][1]
query.reset_mock(side_effect=True)
assert window_namespace['switch_window']('unsafe";', ('private_test', '/private')) == 'unavailable'
query.assert_not_called()
query.side_effect = ['{}', RuntimeError('window closed')]
window_namespace['time'].monotonic = Mock(return_value=10)
assert window_namespace['switch_window']('bb', ('private_test', '/private')) == 'closed'
assert query.call_count == 2
query.reset_mock(side_effect=True)
query.side_effect = ['{}', 'ok', json.dumps({'stableId': 'aa'})]
window_namespace['time'].monotonic = Mock(side_effect=[10, 10.1, 10.2, 11.2])
assert window_namespace['switch_window']('bb', ('private_test', '/private')) == 'unknown'
assert query.call_count == 3  # Layer release, one dispatch, one readback; no automatic retry.
print('Stable window identity, explicit session routing and focus readback checks passed')

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

gather_source = ast.parse((source / 'gather.py').read_text())
audio_helpers = [n for n in gather_source.body if isinstance(n, ast.FunctionDef)
                 and n.name in ('_wpctl_source_pretty', '_is_hidden_output_sink', '_parse_wpctl_status')]
audio_namespace = {'re': re}
exec(compile(ast.Module(body=audio_helpers, type_ignores=[]), '<audio status>', 'exec'), audio_namespace)
audio_status = '''PipeWire 'private-test'
Audio
 ├─ Sinks:
 │  *   20. Speakers [vol: 0.50]
 │      21. HDMI monitor [vol: 1.00]
 ├─ Sources:
 │  *   22. Microphone [vol: 0.30]
 ├─ Filters:
 │      23. Other filter [Audio/Source/Virtual]
 └─ Streams:
Video
 ├─ Sinks:
 │  *   30. Video output
 ├─ Sources:
 │  *   31. Webcam
 ├─ Filters:
 │  *   32. Camera filter [Video/Source]
 └─ Streams:
Settings
 └─ Default Configured Devices:
'''
parsed_audio = audio_namespace['_parse_wpctl_status'](audio_status)
assert [device['id'] for device in parsed_audio['sinks']] == [20], parsed_audio
assert [device['id'] for device in parsed_audio['sources']] == [22], parsed_audio
assert parsed_audio['sink_name'] == 'Speakers', parsed_audio
assert parsed_audio['source_name'] == 'Microphone', parsed_audio
print('Audio device status excludes video nodes and preserves active defaults')
