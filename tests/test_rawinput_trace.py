import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests/mouselook"))
import rawinput_trace

WINDOW_TID, RENDER_TID, GAME_PID = 1668, 1888, 0x120


def trace(tick_ms, tid, function, message, pid=GAME_PID, cls='trace'):
    return f"{tick_ms // 1000:3d}.{tick_ms % 1000:03d}:{pid:04x}:{tid:04x}:{cls}:rawinput:{function} {message}\n"


class RawInputTraceSummary(unittest.TestCase):
    """A session where Overwatch registers the mouse with NOLEGACY and reads it with GetRawInputData on its
    window thread, twice per frame at 140 FPS; Battle.net registers nothing and reads nothing."""

    def session(self, folder, reader=WINDOW_TID, function='NtUserGetRawInputData'):
        folder = Path(folder)
        lines = [trace(1000, WINDOW_TID, 'NtUserRegisterRawInputDevices', 'devices 0x5f0, device_count 1, device_size 16.'),
                 trace(1000, WINDOW_TID, 'NtUserRegisterRawInputDevices',
                       'device 0: page 0x1, usage 0x2, flags 0x230, target 0x10050.'),
                 trace(1000, WINDOW_TID, 'NtUserRegisterRawInputDevices', 'Unhandled flags 0x230 for device 0.', cls='fixme')]
        for second in range(2, 12):
            for i in range(280):
                tick = second * 1000 + i * 1000 // 280
                if function == 'NtUserGetRawInputData':
                    lines.append(trace(tick, reader, function, 'handle 0x2a, command 0x10000003, data 0x0, data_size 0x22fd10, header_size 24.'))
                    lines.append(trace(tick, reader, function, 'handle 0x2a, command 0x10000003, data 0x22fc00, data_size 0x22fd10, header_size 24.'))
                else:
                    lines.append(trace(tick, reader, function, 'data 0x22fc00, data_size 0x22fd10, header_size 24'))
        (folder / 'battlenet.log').write_text('wine: starting\n' + ''.join(lines))
        with open(folder / 'input-4242.jsonl', 'w') as f:
            for second in range(12):
                f.write(json.dumps({'exe': 'Overwatch.exe', 'consumer_tid': WINDOW_TID, 'setpos_tid': WINDOW_TID}) + '\n')
        with open(folder / 'frames-1664-run2.csv', 'w') as f:
            f.write('schema_version,present_boundary,unix_us,present_tid\n')
            for n in range(140 * 10):
                f.write(f'5,{n},{1_791_940_000_000_000 + n * 1_000_000 // 140},{RENDER_TID}\n')
        return folder

    def test_window_thread_reads_one_message_at_a_time(self):
        with tempfile.TemporaryDirectory() as folder:
            s = rawinput_trace.summarise(self.session(folder))
        self.assertEqual(len(s['registrations']), 1)
        reg = s['registrations'][0]
        self.assertEqual((reg['usage'], reg['flags'], reg['target']), ('mouse', 0x230, '0x10050'))
        self.assertEqual(reg['flag_names'], ['NOLEGACY', 'CAPTUREMOUSE'])
        reader = s['readers'][0]
        self.assertEqual((reader['tid'], reader['game']), (WINDOW_TID, True))
        self.assertEqual(reader['calls'], {'GetRawInputData read': 2800, 'GetRawInputData size': 2800})
        self.assertEqual(reader['reads_per_second_median'], 280)
        self.assertEqual(s['median_fps'], 140)
        self.assertIn('one message at a time', ' '.join(s['verdict']))
        self.assertIn('about 2.0 per frame', ' '.join(s['verdict']))
        self.assertEqual(len(s['fixmes']), 1)

    def test_other_thread_with_batches(self):
        with tempfile.TemporaryDirectory() as folder:
            s = rawinput_trace.summarise(self.session(folder, reader=0x7a0, function='NtUserGetRawInputBuffer'))
        reader = s['readers'][0]
        self.assertEqual((reader['tid'], reader['role']), (0x7a0, 'another thread'))
        self.assertIn('other than the one that receives', ' '.join(s['verdict']))

    def test_no_trace(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'battlenet.log').write_text('wine: starting\n')
            self.assertIn('--trace-rawinput', rawinput_trace.summarise(folder)['verdict'][0])


if __name__ == '__main__':
    unittest.main()
