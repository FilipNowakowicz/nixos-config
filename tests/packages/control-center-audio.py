"""Stable audio identity, effective-default evidence and guarded command outcomes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('audio', Path(sys.argv.pop(1)))
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


def node(idx, name, media='Audio/Sink', desc=None):
    return {'id': idx, 'type': 'PipeWire:Interface:Node', 'info': {'props': {
        'node.name': name, 'media.class': media, 'node.description': desc or name}}}


def metadata(effective='speakers', configured='absent'):
    return {'type': 'PipeWire:Interface:Metadata', 'props': {'metadata.name': 'default'}, 'metadata': [
        {'subject': 0, 'key': 'default.audio.sink', 'value': {'name': effective}},
        {'subject': 0, 'key': 'default.configured.audio.sink', 'value': {'name': configured}}]}


class AudioTests(unittest.TestCase):
    def setUp(self):
        self.objects = [node(20, 'speakers'), node(21, 'headphones'), node(22, 'mic', 'Audio/Source'),
                        node(23, 'effects', 'Audio/Source/Virtual'), node(24, 'webcam', 'Video/Source'),
                        node(25, 'inactive-hdmi', desc='HDMI monitor'), metadata()]
        self.command = ['pw-metadata', '-n', 'default', '0', 'default.configured.audio.sink',
                        json.dumps({'name': 'headphones'}), 'Spa:String:JSON']

    def test_effective_default_and_only_audio_nodes(self):
        state = audio.parse_devices(json.dumps(self.objects))
        self.assertEqual([n['name'] for n in state['sinks']], ['speakers', 'headphones'])
        self.assertEqual([n['name'] for n in state['sources']], ['mic', 'effects'])
        self.assertEqual(state['sink_node_name'], 'speakers')
        self.assertIsNone(state['source_node_name'])

    def test_missing_and_ambiguous_defaults_cannot_confirm(self):
        self.objects[-1] = metadata('absent')
        self.assertIsNone(audio.parse_devices(json.dumps(self.objects))['sink_node_name'])
        self.objects[-1] = metadata('speakers')
        self.objects.append(node(99, 'speakers'))
        state = audio.parse_devices(json.dumps(self.objects))
        self.assertIsNone(state['sink_node_name'])
        self.assertNotIn('speakers', [n['name'] for n in state['sinks']])

    def test_numeric_id_reuse_does_not_select_replacement(self):
        self.objects[1] = node(21, 'unrelated')
        with patch.object(audio.subprocess, 'run', return_value=Mock(returncode=0, stdout=json.dumps(self.objects))) as run:
            self.assertEqual(audio.write_default(self.command), 'failed')
            self.assertEqual(run.call_count, 1)  # Discovery only; no write.

    def test_correct_name_with_changed_id_is_accepted(self):
        self.objects[1]['id'] = 101
        with patch.object(audio.subprocess, 'run', side_effect=[Mock(returncode=0, stdout=json.dumps(self.objects)), Mock(returncode=0)]) as run:
            self.assertEqual(audio.write_default(self.command), 'ok')
            self.assertEqual(run.call_args_list[-1].args[0], self.command)

    def test_wrong_media_class_and_invalid_discovery_do_not_write(self):
        for contents in ('broken json', '{}', json.dumps([node(21, 'headphones', 'Video/Source')])):
            with patch.object(audio.subprocess, 'run', return_value=Mock(returncode=0, stdout=contents)) as run:
                self.assertEqual(audio.write_default(self.command), 'failed')
                self.assertEqual(run.call_count, 1)

    def test_rejection_and_timeout_are_not_success_or_automatic_retry(self):
        for effect, expected in ((Mock(returncode=1), 'failed'), (subprocess.TimeoutExpired(self.command, 8), 'unknown')):
            with patch.object(audio.subprocess, 'run', side_effect=[Mock(returncode=0, stdout=json.dumps(self.objects)), effect]) as run:
                self.assertEqual(audio.write_default(self.command), expected)
                self.assertEqual(run.call_count, 2)


unittest.main()
